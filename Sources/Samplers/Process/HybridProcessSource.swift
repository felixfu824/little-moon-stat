import Foundation
import MonitorCore

/// libproc for every readable pid (cheap, ns precision) plus a tiered `ps` bridge for the pids
/// libproc cannot read (other users: WindowServer, root daemons).
///
/// Measured on this Mac (1818 pids, 420 unreadable): `ps` costs ~0.02 ms per process it lists plus a
/// ~1.5 ms spawn, and `ps -p a,b` is pathological (~140 ms). So:
///  - *discovery* (the first two reads, then every `discoveryEvery`-th read): `ps -U <uids of unreadable pids>`
///    for all unreadable pids, no `comm`. Finds which of them burn CPU.
///  - *watch* (every other read): one `ps -p <pid>` per hot unreadable pid (at most `maxWatched`).
/// `discoveryEvery = 1` degrades to "scan every unreadable pid on every read".
public final class HybridProcessSource: ProcessSource, ProcessSourceStatusProviding {
    private let libproc = LibprocProcessSource()
    private let table = KernelProcessTable()
    public let discoveryEvery: Int
    public let maxWatched: Int
    public let hotThresholdPercent: Double

    var psExecutable: String?
    public private(set) var metricStatus: MetricStatus = .live(.libprocAndPS)
    private(set) var retry: RetrySchedule
    private var psAllowed = true
    private var readsSinceDiscovery = 0
    private var discoveries = 0
    /// Latest known entry of every unreadable pid. Carried into each reading unchanged when not
    /// refreshed. ProcessSampler retains their last valid rate until expiry, without a new EMA step.
    private(set) var state: [Int32: ProcessEntry] = [:]
    private(set) var watch: [Int32] = []
    private(set) var names: [Int32: String] = [:]

    public var lastSurvey: LibprocProcessSource.Survey { libproc.lastSurvey }
    public private(set) var lastWatchCount = 0
    public private(set) var lastWasDiscovery = false

    public init(discoveryEvery: Int = 5, maxWatched: Int = 2, hotThresholdPercent: Double = 3.0) {
        self.retry = Self.retrySchedule(discoveryEvery: discoveryEvery,
            processInterval: SamplingCadence.processInterval(logicalCoreCount: ProcessInfo.processInfo.processorCount))
        self.discoveryEvery = max(1, discoveryEvery)
        self.maxWatched = maxWatched
        self.hotThresholdPercent = hotThresholdPercent
    }

    static func retrySchedule(discoveryEvery: Int, processInterval: Double) -> RetrySchedule {
        let cycles = max(3, Int(ceil(300 / (Double(max(1, discoveryEvery)) * processInterval))))
        return RetrySchedule(offsets: [3, 3, cycles])
    }

    // Injectable boundaries exercise PID exit races without depending on live root daemons.
    var readPS: ((PSRunner.Scope, Bool) -> PSRunner.Outcome)?
    var survey: (() -> (ProcessReading, Set<Int32>))?
    private func ps(_ scope: PSRunner.Scope, withName: Bool) -> PSRunner.Outcome {
        readPS?(scope, withName) ?? PSRunner.runStatus(scope, withName: withName, withStartTime: true, executable: psExecutable)
    }

    /// Only libproc deltas need a new baseline. Leave ps rows, watches, names,
    /// discovery cadence and retry history untouched during visibility changes.
    func readBaseline() -> ProcessReading? { survey?().0 ?? libproc.read() }

    public func read() -> ProcessReading? {
        let injected = survey?()
        guard var reading = injected?.0 ?? libproc.read() else { metricStatus = .unavailable(.apiError, source: .libprocOnly); return nil }
        let unreadable = injected?.1 ?? Set(libproc.lastSurvey.unreadablePids)
        state = state.filter { unreadable.contains($0.key) }
        names = names.filter { state[$0.key] != nil }

        let discover = discoveries < 2 || readsSinceDiscovery + 1 >= discoveryEvery
        lastWasDiscovery = discover
        if discover {
            readsSinceDiscovery = 0
            discoveries += 1
            psAllowed = retry.shouldAttempt()
            if psAllowed { discoverUnreadable(unreadable) }
        } else {
            readsSinceDiscovery += 1
            for pid in watch where psAllowed && unreadable.contains(pid) { fetchOne(pid) }
        }
        lastWatchCount = watch.count
        for (pid, e) in state where psAllowed && unreadable.contains(pid) { reading.entries[pid] = e }
        return reading
    }

    /// Called only for rows that made the top list. Unreadable pids that were not watched cost one
    /// single-pid `ps` (~1.8 ms) the first time; the name is cached afterwards.
    public func name(for pid: Int32) -> String? {
        if let n = names[pid] ?? libproc.name(for: pid) { return n }
        if psAllowed { fetchOne(pid) }
        return names[pid]
    }

    // MARK: private

    private func discoverUnreadable(_ unreadable: Set<Int32>) {
        // Leave out (a) uids >= 2^31 (`nobody` = 4294967294 makes `ps -U` fail outright) and (b) our own
        // uid: a few of our own pids are unreadable (login, zombies) and listing uid 501 would make ps
        // print all ~1400 of our processes (40 ms instead of 12 ms).
        let me = getuid()
        let uids = table.realUIDs(of: Array(unreadable)).filter { $0 < 0x8000_0000 && $0 != me }.sorted()
        guard !uids.isEmpty || !unreadable.isEmpty else {
            metricStatus = .live(.libprocAndPS); return
        }
        let outcome = ps(uids.isEmpty ? .all : .users(uids), withName: false)
        guard let r = accept(outcome) else { return }
        let found = PSParsing.parse(r.output, atNanos: r.midNanos, withStartTime: true).filter { unreadable.contains($0.key) }

        // Hot = unreadable pids with CPU since the last time we saw them.
        let ranked = ProcessDelta.rank(
            previous: ProcessReading(entries: state), current: ProcessReading(entries: found))
        watch = ranked.prefix(maxWatched).filter { $0.percent >= hotThresholdPercent }.map(\.entry.pid)

        names = names.filter { found[$0.key]?.startTime == state[$0.key]?.startTime }   // drop vanished pids (pid reuse)
        var next = found
        for pid in found.keys { next[pid]?.name = names[pid] }
        state = next
        // Names (and a fresher reading) for the pids we are about to watch: one single-pid spawn each.
        for pid in watch where names[pid] == nil { fetchOne(pid) }
    }

    private func accept(_ outcome: PSRunner.Outcome) -> PSRunner.Result? {
        if let result = outcome.result {
            retry.recordSuccess(); metricStatus = .live(.libprocAndPS); return result
        }
        let fault = outcome.fault ?? .psUnavailable
        metricStatus = .estimated(.libprocOnly, fault: fault)
        // Spawn failures also back off: repeated EAGAIN should reduce system pressure.
        retry.recordFailure(); psAllowed = false
        state.removeAll(keepingCapacity: true); watch.removeAll(keepingCapacity: true)
        return nil
    }

    private func fetchOne(_ pid: Int32) {
        guard psAllowed else { return }
        let outcome = ps(.pid(pid), withName: true)
        if let result = outcome.result,
           result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.removeValue(forKey: pid); names.removeValue(forKey: pid)
            watch.removeAll { $0 == pid }
            return
        }
        guard let r = accept(outcome),
              let e = PSParsing.parse(r.output, atNanos: r.midNanos, withStartTime: true)[pid] else { return }
        if state[pid]?.startTime != e.startTime { names[pid] = nil }
        if let n = e.name { names[pid] = n }
        state[pid] = e
    }
}
