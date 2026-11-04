import Foundation
import Darwin
import MonitorCore

/// Lifecycle belongs to the main actor; all sampling and aggregation belong to one
/// utility queue. A generation rejects already-enqueued publications after pause/wake.
@MainActor
public final class SamplingEngine: MonitorEngine {
    public let store: SnapshotStore
    /// Optional diagnostics sink, called on the main actor after every publication.
    /// Unlike Observation invalidation, this does not coalesce consecutive updates.
    public var onPublish: ((Snapshot) -> Void)?
    private let queue: DispatchQueue
    private let state: SamplingState
    private(set) var pendingWakeReset = false
    private var pendingLaunch: SamplingLaunch?
    private var generation = 0
    private var running = false
    private var detailSampling = true
    private var presentationOptions = DisplayOptions()
    public private(set) var menuBarValues: MenuBarValues?

    public convenience init(store: SnapshotStore, cpuSource: CPUUsageSampling? = nil, faults: FaultConfiguration = FaultConfiguration()) {
        self.init(store: store, cpuSource: cpuSource,
                  faults: faults, queue: DispatchQueue(label: "MacMonitorPanel.sampling", qos: .utility))
    }
    // Queue injection lets lifecycle tests cancel starts before any hardware work begins.
    init(store: SnapshotStore, cpuSource: CPUUsageSampling?, faults: FaultConfiguration = FaultConfiguration(), queue: DispatchQueue) {
        self.store = store
        self.queue = queue
        self.state = SamplingState(cpuSource: cpuSource, faults: faults)
    }
    /// Menu-bar-only closed mode needs SMC temperatures, with no process scans,
    /// IOAccelerator, CPU deltas, memory, disk or thermal polling.
    public func setDetailSampling(_ enabled: Bool) {
        guard detailSampling != enabled else { return }
        detailSampling = enabled
        if running {
            let state = state
            queue.async { [queue] in state.setDetails(enabled, on: queue) }
        }
    }
    public func setPopoverOpen(_ open: Bool) {
        let state=state
        queue.async { state.popoverOpen=open }
    }
    public func setPresentationOptions(_ options: DisplayOptions) {
        guard options != presentationOptions else { return }
        presentationOptions=options
        let state=state
        queue.async { state.presentationOptions=options }
    }
    public func start() { resume() }
    public func stop() { pause() }
    public func pause() {
        pendingLaunch?.cancel()
        running = false
        generation += 1
        let state = state
        queue.async { state.stop() }
    }
    public func resume() {
        guard !running else { return }
        launch(resetSMC: pendingWakeReset)
    }
    public func systemDidWake() {
        pendingWakeReset = true
        if running { launch(resetSMC: true) }
    }

    private func launch(resetSMC: Bool) {
        pendingLaunch?.cancel()
        let launch = SamplingLaunch()
        pendingLaunch = launch
        running = true
        generation += 1
        let current = generation
        let state = state
        let details = detailSampling
        let options = presentationOptions
        queue.async { [weak self, queue] in
            guard launch.isValid else { return }
            state.start(on: queue, resetSMC: resetSMC, details: details, options: options) { [weak self] snapshot in
                let values=state.menuBarValues
                Task { @MainActor [weak self] in
                    guard let self, self.running, self.generation == current else { return }
                    self.menuBarValues=values
                    self.store.publish(snapshot)
                    self.onPublish?(snapshot)
                }
            }
            // A cancelled queued start must not consume the wake reset. An older
            // start finishing after a newer wake likewise cannot clear its reset.
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.pendingWakeReset = false
            }
        }
    }
    deinit {
        pendingLaunch?.cancel()
        let state = state
        queue.async { state.stop() }
    }
}

private final class SamplingLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func cancel() { lock.lock(); valid = false; lock.unlock() }
}

/// Accessed exclusively by SamplingEngine.queue, including sampler creation/reset.
final class SamplingState: @unchecked Sendable {
    private let profile = ProcessInfo.processInfo.environment["MAC_MONITOR_PROFILE"] == "1"
    private(set) var fastTimer: DispatchSourceTimer?
    private var detailTimers: [DispatchSourceTimer] = []
    private var details = true
    private var wasDetailSampling = false
    var popoverOpen = false
    var presentationOptions = DisplayOptions()
    private var menuQuantizer = MenuBarQuantizer()
    private(set) var menuBarValues: MenuBarValues?
    private let samplers: SamplerSet
    private let readings: FaultInjectingSamplers
    private var stoppedAt: Double?
    private let uptime: () -> Double
    private var lastStatuses: [String] = []
    init(cpuSource: CPUUsageSampling? = nil, samplerSet: SamplerSet? = nil, faults: FaultConfiguration = FaultConfiguration(),
         uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
        let set = samplerSet ?? SamplerSet()
        if let cpuSource { set.cpu = cpuSource }
        samplers = set; readings = FaultInjectingSamplers(base: set, configuration: faults)
    }
    private var system: SystemInfo?
    private var aggregator: Aggregator?
    private var lastKey: String?
    private var publish: ((Snapshot) -> Void)?
    private var preparing = false

