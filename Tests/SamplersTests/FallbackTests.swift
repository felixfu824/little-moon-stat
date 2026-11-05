import Foundation
import Darwin
import Testing
import MonitorCore
@testable import Samplers

private final class Reader: SMCReading {
    var inventory: Set<String> = ["Tp00", "Tp04", "TpZZ", "Te05", "Tg00", "Tg01", "TA00"]
    var totalKeyCount: Int { inventory.count }
    var rejected: Set<String> = []
    var calls: [String: Int] = [:]
    var opens = 0
    var unavailable = false
    var transportAt: Int?
    var reads = 0
    var values: [String: Double] = [:]
    func reopen() throws { opens += 1; if unavailable { throw SMCReadFailure.unavailable } }
    func close() {}
    func readTemperature(key: String) -> Result<Double, SMCReadFailure> {
        calls[key, default: 0] += 1; reads += 1
        if reads == transportAt { return .failure(.transport) }
        return rejected.contains(key) ? .failure(.rejected) : .success(values[key] ?? 50)
    }
}

@Test func rejectedKeyDoesNotReopenAndFamilyFallsToTpUnionTe() {
    let reader = Reader(); reader.rejected = ["Tp00"]
    let sampler = SMCTemperatureSampler(chipName: "Apple M5 Max", reader: reader)
    let sample = sampler.sampleTemperaturesStatus()
    #expect(sample.cpu.source == .genericFamily && sample.cpu.fault == .familyMissing)
    #expect(sample.cpu.value?.sensorCount == 3) // Tp04 + TpZZ + Te05
    #expect(sample.gpu.source == .chipMap && sample.gpu.value?.sensorCount == 2)
    #expect(reader.opens == 1)
    for _ in 0..<60 { _ = sampler.sampleTemperaturesStatus() }
    #expect(reader.opens == 1)
    #expect((reader.calls["Tp00"] ?? 0) < 20)
    #expect(reader.calls["Tg00"] == 61)
    reader.rejected = []
    for _ in 0..<160 { _ = sampler.sampleTemperaturesStatus() }
    #expect(sampler.sampleTemperaturesStatus().cpu.source == .chipMap)
}

@Test func poweredDownKeysDoNotDemoteKnownFamily() {
    let reader = Reader(); reader.values["Tp00"] = 0
    let sample = SMCTemperatureSampler(chipName: "Apple M5 Max", reader: reader).sampleTemperaturesStatus()
    #expect(sample.cpu.source == .chipMap && sample.cpu.value?.sensorCount == 1)
}

@Test func unavailableSMCUsesTickBackoffAndPreservesMetadataOnTransport() {
    let reader = Reader(); reader.unavailable = true
    let sampler = SMCTemperatureSampler(chipName: "Apple M5 Max", reader: reader)
    for _ in 0..<30 { _ = sampler.sampleTemperaturesStatus() }
    #expect(reader.opens == 5) // initial + offsets 1,1,1,15; next at 33
    let transport = Reader(); transport.transportAt = 3
    let diagnostic = SMCTemperatureSampler(chipName: "Apple M5 Max", reader: transport)
    let result = diagnostic.readAll()
    #expect(result.count == transport.inventory.count)
    #expect(result.filter { (try? $0.value.get()) != nil }.count == 2)
    #expect(diagnostic.inventory == transport.inventory)
}

