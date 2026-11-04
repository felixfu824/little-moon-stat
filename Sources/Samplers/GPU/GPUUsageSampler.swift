import Foundation
import IOKit
import MonitorCore

public final class GPUUsageSampler: GPUUsageSampling {
    private var retry = RetrySchedule()
    private var lastFault: MetricFault = SystemInfo.hvVMMPresent ? .virtualMachine : .serviceUnavailable
    public init() {}
    public func sampleGPU() -> Double? { sampleGPUStatus().value }
    public func sampleGPUStatus() -> Sample<Double> {
        guard retry.shouldAttempt() else { return .failure(lastFault, source: .ioAccelerator) }
        let result = readGPU()
        if result.value != nil { retry.recordSuccess() } else { retry.recordFailure() }
        return result
    }
    private func readGPU() -> Sample<Double> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                          &iterator) == KERN_SUCCESS else { return .failure(lastFault, source: .ioAccelerator) }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return .failure(lastFault, source: .ioAccelerator) }
            let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue()
            IOObjectRelease(service)
            if let stats = property as? [String: Any],
               let number = stats["Device Utilization %"] as? NSNumber {
                let value = number.doubleValue
                return Sample(value: value, source: .ioAccelerator)
            }
        }
    }
}
