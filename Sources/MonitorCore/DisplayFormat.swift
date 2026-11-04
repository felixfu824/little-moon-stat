import Foundation

/// Shared visible precision for rendering and publication change detection.
public enum DisplayFormat {
    public static let missing = "—"
    public static let gib = 1_073_741_824.0
    public static func number(_ value: Double?, decimals: Int = 0) -> String {
        guard let value, value.isFinite else { return missing }
        // No locale argument: printf's fixed decimal syntax avoids constructing
        // ICU number formatters for every live digit. The output stays ASCII.
        return String(format: "%.*f", decimals, value)
    }
    public static func percent(_ value: Double?, decimals: Int = 0) -> String {
        let result = number(value, decimals: decimals)
        return result == missing ? result : result + "%"
    }
    /// AppleTemperatureUnit is the explicit Language & Region override; Foundation
    /// UnitTemperature(forLocale:usage:) supplies the locale default when the preference is absent.
    private static let temperaturePreference = TemperaturePreferenceCache()
    public static func resolvedUnit(_ unit: TemperatureUnit) -> TemperatureUnit {
        unit == .system ? temperaturePreference.unit() : unit
    }
    public static func resolvedUnit(_ unit: TemperatureUnit, locale: Locale = .current,
                                    preference: String?) -> TemperatureUnit {
        guard unit == .system else { return unit }
        if preference == "Fahrenheit" { return .fahrenheit }
        if preference == "Celsius" { return .celsius }
        return UnitTemperature(forLocale: locale, usage: .weather) == .fahrenheit ? .fahrenheit : .celsius
    }
    public static func temperature(_ value: Double?, unit: TemperatureUnit = .system) -> String {
        guard let value, value.isFinite else { return missing }
        let fahrenheit = resolvedUnit(unit) == .fahrenheit
        return number(fahrenheit ? value * 9 / 5 + 32 : value) + (fahrenheit ? "°F" : "°C")
    }
    public static func temperatureAccessibility(_ value: Double?, unit: TemperatureUnit, language: AppLanguage) -> String {
        guard let value, value.isFinite else { return language == .english ? "unavailable" : "無資料" }
        let f = resolvedUnit(unit) == .fahrenheit
        let n = number(f ? value * 9 / 5 + 32 : value)
        if language == .traditionalChinese { return (f ? "華氏" : "攝氏") + n + "度" }
        return n + (f ? " degrees Fahrenheit" : " degrees Celsius")
    }
    public static func gb(_ bytes: UInt64?) -> String { number(bytes.map { Double($0) / gib }, decimals: 1) }
    public static func memory(_ value: MemoryStat?) -> String {
        guard let value else { return missing }
        return "\(gb(value.used)) / \(number(Double(value.total) / gib, decimals: Double(value.total).truncatingRemainder(dividingBy: gib) == 0 ? 0 : 1)) GB"
    }
    /// Finder-style decimal storage units; promote when rounding reaches the next unit.
    public static func storage(_ bytes: UInt64?) -> String {
        guard let bytes else { return missing }
        let value = Double(bytes)
        if value >= 999_950_000_000 { return "\(number(value / 1e12, decimals: 1)) TB" }
        if value >= 999_500_000 { return "\(number(value / 1e9)) GB" }
        return "\(number(value / 1e6)) MB"
    }
    public static func processMemory(_ bytes: UInt64?) -> String {
        guard let bytes else { return missing }
        if bytes == 0 || bytes >= 1_000_000_000 { return "\(number(Double(bytes) / 1e9, decimals: 1)) GB" }
        return storage(bytes)
    }
    public static func hot(_ cpu: Double) -> Bool { cpu >= 50 }
}

/// Reading locale measurement preferences through Foundation is comparatively
/// expensive. Refresh on preference notifications, never for every visible digit.
private final class TemperaturePreferenceCache: @unchecked Sendable {
    private let lock=NSLock()
    private var value: TemperatureUnit
    private var preference: String?
    private var observers:[NSObjectProtocol]=[]
    init() {
        preference=UserDefaults.standard.string(forKey:"AppleTemperatureUnit")
        value=DisplayFormat.resolvedUnit(.system,locale:.current,preference:preference)
        for name in [NSLocale.currentLocaleDidChangeNotification,UserDefaults.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:nil) { [weak self] _ in
                self?.refresh(force:name == NSLocale.currentLocaleDidChangeNotification)
            })
        }
    }
    private func refresh(force:Bool) {
        let next=UserDefaults.standard.string(forKey:"AppleTemperatureUnit")
        lock.lock()
        guard force || next != preference else { lock.unlock(); return }
        preference=next; lock.unlock()
        let resolved=DisplayFormat.resolvedUnit(.system,locale:.current,preference:next)
        lock.lock(); value=resolved; lock.unlock()
    }
    func unit()->TemperatureUnit { lock.lock(); defer { lock.unlock() }; return value }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// Eight-step phase/colour state with a one-unit boundary hysteresis.
public struct MenuBarStepHysteresis: Sendable {
    public private(set) var current: Int?
    private let start: Double
    private let span: Double
    public init(start: Double = 50, span: Double = 45) { self.start=start; self.span=span }
    public static func step(_ value: Double?, start: Double = 50, span: Double = 45) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int((min(1,max(0,(value-start)/span))*7).rounded())
    }
    @discardableResult public mutating func update(_ value: Double?) -> Int? {
        guard let next=Self.step(value,start:start,span:span), let value else { current=nil; return nil }
        guard let previous=current else { current=next; return next }
        if next > previous && value >= start+(Double(previous)+0.5)*span/7+1 { current=next }
        if next < previous && value <= start+(Double(previous)-0.5)*span/7-1 { current=next }
        return current
    }
}

