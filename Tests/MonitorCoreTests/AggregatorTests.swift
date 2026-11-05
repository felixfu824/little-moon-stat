import Foundation
import Testing
@testable import MonitorCore

private let time = Date(timeIntervalSince1970: 1_800_000_000)
private func fast(_ a: inout Aggregator, _ cpu: Double?, _ gpu: Double? = nil, _ temp: TempStat? = nil) {
    a.updateFast(cpu: cpu, gpu: gpu, cpuTemp: temp, gpuTemp: temp, memory: nil, thermal: nil, at: time)
}
private func proc(_ pid: Int32, _ cpu: Double, name: String? = nil, rss: UInt64 = 1) -> ProcRow {
    ProcRow(pid: pid, name: name ?? "p\(pid)", cpuPercent: cpu, residentBytes: rss)
}

@Test func aggregatorEMAAndTemperatureMetadata() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    fast(&a, 20, 40, TempStat(peak: 80, average: 60, sensorCount: 10))
    #expect(a.snapshot.cpuPercent == 20)
    #expect(a.snapshot.gpuPercent == 40)
    fast(&a, 80, 60, TempStat(peak: 100, average: 80, sensorCount: 12))
    #expect(a.snapshot.cpuPercent == 50)
    #expect(a.snapshot.gpuPercent == 50)
    // The popover gets the same validated readings without smoothing.
    #expect(a.snapshot.unsmoothed?.cpuPercent == 80)
    #expect(a.snapshot.unsmoothed?.gpuPercent == 60)
    #expect(a.snapshot.unsmoothed?.cpuTemp == TempStat(peak: 100, average: 80, sensorCount: 12))
    #expect(a.snapshot.forPopover.cpuPercent == 80)
    #expect(a.snapshot.forPopover.unsmoothed == nil)
    #expect(a.snapshot.cpuTemp == TempStat(peak: 90, average: 70, sensorCount: 12))
    #expect(a.snapshot.gpuTemp == a.snapshot.cpuTemp)
}

@Test func aggregatorMissingValuesExpireAndRecoverWithoutStaleEMA() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    fast(&a, 20, 30, TempStat(peak: 70, average: 60, sensorCount: 2))
    for _ in 0..<2 {
        fast(&a, nil)
        #expect(a.snapshot.cpuPercent == 20)
        #expect(a.snapshot.cpuTemp?.peak == 70)
    }
    fast(&a, nil)
    #expect(a.snapshot.cpuPercent == nil)
    #expect(a.snapshot.gpuPercent == nil)
    #expect(a.snapshot.cpuTemp == nil)
    fast(&a, 80)
    #expect(a.snapshot.cpuPercent == 80)
    fast(&a, .nan)
    #expect(a.snapshot.cpuPercent == 80)
}

@Test func aggregatorCadencesAndUnsmoothedFieldsAreIndependent() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    let disk = DiskStat(volumeName: "HD", total: 100, free: 40)
    let memory = MemoryStat(wired: 1, active: 2, compressed: 3, total: 10)
    a.updateDisk(disk, at: time)
    a.updateFast(cpu: 40, gpu: 50, cpuTemp: nil, gpuTemp: nil, memory: memory, thermal: .fair, at: time)
    for _ in 0..<20 { a.updateProcesses(nil, at: time) }
    #expect(a.snapshot.cpuPercent == 40)
    #expect(a.snapshot.disk == disk)
    #expect(a.snapshot.memory == memory)
    #expect(a.snapshot.thermal == .fair)
    for _ in 0..<2 { fast(&a, nil); a.updateDisk(nil, at: time) }
    #expect(a.snapshot.memory == memory)
    #expect(a.snapshot.disk == disk)
    #expect(a.snapshot.thermal == .fair)
    fast(&a, nil)
    a.updateDisk(nil, at: time)
    #expect(a.snapshot.memory == nil)
    #expect(a.snapshot.disk == nil)
    #expect(a.snapshot.thermal == nil)
}

