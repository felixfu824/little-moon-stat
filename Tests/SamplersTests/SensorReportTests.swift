import Testing
import Foundation
@testable import Samplers

@Test func reportMediansRequireFiveValidReadings() {
    let samples: [[String: Double]] = [["Tp00": 5, "Tp04": 6], ["Tp00": 1], ["Tp00": 3], ["Tp00": 2], ["Tp00": 4]]
    #expect(SensorReportRunner.medians(samples) == ["Tp00": 3])
    #expect(SensorReportRunner.medians([]).isEmpty)
    #expect(SensorReportRunner.medians(Array(repeating: ["Tp00": Double.nan], count: 5)).isEmpty)
}

@Test func reportVerdictsExposeContradictionsAndMissingKeys() {
    let readings: [SensorReport.Reading] = [
        .init(key: "Tp00", idle: 40, cpuLoaded: 60, gpuIdle: 40, gpuLoaded: 45, cpuDelta: 20, gpuDelta: 5),
        .init(key: "Tp04", idle: 40, cpuLoaded: 50, gpuIdle: 40, gpuLoaded: 55, cpuDelta: 10, gpuDelta: 15),
    ]
    let cpu = SensorReport.verdict(keys: ["Tp00", "Tp04"], readings: readings, cpu: true)
    #expect(cpu.status == "pass")
    #expect(cpu.contradictingKeys == ["Tp04"])
    #expect(cpu.cpuLoadRise == 15 && cpu.gpuLoadRise == 10)
    #expect(SensorReport.verdict(keys: ["Tp00", "Tp04"], readings: readings, cpu: false).status == "fail")
    let missing = SensorReport.verdict(keys: ["Tp00", "TpZZ"], readings: readings, cpu: true)
    #expect(missing.status == "inconclusive" && missing.unavailableKeys == ["TpZZ"])
    #expect(SensorReport.verdict(keys: [], readings: [], cpu: true).status == "inconclusive")
    #expect(SensorReport.verdict(keys: ["Tp00"], readings: readings, cpu: true).status == "inconclusive")
}

@Test func cancelledReportNeverStartsHardwareOrLoads() throws {
    let cancellation = SensorReportCancellation()
    cancellation.cancel()
    #expect(throws: SensorReportError.self) { try SensorReportRunner(cancellation: cancellation).run() }
}

@Test func missingReportReadingsEncodeAsNull() throws {
    let reading = SensorReport.Reading(key: "Tp00", idle: nil, cpuLoaded: 70, gpuIdle: nil, gpuLoaded: nil, cpuDelta: nil, gpuDelta: nil)
    let encoded = try JSONEncoder().encode(reading)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["idle"] is NSNull)
    #expect(json["cpuDelta"] is NSNull)
    #expect(json["cpuLoaded"] as? Double == 70)
}


@Test func reportRetainsFiniteSentinelsWithoutAFalseVerdict() throws {
    let raw = SensorReportRunner.medians(Array(repeating: ["Tp00": -127.0, "Tp04": 40.0], count: 5))
    #expect(raw["Tp00"] == -127)
    let sentinel = SensorReport.Reading(key: "Tp00", idle: -127, cpuLoaded: 70, gpuIdle: -127, gpuLoaded: -127, cpuDelta: 197, gpuDelta: 0)
    let good = SensorReport.Reading(key: "Tp04", idle: 40, cpuLoaded: 60, gpuIdle: 40, gpuLoaded: 45, cpuDelta: 20, gpuDelta: 5)
    let verdict = SensorReport.verdict(keys: ["Tp00", "Tp04"], readings: [sentinel, good], cpu: true)
    #expect(verdict.status == "inconclusive")
    #expect(verdict.unavailableKeys == ["Tp00"])
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(sentinel)) as? [String: Any])
    #expect(json["idle"] as? Double == -127)
}
