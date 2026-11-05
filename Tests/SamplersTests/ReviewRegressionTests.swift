import Foundation
import Darwin
import Testing
import XCTest
import MonitorCore
@testable import Samplers

private final class ScriptedProcessSource: ProcessSource {
    var readings: [ProcessReading]
    init(_ readings: [ProcessReading]) { self.readings = readings }
    func read() -> ProcessReading? { readings.isEmpty ? nil : readings.removeFirst() }
    func name(for pid: Int32) -> String? { "cached-\(pid)" }
}

private func entry(_ pid: Int32, _ cpu: Double, _ seconds: UInt64, start: UInt64 = 1) -> ProcessEntry {
    ProcessEntry(pid: pid, name: "cached-\(pid)", cpuSeconds: cpu, residentBytes: 1024,
                 atNanos: seconds * 1_000_000_000, startTime: start)
}
private func reading(_ entries: [ProcessEntry]) -> ProcessReading {
    ProcessReading(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) }))
}

@Test func livingRootsSurviveMultipleWatchCadencesWithoutRepeatedEMA() {
    let raw = ScriptedProcessSource([
        reading([entry(1,0,1), entry(2,0,1), entry(3,0,1), entry(4,0,1)]),
        reading([entry(1,5,6), entry(2,4,6), entry(3,3,6), entry(4,0.05,6)]),
    ] + [UInt64(11),16,21,26].map { t in
        // Only the two watched roots refresh. The third root still exists in every table.
        reading([entry(1,Double(t-1),t), entry(2,Double(t-1)*0.8,t), entry(3,3,6), entry(4,Double(t-1)*0.01,t)])
    } + [reading([entry(1,30,31), entry(2,24,31), entry(3,8,31), entry(4,0.3,31)])])
    let sampler = ProcessSampler(source: EngineProcessSource(source: raw))
    var aggregator = Aggregator(machineName: "Mac", chipName: "M5")
    #expect(sampler.sampleProcesses(limit: .max).isEmpty)
    for tick in 0..<6 {
        let rows = sampler.sampleProcesses(limit: .max)
        aggregator.updateProcesses(rows, at: Date(), freshPIDs: sampler.freshPIDs)
        #expect(aggregator.snapshot.topProcesses.map(\.pid) == [1,2,3])
        #expect(abs(aggregator.snapshot.topProcesses[2].cpuPercent - (tick == 5 ? 32 : 60)) < 0.0001) // 0.3 × 60 + 0.7 × 20
    }
}

@Test func staleRatesExpireAndVanishedRowsDropImmediately() {
    let raw = ScriptedProcessSource([
        reading([entry(1,0,1), entry(2,0,1)]),
        reading([entry(1,5,6), entry(2,1,6)]),
        reading([entry(1,5,6), entry(2,2,11)]),
        reading([entry(1,5,6), entry(2,3,37)]),
        reading([]),
    ])
    let sampler = ProcessSampler(source: raw)
    _ = sampler.sampleProcesses(limit: .max)
    #expect(sampler.sampleProcesses(limit: .max).count == 2)
    #expect(sampler.sampleProcesses(limit: .max).count == 2)
    #expect(sampler.sampleProcesses(limit: .max).map(\.pid) == [2])
    #expect(sampler.sampleProcesses(limit: .max).isEmpty)
    #expect(sampler.lastReadSucceeded)
}

@Test func replacementIdentityResetsBaselinesEvenWithIncreasingCPU() {
    for replacementCPU in [0.0, 20.0] {
        let raw = ScriptedProcessSource([
            reading([entry(42,0,1)]), reading([entry(42,5,6)]),
            reading([entry(42,replacementCPU,11,start: 2)]),
            reading([entry(42,replacementCPU,16,start: 2)]),
        ])
        let sampler = ProcessSampler(source: raw)
        var aggregator = Aggregator(machineName: "Mac", chipName: "M5")
        _ = sampler.sampleProcesses(limit: .max)
        aggregator.updateProcesses(sampler.sampleProcesses(limit: .max), at: Date())
        #expect(aggregator.snapshot.topProcesses.first?.cpuPercent == 100)
        let baseline = sampler.sampleProcesses(limit: .max)
        #expect(baseline.isEmpty)
        aggregator.updateProcesses(baseline, at: Date())
        aggregator.updateProcesses(sampler.sampleProcesses(limit: .max), at: Date())
        #expect(aggregator.snapshot.topProcesses.first?.cpuPercent == 0)
        #expect(aggregator.snapshot.topProcesses.first?.startTime == 2)
    }
}