@Test func aggregatorProcessMembershipHysteresisAndLatestMetadata() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses([proc(0, 1000), proc(1, 90), proc(2, 80), proc(3, 70), proc(4, 1)], at: time)
    #expect(a.snapshot.topProcesses.map(\.pid) == [1, 2, 3])
    let changed = [proc(1, 1, name: "renamed", rss: 99), proc(2, 1), proc(3, 1), proc(4, 200)]
    a.updateProcesses(changed, at: time)
    // Held members keep their places, except against a clearly hotter newcomer (4 at 100.5
    // against 3 at 35.5), which takes the weakest held place at once.
    #expect(a.snapshot.topProcesses.map(\.pid) == [4, 1, 2])
    #expect(a.snapshot.topProcesses.first { $0.pid == 1 }?.name == "renamed")
    #expect(a.snapshot.topProcesses.first { $0.pid == 1 }?.residentBytes == 99)
    a.updateProcesses(changed, at: time)
    #expect(a.snapshot.topProcesses.map(\.pid) == [4, 1, 2])
    // A newly selected pid vanishes before its two guaranteed ticks: drop immediately.
    a.updateProcesses([proc(1, 1), proc(2, 1), proc(3, 1)], at: time)
    #expect(a.snapshot.topProcesses.map(\.pid).contains(4) == false)
}

@Test func aggregatorHoldStillStopsNearEqualSwaps() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses([proc(1, 50), proc(2, 40), proc(3, 30), proc(4, 20)], at: time)
    let next = [proc(1, 50), proc(2, 40), proc(3, 20), proc(4, 40)]
    a.updateProcesses(next, at: time) // 4 at 30 against held 3 at 25: not clearly hotter.
    #expect(a.snapshot.topProcesses.map(\.pid) == [1, 2, 3])
    a.updateProcesses(next, at: time) // Hold over: plain ranking, 4 at 35 beats 3 at 22.5.
    #expect(a.snapshot.topProcesses.map(\.pid) == [1, 2, 4])
}

@Test func aggregatorProcessEMAForgettingAndFailureCarry() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses([proc(1, 100)], at: time)
    a.updateProcesses([proc(1, 20)], at: time)
    #expect(a.snapshot.topProcesses.first?.cpuPercent == 60)
    #expect(a.snapshot.unsmoothed?.topProcesses.first?.cpuPercent == 20)
    for _ in 0..<2 { a.updateProcesses(nil, at: time); #expect(a.snapshot.topProcesses.count == 1) }
    a.updateProcesses(nil, at: time)
    #expect(a.snapshot.topProcesses.isEmpty)
    a.updateProcesses([proc(1, 10)], at: time)
    #expect(a.snapshot.topProcesses.first?.cpuPercent == 10)
    // A confirmed disappearance clears both membership and CPU history.
    a.updateProcesses([], at: time)
    #expect(a.snapshot.topProcesses.isEmpty)
    a.updateProcesses([proc(1, 30)], at: time)
    #expect(a.snapshot.topProcesses.first?.cpuPercent == 30)
    for _ in 0..<3 { a.updateProcesses([], at: time) }
    a.updateProcesses([proc(1, 50)], at: time)
    #expect(a.snapshot.topProcesses.first?.cpuPercent == 50)
}

@Test func aggregatorProcessTiesAndDuplicatesAreDeterministic() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses([proc(4, 10), proc(2, 10), proc(1, 10), proc(3, 10), proc(1, 900), proc(5, .nan)], at: time)
    #expect(a.snapshot.topProcesses.map(\.pid) == [1, 2, 3])
}

