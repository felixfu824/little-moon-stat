import Foundation
import Darwin
import IOKit
import MonitorCore

public struct SystemInfo: Sendable {
    public let machineName: String
    public let chipName: String
    public let status: MetricStatus
    public static var hvVMMPresent: Bool {
        var value: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }
    public init() {
        let service = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        var product: String?
        if service != 0 {
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(service, "product-name" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let data = property as? Data { product = String(data: data, encoding: .utf8) }
            else { product = property as? String }
        }
        machineName = Self.modelName(product)
        var size = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 {
                chipName = String(cString: bytes)
            } else { chipName = "Apple Silicon" }
        } else { chipName = "Apple Silicon" }
        if machineName == "Mac" || chipName == "Apple Silicon" {
            status = .estimated(.builtInDefault, fault: .apiError)
        } else if !SMCSensorMap.forChip(chipName).verified {
            status = .estimated(.sysctl, fault: .unknownChip)
        } else { status = .live(.deviceTree) }
    }

    static func modelName(_ product: String?) -> String {
        let value = (product ?? "").replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = value.components(separatedBy: " (").first ?? ""
        return name.isEmpty ? "Mac" : name
    }
}
