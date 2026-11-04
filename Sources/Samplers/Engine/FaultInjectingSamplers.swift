import Foundation
import MonitorCore

/// Explicit launch-only diagnostics. No preference or global environment mutation.
public struct FaultConfiguration: Sendable {
    public enum Mode: String, Sendable { case unavailable, nan, range, stuck, jump, generic, slow, nops }
    public var modes: [String: Mode] = [:]
    public init(_ specification: String = "") {
        let metrics: Set<String> = ["cpu", "gpu", "cpuTemp", "gpuTemp", "ram", "disk", "procs", "thermal", "identity"]
        for item in specification.split(separator: ",") {
            let pair = item.split(separator: ":")
            if pair.count == 2, metrics.contains(String(pair[0])), let mode = Mode(rawValue: String(pair[1])) {
                let metric = String(pair[0])
                let supported: Set<Mode>
                switch metric {
                case "cpuTemp", "gpuTemp": supported = [.unavailable, .nan, .range, .stuck, .jump, .generic]
                case "procs": supported = [.unavailable, .nan, .range, .stuck, .slow, .nops]
                case "identity": supported = [.unavailable, .nan, .range, .generic]
                default: supported = [.unavailable, .nan, .range, .stuck]
                }
                if supported.contains(mode) { modes[metric] = mode }
                else { fputs("FAULT ignored undefined mode \(metric):\(mode.rawValue)\n", stderr) }
            }
        }
    }
}

/// Lazy production default preserves the menu-bar-only hardware gates.
final class SamplerSet {
    lazy var cpu: CPUUsageSampling = CPUUsageSampler()
    lazy var gpu: GPUUsageSampling = GPUUsageSampler()
    lazy var temperatures: TemperatureSampling = SMCTemperatureSampler()
    lazy var memory: MemorySampling = MemorySampler()
    lazy var disk: DiskSampling = DiskSampler()
    lazy var thermal: ThermalSampling = ThermalSampler()
    lazy var processSource = EngineProcessSource(source: HybridProcessSource(discoveryEvery:
        SamplingCadence.discoveryEvery(processInterval: SamplingCadence.processInterval(logicalCoreCount: ProcessInfo.processInfo.processorCount))))
    lazy var processes: ProcessSampling = ProcessSampler(source: processSource)
    var injected = false
    init() {}
    init(cpu: CPUUsageSampling, gpu: GPUUsageSampling, temperatures: TemperatureSampling,
         memory: MemorySampling, disk: DiskSampling, processes: ProcessSampling, thermal: ThermalSampling) {
        self.cpu = cpu; self.gpu = gpu; self.temperatures = temperatures; self.memory = memory
        self.disk = disk; self.processes = processes; self.thermal = thermal; injected = true
    }
    func resetProcesses() {
        guard !injected else { return }
        (processes as? ProcessSampler)?.resetBaseline(processSource.readBaseline())
    }
}