@Test func psStartIdentityPreservesNamesWithSpacesAndChangesOnReuse() throws {
    let first = try #require(PSParsing.parse("42 10 0:01.00 Wed Nov  4 01:00:00 2026 /Applications/Old App", atNanos: 1, withStartTime: true)[42])
    let second = try #require(PSParsing.parse("42 10 0:20.00 Wed Nov  4 01:00:01 2026 /Applications/New App", atNanos: 2, withStartTime: true)[42])
    #expect(first.name == "Old App")
    #expect(first.startTime != second.startTime)
    #expect(ProcessDelta.rank(previous: reading([first]), current: reading([second])).isEmpty)
    let source = EngineProcessSource(source: ScriptedProcessSource([reading([first]), reading([second])]))
    #expect(try #require(source.read()).entries[42]?.name == "Old App")
    #expect(try #require(source.read()).entries[42]?.name == "New App")
}

private final class FailedCPU: CPUUsageSampling {
    var calls = 0
    func sampleCPU() -> Double? { calls += 1; return nil }
}

@Test @MainActor func pausedWakeDoesNotCallAnyCPUSampler() async {
    let cpu = FailedCPU()
    let engine = SamplingEngine(store: SnapshotStore(), cpuSource: cpu)
    engine.systemDidWake()
    try? await Task.sleep(for: .milliseconds(150))
    #expect(cpu.calls == 0)
    engine.stop()
}

@Test func failingInitialCPUStillPublishesOtherMetrics() {
    let cpu = FailedCPU()
    let state = SamplingState(cpuSource: cpu)
    let queue = DispatchQueue(label: "test.sampling")
    queue.sync {
        var snapshots: [Snapshot] = []
        state.start(on: queue, resetSMC: false) { snapshots.append($0) }
        state.stop()
        #expect(cpu.calls == 1)
        #expect(!snapshots.isEmpty)
        #expect(snapshots.allSatisfy { $0.cpuPercent == nil })
        #expect(snapshots.last?.memory != nil)
        #expect(snapshots.last?.disk != nil)
    }
}

final class HostReferenceRegressionTests: XCTestCase {
func testHostSendReferencesRemainStableAcrossTwoHundredSamples() {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    func refs() -> mach_port_urefs_t {
        var count: mach_port_urefs_t = 0
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &count), KERN_SUCCESS)
        return count
    }
    let cpu = CPUUsageSampler(), memory = MemorySampler()
    _ = cpu.sampleCPU(); _ = memory.sampleMemory()
    let before = refs()
    for _ in 0..<100 { _ = cpu.sampleCPU() }
    let afterCPU = refs()
    for _ in 0..<100 { _ = memory.sampleMemory() }
    let afterMemory = refs()
    print("host send refs baseline=\(before) after100CPU=\(afterCPU) after100Memory=\(afterMemory)")
    XCTAssertEqual(afterCPU, before)
    XCTAssertEqual(afterMemory, before)
}

}

@Test func deferredNameCacheIsDiscardedWhenPIDCreationChanges() throws {
    var old = entry(42, 0.1, 1, start: 1)
    var replacement = entry(42, 2, 4, start: 2)
    old.name = nil
    replacement.name = nil
    let source = EngineProcessSource(source: ScriptedProcessSource([reading([old]), reading([replacement])]))
    #expect(try #require(source.read()).entries[42]?.name == "")
    #expect(source.name(for: 42) == "cached-42")
    // The replacement must require a new name lookup rather than inherit cached-42.
    #expect(try #require(source.read()).entries[42]?.name == "")
}

@Test @MainActor func cancelledResumePreservesPendingWakeResetWithoutSampling() async {
    let queue = DispatchQueue(label: "test.suspended.sampling")
    queue.suspend()
    let cpu = FailedCPU()
    let engine = SamplingEngine(store: SnapshotStore(), cpuSource: cpu, queue: queue)
    engine.systemDidWake()
    for _ in 0..<2 {
        engine.resume()
        #expect(engine.pendingWakeReset)
        engine.pause()
        #expect(engine.pendingWakeReset)
    }
    queue.resume()
    try? await Task.sleep(for: .milliseconds(150))
    #expect(cpu.calls == 0)
    #expect(engine.pendingWakeReset)
}

@Test func closedMenuBarSamplesNoPanelMetricsAndDetailsRecover() {
    let cpu = FailedCPU()
    nonisolated(unsafe) var now = 100.0
    let state = SamplingState(cpuSource: cpu, uptime: { now })
    let queue = DispatchQueue(label: "test.menubar.gating")
    queue.sync {
        var snapshots: [Snapshot] = []
        state.start(on: queue, resetSMC: false, details: false, options: DisplayOptions(menuBarMoons:[.cpu,.gpu])) { snapshots.append($0) }
        state.stop()
        #expect(cpu.calls == 0)
        #expect(!snapshots.isEmpty)
        #expect(snapshots.allSatisfy { $0.cpuPercent == nil && $0.gpuPercent == nil && $0.memory == nil && $0.disk == nil && $0.thermal == nil && $0.topProcesses.isEmpty })
        snapshots.removeAll()
        state.start(on: queue, resetSMC: false, details: true) { snapshots.append($0) }
        now += 2 // The next fast tick is one period after the new baseline.
        state.fastTick() // Details resume on the existing fast cadence, retaining held values until then.
        state.stop()
        #expect(cpu.calls == 2)
        #expect(snapshots.last?.memory != nil)
        #expect(snapshots.last?.disk != nil)
    }
}

