import Foundation

/// Pure state for the three independent sampling cadences. Missing values expire on
/// their own cadence (the third consecutive miss), never on another metric's timer.
///
/// Status rules: a fresh value takes the read's quality
/// (estimated for a fallback source or a fault); a held value (≤ 2 misses) keeps its status; the 3rd miss turns
/// the metric unavailable with that miss's fault (`firstSample` if it never had a value, else `apiError` when the
/// sampler gave no reason). Temperatures also pass `StuckDetector` and `JumpGuard`. A nil sample means "not
/// sampled this tick" (e.g. CPU % in menu-bar-only mode): it ages the held value but carries no fault.
public struct Aggregator: Sendable {
    private struct Held<Value: Sendable>: Sendable {
        var value: Value?
        var misses = 0
        mutating func update(_ next: Value?, blend: (Value, Value) -> Value = { _, new in new }) {
            guard let next else {
                misses += 1
                if misses > 2 { value = nil }
                return
            }
            value = value.map { blend($0, next) } ?? next
            misses = 0
        }
        mutating func clear() { value = nil; misses = 3 }
    }
    private struct Tracked<Value: Sendable>: Sendable {
        var held = Held<Value>()
        var status = MetricStatus.unavailable(.firstSample)
        var everHadValue = false
        var value: Value? { held.value }

        mutating func update(_ sample: Sample<Value>?, blend: (Value, Value) -> Value = { _, new in new }) {
            guard let sample else {
                held.update(nil)
                if held.value == nil, status.quality != .unavailable {
                    status = .unavailable(.firstSample, source: status.source)
                }
                return
            }
            if let value = sample.value {
                held.update(value, blend: blend)
                everHadValue = true
                status = sample.quality == .estimated ? .estimated(sample.source, fault: sample.fault)
                                                      : .live(sample.source)
            } else {
                miss(sample.fault, source: sample.source)
            }
        }
        mutating func miss(_ fault: MetricFault?, source: MetricSource) {
            held.update(nil)
            guard held.value == nil else { return }
            status = .unavailable(fault ?? (everHadValue ? .apiError : .firstSample), source: source)
        }
        mutating func clear(_ fault: MetricFault, source: MetricSource) {
            held.clear()
            status = .unavailable(fault, source: source)
        }
    }
    private var cpu = Tracked<Double>(), gpu = Tracked<Double>()
    private var cpuTemp = Tracked<TempStat>(), gpuTemp = Tracked<TempStat>()
    private var memory = Tracked<MemoryStat>(), disk = Tracked<DiskStat>(), thermal = Tracked<ThermalLevel>()
    private var cpuJump = JumpGuard(), gpuJump = JumpGuard()
    private var cpuStuck: StuckDetector, gpuStuck: StuckDetector
    /// Set when a temperature family entered the stuck state; the engine resets the SMC sampler once and
    /// clears the flag with `consumeTemperatureReset()`.
    public private(set) var temperatureResetRequested = false
    private struct ProcessState: Sendable {
        var row: ProcRow
        var lastSeen: Int
    }
    private var processes: [Int32: ProcessState] = [:]
    private var entered: [Int32: Int] = [:]
    private var selected: [ProcRow] = []
    private var processTick = 0
    private var processMisses = 0
    private var processesEverScanned = false
    public private(set) var snapshot: Snapshot

    public init(machineName: String, chipName: String, identityStatus: MetricStatus = .live,
                stuckDetector: StuckDetector = StuckDetector(), timestamp: Date = Date()) {
        cpuStuck = stuckDetector
        gpuStuck = stuckDetector
        let measuring = MetricStatus.unavailable(.firstSample)
        snapshot = Snapshot(timestamp: timestamp, machineName: machineName, chipName: chipName,
                            cpuPercent: nil, gpuPercent: nil, cpuTemp: nil, gpuTemp: nil,
                            memory: nil, disk: nil, topProcesses: [], thermal: nil,
                            status: SnapshotStatus(cpuPercent: measuring, gpuPercent: measuring, cpuTemp: measuring,
                                                   gpuTemp: measuring, memory: measuring, disk: measuring,
                                                   processes: measuring, thermal: measuring, identity: identityStatus))
    }

