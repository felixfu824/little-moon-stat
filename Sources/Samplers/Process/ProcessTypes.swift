import Foundation
import MonitorCore

/// One process as seen by a source at one instant. CPU time is cumulative (user + system) in seconds.
public struct ProcessEntry: Sendable, Equatable {
    /// Stable creation identity: libproc start abstime or the C-locale ps lstart fingerprint.
    public var startTime: UInt64
    public var pid: Int32
    /// Executable basename. `nil` when the source did not resolve it (libproc resolves lazily).
    public var name: String?
    public var cpuSeconds: Double
    public var residentBytes: UInt64
    /// Monotonic time (ns, `CLOCK_UPTIME_RAW`) at which `cpuSeconds` was read.
    public var atNanos: UInt64

    public init(pid: Int32, name: String?, cpuSeconds: Double, residentBytes: UInt64, atNanos: UInt64, startTime: UInt64 = 0) {
        self.startTime = startTime
        self.pid = pid
        self.name = name
        self.cpuSeconds = cpuSeconds
        self.residentBytes = residentBytes
        self.atNanos = atNanos
    }
}

/// A full scan of the process table.
public struct ProcessReading: Sendable {
    public var entries: [Int32: ProcessEntry]
    public init(entries: [Int32: ProcessEntry]) { self.entries = entries }
}

protocol ProcessSourceStatusProviding { var metricStatus: MetricStatus { get } }

/// Produces a cumulative-CPU snapshot of all processes. Implementations never throw.
public protocol ProcessSource: AnyObject {
    func read() -> ProcessReading?
    /// Resolve a display name for a pid whose entry has `name == nil`.
    func name(for pid: Int32) -> String?
}

@inline(__always)
func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Pure delta maths, kept free of system calls so it is unit-testable.
public enum ProcessDelta {
    /// CPU share of one core (can exceed 100) for every pid present in both readings.
    /// Pids that appeared since `previous` are skipped (no baseline). A cumulative time that went
    /// backwards (pid reuse) is skipped, and so is an entry whose timestamp did not advance (stale).
    /// `limit` keeps only the best N (insertion into a small sorted array, no full sort).
    /// Result is sorted by percent descending, then pid ascending.
    public static func rank(
        previous: ProcessReading,
        current: ProcessReading,
        limit: Int = .max,
        onInvalid: ((Int32) -> Void)? = nil
    ) -> [(entry: ProcessEntry, percent: Double)] {
        var out: [(entry: ProcessEntry, percent: Double)] = []
        out.reserveCapacity(limit == .max ? current.entries.count : limit + 1)
        @inline(__always) func before(_ a: (entry: ProcessEntry, percent: Double),
                                      _ b: (entry: ProcessEntry, percent: Double)) -> Bool {
            a.percent != b.percent ? a.percent > b.percent : a.entry.pid < b.entry.pid
        }
        let maximumPercent = Double(ProcessInfo.processInfo.processorCount) * 100
        for (pid, cur) in current.entries {
            guard let prev = previous.entries[pid], prev.startTime == cur.startTime else { continue }
            let dCPU = cur.cpuSeconds - prev.cpuSeconds
            let dWall = Double(cur.atNanos &- prev.atNanos) / 1e9
            guard dCPU >= 0, cur.atNanos > prev.atNanos, dWall > 0.05 else {
                if cur.atNanos > prev.atNanos && (!dCPU.isFinite || dCPU < 0) { onInvalid?(pid) }
                continue
            }
            let percent = dCPU / dWall * 100
            guard percent.isFinite, percent <= maximumPercent else { onInvalid?(pid); continue }
            let item = (entry: cur, percent: percent)
            if limit == .max {
                out.append(item)
                continue
            }
            if out.count == limit, let last = out.last, !before(item, last) { continue }
            // insert keeping `out` sorted
            var lo = 0, hi = out.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if before(out[mid], item) { lo = mid + 1 } else { hi = mid }
            }
            out.insert(item, at: lo)
            if out.count > limit { out.removeLast() }
        }
        if limit == .max {
            // Full-table engine samples need O(n log n), not O(n²) sorted insertion.
            // Lower-bound insertion above reverses comparator-equivalent rows. Reverse
            // first so stable sort preserves that behavior even for malformed duplicate pids.
            out.reverse()
            out.sort(by: before)
        }
        return out
    }
}