public struct MenuBarGauge: Equatable, Sendable {
    public var number: Double?
    public var phase: Int?
    public var colour: Int?
}
public struct MenuBarValues: Equatable, Sendable {
    public var cpu: MenuBarGauge
    public var gpu: MenuBarGauge
    public var ram: MenuBarGauge
    public func key(_ moons: MenuBarMoons) -> String {
        [(MenuBarMoons.cpu,cpu),(.gpu,gpu),(.ram,ram)].filter { moons.contains($0.0) }.map {
            "\($0.1.number.map { String($0) } ?? "missing"):\($0.1.phase ?? -1):\($0.1.colour ?? -1)"
        }.joined(separator:"|")
    }
}
/// A shared worker-side display model. Desktop values are never deadbanded.
public struct MenuBarQuantizer: Sendable {
    private var cpuPhase=MenuBarStepHysteresis(), gpuPhase=MenuBarStepHysteresis()
    private var ramPhase=MenuBarStepHysteresis(start:0,span:100), ramColour=MenuBarStepHysteresis()
    private var cpuNumber: Double?, gpuNumber: Double?, ramNumber: Double?
    public init() {}
    private var numberUnit: TemperatureUnit?
    public mutating func update(_ snapshot: Snapshot, unit: TemperatureUnit = .celsius) -> MenuBarValues {
        let resolved=DisplayFormat.resolvedUnit(unit)
        if numberUnit != resolved { cpuNumber=nil; gpuNumber=nil; numberUnit=resolved }
        func deadband(_ value: Double?, _ previous: inout Double?) -> Double? {
            guard let value, value.isFinite else { previous=nil; return nil }
            if previous == nil || abs(value-previous!) >= 1 { previous=value.rounded() }
            return previous
        }
        func temperatureNumber(_ value: Double?, _ previous: inout Double?) -> Double? {
            let display=value.map { resolved == .fahrenheit ? $0*9/5+32:$0 }
            guard let shown=deadband(display,&previous) else { return nil }
            // Gauges retain Celsius for shared rendering/accessibility contracts.
            return resolved == .fahrenheit ? (shown-32)*5/9:shown
        }
        let cpu=snapshot.cpuTemp?.peak, gpu=snapshot.gpuTemp?.peak
        let ram=snapshot.memory.flatMap { $0.total > 0 ? Double($0.used)/Double($0.total)*100 : nil }
        let cp=cpuPhase.update(cpu), gp=gpuPhase.update(gpu)
        return MenuBarValues(cpu:MenuBarGauge(number:temperatureNumber(cpu,&cpuNumber),phase:cp,colour:cp),
            gpu:MenuBarGauge(number:temperatureNumber(gpu,&gpuNumber),phase:gp,colour:gp),
            ram:MenuBarGauge(number:deadband(ram,&ramNumber),phase:ramPhase.update(ram),colour:ramColour.update(ram)))
    }
}

/// The popover's finite paint identity, shared with its drawing code. Evaluated
/// by the sampler only while that surface is open.
public enum PopoverPresentation {
    public static let stars: [(Double, Double, Double)] = {
        var seed = 7.0
        func rnd() -> Double { seed = (seed*9301+49297).truncatingRemainder(dividingBy:233280); return seed/233280 }
        var result: [(Double, Double, Double)] = []
        for _ in 0..<64 {
            let x=10+rnd()*308, y=14+rnd()*118
            let arch=y >= 100 || pow((x-164)/158,2)+pow((y-101)/95,2) <= 1
            if arch && hypot(x-104,y-90) >= 48 && hypot(x-224,y-90) >= 48 { result.append((x,y,rnd())) }
            if result.count == 34 { break }
        }
        return result
    }()
    public static func starMask(_ s: Snapshot) -> UInt64 {
        stars.enumerated().reduce(0) { result, entry in
            let load=(entry.element.0 < 164 ? s.cpuPercent:s.gpuPercent) ?? 0
            return entry.element.2 < load/100 ? result | (UInt64(1) << entry.offset):result
        }
    }
    public static func memoryLevels(_ m: MemoryStat?) -> [Double] {
        guard let m, m.total > 0 else { return [] }
        let denominator=max(Double(m.total),Double(m.wired)+Double(m.active)+Double(m.compressed))
        let wired=Double(m.wired)/denominator, active=Double(m.active)/denominator, compressed=Double(m.compressed)/denominator
        return [1-wired,1-wired-active,1-wired-active-compressed].map { ($0*96).rounded()/2 }
    }
    public static func processSize(_ cpu: Double) -> Double { (10*(7+6*min(1,max(0,cpu)/100))).rounded()/10 }
    public static func diskDots(_ disk: DiskStat?) -> Int {
        let used=disk.map { $0.total > 0 ? Double($0.used)/Double($0.total):0 } ?? 0
        return (0..<41).filter { Double($0)/41 < used }.count
    }
    public static func key(_ s: Snapshot) -> String {
        let phases="\(MenuBarStepHysteresis.step(s.cpuTemp?.peak) ?? -1)|\(MenuBarStepHysteresis.step(s.gpuTemp?.peak) ?? -1)"
        let processes=s.topProcesses.prefix(3).map { "\($0.cpuPercent > 70):\(processSize($0.cpuPercent))" }.joined(separator:"|")
        return "\(phases)|\(starMask(s))|\(memoryLevels(s.memory))|\(diskDots(s.disk))|\(processes)"
    }
}