    /// Pre-contract entry point: nil means a miss with no reason. Kept for tests and old call sites.
    public mutating func updateFast(cpu: Double?, gpu: Double?, cpuTemp: TempStat?, gpuTemp: TempStat?,
                                    memory: MemoryStat?, thermal: ThermalLevel?, at date: Date) {
        updateFast(cpu: Sample(value: cpu, source: .hostProcessorInfo),
                   gpu: Sample(value: gpu, source: .ioAccelerator),
                   temperatures: TemperatureSample(cpu: Sample(value: cpuTemp, source: .chipMap),
                                                   gpu: Sample(value: gpuTemp, source: .chipMap)),
                   memory: Sample(value: memory, source: .hostStatistics),
                   thermal: Sample(value: thermal, source: .processInfo), at: date)
    }

    /// Status-aware fast tick. Pass nil for a metric that was not sampled on this tick.
    public mutating func updateFast(cpu: Sample<Double>?, gpu: Sample<Double>?, temperatures: TemperatureSample?,
                                    memory: Sample<MemoryStat>?, thermal: Sample<ThermalLevel>?, at date: Date) {
        self.cpu.update(cpu.map(Self.checkedPercent), blend: Self.ema)
        self.gpu.update(gpu.map(Self.checkedPercent), blend: Self.ema)
        let rawCPU = cpu?.value.flatMap { $0.isFinite ? $0 : nil }
        if let temperatures {
            Self.updateTemperature(&cpuTemp, temperatures.cpu, jump: &cpuJump, stuck: &cpuStuck,
                                   cpuPercent: rawCPU, resetRequested: &temperatureResetRequested)
            Self.updateTemperature(&gpuTemp, temperatures.gpu, jump: &gpuJump, stuck: &gpuStuck,
                                   cpuPercent: rawCPU, resetRequested: &temperatureResetRequested)
        } else {
            cpuTemp.update(nil)
            gpuTemp.update(nil)
        }
        self.memory.update(memory.map(Self.checkedMemory))
        self.thermal.update(thermal)
        snapshot.cpuPercent = self.cpu.value
        snapshot.gpuPercent = self.gpu.value
        snapshot.cpuTemp = cpuTemp.value
        snapshot.gpuTemp = gpuTemp.value
        snapshot.memory = self.memory.value
        snapshot.thermal = self.thermal.value
        snapshot.status.cpuPercent = self.cpu.status
        snapshot.status.gpuPercent = self.gpu.status
        snapshot.status.cpuTemp = cpuTemp.status
        snapshot.status.gpuTemp = gpuTemp.status
        snapshot.status.memory = self.memory.status
        snapshot.status.thermal = self.thermal.status
        snapshot.timestamp = date
    }

    public mutating func updateDisk(_ disk: DiskStat?, at date: Date) {
        updateDisk(Sample(value: disk, source: .volumeCapacity), at: date)
    }

    public mutating func updateDisk(_ sample: Sample<DiskStat>, at date: Date) {
        disk.update(Self.checkedDisk(sample))
        snapshot.disk = disk.value
        snapshot.status.disk = disk.status
        snapshot.timestamp = date
    }

    /// Identity (machine and chip name) is read once at start; its status is set by the engine.
    public mutating func setIdentityStatus(_ status: MetricStatus) { snapshot.status.identity = status }

    /// Call on `systemDidWake` and on resume after a pause longer than 10 s.
    public mutating func resetDetectors() {
        cpuJump.reset(); gpuJump.reset()
        cpuStuck.reset(); gpuStuck.reset()
    }

    /// True once per stuck episode: the engine should `reset()` the temperature sampler.
    public mutating func consumeTemperatureReset() -> Bool {
        defer { temperatureResetRequested = false }
        return temperatureResetRequested
    }

