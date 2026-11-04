import Testing
import MonitorCore
@testable import Samplers

private let sampleOutput = """
    1  33312 134:01.32 /sbin/launchd
  601 523040 2059:38.24 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
 4242  10240   0:00.05 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
 4243   2048   1:02.50 /usr/bin/yes
garbage line without columns
   77   abc   0:01.00 /bin/bad-rss
"""

@Test func cpuTimeFormats() {
    #expect(PSParsing.parseCPUTime("0:00.05") == 0.05)
    #expect(PSParsing.parseCPUTime("1:02.50") == 62.5)
    // Minutes past 60 stay in the minutes field on macOS ps.
    let rollover = PSParsing.parseCPUTime("123:45.67")
    #expect(rollover != nil && abs(rollover! - (123 * 60 + 45.67)) < 1e-9)
    #expect(PSParsing.parseCPUTime("2059:38.24") == 2059 * 60 + 38.24)
    // Hour and day forms, in case ps ever switches format.
    #expect(PSParsing.parseCPUTime("1:00:00.50") == 3600.5)
    #expect(PSParsing.parseCPUTime("2-01:00:00") == 176_400.0)
    #expect(PSParsing.parseCPUTime("abc") == nil)
    #expect(PSParsing.parseCPUTime("12") == nil)
    #expect(PSParsing.parseCPUTime("1:xx") == nil)
}

@Test func executableNameIsBasename() {
    #expect(PSParsing.executableName("/sbin/launchd") == "launchd")
    #expect(PSParsing.executableName("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") == "Google Chrome")
    #expect(PSParsing.executableName("kernel_task") == "kernel_task")
    #expect(PSParsing.executableName("(ps)") == "(ps)")
}

@Test func parsesSyntheticPSOutput() {
    let e = PSParsing.parse(sampleOutput, atNanos: 7)
    #expect(e.count == 4)                      // garbage and bad-rss lines skipped
    #expect(e[601]?.name == "WindowServer")
    #expect(e[601]?.residentBytes == 523_040 * 1024)
    #expect(e[601]?.cpuSeconds == 2059 * 60 + 38.24)
    #expect(e[601]?.atNanos == 7)
    #expect(e[4242]?.name == "Google Chrome")  // spaces in the path survive
    #expect(e[4243]?.cpuSeconds == 62.5)
}

private func entry(_ pid: Int32, cpu: Double, at: UInt64, rss: UInt64 = 1024, name: String = "p") -> ProcessEntry {
    ProcessEntry(pid: pid, name: "\(name)\(pid)", cpuSeconds: cpu, residentBytes: rss, atNanos: at)
}
private func reading(_ es: [ProcessEntry]) -> ProcessReading {
    ProcessReading(entries: Dictionary(uniqueKeysWithValues: es.map { ($0.pid, $0) }))
}
private let sec: UInt64 = 1_000_000_000

@Test func deltaMathsGivesShareOfOneCore() {
    let a = reading([entry(1, cpu: 10, at: 0), entry(2, cpu: 5, at: 0)])
    let b = reading([entry(1, cpu: 12, at: 2 * sec), entry(2, cpu: 5.5, at: 2 * sec)])
    let r = ProcessDelta.rank(previous: a, current: b)
    #expect(r.map(\.entry.pid) == [1, 2])
    #expect(abs(r[0].percent - 100) < 1e-9)   // 2 s of CPU in 2 s
    #expect(abs(r[1].percent - 25) < 1e-9)
}

@Test func percentCanExceedOneHundred() {
    let a = reading([entry(1, cpu: 0, at: 0)])
    let b = reading([entry(1, cpu: 6, at: 2 * sec)])
    #expect(abs(ProcessDelta.rank(previous: a, current: b)[0].percent - 300) < 1e-9)
}

@Test func vanishedAndNewPidsAreSkipped() {
    let a = reading([entry(1, cpu: 1, at: 0), entry(2, cpu: 1, at: 0)])
    let b = reading([entry(2, cpu: 2, at: 2 * sec), entry(3, cpu: 9, at: 2 * sec)])
    let r = ProcessDelta.rank(previous: a, current: b)
    #expect(r.map(\.entry.pid) == [2])         // 1 vanished, 3 has no baseline
}

@Test func pidReuseWithSmallerCPUTimeIsSkipped() {
    let a = reading([entry(1, cpu: 500, at: 0)])
    let b = reading([entry(1, cpu: 0.1, at: 2 * sec)])
    #expect(ProcessDelta.rank(previous: a, current: b).isEmpty)
}

@Test func tieBreaksByPidAndSortsDescending() {
    let a = reading([entry(9, cpu: 0, at: 0), entry(3, cpu: 0, at: 0), entry(5, cpu: 0, at: 0)])
    let b = reading([entry(9, cpu: 1, at: 2 * sec), entry(3, cpu: 1, at: 2 * sec), entry(5, cpu: 2, at: 2 * sec)])
    #expect(ProcessDelta.rank(previous: a, current: b).map(\.entry.pid) == [5, 3, 9])
}

@Test func tooShortWallIntervalIsIgnored() {
    let a = reading([entry(1, cpu: 0, at: 0)])
    let b = reading([entry(1, cpu: 1, at: sec / 100)])
    #expect(ProcessDelta.rank(previous: a, current: b).isEmpty)
}

/// Scripted source for sampler-level tests.
private final class FakeSource: ProcessSource {
    var queue: [ProcessReading?]
    init(_ q: [ProcessReading?]) { queue = q }
    func read() -> ProcessReading? { queue.isEmpty ? nil : queue.removeFirst() }
    func name(for pid: Int32) -> String? { "resolved\(pid)" }
}

@Test func samplerFirstCallEmptyThenRanksAndHandlesVanishedPid() {
    let r1 = reading([entry(1, cpu: 0, at: 0), entry(2, cpu: 0, at: 0), entry(3, cpu: 0, at: 0)])
    let r2 = reading([entry(1, cpu: 2, at: 2 * sec), entry(3, cpu: 1, at: 2 * sec)])   // pid 2 vanished
    let sampler = ProcessSampler(source: FakeSource([r1, r2]))
    #expect(sampler.sampleProcesses(limit: 3).isEmpty)
    let rows = sampler.sampleProcesses(limit: 3)
    #expect(rows.map(\.pid) == [1, 3])
    #expect(rows[0].name == "p1")
    #expect(abs(rows[0].cpuPercent - 100) < 1e-9)
    #expect(rows[0].residentBytes == 1024)
}

@Test func samplerSurvivesFailedReadAndKeepsBaseline() {
    let r1 = reading([entry(1, cpu: 0, at: 0)])
    let r3 = reading([entry(1, cpu: 4, at: 4 * sec)])
    let sampler = ProcessSampler(source: FakeSource([r1, nil, r3]))
    _ = sampler.sampleProcesses(limit: 1)
    #expect(sampler.sampleProcesses(limit: 1).isEmpty)       // failed read
    #expect(sampler.sampleProcesses(limit: 1).first?.pid == 1) // baseline survived
}

@Test func samplerResolvesMissingNamesLazily() {
    let a = ProcessEntry(pid: 8, name: nil, cpuSeconds: 0, residentBytes: 0, atNanos: 0)
    let b = ProcessEntry(pid: 8, name: nil, cpuSeconds: 1, residentBytes: 0, atNanos: 2 * sec)
    let sampler = ProcessSampler(source: FakeSource([reading([a]), reading([b])]))
    _ = sampler.sampleProcesses(limit: 1)
    #expect(sampler.sampleProcesses(limit: 1).first?.name == "resolved8")
}
