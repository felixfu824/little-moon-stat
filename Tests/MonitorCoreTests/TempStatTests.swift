import Testing
@testable import MonitorCore

@Test func tempStatTakesPeakAndMeanOfPlausibleReadings() throws {
    let stat = try #require(TempStat(readings: [70, 80, 90]))
    #expect(stat.peak == 90)
    #expect(stat.average == 80)
    #expect(stat.sensorCount == 3)
}

@Test func tempStatDropsJunkReadings() throws {
    let stat = try #require(TempStat(readings: [0, -5, 200, .nan, 60, 62]))
    #expect(stat.peak == 62)
    #expect(stat.sensorCount == 2)
}

@Test func tempStatIsNilWhenNothingIsPlausible() {
    #expect(TempStat(readings: [0, 0, 255]) == nil)
    #expect(TempStat(readings: []) == nil)
}

@Test func memoryAndDiskDerivedFields() {
    let mem = MemoryStat(wired: 1, active: 2, compressed: 3, total: 10)
    #expect(mem.used == 6)
    #expect(DiskStat(volumeName: "x", total: 10, free: 4).used == 6)
    #expect(DiskStat(volumeName: "x", total: 4, free: 10).used == 0)
}
