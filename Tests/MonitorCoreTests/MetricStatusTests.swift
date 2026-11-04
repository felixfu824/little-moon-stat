import Foundation
import Testing
@testable import MonitorCore

// Metric status: contract, detectors and Aggregator status plumbing.

private let time = Date(timeIntervalSince1970: 1_800_000_000)
/// `#expect` cannot wrap a mutating call; evaluate it first.
private func check<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
private let warm = TempStat(peak: 60, average: 55, sensorCount: 8)

private func temps(_ cpu: Sample<TempStat>, _ gpu: Sample<TempStat>? = nil) -> TemperatureSample {
    TemperatureSample(cpu: cpu, gpu: gpu ?? Sample(value: warm, source: .chipMap))
}
private func tick(_ a: inout Aggregator, cpu: Sample<Double>? = nil, temp: Sample<TempStat>? = nil) {
    a.updateFast(cpu: cpu, gpu: nil, temperatures: temp.map { temps($0) }, memory: nil, thermal: nil, at: time)
}

// MARK: Sample quality and status helpers

@Test func sampleQualityFollowsValueSourceAndFault() {
    #expect(Sample<Double>(value: 5, source: .hostProcessorInfo).quality == .live)
    #expect(Sample<Double>(value: nil, source: .hostProcessorInfo).quality == .unavailable)
    #expect(Sample(value: warm, source: .genericFamily, fault: .unknownChip).quality == .estimated)
    #expect(Sample(value: warm, source: .genericFamily).quality == .estimated)
    #expect(Sample<[ProcRow]>(value: [], source: .libprocOnly, fault: .psUnavailable).quality == .estimated)
    #expect(MetricStatus.unavailable(.stuck, source: .chipMap).key == "unavailable:stuck")
    #expect(MetricStatus.live(.chipMap).key == "live:-")
}

@Test func statusLinePicksHighestPriorityNonLiveMetric() {
    var status = SnapshotStatus.live
    #expect(status.statusLine == nil)
    status.identity = .estimated(.builtInDefault)
    #expect(status.statusLine == nil)                      // identity never drives the status line
    status.disk = .unavailable(.apiError)
    status.processes = .estimated(.libprocOnly, fault: .psUnavailable)
    #expect(status.statusLine?.metric == .processes)
    status.gpuTemp = .estimated(.genericFamily, fault: .unknownChip)
    #expect(status.statusLine?.metric == .gpuTemp)
    #expect(status.keys.count == StatusMetric.allCases.count)
}

@Test func defaultWrappersReportPrimarySources() {
    final class CPU: CPUUsageSampling { func sampleCPU() -> Double? { 12 } }
    final class Temps: TemperatureSampling {
        func sampleTemperatures() -> (cpu: TempStat?, gpu: TempStat?) { (warm, nil) }
    }
    final class Procs: ProcessSampling { func sampleProcesses(limit: Int) -> [ProcRow] { [] } }
    let cpu = CPU().sampleCPUStatus()
    #expect(cpu.value == 12 && cpu.source == .hostProcessorInfo && cpu.fault == nil)
    let t = Temps().sampleTemperaturesStatus()
    #expect(t.cpu.value == warm && t.cpu.source == .chipMap)
    #expect(t.gpu.value == nil && t.gpu.fault == nil)
    #expect(Procs().sampleProcessesStatus(limit: 3).value == [])
}

@Test func snapshotDefaultsToLiveAndPreviewStaysLive() {
    #expect(Snapshot.preview.status == .live)
}

// MARK: JumpGuard

@Test func jumpGuardHoldsOneTickThenAcceptsConfirmedJump() {
    var guardian = JumpGuard()
    check(guardian.check(50), JumpGuard.Verdict.accept)                 // first read after reset
    check(guardian.check(85), JumpGuard.Verdict.accept)                 // 35 °C: below the 40 °C threshold
    check(guardian.check(30), JumpGuard.Verdict.hold)                   // 55 °C drop: suspect
    check(guardian.check(32), JumpGuard.Verdict.accept)                 // confirmed: accepted
    check(guardian.check(34), JumpGuard.Verdict.accept)                 // new baseline is 32
}

@Test func jumpGuardDiscardsGlitchAndCatchesAlternatingSpikes() {
    var guardian = JumpGuard()
    check(guardian.check(60), JumpGuard.Verdict.accept)
    check(guardian.check(120), JumpGuard.Verdict.hold)                  // glitch
    check(guardian.check(61), JumpGuard.Verdict.accept)                 // back near the held value
    check(guardian.check(120), JumpGuard.Verdict.hold)                  // the next spike is caught again
    check(guardian.check(60), JumpGuard.Verdict.accept)
    guardian.reset()
    check(guardian.check(120), JumpGuard.Verdict.accept)                // no baseline after a reset
}

