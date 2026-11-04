import Foundation
import MonitorCore

@main struct SettingsCheck {
    @MainActor static func main() {
        guard let domain = ProcessInfo.processInfo.environment["MAC_MONITOR_SETTINGS_DOMAIN"],
              domain.hasPrefix("com.felixfu.MacMonitorPanel.wpz-child-") else {
            fatalError("runner must allocate an explicit isolated child domain")
        }
        let defaults = UserDefaults(suiteName: domain)!
        // Parent owns deletion after this writer exits; flush before then.
        defer { defaults.synchronize() }
        let settings = Settings(defaults: defaults)
        precondition(settings.options.displayMode == .both)
        defaults.set(false, forKey: "panelVisible")
        defaults.set("medium", forKey: "size")
        precondition(settings.options.displayMode == .both && !settings.panelVisible)
        precondition(settings.options.size == .medium)
        for mode in DisplayMode.allCases {
            var options = settings.options; options.displayMode = mode; options.temperatureUnit = .fahrenheit
            settings.options = options
            precondition(Settings(defaults: defaults).options == options)
        }
        for raw in 0...7 {
            var o=settings.options; o.menuBarMoons=MenuBarMoons(rawValue:raw); settings.options=o
            precondition(Settings(defaults:defaults).options.menuBarMoons.rawValue == raw)
        }
        print("PASS settings migration and all display modes/unit persistence")
    }
}