@Test func aggregatorDeferredNamesDoNotSmoothOrAdvanceHysteresis() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses([proc(1, 100), proc(2, 90), proc(3, 80)], at: time)
    a.updateProcessNames([1: "WindowServer", 9: "absent"])
    #expect(a.snapshot.topProcesses[0].name == "WindowServer")
    #expect(a.snapshot.topProcesses[0].cpuPercent == 100)
    a.updateProcesses([proc(1, 0), proc(2, 0), proc(3, 0), proc(4, 1000)], at: time)
    // Names did not advance the hold or smooth again: 1 is at 50 after one blend, and the
    // clearly hotter 4 took the weakest held place.
    #expect(a.snapshot.topProcesses.map(\.pid) == [4, 1, 2])
    #expect(a.snapshot.topProcesses.first { $0.pid == 1 }?.cpuPercent == 50)
    // The popover list ranks by the latest rates alone: the hot newcomer is in at once.
    #expect(a.snapshot.unsmoothed?.topProcesses.first?.pid == 4)
}

@Test func aggregatorRestartedProcessSmoothingTakesTheNextScanRaw() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses([proc(1, 100), proc(2, 5)], at: time)
    a.restartProcessSmoothing()
    a.updateProcesses([proc(1, 4), proc(2, 90)], at: time)
    // Held figures are replaced, not blended; membership rules still apply.
    #expect(a.snapshot.topProcesses.map(\.pid) == [2, 1])
    #expect(a.snapshot.topProcesses.map(\.cpuPercent) == [90, 4])
    // Only one scan is raw; the next one blends again.
    a.updateProcesses([proc(1, 4), proc(2, 0)], at: time)
    #expect(a.snapshot.topProcesses.first { $0.pid == 2 }!.cpuPercent == 45)
}

@Test func restartedSmoothingWaitsForEachProcessesOwnFreshRate() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses([proc(1, 100), proc(2, 80)], at: time)
    a.restartProcessSmoothing()
    // pid 2 has no fresh rate on this scan: it keeps its figure and stays pending.
    a.updateProcesses([proc(1, 10), proc(2, 80)], at: time, freshPIDs: [1])
    #expect(a.snapshot.topProcesses.first { $0.pid == 1 }!.cpuPercent == 10)
    #expect(a.snapshot.topProcesses.first { $0.pid == 2 }!.cpuPercent == 80)
    a.updateProcesses([proc(1, 10), proc(2, 6)], at: time, freshPIDs: [1, 2])
    #expect(a.snapshot.topProcesses.first { $0.pid == 2 }!.cpuPercent == 6)
    #expect(a.snapshot.topProcesses.first { $0.pid == 1 }!.cpuPercent == 10)
}

@Test func aggregatorDisplayKeyUsesVisiblePrecisionAndAllVisibleFields() {
    var s = Snapshot.preview
    s.timestamp = time
    s.cpuPercent = 20.1
    s.memory = MemoryStat(wired: 1_010_000_000, active: 2_010_000_000, compressed: 3_010_000_000, total: 10_000_000_000)
    s.disk = DiskStat(volumeName: "HD", total: 100_100_000_000, free: 40_100_000_000)
    s.topProcesses = [proc(1, 10.1, rss: 1_010_000_000)]
    let key = displayKey(s)
    var same = s
    same.cpuPercent = 20.2
    same.timestamp.addTimeInterval(10)
    same.cpuTemp?.sensorCount += 1
    same.topProcesses[0].pid = 100
    same.topProcesses[0].cpuPercent = 10.11
    same.topProcesses[0].residentBytes += 1_000_000
    same.disk?.free += 1_000_000
    #expect(displayKey(same) == key)
    func differs(_ change: (inout Snapshot) -> Void) {
        var changed = s
        change(&changed)
        #expect(displayKey(changed) != key)
    }
    differs { $0.cpuPercent = 21 }
    differs { $0.gpuPercent = nil }
    differs { $0.cpuTemp?.average += 1 }
    differs { $0.gpuTemp?.peak += 1 }
    differs { $0.memory?.wired += 100_000_000 }
    differs { $0.disk?.free += 1_000_000_000 }
    differs { $0.disk?.volumeName = "different" }
    differs { $0.topProcesses[0].name = "new" }
    differs { $0.topProcesses[0].cpuPercent = 10.2 }
    differs { $0.topProcesses[0].residentBytes += 100_000_000 }
    differs { $0.thermal = .critical }
    differs { $0.timestamp.addTimeInterval(60) }
    differs { $0.machineName = "Studio" }
    differs { $0.chipName = "M6" }
}