/// Wraps the real set; failure injection avoids touching the failed hardware path.
final class FaultInjectingSamplers: CPUUsageSampling, GPUUsageSampling, TemperatureSampling,
    MemorySampling, DiskSampling, ProcessSampling, ThermalSampling {
    let base: SamplerSet
    let configuration: FaultConfiguration
    private var temperatureTick = 0
    private var heldMemory: Sample<MemoryStat>?
    private var heldDisk: Sample<DiskStat>?
    private var heldProcesses: Sample<[ProcRow]>?
    init(base: SamplerSet, configuration: FaultConfiguration) { self.base = base; self.configuration = configuration }
    private func number(_ key: String, source: MetricSource, read: () -> Sample<Double>) -> Sample<Double> {
        switch configuration.modes[key] {
        case .unavailable: return .failure(.apiError, source: source)
        case .nan: return Sample(value: .nan, source: source)
        case .range: return Sample(value: 140, source: source)
        case .stuck: return Sample(value: 33, source: source)
        default: return read()
        }
    }
    func sampleCPU() -> Double? { sampleCPUStatus().value }
    func sampleCPUStatus() -> Sample<Double> { number("cpu", source: .hostProcessorInfo) { base.cpu.sampleCPUStatus() } }
    func sampleGPU() -> Double? { sampleGPUStatus().value }
    func sampleGPUStatus() -> Sample<Double> { number("gpu", source: .ioAccelerator) { base.gpu.sampleGPUStatus() } }
    func sampleTemperatures() -> (cpu: TempStat?, gpu: TempStat?) { let s = sampleTemperaturesStatus(); return (s.cpu.value, s.gpu.value) }
    func sampleTemperaturesStatus() -> TemperatureSample {
        guard !configuration.modes.isEmpty else { return base.temperatures.sampleTemperaturesStatus() }
        temperatureTick += 1
        let smc = base.temperatures as? SMCTemperatureSampler
        smc?.forceGenericCPU = configuration.modes["cpuTemp"] == .generic || configuration.modes["identity"] == .generic
        smc?.forceGenericGPU = configuration.modes["gpuTemp"] == .generic || configuration.modes["identity"] == .generic
        let bypass: Set<FaultConfiguration.Mode> = [.unavailable, .nan, .range, .stuck, .jump]
        let bothBypassed = ["cpuTemp", "gpuTemp"].allSatisfy { configuration.modes[$0].map { bypass.contains($0) } ?? false }
        let real = bothBypassed ? nil : base.temperatures.sampleTemperaturesStatus()
        func family(_ key: String, _ actual: Sample<TempStat>?) -> Sample<TempStat> {
            let mode = configuration.modes[key]
            if mode == .unavailable { return .failure(.apiError, source: .chipMap) }
            let peak: Double?
            switch mode {
            case .nan: peak = .nan
            case .range: peak = 300
            case .stuck: peak = 60
            case .jump: peak = temperatureTick % 10 == 0 ? 120 : 60
            default: peak = nil
            }
            if let peak { return Sample(value: TempStat(peak: peak, average: peak - 5, sensorCount: 2), source: .chipMap) }
            return actual ?? .failure(.apiError, source: .chipMap)
        }
        return TemperatureSample(cpu: family("cpuTemp", real?.cpu), gpu: family("gpuTemp", real?.gpu))
    }
    func sampleMemory() -> MemoryStat? { sampleMemoryStatus().value }
    func sampleMemoryStatus() -> Sample<MemoryStat> {
        switch configuration.modes["ram"] {
        case .unavailable, .nan: return .failure(configuration.modes["ram"] == .nan ? .nonFinite : .apiError, source: .hostStatistics)
        case .range: return Sample(value: MemoryStat(wired: 200, active: 0, compressed: 0, total: 100), source: .hostStatistics)
        case .stuck:
            if heldMemory == nil { heldMemory = base.memory.sampleMemoryStatus() }
            return heldMemory!
        default: return base.memory.sampleMemoryStatus()
        }
    }
    func sampleDisk() -> DiskStat? { sampleDiskStatus().value }
    func sampleDiskStatus() -> Sample<DiskStat> {
        switch configuration.modes["disk"] {
        case .unavailable, .nan: return .failure(configuration.modes["disk"] == .nan ? .nonFinite : .apiError, source: .volumeCapacity)
        case .range: return Sample(value: DiskStat(volumeName: "test", total: 100, free: 200), source: .volumeCapacity)
        case .stuck:
            if heldDisk == nil { heldDisk = base.disk.sampleDiskStatus() }
            return heldDisk!
        default: return base.disk.sampleDiskStatus()
        }
    }
    func sampleProcesses(limit: Int) -> [ProcRow] { sampleProcessesStatus(limit: limit).value ?? [] }
    func sampleProcessesStatus(limit: Int) -> Sample<[ProcRow]> {
        if let mode = configuration.modes["procs"] {
            if mode == .unavailable { return .failure(.apiError, source: .libprocOnly) }
            if mode == .nan || mode == .range { return .failure(mode == .nan ? .nonFinite : .outOfRange, source: .libprocOnly) }
            if mode == .stuck {
                if heldProcesses == nil { heldProcesses = base.processes.sampleProcessesStatus(limit: limit) }
                return heldProcesses!
            }
        }
        // Executable overrides live on the owned hybrid source, never in process-wide environment.
        if let mode = configuration.modes["procs"], mode == .slow || mode == .nops {
            base.processSource.psExecutable = mode == .slow ?
                (ProcessInfo.processInfo.environment["MAC_MONITOR_PS_EXECUTABLE"] ?? "Tests/Scripts/slow_ps.sh") : "/nonexistent/wpv-ps"
        }
        return base.processes.sampleProcessesStatus(limit: limit)
    }
    func sampleThermal() -> ThermalLevel? { sampleThermalStatus().value }
    func sampleThermalStatus() -> Sample<ThermalLevel> {
        if configuration.modes["thermal"] == .stuck { return Sample(value: .nominal, source: .processInfo) }
        if let mode = configuration.modes["thermal"] {
            return .failure(mode == .nan ? .nonFinite : mode == .range ? .outOfRange : .apiError, source: .processInfo)
        }
        return base.thermal.sampleThermalStatus()
    }
}
