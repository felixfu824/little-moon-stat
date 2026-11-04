import Foundation
import Darwin
import Testing
@testable import MonitorCore

@Test func temperatureUnitsAndSystemPreference() {
    #expect(DisplayFormat.temperature(75, unit: .celsius) == "75°C")
    #expect(DisplayFormat.temperature(75, unit: .fahrenheit) == "167°F")
    #expect(DisplayFormat.temperature(100, unit: .celsius) == "100°C")
    #expect(DisplayFormat.temperature(100, unit: .fahrenheit) == "212°F")
    #expect(DisplayFormat.temperature(nil, unit: .fahrenheit) == "—")
    #expect(DisplayFormat.temperature(.infinity, unit: .celsius) == "—")
    #expect(DisplayFormat.resolvedUnit(.system, locale: Locale(identifier: "en_US"), preference: nil) == .fahrenheit)
    #expect(DisplayFormat.resolvedUnit(.system, locale: Locale(identifier: "zh_TW"), preference: nil) == .celsius)
    #expect(DisplayFormat.resolvedUnit(.system, locale: Locale(identifier: "en_US"), preference: "Celsius") == .celsius)
    #expect(DisplayFormat.resolvedUnit(.system, locale: Locale(identifier: "zh_TW"), preference: "Fahrenheit") == .fahrenheit)
    #expect(DisplayFormat.resolvedUnit(.celsius, preference: "Fahrenheit") == .celsius)
}

@Test func displayModeMigration() {
    #expect(DisplayMode.restored(nil) == .both)
    #expect(DisplayMode.restored("unknown") == .both)
    for mode in DisplayMode.allCases { #expect(DisplayMode.restored(mode.rawValue) == mode) }
    #expect(DisplayOptions().displayMode == .both)
    #expect(DisplayOptions().temperatureUnit == .system)
    #expect(DisplayMode.menuBar.title(.traditionalChinese) == "選單列")
}


@Test func fixedNumericPrecisionIgnoresThreadRegionalDecimalSeparator() throws {
    let french = try #require(newlocale(LC_NUMERIC_MASK, "fr_FR.UTF-8", nil))
    let previous = uselocale(french)
    defer { _ = uselocale(previous); freelocale(french) }
    #expect(DisplayFormat.number(12.5, decimals: 1) == "12.5")
    #expect(DisplayFormat.number(2.5) == "2")
    #expect(DisplayFormat.temperature(75, unit: .fahrenheit) == "167°F")
}

@Test func menuNumbersUseApprovedDeadbandAndRAMUsesPercentagePhase() {
    var s=Snapshot.preview, q=MenuBarQuantizer()
    s.cpuTemp=TempStat(peak:75,average:68,sensorCount:1)
    s.memory=MemoryStat(wired:0,active:58,compressed:0,total:100)
    let first=q.update(s)
    #expect(first.cpu.number == 75)
    #expect(first.ram.number == 58)
    #expect(first.ram.phase == 4)
    #expect(first.ram.colour == 1)
    s.cpuTemp?.peak=75.8
    #expect(q.update(s).cpu.number == 75)
    s.cpuTemp?.peak=76.01
    #expect(q.update(s).cpu.number == 76)
    s.cpuTemp?.peak=75.6
    #expect(q.update(s).cpu.number == 76)
    s.cpuTemp=nil
    #expect(q.update(s).cpu.number == nil)
    #expect(MenuBarMoons.restored(nil) == .all)
    #expect(MenuBarMoons.restored(0).isEmpty)
}

@Test func menuTemperatureSweepsReachEveryIntegerInBothUnits() {
    for unit in [TemperatureUnit.celsius,.fahrenheit] {
        let expected=unit == .celsius ? Set(40...100):Set(104...212)
        for ascending in [true,false] {
            var q=MenuBarQuantizer(), s=Snapshot.preview
            var reached=Set<Int>()
            let ticks=ascending ? Array(400...1000):Array((400...1000).reversed())
            for tick in ticks {
                let raw=Double(tick)/10
                s.cpuTemp=TempStat(peak:raw,average:raw,sensorCount:1); s.gpuTemp=s.cpuTemp
                let values=q.update(s,unit:unit)
                let cpu=DisplayFormat.temperature(values.cpu.number,unit:unit)
                #expect(cpu == DisplayFormat.temperature(values.gpu.number,unit:unit))
                reached.insert(Int(cpu.dropLast(2))!)
            }
            #expect(reached == expected)
        }
    }
}

@Test func menuTemperatureDeadbandSuppressesOscillationAndAllowsFastJumps() {
    for unit in [TemperatureUnit.celsius,.fahrenheit] {
        var q=MenuBarQuantizer(), s=Snapshot.preview
        func sample(_ c: Double) -> String {
            s.cpuTemp=TempStat(peak:c,average:c,sensorCount:1)
            return DisplayFormat.temperature(q.update(s,unit:unit).cpu.number,unit:unit)
        }
        let initial=sample(60)
        let delta=unit == .fahrenheit ? 0.9*5/9:0.9
        for _ in 0..<5 { #expect(sample(60+delta) == initial); #expect(sample(60-delta) == initial) }
        #expect(sample(70) == DisplayFormat.temperature(70,unit:unit))
        s.cpuTemp=nil
        #expect(q.update(s,unit:unit).cpu.number == nil)
        #expect(sample(60) == initial)
    }
}
