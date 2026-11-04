import AppKit
import MonitorCore

/// UserDefaults persistence. Domain = bundle id (`com.felixfu.MacMonitorPanel`) when launched from the
/// .app; when the bare binary runs with no bundle, the same domain is opened by suite name.
/// Keys: size, glass, language (raw values of the MonitorCore enums), panelVisible (Bool),
/// panelOriginX / panelOriginY (Double, bottom-left frame origin in global screen coordinates).
@MainActor
final class Settings {
    static let domain = ProcessInfo.processInfo.environment["MAC_MONITOR_SETTINGS_DOMAIN"] ?? "com.felixfu.MacMonitorPanel"
    private let defaults: UserDefaults

    init(defaults injected: UserDefaults? = nil) {
        if let injected { defaults = injected; return }
        if Bundle.main.bundleIdentifier == Settings.domain {
            defaults = .standard
        } else {
            defaults = UserDefaults(suiteName: Settings.domain) ?? .standard
        }
    }

    var options: DisplayOptions {
        get {
            DisplayOptions(
                size: defaults.string(forKey: "size").flatMap(PanelSize.init(rawValue:)) ?? .large,
                glass: defaults.string(forKey: "glass").flatMap(GlassStyle.init(rawValue:)) ?? .clear,
                language: defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .english,
                temperatureUnit: defaults.string(forKey: "temperatureUnit").flatMap(TemperatureUnit.init(rawValue:)) ?? .system,
                displayMode: DisplayMode.restored(defaults.string(forKey: "displayMode")),
                menuBarMoons: MenuBarMoons.restored(defaults.object(forKey: "menuBarMoons") as? Int)
            )
        }
        set {
            defaults.set(newValue.size.rawValue, forKey: "size")
            defaults.set(newValue.glass.rawValue, forKey: "glass")
            defaults.set(newValue.language.rawValue, forKey: "language")
            defaults.set(newValue.temperatureUnit.rawValue, forKey: "temperatureUnit")
            defaults.set(newValue.displayMode.rawValue, forKey: "displayMode")
            defaults.set(newValue.menuBarMoons.rawValue, forKey: "menuBarMoons")
        }
    }

    var panelVisible: Bool {
        get { defaults.object(forKey: "panelVisible") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "panelVisible") }
    }

    var panelOrigin: NSPoint? {
        get {
            guard let x = defaults.object(forKey: "panelOriginX") as? Double,
                  let y = defaults.object(forKey: "panelOriginY") as? Double else { return nil }
            return NSPoint(x: x, y: y)
        }
        set {
            if let p = newValue {
                defaults.set(Double(p.x), forKey: "panelOriginX")
                defaults.set(Double(p.y), forKey: "panelOriginY")
            } else {
                defaults.removeObject(forKey: "panelOriginX")
                defaults.removeObject(forKey: "panelOriginY")
            }
        }
    }
    // MARK: Tour
    var tourVersion: Int { defaults.integer(forKey: "tourVersion") }
    var tourOutcome: String? { defaults.string(forKey: "tourOutcome") }
    var tourDate: Double { defaults.double(forKey: "tourDate") }
    func recordTour(_ outcome: String) {
        defaults.set(1, forKey: "tourVersion")
        defaults.set(outcome, forKey: "tourOutcome")
        defaults.set(Date().timeIntervalSince1970, forKey: "tourDate")
    }
    func resetTour() {
        for key in ["tourVersion", "tourOutcome", "tourDate"] { defaults.removeObject(forKey: key) }
    }

}
