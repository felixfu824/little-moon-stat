import Foundation

extension Snapshot {
    /// Fixture matching the approved mockup numbers.
    public static let preview = Snapshot(
        timestamp: Date(timeIntervalSince1970: 1_793_715_000),
        machineName: "MacBook Pro",
        chipName: "Apple M5 Max",
        cpuPercent: 26,
        gpuPercent: 59,
        cpuTemp: TempStat(peak: 75, average: 68, sensorCount: 23),
        gpuTemp: TempStat(peak: 69, average: 67, sensorCount: 84),
        memory: MemoryStat(
            // Binary GB, matching the mockup's "74.4 / 128 GB" (8.8 + 52.3 + 13.3).
            wired: UInt64(8.8 * 1_073_741_824),
            active: UInt64(52.3 * 1_073_741_824),
            compressed: UInt64(13.3 * 1_073_741_824),
            total: 128 * 1_073_741_824
        ),
        disk: DiskStat(volumeName: "Macintosh HD", total: 1_379_000_000_000, free: 379_000_000_000),
        topProcesses: [
            ProcRow(pid: 401, name: "WindowServer", cpuPercent: 85.5, residentBytes: 1_200_000_000),
            ProcRow(pid: 9123, name: "Codex (Server)", cpuPercent: 33.4, residentBytes: 2_800_000_000),
            ProcRow(pid: 312, name: "syspolicyd", cpuPercent: 23.1, residentBytes: 96_000_000),
        ],
        thermal: .nominal
    )
}
