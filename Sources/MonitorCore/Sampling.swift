import Foundation

// One protocol per metric so the aggregator can be tested with fakes.
// Every sampler returns nil (or empty) on failure; it never throws and never crashes the panel.
// Samplers are called from one utility queue; they need not be thread-safe beyond that.
//
// WP-V0: every protocol also has a status method (value + source + fault). The default extension wraps the
// old method, so existing samplers and fakes compile unchanged; a sampler that knows why it failed, or that
// it fell back to a generic source, overrides the status method. The engine should call only status methods.

/// Whole-machine CPU busy share, 0...100. The first call may return nil (needs a delta).
public protocol CPUUsageSampling: AnyObject {
    func sampleCPU() -> Double?
    func sampleCPUStatus() -> Sample<Double>
}

/// Whole-GPU busy share, 0...100.
public protocol GPUUsageSampling: AnyObject {
    func sampleGPU() -> Double?
    func sampleGPUStatus() -> Sample<Double>
}

/// CPU (SMC Tp*) and GPU (SMC Tg*) die temperatures.
public protocol TemperatureSampling: AnyObject {
    func sampleTemperatures() -> (cpu: TempStat?, gpu: TempStat?)
    func sampleTemperaturesStatus() -> TemperatureSample
}

public protocol MemorySampling: AnyObject {
    func sampleMemory() -> MemoryStat?
    func sampleMemoryStatus() -> Sample<MemoryStat>
}

public protocol DiskSampling: AnyObject {
    func sampleDisk() -> DiskStat?
    func sampleDiskStatus() -> Sample<DiskStat>
}

/// Raw per-process CPU over the last interval, sorted by cpuPercent descending.
/// Must include root-owned processes such as WindowServer. Ranking stability is the aggregator's job.
public protocol ProcessSampling: AnyObject {
    func sampleProcesses(limit: Int) -> [ProcRow]
    /// `value == nil` is a failed scan; `[]` is a successful scan with no rows.
    func sampleProcessesStatus(limit: Int) -> Sample<[ProcRow]>
}

public protocol ThermalSampling: AnyObject {
    func sampleThermal() -> ThermalLevel?
    func sampleThermalStatus() -> Sample<ThermalLevel>
}

// A nil value from a default wrapper carries no fault; the Aggregator reports it as `firstSample` until the
// metric has produced a value once, and as `apiError` after that.

extension CPUUsageSampling {
    public func sampleCPUStatus() -> Sample<Double> { Sample(value: sampleCPU(), source: .hostProcessorInfo) }
}

extension GPUUsageSampling {
    public func sampleGPUStatus() -> Sample<Double> { Sample(value: sampleGPU(), source: .ioAccelerator) }
}

extension TemperatureSampling {
    public func sampleTemperaturesStatus() -> TemperatureSample {
        let read = sampleTemperatures()
        return TemperatureSample(cpu: Sample(value: read.cpu, source: .chipMap),
                                 gpu: Sample(value: read.gpu, source: .chipMap))
    }
}

extension MemorySampling {
    public func sampleMemoryStatus() -> Sample<MemoryStat> { Sample(value: sampleMemory(), source: .hostStatistics) }
}

extension DiskSampling {
    public func sampleDiskStatus() -> Sample<DiskStat> { Sample(value: sampleDisk(), source: .volumeCapacity) }
}

extension ProcessSampling {
    public func sampleProcessesStatus(limit: Int) -> Sample<[ProcRow]> {
        Sample(value: sampleProcesses(limit: limit), source: .libprocAndPS)
    }
}

extension ThermalSampling {
    public func sampleThermalStatus() -> Sample<ThermalLevel> { Sample(value: sampleThermal(), source: .processInfo) }
}
