import Darwin
import Testing
@testable import Samplers

@Test func cpuTickMathIncludesNiceAndSystemAcrossAllCores() {
    // Darwin order: USER, SYSTEM, IDLE, NICE. Core busy: 50% and 25% => 37.5%.
    #expect(CPUUsageSampler.busyPercent(previous: [0,0,0,0, 0,0,0,0],
                                       current: [20,20,50,10, 10,10,75,5]) == 37.5)
    #expect(CPUUsageSampler.busyPercent(previous: [0,0,0,0], current: [0,0,0,0]) == nil)
    #expect(CPUUsageSampler.busyPercent(previous: [], current: []) == nil)
    #expect(CPUUsageSampler.busyPercent(previous: [0], current: [0]) == nil)
    #expect(CPUUsageSampler.busyPercent(previous: [0,0,0,0], current: []) == nil)
}

@Test func cpuTickMathHandlesCounterWrap() {
    #expect(CPUUsageSampler.busyPercent(previous: [.max - 4, 0, .max - 4, 0],
                                       current: [5, 0, 5, 0]) == 50)
}

@Test func systemMarketingNamesDropNULAndModelDetails() {
    #expect(SystemInfo.modelName("MacBook Pro (14-inch, M5, 2026)\0") == "MacBook Pro")
    #expect(SystemInfo.modelName("Mac Studio\0\0") == "Mac Studio")
    #expect(SystemInfo.modelName(nil) == "Mac")
    #expect(SystemInfo.modelName("\0\n ") == "Mac")
}

private final class DeferredNameSource: ProcessSource {
    var tick: UInt64 = 1_000_000_000
    var lookups: [Int32] = []
    var pids: [Int32] = Array(1...100)
    var resolvedName = "actual"
    func read() -> ProcessReading? {
        defer { tick += 3_000_000_000 }
        return ProcessReading(entries: Dictionary(uniqueKeysWithValues: pids.map {
            ($0, ProcessEntry(pid: $0, name: nil, cpuSeconds: Double(tick) / 1e9,
                              residentBytes: 100, atNanos: tick))
        }))
    }
    func name(for pid: Int32) -> String? { lookups.append(pid); return resolvedName }
}

@Test func engineSourceKeepsAllPidsAndDefersOnlyNames() throws {
    let raw = DeferredNameSource()
    let source = EngineProcessSource(source: raw)
    let sampler = ProcessSampler(source: source)
    #expect(sampler.sampleProcesses(limit: .max).isEmpty)
    let rows = sampler.sampleProcesses(limit: .max)
    #expect(rows.count == 100)
    #expect(raw.lookups.isEmpty)
    #expect(source.name(for: 1) == "actual")
    #expect(raw.lookups == [1])
    let reading = try #require(source.read())
    #expect(reading.entries[1]?.name == "actual")
    // Names are refreshed whenever a row is displayed, including after exec/rename.
    raw.resolvedName = "renamed"
    #expect(source.name(for: 1) == "renamed")
    raw.pids = [2]
    #expect(try #require(source.read()).entries.count == 1)
    raw.pids = [1]
    #expect(try #require(source.read()).entries[1]?.name == "")
}