// MARK: StuckDetector

@Test func stuckDetectorNeedsCPUSwingInsideShortWindow() {
    var detector = StuckDetector(windowTicks: 5, maximumTicks: 20, minimumCPUSpan: 25)
    for _ in 0..<10 { check(detector.observe(peak: 50, average: 45, cpuPercent: 10), StuckDetector.Event.normal) }
    var other = StuckDetector(windowTicks: 5, maximumTicks: 20, minimumCPUSpan: 25)
    let loads: [Double] = [5, 40, 5, 40]
    for load in loads { check(other.observe(peak: 50, average: 45, cpuPercent: load), StuckDetector.Event.normal) }
    check(other.observe(peak: 50, average: 45, cpuPercent: 5), StuckDetector.Event.becameStuck)   // 5th identical, span 35
    check(other.observe(peak: 50, average: 45, cpuPercent: 5), StuckDetector.Event.stillStuck)
    check(other.observe(peak: 50.01, average: 45, cpuPercent: 5), StuckDetector.Event.normal)    // first differing read
    #expect(!other.isStuck)
}

@Test func stuckDetectorTripsOnLongWindowRegardlessOfLoad() {
    var detector = StuckDetector(windowTicks: 5, maximumTicks: 8, minimumCPUSpan: 25)
    for _ in 0..<7 { check(detector.observe(peak: 50, average: 45, cpuPercent: nil), StuckDetector.Event.normal) }
    check(detector.observe(peak: 50, average: 45, cpuPercent: nil), StuckDetector.Event.becameStuck)
    detector.reset()
    check(detector.observe(peak: 50, average: 45, cpuPercent: nil), StuckDetector.Event.normal)
}

@Test func stuckDetectorDefaultsMatchSpec() {
    let detector = StuckDetector()
    #expect(detector.windowTicks == 90 && detector.maximumTicks == 300 && detector.minimumCPUSpan == 25)
}

// MARK: RetrySchedule

@Test func retryScheduleFollowsStandardOffsets() {
    var schedule = RetrySchedule()
    check(schedule.shouldAttempt(), true); #expect(!schedule.isBackingOff)
    var attempts: [Int] = []
    var tickIndex = 0
    schedule.recordFailure()                               // failure 1 at tick 0
    while attempts.count < 8, tickIndex < 2_000 {
        tickIndex += 1
        if schedule.shouldAttempt() {
            attempts.append(tickIndex)
            schedule.recordFailure()
        }
    }
    let gaps = zip(attempts, [0] + attempts).map { $0 - $1 }
    #expect(gaps == [1, 1, 1, 15, 15, 15, 150, 150])
    schedule.recordSuccess()
    #expect(!schedule.isBackingOff); check(schedule.shouldAttempt(), true)
}

@Test func retryScheduleCustomOffsetsForProcessBackoff() {
    var schedule = RetrySchedule(offsets: [3])
    schedule.recordFailure()
    check(schedule.shouldAttempt(), false)
    check(schedule.shouldAttempt(), false)
    check(schedule.shouldAttempt(), true)
}

// MARK: Aggregator status plumbing

@Test func aggregatorStartsMeasuringThenGoesLive() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    #expect(a.snapshot.status.cpuTemp == .unavailable(.firstSample))
    #expect(a.snapshot.status.identity == .live)
    tick(&a, cpu: Sample(value: nil, source: .hostProcessorInfo), temp: Sample(value: warm, source: .chipMap))
    #expect(a.snapshot.status.cpuPercent == .unavailable(.firstSample, source: .hostProcessorInfo))
    #expect(a.snapshot.status.cpuTemp == .live(.chipMap))
    tick(&a, cpu: Sample(value: 20, source: .hostProcessorInfo), temp: Sample(value: warm, source: .chipMap))
    #expect(a.snapshot.status.cpuPercent == .live(.hostProcessorInfo))
}

