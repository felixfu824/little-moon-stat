import Foundation

/// Peak and mean of a group of temperature sensors, in degrees Celsius.
public struct TempStat: Sendable, Equatable {
    public var peak: Double
    public var average: Double
    public var sensorCount: Int

    public init(peak: Double, average: Double, sensorCount: Int) {
        self.peak = peak
        self.average = average
        self.sensorCount = sensorCount
    }

    /// Plausible sensor range. Readings outside it (0, junk, unset keys) are dropped.
    public static let validRange: ClosedRange<Double> = 0.5...150

    /// Builds a stat from raw readings, or nil when no reading is plausible.
    public init?(readings: [Double]) {
        let valid = readings.filter { $0.isFinite && Self.validRange.contains($0) }
        guard let peak = valid.max() else { return nil }
        self.init(peak: peak, average: valid.reduce(0, +) / Double(valid.count), sensorCount: valid.count)
    }
}

/// Memory in bytes. `used` = wired + active + compressed, matching the design's bar.
public struct MemoryStat: Sendable, Equatable {
    public var wired: UInt64
    public var active: UInt64
    public var compressed: UInt64
    public var total: UInt64

    public init(wired: UInt64, active: UInt64, compressed: UInt64, total: UInt64) {
        self.wired = wired
        self.active = active
        self.compressed = compressed
        self.total = total
    }

    public var used: UInt64 { wired + active + compressed }
}

/// Startup volume capacity in bytes. `free` is "available for important usage" (includes purgeable).
public struct DiskStat: Sendable, Equatable {
    public var volumeName: String
    public var total: UInt64
    public var free: UInt64

    public init(volumeName: String, total: UInt64, free: UInt64) {
        self.volumeName = volumeName
        self.total = total
        self.free = free
    }

    public var used: UInt64 { total > free ? total - free : 0 }
}

/// One process row. `cpuPercent` is share of ONE core (can exceed 100).
public struct ProcRow: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double
    public var residentBytes: UInt64
    public var startTime: UInt64

    public init(pid: Int32, name: String, cpuPercent: Double, residentBytes: UInt64, startTime: UInt64 = 0) {
        self.startTime = startTime
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }

    public var id: Int32 { pid }
}

/// macOS's own four thermal states (ProcessInfo.ThermalState). No invented scale.
public enum ThermalLevel: String, Sendable, Equatable, CaseIterable {
    case nominal, fair, serious, critical
}

/// Everything one panel render needs. A nil field renders as "—".
public struct Snapshot: Sendable, Equatable {
    public var timestamp: Date
    /// Marketing model name, e.g. "MacBook Pro" (IOPlatformExpertDevice product-name, fallback "Mac").
    public var machineName: String
    /// e.g. "Apple M5 Max" (sysctl machdep.cpu.brand_string).
    public var chipName: String
    public var cpuPercent: Double?
    public var gpuPercent: Double?
    public var cpuTemp: TempStat?
    public var gpuTemp: TempStat?
    public var memory: MemoryStat?
    public var disk: DiskStat?
    public var topProcesses: [ProcRow]
    public var thermal: ThermalLevel?
    /// How far each field can be trusted (WP-V). Defaults to all live, so fixtures stay as they were.
    public var status: SnapshotStatus

    public init(
        timestamp: Date,
        machineName: String,
        chipName: String,
        cpuPercent: Double?,
        gpuPercent: Double?,
        cpuTemp: TempStat?,
        gpuTemp: TempStat?,
        memory: MemoryStat?,
        disk: DiskStat?,
        topProcesses: [ProcRow],
        thermal: ThermalLevel?,
        status: SnapshotStatus = .live
    ) {
        self.timestamp = timestamp
        self.machineName = machineName
        self.chipName = chipName
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.memory = memory
        self.disk = disk
        self.topProcesses = topProcesses
        self.thermal = thermal
        self.status = status
    }
}
