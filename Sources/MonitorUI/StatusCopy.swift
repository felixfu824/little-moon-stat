import SwiftUI
import MonitorCore

/// Shared short reasons for the cards, popover, status item and VoiceOver.
public enum StatusCopy {
    public static func reason(_ status: MetricStatus, metric: StatusMetric, language: AppLanguage) -> String {
        let zh = language == .traditionalChinese
        func text(_ en: String, _ cn: String) -> String { zh ? cn : en }
        let fault = status.fault ?? (status.source == .genericFamily ? .unknownChip : status.source == .libprocOnly ? .psUnavailable : .apiError)
        switch fault {
        case .firstSample: return text("Measuring…", "測量中…")
        case .wakeTransient: return text("Resuming after sleep…", "喚醒後恢復中…")
        case .apiError: return text("System call failed; retrying", "系統呼叫失敗，重試中")
        case .serviceUnavailable:
            return metric == .gpuPercent ? text("GPU usage not reported by this Mac", "此 Mac 不回報 GPU 使用率") : text("Temperature sensors not readable on this Mac", "此 Mac 無法讀取溫度感測器")
        case .virtualMachine: return text("No sensors in a virtual machine", "虛擬機器沒有感測器")
        case .permission: return text("Sensors blocked by the app sandbox", "App 沙盒阻擋了感測器")
        case .familyMissing: return text("No CPU/GPU temperature sensors found", "找不到 CPU/GPU 溫度感測器")
        case .unknownChip: return text("Generic sensor set for this chip", "此晶片使用通用感測器組")
        case .stuck: return text("Sensor stopped updating; reconnecting", "感測器停止更新，重新連線中")
        case .jump: return text("Reading changed too fast; confirming", "讀數變化過快，確認中")
        case .outOfRange, .nonFinite: return text("Reading out of range", "讀數超出範圍")
        case .psUnavailable: return text("System processes hidden (ps unavailable)", "看不到系統程序（ps 無法使用）")
        case .timeout: return text("Process list timed out; retrying", "程序清單逾時，重試中")
        }
    }
    public static func readout(_ value: String, status: MetricStatus) -> String {
        status.quality == .unavailable ? "—" : (status.quality == .estimated ? "≈ " : "") + value
    }
    public static func accessibility(_ value: String, status: MetricStatus, metric: StatusMetric, language: AppLanguage) -> String {
        let zh = language == .traditionalChinese
        switch status.quality {
        case .live: return value
        case .unavailable: return (zh ? "無資料，" : "unavailable, ") + reason(status, metric: metric, language: language)
        case .estimated:
            let why = status.source == .genericFamily ? (zh ? "通用感測器" : "generic sensors") : reason(status, metric: metric, language: language)
            return (zh ? "約" : "approximately ") + value + (zh ? "，" : ", ") + why
        }
    }
    public static func temperatureAccessibility(_ value: Double?, status: MetricStatus, metric: StatusMetric, unit: TemperatureUnit, language: AppLanguage) -> String {
        accessibility(DisplayFormat.temperatureAccessibility(value, unit: unit, language: language), status: status, metric: metric, language: language)
    }
    public static func memoryAccessibility(_ value: MemoryStat?, status: MetricStatus, language: AppLanguage) -> String {
        let fields = [L10n.memory.text(language) + " " + DisplayFormat.memory(value),
                      L10n.wired.text(language) + " " + DisplayFormat.gb(value?.wired) + " GB",
                      L10n.active.text(language) + " " + DisplayFormat.gb(value?.active) + " GB",
                      L10n.compressed.text(language) + " " + DisplayFormat.gb(value?.compressed) + " GB"]
        return accessibility(fields.joined(separator: ", "), status: status, metric: .memory, language: language)
    }
    public static func processAccessibility(_ row: ProcRow?, status: MetricStatus, language: AppLanguage) -> String {
        let name = row.map { $0.name + ", " } ?? ""
        let value = DisplayFormat.percent(row?.cpuPercent, decimals: 1) + ", " + DisplayFormat.processMemory(row?.residentBytes)
        return name + accessibility(value, status: status, metric: .processes, language: language)
    }
    public static func dashed(_ status: MetricStatus) -> Bool { status.quality == .estimated }
}

/// The overlay consumes no layout width or height, including a 212°F tile.
struct StatusDecoration: ViewModifier {
    let status: MetricStatus
    let metric: StatusMetric
    let language: AppLanguage
    var underline = true
    @ViewBuilder func body(content: Content) -> some View {
        if status.quality == .live { content }
        else { content.overlay(alignment: .bottom) {
            if underline && StatusCopy.dashed(status) {
                GeometryReader { geometry in
                    Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: geometry.size.width, y: 0)) }
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }.frame(height: 1).offset(y: 1).accessibilityHidden(true)
            }
        }.help(StatusCopy.reason(status, metric: metric, language: language))
            .transaction { $0.animation = nil }
        }
    }
}

/// Preserve SwiftUI's complete native label in live state; format a diagnostic label only when needed.
struct StatusAccessibility: ViewModifier {
    let status: MetricStatus
    let label: () -> String
    @ViewBuilder func body(content: Content) -> some View {
        if status.quality == .live { content }
        else { content.accessibilityLabel(label()) }
    }
}
