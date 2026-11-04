import Darwin
import MonitorCore

/// Tick counters are per logical CPU. The returned allocation belongs to the caller.
public final class CPUUsageSampler: CPUUsageSampling {
    private var previous: [UInt32]?
    private var resuming = false
    private var zeroDeltas = 0
    public init() {}
    public func reset(wakeTransient: Bool = false) { previous = nil; zeroDeltas = 0; resuming = wakeTransient }

    public func sampleCPU() -> Double? { sampleCPUStatus().value }

    public func sampleCPUStatus() -> Sample<Double> {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var count: mach_msg_type_number_t = 0
        var processors: natural_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO,
                                  &processors, &info, &count) == KERN_SUCCESS, let info else {
            previous = nil; zeroDeltas = 0
            return .failure(.apiError, source: .hostProcessorInfo)
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let ticks = UnsafeBufferPointer(start: info, count: Int(count)).map { UInt32(bitPattern: $0) }
        defer { previous = ticks }
        guard let previous, previous.count == ticks.count,
              ticks.count == Int(processors) * Int(CPU_STATE_MAX) else {
            zeroDeltas = 0
            let fault: MetricFault = resuming ? .wakeTransient : .firstSample
            resuming = false
            return .failure(fault, source: .hostProcessorInfo)
        }
        guard let percent = Self.busyPercent(previous: previous, current: ticks) else {
            zeroDeltas += 1
            return .failure(zeroDeltas >= 2 ? .stuck : .firstSample, source: .hostProcessorInfo)
        }
        zeroDeltas = 0
        return Sample(value: percent, source: .hostProcessorInfo)
    }

    static func busyPercent(previous: [UInt32], current: [UInt32]) -> Double? {
        guard !current.isEmpty, previous.count == current.count,
              current.count % Int(CPU_STATE_MAX) == 0 else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in current.indices {
            let delta = UInt64(current[i] &- previous[i]) // 32-bit tick wrap is normal.
            total += delta
            if i % Int(CPU_STATE_MAX) != Int(CPU_STATE_IDLE) { busy += delta }
        }
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}