    func start(on queue: DispatchQueue, resetSMC: Bool, details: Bool = true, options: DisplayOptions = DisplayOptions(), publish: @escaping (Snapshot) -> Void) {
        let previousStop = stoppedAt
        stop()
        stoppedAt = previousStop
        self.publish = publish
        self.details = details
        self.presentationOptions=options
        if system == nil { system = measured("system.init") { SystemInfo() } }
        let longPause = stoppedAt.map { uptime() - $0 > 10 } ?? false
        stoppedAt = nil
        let isInitial = aggregator == nil
        let enteringDetails = details && (!self.wasDetailSampling || previousStop != nil)
        if details && (isInitial || enteringDetails || resetSMC || longPause) {
            (samplers.cpu as? CPUUsageSampler)?.reset(wakeTransient: resetSMC || longPause)
            if !isInitial { samplers.resetProcesses() }
        }
        wasDetailSampling = details
        if resetSMC { (samplers.temperatures as? SMCTemperatureSampler)?.reset() }
        guard let system else { return }
        let ticks = ProcessInfo.processInfo.environment["MAC_MONITOR_STUCK_TICKS"].flatMap(Int.init).map { max(1, $0) }
        let detector = ticks.map { StuckDetector(windowTicks: $0, maximumTicks: $0) } ?? StuckDetector()
        let identityMode = readings.configuration.modes["identity"]
        let identity = identityMode == nil ? system.status : MetricStatus.estimated(.builtInDefault, fault: identityMode == .generic ? .unknownChip : identityMode == .nan ? .nonFinite : identityMode == .range ? .outOfRange : .apiError)
        if aggregator == nil {
            aggregator = Aggregator(machineName: identityMode == nil ? system.machineName : "Mac", chipName: identityMode == nil ? system.chipName : "Apple Silicon", identityStatus: identity, stuckDetector: detector)
        }
        if resetSMC || longPause { aggregator?.resetDetectors() }
        let processInterval = SamplingCadence.processInterval(logicalCoreCount: ProcessInfo.processInfo.processorCount)
        lastKey = nil
        // Baselines immediately, then the first CPU delta is available about two seconds later.
        preparing = true
        if details {
            if isInitial { processTick(); diskTick() }
            else if enteringDetails || resetSMC || longPause {
                // Establish new deltas without replacing the aggregator's held rows/status.
                // Recovery's immediate fast tick must publish the first wakeTransient
                // baseline result; short resumes wait for the existing next delta.
                if !resetSMC && !longPause { _ = readings.sampleCPUStatus() }
                if aggregator?.snapshot.disk == nil { diskTick() }
            }
        }
        preparing = false
        if isInitial || resetSMC || longPause { fastTick() }
        else { publishIfChanged() }
        fastTimer = timer(on: queue, every: 2) { [weak self] in self?.fastTick() }
        if details { startDetailTimers(on: queue, processInterval: processInterval) }
    }

    /// A visibility change only changes the optional detail cadence. Keep the fast
    /// timer's deadline, publication generation, and all measurement policy intact.
    func setDetails(_ enabled: Bool, on queue: DispatchQueue) {
        guard publish != nil, details != enabled else { return }
        details = enabled; wasDetailSampling = enabled
        for timer in detailTimers { timer.setEventHandler {}; timer.cancel() }
        detailTimers.removeAll()
        if enabled {
            (samplers.cpu as? CPUUsageSampler)?.reset()
            samplers.resetProcesses()
            _ = readings.sampleCPUStatus()
            if aggregator?.snapshot.disk == nil { diskTick() }
            startDetailTimers(on: queue, processInterval: SamplingCadence.processInterval(logicalCoreCount: ProcessInfo.processInfo.processorCount))
        }
    }

    private func startDetailTimers(on queue: DispatchQueue, processInterval: Double) {
        detailTimers = [
            timer(on: queue, every: processInterval) { [weak self] in self?.processTick() },
            timer(on: queue, every: 60) { [weak self] in self?.diskTick() }
        ]
    }

    func stop() {
        if stoppedAt == nil { stoppedAt = uptime() }
        if let timer = fastTimer { timer.setEventHandler {}; timer.cancel() }
        fastTimer = nil
        for timer in detailTimers { timer.setEventHandler {}; timer.cancel() }
        detailTimers.removeAll()
        publish = nil
    }

