import Foundation
import Darwin

/// Unprivileged libproc scan. Nanosecond CPU precision, but other users' processes
/// (WindowServer, kernel_task, ...) fail with EPERM.
public final class LibprocProcessSource: ProcessSource {
    /// What the last `read()` saw. Used by the spike to report visibility.
    public struct Survey: Sendable {
        public var totalPids = 0
        public var readable = 0
        public var failuresByErrno: [Int32: Int] = [:]
        public var unreadablePids: [Int32] = []
    }

    public private(set) var lastSurvey = Survey()
    private var timebase = mach_timebase_info_data_t(numer: 0, denom: 0)
    private var pidBuffer = [pid_t](repeating: 0, count: 4096)

    public init() {
        mach_timebase_info(&timebase)
        if timebase.denom == 0 { timebase = mach_timebase_info_data_t(numer: 1, denom: 1) }
    }

    public func read() -> ProcessReading? {
        // proc_listallpids takes a byte capacity but RETURNS A PID COUNT (not bytes).
        var count = Int(proc_listallpids(&pidBuffer, Int32(pidBuffer.count * MemoryLayout<pid_t>.stride)))
        if count <= 0 { return nil }
        // Table grew to fill the buffer: double it and retry once.
        if count >= pidBuffer.count - 16 {
            pidBuffer = [pid_t](repeating: 0, count: pidBuffer.count * 2)
            count = Int(proc_listallpids(&pidBuffer, Int32(pidBuffer.count * MemoryLayout<pid_t>.stride)))
            if count <= 0 { return nil }
        }
        var survey = Survey()
        survey.totalPids = count
        var scanned: [(pid: Int32, seconds: Double, rss: UInt64, start: UInt64)] = []
        scanned.reserveCapacity(count)
        let numer = Double(timebase.numer), denom = Double(timebase.denom)

        var info = rusage_info_v0()   // V0 already has user/system time and resident size; ~18% cheaper than V4
        let t0 = monotonicNanos()
        for i in 0..<count {
            let pid = pidBuffer[i]
            if pid < 0 { continue }
            let rc = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
                }
            }
            if rc != 0 {
                let e = errno
                survey.failuresByErrno[e, default: 0] += 1
                survey.unreadablePids.append(pid)
                continue
            }
            let ticks = info.ri_user_time &+ info.ri_system_time
            let seconds = Double(ticks) * numer / denom / 1e9
            scanned.append((pid, seconds, info.ri_resident_size, info.ri_proc_start_abstime))
            survey.readable += 1
        }
        // One timestamp for the whole scan (the midpoint): the scan takes a few ms, the cadence is seconds.
        let mid = t0 / 2 + monotonicNanos() / 2
        var entries: [Int32: ProcessEntry] = [:]
        entries.reserveCapacity(scanned.count)
        for r in scanned {
            entries[r.pid] = ProcessEntry(pid: r.pid, name: nil, cpuSeconds: r.seconds,
                                          residentBytes: r.rss, atNanos: mid, startTime: r.start)
        }
        lastSurvey = survey
        return ProcessReading(entries: entries)
    }

    public func name(for pid: Int32) -> String? {
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathCount = proc_pidpath(pid, &path, UInt32(path.count))
        if pathCount > 0, let full = String(bytes: path.prefix { $0 != 0 }, encoding: .utf8) {
            return PSParsing.executableName(full[...])
        }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let name = Self.decodeTruncatedName(Array(buf.prefix(Int(n)).prefix { $0 != 0 }))
        return name.isEmpty ? nil : name
    }

    /// Kernel name buffers can end partway through a UTF-8 scalar. Trim only
    /// that incomplete suffix; do not insert a replacement character.
    static func decodeTruncatedName(_ bytes: [UInt8]) -> String {
        for removed in 0...min(3, bytes.count) {
            let prefix = bytes.dropLast(removed)
            if let value = String(bytes: prefix, encoding: .utf8) { return value }
            // A removed ASCII byte cannot be an incomplete trailing scalar.
            if removed > 0 && bytes[bytes.count - removed] < 0x80 { break }
        }
        return ""
    }
}
