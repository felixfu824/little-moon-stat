import Foundation
import MonitorCore

/// All interface words live here; no resource bundle or system-language dependency.
enum L10n: String, CaseIterable {
    case memory, wired, active, compressed, disk, used, free, topCPU, columns, cpuMax, gpuMax, average
    case nominal, fair, serious, critical

    func text(_ language: AppLanguage) -> String {
        let pair: (String, String)
        switch self {
        case .memory: pair = ("Memory", "記憶體")
        case .wired: pair = ("Wired", "固定")
        case .active: pair = ("Active", "使用中")
        case .compressed: pair = ("Compressed", "已壓縮")
        case .disk: pair = ("Disk", "磁碟")
        case .used: pair = ("used", "已用")
        case .free: pair = ("free", "可用")
        case .topCPU: pair = ("Top CPU", "CPU 前三名")
        case .columns: pair = ("% CPU · Memory", "% CPU · 記憶體")
        case .cpuMax: pair = ("CPU max", "CPU 最高")
        case .gpuMax: pair = ("GPU max", "GPU 最高")
        case .average: pair = ("avg", "平均")
        case .nominal: pair = ("Nominal", "正常")
        case .fair: pair = ("Fair", "尚可")
        case .serious: pair = ("Serious", "嚴重")
        case .critical: pair = ("Critical", "危急")
        }
        return language == .english ? pair.0 : pair.1
    }
}

enum CardFormat {
    static let missing = DisplayFormat.missing
    static let gib = DisplayFormat.gib
    static func number(_ value: Double?, decimals: Int = 0) -> String { DisplayFormat.number(value, decimals: decimals) }
    static func percent(_ value: Double?, decimals: Int = 0) -> String { DisplayFormat.percent(value, decimals: decimals) }
    static func temperature(_ value: Double?) -> String { DisplayFormat.temperature(value) }
    /// Normalize inconsistent totals without allowing the segments to exceed the track.
    static func memoryFractions(_ memory: MemoryStat?) -> [Double] {
        guard let memory, memory.total > 0 else { return [] }
        // A bare Double.init reference selects init(bitPattern:) for UInt64 here.
        let values = [memory.wired, memory.active, memory.compressed].map { Double($0) }
        let denominator = max(Double(memory.total), values.reduce(0, +))
        return values.map { $0 / denominator }
    }
    static func gb(_ bytes: UInt64?) -> String { DisplayFormat.gb(bytes) }
    static func memory(_ value: MemoryStat?) -> String { DisplayFormat.memory(value) }
    static func storage(_ bytes: UInt64?) -> String { DisplayFormat.storage(bytes) }
    static func processMemory(_ bytes: UInt64?) -> String { DisplayFormat.processMemory(bytes) }
    static func disk(_ value: DiskStat?, language: AppLanguage) -> String {
        guard let value else { return missing }
        if language == .english { return "\(storage(value.used)) used · \(storage(value.free)) free" }
        return "已用 \(storage(value.used)) · 可用 \(storage(value.free))"
    }
    static func hot(_ cpu: Double) -> Bool { DisplayFormat.hot(cpu) }
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    static func thermal(_ level: ThermalLevel?, language: AppLanguage) -> String {
        guard let level else { return missing }
        return L10n(rawValue: level.rawValue)!.text(language)
    }
}