    private func timer(on queue: DispatchQueue, every seconds: Double, handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds,
                       leeway: .milliseconds(Int(seconds * 100)))
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
    func fastTick() {
        let usage = details ? measured("cpu") { readings.sampleCPUStatus() } : nil
        let temps = measured("smc") { readings.sampleTemperaturesStatus() }
        let gpuUsage = details ? measured("gpu") { readings.sampleGPUStatus() } : nil
        let needsMemory=details || presentationOptions.menuBarMoons.contains(.ram)
        let memoryUsage = needsMemory ? measured("memory") { readings.sampleMemoryStatus() } : nil
        let level = details ? measured("thermal") { readings.sampleThermalStatus() } : nil
        measured("aggregate.fast") {
            aggregator?.updateFast(cpu: usage, gpu: gpuUsage, temperatures: temps,
                                   memory: memoryUsage, thermal: level, at: Date())
        }
        if aggregator?.consumeTemperatureReset() == true { (samplers.temperatures as? SMCTemperatureSampler)?.reset() }
        publishIfChanged()
    }
    func processTick() {
        let rows = measured("process") { readings.sampleProcessesStatus(limit: .max) }
        measured("aggregate.process") { aggregator?.updateProcesses(rows, at: Date(), freshPIDs: (samplers.processes as? ProcessSampler)?.freshPIDs) }
        if rows.value?.isEmpty == false, let selected = aggregator?.snapshot.topProcesses {
            var names: [Int32: String] = [:]
            measured("process.names") {
                for row in selected { names[row.pid] = samplers.injected ? row.name : samplers.processSource.name(for: row.pid) ?? "pid \(row.pid)" }
            }
            aggregator?.updateProcessNames(names)
        }
        publishIfChanged()
    }
    private func diskTick() {
        let stat = measured("disk") { readings.sampleDiskStatus() }
        aggregator?.updateDisk(stat, at: Date())
        publishIfChanged()
    }
    private func publishIfChanged() {
        guard !preparing, let snapshot = aggregator?.snapshot else { return }
        let statuses = snapshot.status.keys
        if statuses != lastStatuses {
            for (index, metric) in StatusMetric.allCases.enumerated() where lastStatuses.indices.contains(index) == false || lastStatuses[index] != statuses[index] {
                let status = snapshot.status[metric]
                fputs("STATUS \(metric.rawValue) \(status.quality.rawValue) \(status.fault?.rawValue ?? "-")\n", stderr)
            }
            lastStatuses = statuses
        }
        let values=menuQuantizer.update(snapshot,unit:presentationOptions.temperatureUnit)
        menuBarValues=values
        let key = measured("key") { publicationKey(snapshot,options:presentationOptions,menuValues:values,popoverOpen:popoverOpen) }
        guard key != lastKey else { return }
        lastKey = key
        if profile { fputs("PUBLISH\n",stderr) }
        publish?(snapshot)
    }

    /// Opt-in diagnostic output: worker-thread CPU excludes main-actor JSON work;
    /// child CPU includes reaped ps children. Default runs perform no timing syscalls.
    private func measured<Value>(_ label: String, _ action: () -> Value) -> Value {
        guard profile else { return action() }
        func childCPU() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_CHILDREN, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let childrenBefore = childCPU()
        let value = action()
        let children = (childCPU() - childrenBefore) * 1000
        let own = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1e6
        fputs(String(format: "COST\t%@\t%.6f\t%.6f\n", label, own, children), stderr)
        return value
    }
}

/// The M3 Air needs less process work; the fast metrics remain on their 2 s timer.
enum SamplingCadence {
    static func processInterval(logicalCoreCount: Int) -> Double { logicalCoreCount <= 10 ? 8 : 5 }
    static func discoveryEvery(processInterval: Double) -> Int { max(1, Int(25 / processInterval)) }
}

/// Publication follows visible precision, never raw sensor noise. Explicit/system
/// Fahrenheit still gets its finer visible digit transitions without a raw key.
func publicationKey(_ snapshot: Snapshot, options: DisplayOptions, menuValues: MenuBarValues, popoverOpen: Bool = false) -> String {
    var result=displayKey(snapshot)
    if DisplayFormat.resolvedUnit(options.temperatureUnit) == .fahrenheit {
        result += [snapshot.cpuTemp?.peak,snapshot.cpuTemp?.average,snapshot.gpuTemp?.peak,snapshot.gpuTemp?.average]
            .map { DisplayFormat.temperature($0,unit:.fahrenheit) }.joined(separator:"|")
    }
    if options.displayMode != .desktop { result += menuValues.key(options.menuBarMoons) }
    if popoverOpen { result += "|popover:" + PopoverPresentation.key(snapshot) }
    return result
}
