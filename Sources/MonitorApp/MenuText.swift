import MonitorCore
import AppKit

/// App-local string table for the status-item menu (en + zh-Hant). Card text lives in MonitorUI.
enum MenuText {
    case sensorReport, cancelSensorReport, cancellingSensorReport, reportError, reportIdle, reportCPU, reportCooldown, reportGPU
    case show, hide, size, large, medium, glass, clear, tinted, language
    case english, traditionalChinese, launchAtLogin, resetPosition, showTour, about, quit
    case loginError, loginNeedsApproval, ok, openSettings

    func string(_ lang: AppLanguage) -> String {
        let zh = lang == .traditionalChinese
        switch self {
        case .sensorReport: return zh ? "感測器報告…" : "Sensor Report…"
        case .cancellingSensorReport: return zh ? "正在取消感測器報告…" : "Cancelling Sensor Report…"
        case .cancelSensorReport: return zh ? "取消感測器報告" : "Cancel Sensor Report"
        case .reportError: return zh ? "無法建立感測器報告" : "Could not create Sensor Report"
        case .reportIdle: return zh ? "閒置取樣" : "Idle readings"
        case .reportCPU: return zh ? "CPU 負載" : "CPU load"
        case .reportCooldown: return zh ? "冷卻中" : "Cooling down"
        case .reportGPU: return zh ? "GPU 負載" : "GPU load"
        case .show: return zh ? "顯示面板" : "Show Panel"
        case .hide: return zh ? "隱藏面板" : "Hide Panel"
        case .size: return zh ? "尺寸" : "Size"
        case .large: return zh ? "大" : "Large"
        case .medium: return zh ? "中" : "Medium"
        case .glass: return zh ? "玻璃效果" : "Glass"
        case .clear: return zh ? "透明" : "Clear"
        case .tinted: return zh ? "深色調" : "Tinted"
        case .language: return zh ? "語言" : "Language"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .launchAtLogin: return zh ? "登入時開啟" : "Launch at Login"
        case .resetPosition: return zh ? "重設位置" : "Reset Position"
        case .showTour: return zh ? "顯示導覽…" : "Show Tour…"
        case .about: return zh ? "關於 Little Moon" : "About Little Moon"
        case .quit: return zh ? "結束" : "Quit"
        case .loginError: return zh ? "無法變更「登入時開啟」" : "Could not change Launch at Login"
        case .loginNeedsApproval:
            return zh ? "請在「系統設定 › 一般 › 登入項目」中允許 Little Moon。"
                      : "Allow Little Moon in System Settings › General › Login Items."
        case .ok: return zh ? "好" : "OK"
        case .openSettings: return zh ? "開啟系統設定" : "Open System Settings"
        }
    }
}

/// Pure state/presentation, shared by the real menu and the standalone unit test.
struct SensorReportMenuState {
    enum Status { case ready, running, cancelling }
    private(set) var status: Status = .ready
    private(set) var phase = "idle"
    private(set) var fraction = 0.0
    mutating func begin() { status = .running; phase = "idle"; fraction = 0 }
    mutating func update(phase: String, fraction: Double) {
        guard status == .running else { return }
        self.phase = phase
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
    mutating func cancel() { if status == .running { status = .cancelling } }
    mutating func finish() { self = Self() }
    func title(_ language: AppLanguage) -> String {
        if status == .ready { return MenuText.sensorReport.string(language) }
        if status == .cancelling { return MenuText.cancellingSensorReport.string(language) }
        let text: MenuText = phase == "cpu" ? .reportCPU : phase == "gpu" ? .reportGPU : phase == "cooldown" ? .reportCooldown : .reportIdle
        return "\(MenuText.cancelSensorReport.string(language)) (\(text.string(language)) \(Int(fraction * 100))%)"
    }
    func item(_ language: AppLanguage, target: AnyObject?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title(language), action: action, keyEquivalent: "")
        item.target = target
        item.isEnabled = status != .cancelling
        return item
    }
}
