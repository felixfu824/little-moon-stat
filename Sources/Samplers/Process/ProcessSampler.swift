import Foundation
import MonitorCore

/// Top-N processes by CPU, including other users' processes (WindowServer, kernel_task).
/// First call returns an empty list (it needs a baseline). Never throws, never crashes on a vanished pid.
public final class ProcessSampler: ProcessSampling {
    private let source: ProcessSource
    private var previous: ProcessReading?
    private var rebaselineAfter: UInt64?
    private var rates: [Int32: (entry: ProcessEntry, percent: Double)] = [:]
    private let expiryNanos: UInt64
    /// PIDs with a new timestamp and valid CPU delta; carried observations are not fresh.
    public private(set) var freshPIDs: Set<Int32> = []
    public private(set) var lastReadSucceeded = false

    public init(source: ProcessSource = HybridProcessSource(), expirySeconds: Double = 30) {
        self.expiryNanos = UInt64(max(0, expirySeconds) * 1e9)
        self.source = source
    }

    /// Restart only delta measurement; the source retains discovery and retry policy.
    func resetBaseline(_ reading: ProcessReading? = nil) {
        // A carried ps entry can predate the pause. Do not let it become a
        // baseline again before that PID receives a genuinely new observation.
        rebaselineAfter = previous == nil ? nil : (reading?.entries.values.map(\.atNanos).max() ?? monotonicNanos())
        previous = reading; freshPIDs = []
    }

    public func sampleProcesses(limit: Int) -> [ProcRow] {
        freshPIDs = []
        lastReadSucceeded = false
        guard limit > 0, var current = source.read() else { return [] }
        var carried: [Int32: ProcessEntry] = [:]
        if let cutoff = rebaselineAfter {
            for (pid, entry) in current.entries where entry.atNanos < cutoff { carried[pid] = entry }
            if carried.isEmpty { rebaselineAfter = nil }
            else { for pid in carried.keys { current.entries.removeValue(forKey: pid) } }
        }
        lastReadSucceeded = true
        defer { previous = current }
        let now = current.entries.values.map(\.atNanos).max() ?? 0
        rates = rates.filter { pid, rate in
            guard let entry = current.entries[pid] ?? carried[pid] else { return false }
            return entry.startTime == rate.entry.startTime && entry.cpuSeconds >= rate.entry.cpuSeconds
                && now >= rate.entry.atNanos && now - rate.entry.atNanos <= expiryNanos
        }
        if let previous {
            for item in ProcessDelta.rank(previous: previous, current: current,
                                          onInvalid: { self.rates.removeValue(forKey: $0) }) {
                rates[item.entry.pid] = item
                freshPIDs.insert(item.entry.pid)
            }
        }
        let ranked = rates.values.sorted {
            $0.percent == $1.percent ? $0.entry.pid < $1.entry.pid : $0.percent > $1.percent
        }.prefix(limit)
        return ranked.map { item in
            ProcRow(pid: item.entry.pid,
                    name: item.entry.name ?? source.name(for: item.entry.pid) ?? "pid \(item.entry.pid)",
                    cpuPercent: item.percent, residentBytes: item.entry.residentBytes,
                    startTime: item.entry.startTime)
        }
    }
    public func sampleProcessesStatus(limit: Int) -> Sample<[ProcRow]> {
        let rows = sampleProcesses(limit: limit)
        guard lastReadSucceeded else { return .failure(.apiError, source: .libprocOnly) }
        let status = (source as? ProcessSourceStatusProviding)?.metricStatus ?? .live(.libprocAndPS)
        return Sample(value: rows, source: status.source, fault: status.fault)
    }

}
