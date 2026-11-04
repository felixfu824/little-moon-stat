import Testing
import Darwin
import MonitorCore
@testable import Samplers

/// These hit the real kernel but only for our own pid, which works in any sandbox.
@Test func libprocReadsOwnProcess() throws {
    let source = LibprocProcessSource()
    let reading = try #require(source.read())
    let me = try #require(reading.entries[getpid()])
    #expect(me.cpuSeconds > 0)
    #expect(me.residentBytes > 0)
    #expect(source.lastSurvey.totalPids >= reading.entries.count)
    #expect(source.name(for: getpid()) != nil)
}

@Test func libprocSamplerSeesBusyLoopOverASecond() throws {
    let sampler = ProcessSampler(source: LibprocProcessSource())
    _ = sampler.sampleProcesses(limit: 5)
    let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 600_000_000
    var x = 0.0
    while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end { x += 1; if x > 1e18 { break } }
    let rows = sampler.sampleProcesses(limit: 20)
    let me = try #require(rows.first { $0.pid == getpid() })
    #expect(me.cpuPercent > 50)   // spinning the whole 0.6 s window on one core
}
