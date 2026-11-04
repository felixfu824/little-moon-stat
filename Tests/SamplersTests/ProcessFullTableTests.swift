import Testing
@testable import Samplers

private struct RankRandom {
    var state: UInt64 = 0x5eed
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(bound))
    }
}

/// The existing bounded insertion is the reference: with capacity >= table size,
/// it yields every row. Smaller bounds must equal prefixes of the full-table path.
@Test func processFullTableSortMatchesBoundedInsertionOnRandomizedInputs() {
    var random = RankRandom()
    for round in 0..<80 {
        let count = random.next(200) + 1
        var previous: [Int32: ProcessEntry] = [:]
        var current: [Int32: ProcessEntry] = [:]
        for key in 1...count {
            let pid = Int32(key)
            let before = Double(random.next(20))
            let time = UInt64(random.next(10) + 1) * 1_000_000_000
            // Some deliberately inconsistent dictionary keys/entry pids create exact
            // comparator ties with differing metadata, beyond normal real process input.
            let entryPID = round % 2 == 0 ? pid : Int32(key % 4)
            previous[pid] = ProcessEntry(pid: entryPID, name: "old", cpuSeconds: before,
                                         residentBytes: 1, atNanos: time)
            var now = ProcessEntry(pid: entryPID, name: "row \(key)",
                                   cpuSeconds: before + Double(random.next(4)),
                                   residentBytes: UInt64(key), atNanos: time + 3_000_000_000)
            switch random.next(12) {
            case 0: previous.removeValue(forKey: pid) // new pid
            case 1: now.cpuSeconds = before - 1       // reuse/counter rollback
            case 2: now.atNanos = time                // stale source row
            case 3: now.atNanos = time - 1            // timestamp went backwards
            case 4: now.atNanos = time + 10_000_000   // too short a window
            case 5: now.cpuSeconds = .nan
            case 6: now.cpuSeconds = .infinity        // valid under existing math
            default: break
            }
            if random.next(8) != 0 { current[pid] = now } // vanished pid
        }
        let old = ProcessReading(entries: previous)
        let new = ProcessReading(entries: current)
        let full = ProcessDelta.rank(previous: old, current: new, limit: .max)
        // For malformed duplicate entry pids, bounded pruning retains earlier
        // equal rows once full; only full-capacity insertion is the unbounded oracle.
        let limits = round % 2 == 0 ? Set([0, 1, 3, 10, max(1, current.count)])
            : Set([max(1, current.count)])
        for limit in limits {
            let bounded = ProcessDelta.rank(previous: old, current: new, limit: limit)
            #expect(bounded.count == min(limit, full.count))
            for (actual, expected) in zip(bounded, full) {
                #expect(actual.entry == expected.entry)
                #expect(actual.percent == expected.percent)
            }
        }
    }
    #expect(ProcessDelta.rank(previous: ProcessReading(entries: [:]),
                              current: ProcessReading(entries: [:]), limit: .max).isEmpty)
}