@Test func aggregatorHoldsTwoMissesThenReportsTheFault() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    tick(&a, temp: Sample(value: warm, source: .chipMap))
    for _ in 0..<2 {
        tick(&a, temp: .failure(.serviceUnavailable, source: .chipMap))
        #expect(a.snapshot.cpuTemp == warm)
        #expect(a.snapshot.status.cpuTemp == .live(.chipMap))
    }
    tick(&a, temp: .failure(.serviceUnavailable, source: .chipMap))
    #expect(a.snapshot.cpuTemp == nil)
    #expect(a.snapshot.status.cpuTemp == .unavailable(.serviceUnavailable, source: .chipMap))
    // A miss with no reason after a value existed is an apiError.
    var b = Aggregator(machineName: "Mac", chipName: "M5")
    tick(&b, cpu: Sample(value: 10, source: .hostProcessorInfo))
    for _ in 0..<3 { tick(&b, cpu: Sample(value: nil, source: .hostProcessorInfo)) }
    #expect(b.snapshot.status.cpuPercent == .unavailable(.apiError, source: .hostProcessorInfo))
}

@Test func aggregatorGenericRungIsEstimated() {
    var a = Aggregator(machineName: "Mac", chipName: "M9")
    tick(&a, temp: Sample(value: warm, source: .genericFamily, fault: .unknownChip))
    #expect(a.snapshot.cpuTemp == warm)
    #expect(a.snapshot.status.cpuTemp == .estimated(.genericFamily, fault: .unknownChip))
    #expect(a.snapshot.status.statusLine?.metric == .cpuTemp)
}

@Test func aggregatorNotSampledAgesValueWithoutFault() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    tick(&a, cpu: Sample(value: 30, source: .hostProcessorInfo))
    tick(&a); tick(&a)
    #expect(a.snapshot.cpuPercent == 30 && a.snapshot.status.cpuPercent == .live(.hostProcessorInfo))
    tick(&a)
    #expect(a.snapshot.cpuPercent == nil)
    #expect(a.snapshot.status.cpuPercent == .unavailable(.firstSample, source: .hostProcessorInfo))
}

@Test func aggregatorRejectsOutOfRangeAndNonFiniteValues() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    for _ in 0..<3 { tick(&a, cpu: Sample(value: 140, source: .hostProcessorInfo)) }
    #expect(a.snapshot.cpuPercent == nil)
    #expect(a.snapshot.status.cpuPercent == .unavailable(.outOfRange, source: .hostProcessorInfo))
    let hot = TempStat(peak: 300, average: 200, sensorCount: 2)
    for _ in 0..<3 { tick(&a, temp: Sample(value: hot, source: .chipMap)) }
    #expect(a.snapshot.cpuTemp == nil && a.snapshot.status.cpuTemp.fault == .outOfRange)
    let nan = TempStat(peak: .nan, average: 50, sensorCount: 2)
    var b = Aggregator(machineName: "Mac", chipName: "M5")
    for _ in 0..<3 { tick(&b, temp: Sample(value: nan, source: .chipMap)) }
    #expect(b.snapshot.status.cpuTemp == .unavailable(.nonFinite, source: .chipMap))
    var c = Aggregator(machineName: "Mac", chipName: "M5")
    let bad = MemoryStat(wired: 10, active: 10, compressed: 0, total: 10)
    for _ in 0..<3 { c.updateFast(cpu: nil, gpu: nil, temperatures: nil,
                                  memory: Sample(value: bad, source: .hostStatistics), thermal: nil, at: time) }
    #expect(c.snapshot.status.memory.fault == .outOfRange)
    c.updateDisk(Sample(value: DiskStat(volumeName: "x", total: 4, free: 10), source: .volumeCapacity), at: time)
    #expect(c.snapshot.status.disk == .unavailable(.outOfRange, source: .volumeCapacity))
}

@Test func aggregatorJumpIsHeldOneTick() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    tick(&a, temp: Sample(value: TempStat(peak: 50, average: 45, sensorCount: 4), source: .chipMap))
    tick(&a, temp: Sample(value: TempStat(peak: 110, average: 100, sensorCount: 4), source: .chipMap))
    #expect(a.snapshot.cpuTemp?.peak == 50)                // spike held; the value is unchanged
    #expect(a.snapshot.status.cpuTemp == .live(.chipMap))  // a held tick shows no change
    tick(&a, temp: Sample(value: TempStat(peak: 51, average: 46, sensorCount: 4), source: .chipMap))
    #expect(a.snapshot.cpuTemp?.peak == 50.5)              // glitch discarded, EMA from 50
}

