import Foundation

/// Parsing for `/bin/ps -axo pid=,rss=,time=,comm=` output.
public enum PSParsing {
    /// `TIME` column to seconds. Accepts `M:SS.cc`, `MMM:SS.cc` (minutes may exceed 59),
    /// `H:MM:SS.cc` and `D-HH:MM:SS`. Returns nil on anything else.
    public static func parseCPUTime(_ s: Substring) -> Double? {
        var rest = s
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[rest.startIndex..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0, v.isFinite else { return nil }
            total = total * 60 + v
        }
        return days * 86_400 + total
    }

    /// Basename of the `comm` column (a full path on macOS, may contain spaces).
    public static func executableName(_ comm: Substring) -> String {
        if let slash = comm.lastIndex(of: "/") {
            let tail = comm[comm.index(after: slash)...]
            return tail.isEmpty ? String(comm) : String(tail)
        }
        return String(comm)
    }

    /// Parse the whole output. Malformed lines are skipped. `atNanos` stamps every entry.
    /// The `comm` column is optional: with only `pid,rss,time` the entry name is nil.
    public static func parse(_ text: String, atNanos: UInt64, withStartTime: Bool = false) -> [Int32: ProcessEntry] {
        var entries: [Int32: ProcessEntry] = [:]
        entries.reserveCapacity(1024)
        text.enumerateLines { line, _ in
            // pid rss time [comm...]  (comm keeps its own spaces)
            let f = line.split(separator: " ", maxSplits: withStartTime ? 8 : 3, omittingEmptySubsequences: true)
            guard f.count >= 3,
                  let pid = Int32(f[0]),
                  let rssKB = UInt64(f[1]),
                  let cpu = parseCPUTime(f[2])
            else { return }
            if withStartTime && f.count < 8 { return }
            // ps lstart is stable across scans, unlike elapsed-time rounding. FNV-1a
            // encodes its five fixed English-locale fields without a DateFormatter per process.
            let start = withStartTime ? f[3..<8].joined(separator: " ").utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 } : 0
            let nameIndex = withStartTime ? 8 : 3
            entries[pid] = ProcessEntry(
                pid: pid,
                name: f.count > nameIndex ? executableName(f[nameIndex]) : nil,
                cpuSeconds: cpu,
                residentBytes: rssKB * 1024,
                atNanos: atNanos, startTime: start
            )
        }
        return entries
    }
}
