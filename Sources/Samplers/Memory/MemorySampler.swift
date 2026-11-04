import Foundation
import Darwin
import MonitorCore

public final class MemorySampler: MemorySampling {
    public init() {}
    public func sampleMemory() -> MemoryStat? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        return MemoryStat(wired: UInt64(info.wire_count) * page,
                          active: UInt64(info.active_count) * page,
                          compressed: UInt64(info.compressor_page_count) * page,
                          total: ProcessInfo.processInfo.physicalMemory)
    }
    public func sampleMemoryStatus() -> Sample<MemoryStat> {
        let value = sampleMemory()
        return Sample(value: value, source: .hostStatistics, fault: value == nil ? .apiError : nil)
    }
}