@Test func aggregatorDisplayKeyMatchesBinaryMemoryAndSmallProcessRSS() {
    var s = Snapshot.preview
    s.memory = MemoryStat(wired: 1_020_000_000, active: 0, compressed: 0, total: 8_589_934_592)
    s.topProcesses = [proc(1, 85.5, rss: 100_000_000)]
    let key = displayKey(s)
    var changed = s
    // Both decimal values round to 1.0 GB, but GiB crosses 0.95 => 0.9 to 1.0.
    changed.memory?.wired = 1_021_000_000
    #expect(displayKey(changed) != key)
    changed = s
    changed.topProcesses[0].residentBytes = 101_000_000
    #expect(displayKey(changed) != key)
    changed = s
    changed.topProcesses[0].residentBytes = 100_100_000
    #expect(displayKey(changed) == key)
    changed = s
    changed.cpuPercent = 26.6
    #expect(displayKey(changed) != key)
}

@Test func displayKeyTracksRendererHalfRoundingAndHighlightBoundary() {
    var first = Snapshot.preview
    first.cpuPercent = 26.5
    var second = first
    second.cpuPercent = 26.6
    #expect(DisplayFormat.number(first.cpuPercent) == "26")
    #expect(DisplayFormat.number(second.cpuPercent) == "27")
    #expect(displayKey(first) != displayKey(second))
    first.topProcesses[0].cpuPercent = 49.96
    second = first
    second.topProcesses[0].cpuPercent = 50.04
    #expect(DisplayFormat.number(first.topProcesses[0].cpuPercent, decimals: 1) == DisplayFormat.number(second.topProcesses[0].cpuPercent, decimals: 1))
    #expect(!DisplayFormat.hot(first.topProcesses[0].cpuPercent))
    #expect(DisplayFormat.hot(second.topProcesses[0].cpuPercent))
    #expect(displayKey(first) != displayKey(second))
}

@Test func replacementIdentityClearsEMAAndMembershipHold() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses([ProcRow(pid: 42, name: "old", cpuPercent: 100, residentBytes: 0, startTime: 1),
                       proc(1, 80), proc(2, 60)], at: time)
    a.updateProcesses([ProcRow(pid: 42, name: "new", cpuPercent: 0, residentBytes: 0, startTime: 2),
                       proc(1, 80), proc(2, 60), proc(3, 50)], at: time)
    #expect(a.snapshot.topProcesses.map(\.pid) == [1,2,3])
}

@Test func displayKeyIncludesCompactProcessRoundingAndExactMemoryTotal() {
    var a = Snapshot.preview
    a.topProcesses[0].cpuPercent = 26.49
    var b = a
    b.topProcesses[0].cpuPercent = 26.51
    #expect(DisplayFormat.number(a.topProcesses[0].cpuPercent, decimals: 1) == DisplayFormat.number(b.topProcesses[0].cpuPercent, decimals: 1))
    #expect(displayKey(a) != displayKey(b))
    a.memory = MemoryStat(wired: 0, active: 0, compressed: 0, total: 8_589_934_592)
    b = a
    b.memory?.total += 1
    #expect(DisplayFormat.memory(a.memory) != DisplayFormat.memory(b.memory))
    #expect(displayKey(a) != displayKey(b))
}

@Test func diskBarChangesEvenWhenTerabyteLabelsMatch() {
    var a = Snapshot.preview
    a.disk = DiskStat(volumeName: "HD", total: 4_000_000_000_000, free: 1_960_000_000_000)
    var b = a
    b.disk?.free = 2_040_000_000_000
    #expect(DisplayFormat.storage(a.disk!.used) == DisplayFormat.storage(b.disk!.used))
    #expect(DisplayFormat.storage(a.disk!.free) == DisplayFormat.storage(b.disk!.free))
    #expect(displayKey(a) != displayKey(b))
}