@Test func aggregatorStuckTemperatureGoesUnavailableAndRequestsOneReset() {
    var a = Aggregator(machineName: "Mac", chipName: "M5",
                       stuckDetector: StuckDetector(windowTicks: 3, maximumTicks: 5))
    let frozen = Sample(value: TempStat(peak: 52.25, average: 48.5, sensorCount: 4), source: .chipMap)
    for _ in 0..<4 { tick(&a, temp: frozen) }
    #expect(a.snapshot.status.cpuTemp == .live(.chipMap) && !a.temperatureResetRequested)
    tick(&a, temp: frozen)
    #expect(a.snapshot.cpuTemp == nil)
    #expect(a.snapshot.status.cpuTemp == .unavailable(.stuck, source: .chipMap))
    check(a.consumeTemperatureReset(), true)
    check(a.consumeTemperatureReset(), false)                  // once per episode
    tick(&a, temp: frozen)
    #expect(a.snapshot.status.cpuTemp.fault == .stuck && !a.temperatureResetRequested)
    tick(&a, temp: Sample(value: TempStat(peak: 52.3, average: 48.5, sensorCount: 4), source: .chipMap))
    #expect(a.snapshot.cpuTemp?.peak == 52.3 && a.snapshot.status.cpuTemp == .live(.chipMap))
}

@Test func aggregatorProcessStatusLadder() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    #expect(a.snapshot.status.processes == .unavailable(.firstSample))
    let row = ProcRow(pid: 7, name: "p", cpuPercent: 5, residentBytes: 1)
    a.updateProcesses(Sample(value: [row], source: .libprocOnly, fault: .psUnavailable), at: time)
    #expect(a.snapshot.status.processes == .estimated(.libprocOnly, fault: .psUnavailable))
    a.updateProcesses(Sample(value: [row], source: .libprocAndPS), at: time)
    #expect(a.snapshot.status.processes == .live(.libprocAndPS))
    for _ in 0..<2 { a.updateProcesses(.failure(.timeout, source: .libprocAndPS), at: time) }
    #expect(a.snapshot.status.processes == .live(.libprocAndPS) && !a.snapshot.topProcesses.isEmpty)
    a.updateProcesses(.failure(.timeout, source: .libprocAndPS), at: time)
    #expect(a.snapshot.topProcesses.isEmpty)
    #expect(a.snapshot.status.processes == .unavailable(.timeout, source: .libprocAndPS))
}

@Test func aggregatorFirstFailedProcessScanShowsItsFaultAtOnce() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    a.updateProcesses(.failure(.apiError, source: .libprocOnly), at: time)
    #expect(a.snapshot.status.processes == .unavailable(.apiError, source: .libprocOnly))
    var b = Aggregator(machineName: "Mac", chipName: "M5")
    b.updateProcesses(Sample(value: nil, source: .libprocAndPS), at: time)
    #expect(b.snapshot.status.processes == .unavailable(.firstSample, source: .libprocAndPS))
    // After a successful (even empty) scan the 2-miss hold applies again.
    b.updateProcesses(Sample(value: [], source: .libprocAndPS), at: time)
    for _ in 0..<2 { b.updateProcesses(.failure(.timeout, source: .libprocAndPS), at: time) }
    #expect(b.snapshot.status.processes == .live(.libprocAndPS))
    b.updateProcesses(.failure(.timeout, source: .libprocAndPS), at: time)
    #expect(b.snapshot.status.processes == .unavailable(.timeout, source: .libprocAndPS))
}

@Test func displayKeyChangesOnStatusChangeOnly() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    tick(&a, temp: Sample(value: warm, source: .chipMap))
    let live = displayKey(a.snapshot)
    tick(&a, temp: Sample(value: warm, source: .chipMap))
    #expect(displayKey(a.snapshot) == live)
    tick(&a, temp: Sample(value: warm, source: .genericFamily, fault: .familyMissing))
    #expect(displayKey(a.snapshot) != live)                // same numbers, new status
}

@Test func identityStatusIsSetByTheEngine() {
    var a = Aggregator(machineName: "Mac", chipName: "Apple Silicon", identityStatus: .estimated(.builtInDefault))
    #expect(a.snapshot.status.identity == .estimated(.builtInDefault))
    a.setIdentityStatus(.live(.sysctl))
    #expect(a.snapshot.status.identity == .live(.sysctl))
}

@Test func resetDetectorsClearsJumpBaseline() {
    var a = Aggregator(machineName: "Mac", chipName: "M5")
    tick(&a, temp: Sample(value: TempStat(peak: 40, average: 35, sensorCount: 4), source: .chipMap))
    a.resetDetectors()
    tick(&a, temp: Sample(value: TempStat(peak: 90, average: 80, sensorCount: 4), source: .chipMap))
    #expect(a.snapshot.cpuTemp?.peak == 65)                // accepted (EMA 40 → 90), not held
}
