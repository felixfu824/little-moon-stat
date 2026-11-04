import Foundation
import MonitorCore

public final class DiskSampler: DiskSampling {
    public init() {}
    public func sampleDisk() -> DiskStat? { sampleDiskStatus().value }
    public func sampleDiskStatus() -> Sample<DiskStat> {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey
            ])
            guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage,
                  let name = values.volumeLocalizedName else { return .failure(.apiError, source: .volumeCapacity) }
            guard total > 0, free >= 0 else { return .failure(.outOfRange, source: .volumeCapacity) }
            return Sample(value: DiskStat(volumeName: name, total: UInt64(total), free: UInt64(free)), source: .volumeCapacity)
        } catch { return .failure(.apiError, source: .volumeCapacity) }
    }
}
