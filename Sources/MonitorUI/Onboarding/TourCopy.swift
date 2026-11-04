import MonitorCore

/// Storyboard copy is kept verbatim; icon is the all-moons-off addition flagged in the implementation report.
public enum TourCopy: String, CaseIterable {
    case moons, minimal, hidden, parked, icon, popover, panel, occluded, settings, settingsHidden, mode
    public func text(_ language: AppLanguage) -> (title: String, body: String) {
        let pair: ((String, String), (String, String))
        switch self {
        case .moons: pair = (("Meet your moons", "CPU, GPU and RAM live here. Fuller and redder means hotter. For RAM it means more in use. Numbers are peak temperatures. RAM shows percent used."),
                              ("認識你的月亮", "CPU、GPU、RAM 都在這裡。月亮越圓越紅，代表越熱；RAM 則代表用量越高。數字是峰值溫度，RAM 是使用率。"))
        case .minimal: pair = (("This little moon is the app", "Click it for details. Right-click it for settings. Your live numbers are on the desktop panel."),
                              ("這顆小月亮就是這個 App", "點一下看詳情，按右鍵開設定。即時數字在桌面面板上。"))
        case .hidden: pair = (("Your moons are hidden", "macOS is hiding the menu bar item, maybe behind the notch. The desktop panel shows the same numbers. Also check System Settings › Menu Bar."),
                              ("月亮被藏起來了", "macOS 把選單列項目藏起來了，可能被瀏海擋住。桌面面板有同樣的數字。也可檢查「系統設定 › 選單列」。"))
        case .parked: pair = (("Your moons are tucked away", "A menu bar organizer has hidden the item. Look in its hidden section, or use the desktop panel for the same numbers."),
                              ("月亮被收起來了", "選單列整理工具把項目收起來了。請到它的隱藏區找，或看桌面面板上的同樣數字。"))
        case .popover: pair = (("Click for the full picture", "Peak and average temperatures, load as stars, memory as a tide, disk, and the top three processes. Click the moons any time to open it."),
                              ("點一下看全貌", "峰值與平均溫度、以星星呈現的負載、以潮汐呈現的記憶體、磁碟，以及前三名處理程序。隨時點月亮即可開啟。"))
        case .panel: pair = (("Your desktop panel", "It sits under your windows and updates every 2 seconds. Drag it anywhere. Reset Position in the menu puts it back."),
                              ("你的桌面面板", "它在視窗下方，每 2 秒更新。可隨意拖曳，選單的「重設位置」可移回原位。"))
        case .occluded: pair = (("", "(A window is covering it now.)"),
                              ("", "（目前被其他視窗蓋住。）"))
        case .settings: pair = (("Right-click for settings", "Right-click a moon for Display, Temperature, Language, Menu bar moons, Launch at Login and Sensor Report. The gear in the details window opens it too."),
                              ("按右鍵開設定", "按右鍵可開啟選單：顯示、溫度、語言、選單列月亮、登入時開啟、感測器報告。詳情視窗的齒輪也能開。"))
        case .settingsHidden: pair = (("Settings", "Right-click the desktop panel for settings: Display, Temperature, Language, Menu bar moons, Launch at Login and Sensor Report."),
                              ("設定", "在桌面面板上按右鍵開設定：顯示、溫度、語言、選單列月亮、登入時開啟、感測器報告。"))
        case .mode: pair = (("How do you want it?", "Choose Desktop, Menu bar or Both. You can change it anytime in the Display menu."),
                              ("你想怎麼顯示？", "請選擇「桌面」、「選單列」或「兩者」。之後可隨時在「顯示」選單更改。"))
        case .icon: pair = (("This little moon is the app", "Click it for live numbers and details. Right-click it for settings. Choose which moons to show in Menu bar moons."),
                            ("這顆小月亮就是這個 App", "點一下看即時數字與詳情，按右鍵開設定。可在「選單列月亮」選擇要顯示的月亮。"))
        }
        let value = language == .english ? pair.0 : pair.1
        return (value.0, value.1)
    }
    public static func key(step: TourStep, mode: DisplayMode, hidden: Bool, parked: Bool, moonsEmpty: Bool) -> TourCopy {
        switch step {
        case .moons: return hidden ? (parked ? .parked : .hidden) : mode == .desktop ? .minimal : moonsEmpty ? .icon : .moons
        case .popover: return .popover
        case .panel: return .panel
        case .settings: return hidden ? .settingsHidden : .settings
        case .mode: return .mode
        }
    }
    public static func counter(index: Int, count: Int, language: AppLanguage) -> String {
        language == .english ? "Tour, step \(index + 1) of \(count)" : "導覽，第 \(index + 1) 步，共 \(count) 步"
    }
}