@Test(arguments: chipFixtures + liveChipFixtures) func fallbackIncludesEfficiencyWithoutChangingKnownMaps(f: ChipFixture) {
    let generic = SMCSensorSelection.select(inventory: f.inventory, chipName: "Apple M99")
    #expect(generic.cpuKeys == f.inventory.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") })
    #expect(generic.gpuKeys == f.inventory.filter { $0.hasPrefix("Tg") })
    let mapped = SMCSensorSelection.select(inventory: f.inventory, chipName: f.chip)
    let map = SMCSensorMap.forChip(f.chip)
    let cpu = Set(f.inventory.filter(map.isCPU)), gpu = Set(f.inventory.filter(map.isGPU))
    if map.verified && cpu.count >= 2 { #expect(mapped.cpuKeys == cpu && mapped.cpuSource == .chipMap) }
    if map.verified && gpu.count >= 2 { #expect(mapped.gpuKeys == gpu && mapped.gpuSource == .chipMap) }
}

@Test func psDeadlineKillsAndReapsOnlyOwnedChild() {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/slow_ps.sh").path
    var child: pid_t = 0
    let start = ProcessInfo.processInfo.systemUptime
    let result = PSRunner.runStatus(.all, withName: false, executable: script, timeout: 0.1, onSpawn: { child = $0 })
    #expect(result.result == nil && result.fault == .timeout)
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    #expect(child > 0)
    var status: Int32 = 0
    #expect(waitpid(child, &status, WNOHANG) == -1 && errno == ECHILD)
    #expect(kill(child, 0) == -1 && errno == ESRCH)
    #expect(PSRunner.runStatus(.all, withName: false, executable: "/nonexistent/wpv-ps").fault == .psUnavailable)
}

private final class DiagnosticReader: SMCDiagnosticReading {
    let inventory: Set<String> = ["Tp00", "Tp04", "Tp01", "Tp05", "Tg00", "Tg01", "TA00"]
    var rejected: Set<String> = []
    var phase = "idle"
    func readAll() -> [(key: String, value: Result<Double, SMCReadFailure>)] {
        inventory.sorted().map { key in
            let cpu = key.hasPrefix("Tp")
            let value = phase == "cpu" ? (cpu ? 70.0 : 45.0) : phase == "gpu" ? (cpu ? 45.0 : 70.0) : 40.0
            return (key, rejected.contains(key) ? .failure(.rejected) : .success(value))
        }
    }
}
private func report(_ reader: DiagnosticReader) throws -> SensorReport {
    let runner = SensorReportRunner(cancellation: SensorReportCancellation(), reader: reader)
    runner.diagnosticPause = { _ in }
    runner.diagnosticPhase = { [unowned runner] phase, injected in
        reader.phase = phase
        return try runner.median(injected)
    }
    return try runner.run()
}
@Test func r3UnrelatedRejectedKeyCompletesAndEncodesEveryPhaseNull() throws {
    let reader = DiagnosticReader(); reader.rejected = ["TA00"]
    let report = try report(reader)
    #expect(report.cpuVerdict.status == "pass" && report.gpuVerdict.status == "pass")
    #expect(report.unreadableKeys == ["TA00"])
    let bad = try #require(report.readings.first { $0.key == "TA00" })
    #expect(bad.idle == nil && bad.cpuLoaded == nil && bad.gpuIdle == nil && bad.gpuLoaded == nil)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    #expect(json["appStatus"] is NSNull)
    #expect(json["hvVMMPresent"] is Bool)
}
@Test func r3SelectedRejectedKeyIsInconclusive() throws {
    let reader = DiagnosticReader(); reader.rejected = ["Tp00", "Tp01"] // selected on either tested Mac
    let report = try report(reader)
    #expect(report.cpuVerdict.status == "inconclusive")
    #expect(report.gpuVerdict.status == "pass")
    #expect(report.unreadableKeys == ["Tp00", "Tp01"])
}
@Test func r3UnavailableDeviceThrowsAndPartialTransportStillFormsMedian() throws {
    let reader = DiagnosticReader(); reader.rejected = reader.inventory
    #expect(throws: SensorReportError.self) { try report(reader) }
    let transport = Reader(); transport.transportAt = 3
    let sampler = SMCTemperatureSampler(chipName: "Apple M5 Max", reader: transport)
    let runner = SensorReportRunner(cancellation: SensorReportCancellation(), reader: sampler)
    runner.diagnosticPause = { _ in }
    let median = try runner.median(sampler)
    #expect(median.count == 2)
}

private final class FakeSet: CPUUsageSampling, GPUUsageSampling, TemperatureSampling, MemorySampling, DiskSampling, ProcessSampling, ThermalSampling {
    var reads: [String: Int] = [:]
    var processRows: [ProcRow] = []
    var cpuSamples: [Sample<Double>] = []
    func sampleCPU() -> Double? { fatalError("legacy CPU path") }
    func sampleGPU() -> Double? { fatalError("legacy GPU path") }
    func sampleTemperatures() -> (cpu: TempStat?, gpu: TempStat?) { fatalError("legacy temperatures path") }
    func sampleMemory() -> MemoryStat? { fatalError("legacy memory path") }
    func sampleDisk() -> DiskStat? { fatalError("legacy disk path") }
    func sampleProcesses(limit: Int) -> [ProcRow] { fatalError("legacy processes path") }
    func sampleThermal() -> ThermalLevel? { fatalError("legacy thermal path") }
    func sampleCPUStatus() -> Sample<Double> {
        reads["cpu", default: 0] += 1
        return cpuSamples.isEmpty ? .failure(.wakeTransient, source: .hostProcessorInfo) : cpuSamples.removeFirst()
    }
    func sampleGPUStatus() -> Sample<Double> { reads["gpu", default: 0] += 1; return .failure(.virtualMachine, source: .ioAccelerator) }
    func sampleTemperaturesStatus() -> TemperatureSample {
        reads["temp", default: 0] += 1
        return TemperatureSample(cpu: Sample(value: TempStat(peak: 60, average: 55, sensorCount: 2), source: .genericFamily, fault: .unknownChip), gpu: .failure(.familyMissing, source: .genericFamily))
    }
    func sampleMemoryStatus() -> Sample<MemoryStat> { reads["ram", default: 0] += 1; return .failure(.apiError, source: .hostStatistics) }
    func sampleDiskStatus() -> Sample<DiskStat> { reads["disk", default: 0] += 1; return .failure(.apiError, source: .volumeCapacity) }
    func sampleProcessesStatus(limit: Int) -> Sample<[ProcRow]> { reads["procs", default: 0] += 1; return Sample(value: processRows, source: .libprocOnly, fault: .timeout) }
    func sampleThermalStatus() -> Sample<ThermalLevel> { reads["thermal", default: 0] += 1; return .failure(.apiError, source: .processInfo) }
    var set: SamplerSet { SamplerSet(cpu: self, gpu: self, temperatures: self, memory: self, disk: self, processes: self, thermal: self) }
}
@Test func engineUsesOnlyStatusMethodsAndPreservesFaults() throws {
    let fake = FakeSet()
    let injected = SamplingState(samplerSet: fake.set)
    let queue = DispatchQueue(label: "wpv.injected"); queue.suspend()
    defer { injected.stop(); queue.resume() }
    var last: Snapshot?
    injected.start(on: queue, resetSMC: false) { last = $0 }
    injected.fastTick(); injected.fastTick(); injected.fastTick()
    let snapshot = try #require(last)
    #expect(snapshot.status.cpuTemp == .estimated(.genericFamily, fault: .unknownChip))
    #expect(snapshot.status.cpuPercent.fault == .wakeTransient)
    #expect(snapshot.status.gpuPercent.fault == .virtualMachine)
    #expect(snapshot.status.processes == .estimated(.libprocOnly, fault: .timeout))
    #expect(fake.reads["cpu"] == 4 && fake.reads["disk"] == 1 && fake.reads["procs"] == 1)
}
@Test func injectedEngineKeepsClosedMenuBarCadenceGates() {
    let fake = FakeSet(), queue = DispatchQueue(label: "wpv.menu"); queue.suspend()
    let state = SamplingState(samplerSet: fake.set)
    defer { state.stop(); queue.resume() }
    state.start(on: queue, resetSMC: false, details: false) { _ in }
    #expect(fake.reads["temp"] == 1 && fake.reads["ram"] == 1)
    #expect(fake.reads["cpu"] == nil && fake.reads["gpu"] == nil && fake.reads["procs"] == nil && fake.reads["disk"] == nil)
}

@Test func psTimeoutBackoffSkipsTwoDiscoveriesThenFiveMinutes() {
    for cores in [8, 18] {
        let interval = SamplingCadence.processInterval(logicalCoreCount: cores)
        let discovery = SamplingCadence.discoveryEvery(processInterval: interval)
        var retry = HybridProcessSource.retrySchedule(discoveryEvery: discovery, processInterval: interval)
        for failure in 1...3 {
            retry.recordFailure()
            #expect(retry.failures == failure)
            let gap = failure < 3 ? 3 : Int(ceil(300 / (interval * Double(discovery))))
            for _ in 1..<gap { let attempt = retry.shouldAttempt(); #expect(!attempt) }
            let attempt = retry.shouldAttempt(); #expect(attempt)
        }
        retry.recordSuccess(); #expect(retry.failures == 0)
        let attempt = retry.shouldAttempt(); #expect(attempt)
    }
}

@Test func launchFaultParserAndNonFiniteInjectionNeverPollFailedSource() {
    let fake = FakeSet()
    let config = FaultConfiguration("cpu:nan,gpu:range,cpuTemp:unavailable,gpuTemp:stuck,ram:unavailable,disk:range,procs:unavailable,thermal:unavailable,invalid:stuck")
    #expect(config.modes.count == 8)
    let samplers = FaultInjectingSamplers(base: fake.set, configuration: config)
    #expect(samplers.sampleCPUStatus().value?.isNaN == true)
    #expect(samplers.sampleGPUStatus().value == 140)
    let temps = samplers.sampleTemperaturesStatus()
    #expect(temps.cpu.value == nil && temps.cpu.fault == .apiError)
    #expect(temps.gpu.value?.peak == 60)
    #expect(samplers.sampleMemoryStatus().fault == .apiError)
    #expect(samplers.sampleDiskStatus().value?.free == 200)
    #expect(samplers.sampleProcessesStatus(limit: 3).fault == .apiError)
    #expect(samplers.sampleThermalStatus().fault == .apiError)
    #expect(fake.reads.isEmpty)
}

private final class BadRateSource: ProcessSource {
    var tick = 0
    func read() -> ProcessReading? {
        defer { tick += 1 }
        let bad = tick >= 2 ? Double(ProcessInfo.processInfo.processorCount) * 1_000 : Double(tick) * 8
        let at = UInt64(tick * 8 + 1) * 1_000_000_000
        return ProcessReading(entries: [
            1: ProcessEntry(pid: 1, name: "bad", cpuSeconds: bad, residentBytes: 1, atNanos: at),
            2: ProcessEntry(pid: 2, name: "good", cpuSeconds: Double(tick) * 4, residentBytes: 1, atNanos: at)
        ])
    }
    func name(for pid: Int32) -> String? { nil }
}
@Test func invalidProcessRowDropsItsCarriedRateWithoutDroppingGoodRows() {
    let sampler = ProcessSampler(source: BadRateSource())
    _ = sampler.sampleProcesses(limit: .max)
    #expect(Set(sampler.sampleProcesses(limit: .max).map(\.pid)) == [1, 2])
    #expect(sampler.sampleProcesses(limit: .max).map(\.pid) == [2])
}

@Test(arguments: [Double.nan, Double.infinity, -1, 300])
func malformedMappedPayloadFallsBackAndRetainsFault(value: Double) {
    let reader = Reader(); reader.values["Tp00"] = value
    let sampler = SMCTemperatureSampler(chipName: "Apple M5 Max", reader: reader)
    let sample = sampler.sampleTemperaturesStatus()
    #expect(sample.cpu.source == .genericFamily)
    #expect(sample.cpu.value?.sensorCount == 3)
    #expect(sample.cpu.fault == (value.isFinite ? .outOfRange : .nonFinite))
    for _ in 0..<60 { _ = sampler.sampleTemperaturesStatus() }
    #expect((reader.calls["Tp00"] ?? 0) < 20)
    #expect(reader.opens == 1)
    #expect(sampler.sampleTemperaturesStatus().cpu.fault == sample.cpu.fault)
}

@Test func detailToggleAndShortPausePreserveStuckEpisodeAndHeldStatus() throws {
    let fake = FakeSet(), queue = DispatchQueue(label: "wpz.toggle")
    fake.processRows = [ProcRow(pid: 42, name: "held process", cpuPercent: 7, residentBytes: 1024)]
    queue.suspend()
    let state = SamplingState(samplerSet: fake.set, faults: FaultConfiguration("cpuTemp:stuck"))
    defer { state.stop(); queue.resume() }
    var latest: Snapshot?
    let publish: (Snapshot) -> Void = { latest = $0 }
    state.start(on: queue, resetSMC: false, publish: publish)
    for _ in 0..<310 { state.fastTick() }
    #expect(latest?.status.cpuTemp.fault == .stuck)
    let before = try #require(latest)
    #expect(before.topProcesses.map(\.pid) == [42])
    state.setDetails(false, on: queue)
    #expect(latest?.status == before.status)
    #expect(latest?.topProcesses == before.topProcesses)
    state.setDetails(true, on: queue)
    #expect(latest?.status == before.status)
    #expect(latest?.topProcesses == before.topProcesses)
    state.stop()
    state.start(on: queue, resetSMC: false, publish: publish)
    #expect(latest?.status.cpuTemp.fault == .stuck)
    state.fastTick()
    #expect(latest?.status.cpuTemp.fault == .stuck)
    state.start(on: queue, resetSMC: true, publish: publish)
    #expect(latest?.status.cpuTemp.fault != .stuck)
}

@Test func detailToggleRebaselinesProcessesWithoutReplacingBackoffPolicy() {
    let fake = FakeSet(), set = fake.set
    let hybrid = HybridProcessSource(discoveryEvery: 3)
    hybrid.survey = { (ProcessReading(entries: [:]), [99999]) }
    var attempts = 0
    hybrid.readPS = { _, _ in attempts += 1; return PSRunner.Outcome(result: nil, fault: .timeout) }
    set.processSource = EngineProcessSource(source: hybrid)
    set.processes = ProcessSampler(source: set.processSource)
    set.injected = false
    let source = set.processSource
    let state = SamplingState(samplerSet: set), queue = DispatchQueue(label: "wpz.backoff")
    queue.suspend()
    defer { state.stop(); queue.resume() }
    // Reach the long (five-minute) rung before changing engine visibility.
    for _ in 0..<100 {
        _ = hybrid.read()
        if hybrid.retry.failures == 3 { break }
    }
    #expect(attempts == 3 && hybrid.retry.failures == 3)
    state.start(on: queue, resetSMC: false) { _ in }
    #expect(attempts == 3 && hybrid.retry.failures == 3)
    for _ in 0..<100 { state.setDetails(false, on: queue); state.setDetails(true, on: queue) }
    state.stop()
    state.start(on: queue, resetSMC: false) { _ in }
    #expect(set.processSource === source)
    #expect(attempts == 3 && hybrid.retry.failures == 3)
    #expect(hybrid.metricStatus.fault == .timeout)
}

@Test func startupPublishesOnlyAfterFirstFastTick() {
    let fake = FakeSet(), queue = DispatchQueue(label: "wpz.initial")
    queue.suspend()
    let state = SamplingState(samplerSet: fake.set)
    defer { state.stop(); queue.resume() }
    var snapshots: [Snapshot] = []
    state.start(on: queue, resetSMC: false) { snapshots.append($0) }
    #expect(snapshots.count == 1)
    #expect(snapshots.first?.status.cpuTemp.fault == .unknownChip)
    #expect(snapshots.first?.status.disk.fault == .apiError)
    #expect(fake.reads["temp"] == 1)
}

@Test func vanishedWatchedPIDLeavesSurvivorAndRetryHistoryIntact() {
    let source = HybridProcessSource(discoveryEvery: 10, maxWatched: 2)
    source.survey = { (ProcessReading(entries: [:]), [11111, 22222]) }
    var discovery = 0, vanish = false
    source.readPS = { scope, _ in
        let output: String
        switch scope {
        case .pid(let pid):
            output = vanish && pid == 11111 ? "" : "\(pid) 10 0:02.00 Wed Nov  4 01:00:00 2026 /System/daemon-\(pid)"
        default:
            discovery += 1
            // First discovery fails, establishing nonzero retry history before recovery.
            if discovery == 1 { return PSRunner.Outcome(result: nil, fault: .timeout) }
            let time = discovery == 2 ? "0:01.00" : "0:02.00"
            output = "11111 10 \(time) Wed Nov  4 01:00:00 2026\n22222 10 \(time) Wed Nov  4 01:00:00 2026"
        }
        let time = UInt64(discovery) * 1_000_000_000
        return PSRunner.Outcome(result: PSRunner.Result(output: output, startNanos: time, endNanos: time), fault: nil)
    }
    for _ in 0..<50 {
        _ = source.read()
        if source.watch.count == 2 { break }
    }
    #expect(source.watch.count == 2)
    let retry = source.retry
    vanish = true
    let reading = source.read()
    #expect(reading?.entries[11111] == nil)
    #expect(reading?.entries[22222] != nil)
    #expect(source.watch == [22222])
    #expect(source.names[11111] == nil && source.names[22222] != nil)
    #expect(source.retry.failures == retry.failures)
    #expect(source.metricStatus == .live(.libprocAndPS))
    source.readPS = { _, _ in PSRunner.Outcome(result: nil, fault: .timeout) }
    _ = source.read()
    #expect(source.state.isEmpty && source.watch.isEmpty)
    #expect(source.metricStatus.fault == .timeout && source.retry.failures == 1)
}

@Test func emptySinglePIDIsSuccessfulAbsenceButMissingExecutableIsFailure() {
    let absent = PSRunner.runStatus(.pid(Int32.max), withName: true, withStartTime: true)
    #expect(absent.result?.output == "" && absent.fault == nil)
    #expect(PSRunner.runStatus(.pid(Int32.max), withName: true, executable: "/nonexistent/wpz").fault == .psUnavailable)
}

@Test func thermalAndIdentityFaultModesAreExplicitAndGenericIdentityUsesGenericTemperatures() {
    let fake = FakeSet()
    for (mode, fault) in [("nan", MetricFault.nonFinite), ("range", .outOfRange)] {
        let readings = FaultInjectingSamplers(base: fake.set, configuration: FaultConfiguration("thermal:\(mode)"))
        #expect(readings.sampleThermalStatus().fault == fault)
        let queue = DispatchQueue(label: "wpz.identity"); queue.suspend()
        let state = SamplingState(samplerSet: fake.set, faults: FaultConfiguration("identity:\(mode)"))
        var identity: MetricStatus?
        state.start(on: queue, resetSMC: false) { identity = $0.status.identity }
        #expect(identity?.fault == fault)
        state.stop(); queue.resume()
    }
    #expect(FaultConfiguration("thermal:jump,identity:stuck,cpu:generic").modes.isEmpty)
    let reader = Reader(), set = fake.set
    set.temperatures = SMCTemperatureSampler(chipName: "Apple M5 Max", reader: reader)
    let readings = FaultInjectingSamplers(base: set, configuration: FaultConfiguration("identity:generic"))
    let temps = readings.sampleTemperaturesStatus()
    #expect(temps.cpu.source == .genericFamily && temps.gpu.source == .genericFamily)
    #expect(temps.cpu.fault == .unknownChip && temps.gpu.fault == .unknownChip)
}

@Test func detectorResetRequiresWakeOrPauseLongerThanTenSeconds() {
    let fake = FakeSet(), queue = DispatchQueue(label: "wpz.longPause")
    queue.suspend()
    var uptime = 100.0
    let state = SamplingState(samplerSet: fake.set, faults: FaultConfiguration("cpuTemp:stuck"), uptime: { uptime })
    defer { state.stop(); queue.resume() }
    var status: MetricStatus?
    let publish: (Snapshot) -> Void = { status = $0.status.cpuTemp }
    state.start(on: queue, resetSMC: false, publish: publish)
    for _ in 0..<310 { state.fastTick() }
    #expect(status?.fault == .stuck)
    state.stop(); uptime += 10
    state.start(on: queue, resetSMC: false, publish: publish)
    state.fastTick()
    #expect(status?.fault == .stuck)
    state.stop(); uptime += 10.001
    state.start(on: queue, resetSMC: false, publish: publish)
    #expect(status?.fault != .stuck)
}

@Test func malformedMappedPayloadWithoutGenericCoverageKeepsReason() {
    let reader = Reader(); reader.inventory = ["Tp00", "Tp04", "Tg00", "Tg01"]; reader.values["Tp00"] = .nan
    let sample = SMCTemperatureSampler(chipName: "Apple M5 Max", reader: reader).sampleTemperaturesStatus()
    #expect(sample.cpu.value == nil && sample.cpu.fault == .nonFinite)
}

@Test func rapidDetailTogglesKeepTheFastTimerAndDoNotCreateExtraTemperatureTicks() throws {
    let fake = FakeSet(), queue = DispatchQueue(label: "wpz.fastCadence")
    queue.suspend()
    let state = SamplingState(samplerSet: fake.set)
    defer { state.stop(); queue.resume() }
    state.start(on: queue, resetSMC: false) { _ in }
    let timer = try #require(state.fastTimer)
    for _ in 0..<100 { state.setDetails(false, on: queue); state.setDetails(true, on: queue) }
    let current = try #require(state.fastTimer)
    #expect((timer as AnyObject) === (current as AnyObject))
    #expect(fake.reads["temp"] == 1)
    state.fastTick()
    #expect(fake.reads["temp"] == 2)
}

@Test func recoveryPublishesTheFirstCPUBaselineFaultWithoutConsumingIt() {
    let fake = FakeSet(), queue = DispatchQueue(label: "wpz.wakeBaseline")
    fake.cpuSamples = [.failure(.apiError, source: .hostProcessorInfo),
                       .failure(.wakeTransient, source: .hostProcessorInfo),
                       .failure(.firstSample, source: .hostProcessorInfo)]
    queue.suspend()
    let state = SamplingState(samplerSet: fake.set)
    defer { state.stop(); queue.resume() }
    var status: MetricStatus?
    state.start(on: queue, resetSMC: false) { status = $0.status.cpuPercent }
    #expect(status?.fault == .apiError)
    state.start(on: queue, resetSMC: true) { status = $0.status.cpuPercent }
    #expect(status?.fault == .wakeTransient)
    #expect(fake.reads["cpu"] == 2)
}

@Test func cpuDeltaShorterThanHalfASecondAfterARebaselineIsSkipped() {
    var now = 100.0
    let fake = FakeSet(), queue = DispatchQueue(label: "wp41.window")
    queue.suspend()
    let state = SamplingState(samplerSet: fake.set, uptime: { now })
    defer { state.stop(); queue.resume() }
    var latest: Snapshot?
    state.start(on: queue, resetSMC: false, details: false, publish: { latest = $0 })
    state.setDetails(true, on: queue)
    let calls = fake.reads["cpu", default: 0]
    now += 0.02
    state.fastTick()
    #expect(fake.reads["cpu", default: 0] == calls)
    now += 1
    state.fastTick()
    #expect(fake.reads["cpu", default: 0] == calls + 1)
    _ = latest
}

@Test func timerTicksCloserThanHalfASecondAreMergedAndPopoverKeyUsesUnsmoothedValues() {
    var now = 100.0
    let fake = FakeSet(), queue = DispatchQueue(label: "wp41.merge")
    queue.suspend()
    let state = SamplingState(samplerSet: fake.set, uptime: { now })
    defer { state.stop(); queue.resume() }
    state.start(on: queue, resetSMC: false, details: true, publish: { _ in })
    now += 2; state.fastTick()
    let reads = fake.reads["cpu", default: 0]
    now += 0.2; state.timedFastTick()
    #expect(fake.reads["cpu", default: 0] == reads)
    now += 0.8; state.timedFastTick()
    #expect(fake.reads["cpu", default: 0] == reads + 1)
    #expect(SamplingCadence.fastInterval(popoverOpen: true) == 1)
    #expect(SamplingCadence.fastInterval(popoverOpen: false) == 2)
    var s = Snapshot.preview
    s.unsmoothed = Snapshot.Unsmoothed(cpuPercent: 91, gpuPercent: s.gpuPercent, cpuTemp: s.cpuTemp, gpuTemp: s.gpuTemp, topProcesses: s.topProcesses)
    var q = MenuBarQuantizer()
    let values = q.update(s)
    #expect(publicationKey(s, options: DisplayOptions(), menuValues: values, popoverOpen: false)
            == publicationKey({ var t = s; t.unsmoothed = nil; return t }(), options: DisplayOptions(), menuValues: values, popoverOpen: false))
    #expect(publicationKey(s, options: DisplayOptions(), menuValues: values, popoverOpen: true)
            != publicationKey({ var t = s; t.unsmoothed?.cpuPercent = 12; return t }(), options: DisplayOptions(), menuValues: values, popoverOpen: true))
}

@Test func openPopoverScansProcessesEveryTwoSecondsAndMergesNearScans() {
    #expect(SamplingCadence.processInterval(closed: 5, popoverOpen: true) == 2)
    #expect(SamplingCadence.processInterval(closed: 8, popoverOpen: true) == 2)
    #expect(SamplingCadence.processInterval(closed: 8, popoverOpen: false) == 8)
    var now = 100.0
    let fake = FakeSet(), queue = DispatchQueue(label: "wp41.process")
    queue.suspend()
    let state = SamplingState(samplerSet: fake.set, uptime: { now })
    defer { state.stop(); queue.resume() }
    state.start(on: queue, resetSMC: false, details: true, publish: { _ in })
    let scans = fake.reads["procs", default: 0]
    now += 0.4; state.timedProcessTick()
    #expect(fake.reads["procs", default: 0] == scans)
    now += 2; state.timedProcessTick()
    #expect(fake.reads["procs", default: 0] == scans + 1)
}