    private static func updateTemperature(_ tracked: inout Tracked<TempStat>, _ sample: Sample<TempStat>,
                                          jump: inout JumpGuard, stuck: inout StuckDetector, cpuPercent: Double?,
                                          resetRequested: inout Bool) {
        guard let value = sample.value else { tracked.update(sample, blend: smoothTemp); return }
        guard value.peak.isFinite, value.average.isFinite else {
            tracked.miss(.nonFinite, source: sample.source); return
        }
        guard TempStat.validRange.contains(value.peak), TempStat.validRange.contains(value.average) else {
            tracked.miss(.outOfRange, source: sample.source); return
        }
        switch stuck.observe(peak: value.peak, average: value.average, cpuPercent: cpuPercent) {
        case .becameStuck:
            resetRequested = true
            tracked.clear(.stuck, source: sample.source); return
        case .stillStuck:
            tracked.clear(.stuck, source: sample.source); return
        case .normal:
            break
        }
        if jump.check(value.peak) == .hold { tracked.miss(.jump, source: sample.source); return }
        tracked.update(sample, blend: smoothTemp)
    }

    private static func checkedPercent(_ sample: Sample<Double>) -> Sample<Double> {
        guard let value = sample.value else { return sample }
        guard value.isFinite else { return .failure(.nonFinite, source: sample.source) }
        guard (0...100).contains(value) else { return .failure(.outOfRange, source: sample.source) }
        return sample
    }
    private static func checkedMemory(_ sample: Sample<MemoryStat>) -> Sample<MemoryStat> {
        guard let value = sample.value else { return sample }
        guard value.total > 0, Double(value.used) <= Double(value.total) * 1.05 else {
            return .failure(.outOfRange, source: sample.source)
        }
        return sample
    }
    private static func checkedDisk(_ sample: Sample<DiskStat>) -> Sample<DiskStat> {
        guard let value = sample.value else { return sample }
        guard value.total > 0, value.free <= value.total else { return .failure(.outOfRange, source: sample.source) }
        return sample
    }

    /// nil is a failed scan; [] is a successful scan with no surviving processes.
    /// Every incoming pid participates, including rows below the displayed top three.
    /// A carried observation remains eligible, but only freshPIDs receive another EMA step.
    public mutating func updateProcesses(_ rows: [ProcRow]?, at date: Date, freshPIDs: Set<Int32>? = nil) {
        updateProcesses(Sample(value: rows, source: .libprocAndPS), at: date, freshPIDs: freshPIDs)
    }

    /// Status-aware process tick. `sample.value == nil` is a failed scan (fault says why).
    public mutating func updateProcesses(_ sample: Sample<[ProcRow]>, at date: Date, freshPIDs: Set<Int32>? = nil) {
        processTick += 1
        defer { snapshot.topProcesses = selected; snapshot.timestamp = date }
        guard let rows = sample.value else {
            processMisses += 1
            forgetOldProcesses()
            // The 2-miss hold protects an existing observation; with no successful scan yet there is nothing to
            // hold, so the real fault shows at once (Astra X5).
            if processMisses > 2 || !processesEverScanned {
                if processMisses > 2 { selected = []; entered = [:] }
                snapshot.status.processes = .unavailable(
                    sample.fault ?? (processesEverScanned ? .apiError : .firstSample), source: sample.source)
            }
            return
        }
        processMisses = 0
        processesEverScanned = true
        snapshot.status.processes = sample.quality == .estimated ? .estimated(sample.source, fault: sample.fault)
                                                                 : .live(sample.source)
        var present = Set<Int32>()
        for var row in rows where row.pid != 0 && row.cpuPercent.isFinite && row.cpuPercent >= 0 {
            guard present.insert(row.pid).inserted else { continue }
            if let prior = processes[row.pid], prior.row.startTime == row.startTime {
                row.cpuPercent = freshPIDs?.contains(row.pid) == false
                    ? prior.row.cpuPercent : Self.ema(prior.row.cpuPercent, row.cpuPercent)
            } else { entered[row.pid] = nil }
            processes[row.pid] = ProcessState(row: row, lastSeen: processTick)
        }
        processes = processes.filter { present.contains($0.key) }
        // Entry tick plus the following process tick are guaranteed membership.
        let retained = Set(entered.compactMap { pid, tick in
            present.contains(pid) && processTick - tick < 2 ? pid : nil
        })
        var next = retained.compactMap { processes[$0]?.row }
        let slots = max(0, 3 - next.count)
        var challengers: [ProcRow] = []
        if slots > 0 {
            // Only three places are visible; avoid sorting the entire process table.
            for pid in present where !retained.contains(pid) {
                guard let row = processes[pid]?.row else { continue }
                if challengers.count == slots, let last = challengers.last, !Self.before(row, last) { continue }
                let index = challengers.firstIndex { Self.before(row, $0) } ?? challengers.count
                challengers.insert(row, at: index)
                if challengers.count > slots { challengers.removeLast() }
            }
        }
        next += challengers
        next.sort(by: Self.before)
        let pids = Set(next.map(\.pid))
        entered = entered.filter { pids.contains($0.key) }
        for row in next where entered[row.pid] == nil { entered[row.pid] = processTick }
        selected = next
    }