@Test func publicationKeyIgnoresRawTemperatureNoiseAndKeepsFahrenheitDigits() {
    var s=Snapshot.preview, q=MenuBarQuantizer()
    s.cpuTemp=TempStat(peak:75.01,average:68.01,sensorCount:1)
    let c=DisplayOptions(temperatureUnit:.celsius), f=DisplayOptions(temperatureUnit:.fahrenheit)
    let before=q.update(s)
    let cKey=publicationKey(s,options:c,menuValues:before)
    let fKey=publicationKey(s,options:f,menuValues:before)
    s.cpuTemp?.peak=75.04
    #expect(publicationKey(s,options:c,menuValues:q.update(s)) == cKey)
    s.cpuTemp?.peak=75.4
    #expect(publicationKey(s,options:c,menuValues:q.update(s)) == cKey)
    #expect(publicationKey(s,options:f,menuValues:q.update(s)) != fKey)
}

@Test func closedRAMMoonReadsMemoryWithoutPanelUsageOrProcessWork() {
    let cpu=FailedCPU()
    let ownState=SamplingState(cpuSource:cpu)
    let queue=DispatchQueue(label:"test.ram.only")
    queue.sync {
        var snapshots:[Snapshot]=[]
        ownState.start(on:queue,resetSMC:false,details:false,options:DisplayOptions(menuBarMoons:.ram)) { snapshots.append($0) }
        ownState.stop()
        #expect(cpu.calls == 0)
        #expect(snapshots.last?.memory != nil)
        #expect(snapshots.allSatisfy { $0.cpuPercent == nil && $0.gpuPercent == nil && $0.disk == nil && $0.topProcesses.isEmpty })
    }
}

@Test func popoverPublicationIncludesPhaseStarsAndProcessHighlightOnlyWhenOpen() {
    let options=DisplayOptions(temperatureUnit:.celsius)
    func check(_ before: Snapshot, _ after: Snapshot) {
        var q=MenuBarQuantizer()
        let old=q.update(before), new=q.update(after)
        #expect(displayKey(before) == displayKey(after))
        #expect(old.key(.all) == new.key(.all))
        #expect(publicationKey(before,options:options,menuValues:old) == publicationKey(after,options:options,menuValues:new))
        #expect(publicationKey(before,options:options,menuValues:old,popoverOpen:true) != publicationKey(after,options:options,menuValues:new,popoverOpen:true))
    }
    var a=Snapshot.preview
    a.cpuTemp=TempStat(peak:53.1,average:50,sensorCount:1)
    var b=a; b.cpuTemp?.peak=53.3
    check(a,b)
    a=Snapshot.preview; a.topProcesses[0].cpuPercent=69.96
    b=a; b.topProcesses[0].cpuPercent=70.04
    check(a,b)
    // A star threshold within one rounded desktop-load digit.
    let threshold=PopoverPresentation.stars.first!.2*100
    a=Snapshot.preview
    if PopoverPresentation.stars.first!.0 < 164 { a.cpuPercent=threshold-0.001; b=a; b.cpuPercent=threshold+0.001 }
    else { a.gpuPercent=threshold-0.001; b=a; b.gpuPercent=threshold+0.001 }
    check(a,b)
}

@Test func processRebaselineRejectsCarriedPrePauseEntriesUntilFreshObservations() throws {
    let source = ScriptedProcessSource([
        reading([entry(1,0,1), entry(2,0,1)]),
        reading([entry(1,1,5), entry(2,1,5)]),
        reading([entry(1,2.2,11), entry(2,1,5)]),
        reading([entry(1,3,20), entry(2,100,20)]),
        reading([entry(1,4,28), entry(2,104,28)])
    ])
    let sampler = ProcessSampler(source: source)
    _ = sampler.sampleProcesses(limit: .max)
    #expect(sampler.sampleProcesses(limit: .max).contains { $0.pid == 2 })
    sampler.resetBaseline(reading([entry(1,2,10)]))
    #expect(sampler.sampleProcesses(limit: .max).first { $0.pid == 2 }?.cpuPercent == 25)
    #expect(!sampler.freshPIDs.contains(2))
    // Hold the last rate; the first post-resume ps observation is a baseline,
    // not a new delta spanning the pause.
    #expect(sampler.sampleProcesses(limit: .max).first { $0.pid == 2 }?.cpuPercent == 25)
    #expect(!sampler.freshPIDs.contains(2))
    let fresh = try #require(sampler.sampleProcesses(limit: .max).first { $0.pid == 2 })
    #expect(fresh.cpuPercent == 50)
}