    private mutating func forgetOldProcesses() {
        processes = processes.filter { processTick - $0.value.lastSeen < 3 }
    }

    /// Names may be resolved lazily after ranking. Updating display metadata must
    /// not advance a process tick, apply EMA again, or alter membership guarantees.
    public mutating func updateProcessNames(_ names: [Int32: String]) {
        for (pid, name) in names { processes[pid]?.row.name = name }
        for index in selected.indices {
            if let name = names[selected[index].pid] { selected[index].name = name }
        }
        snapshot.topProcesses = selected
    }
    private static func before(_ a: ProcRow, _ b: ProcRow) -> Bool {
        a.cpuPercent == b.cpuPercent ? a.pid < b.pid : a.cpuPercent > b.cpuPercent
    }
    private static func ema(_ old: Double, _ new: Double) -> Double { old * 0.5 + new * 0.5 }
    private static func smoothTemp(_ old: TempStat, _ new: TempStat) -> TempStat {
        TempStat(peak: ema(old.peak, new.peak), average: ema(old.average, new.average), sensorCount: new.sensorCount)
    }
}

/// Visible precision only. JSON string-array encoding avoids collisions from process
/// names containing separators; POSIX formatting keeps the key independent of locale.
public func displayKey(_ s: Snapshot) -> String {
    func number(_ value: Double?, decimals: Int = 0) -> String { DisplayFormat.number(value, decimals: decimals) }
    var fields = [s.machineName, s.chipName, number(s.cpuPercent), number(s.gpuPercent),
                  number(s.cpuTemp?.peak), number(s.cpuTemp?.average),
                  number(s.gpuTemp?.peak), number(s.gpuTemp?.average),
                  s.thermal?.rawValue ?? "—", String(Int(floor(s.timestamp.timeIntervalSince1970 / 60)))]
    func gib(_ bytes: UInt64) -> String { number(Double(bytes) / 1_073_741_824, decimals: 1) }
    if let m = s.memory { fields += [gib(m.wired), gib(m.active), gib(m.compressed), DisplayFormat.memory(m)] }
    else { fields.append("no-memory") }
    if let d = s.disk {
        // Keep sub-point bar changes at the widest (328 pt) track resolution,
        // even when the TB labels round to the same tenth.
        let usedPerMille = d.total > 0 ? Int(Double(d.used) / Double(d.total) * 1000) : 0
        fields += [d.volumeName, DisplayFormat.storage(d.total), DisplayFormat.storage(d.free),
                   DisplayFormat.storage(d.used), String(usedPerMille)]
    } else { fields.append("no-disk") }
    fields.append("processes")
    for row in s.topProcesses {
        fields += [row.name, number(row.cpuPercent), number(row.cpuPercent, decimals: 1), DisplayFormat.processMemory(row.residentBytes),
                   String(DisplayFormat.hot(row.cpuPercent))]
    }
    // A status change (quality or fault) always publishes, even when the visible numbers did not move.
    fields.append("status")
    fields += s.status.keys
    return String(data: (try? JSONEncoder().encode(fields)) ?? Data(), encoding: .utf8) ?? ""
}
