import Foundation
import Observation

/// The single source of truth the UI observes. Updated on the main actor only.
@MainActor
@Observable
public final class SnapshotStore {
    public private(set) var snapshot: Snapshot

    public init(snapshot: Snapshot = .preview) {
        self.snapshot = snapshot
    }

    /// Engines call this on the main actor. Callers skip it when nothing visible changed.
    public func publish(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }
}

/// Owns the samplers and the timers. The app drives its lifecycle; the UI only reads the store.
@MainActor
public protocol MonitorEngine: AnyObject {
    var store: SnapshotStore { get }
    func start()
    func stop()
    /// Panel hidden or display asleep: stop sampling entirely.
    func pause()
    func resume()
    /// System woke from sleep: reset deltas, reopen IOKit connections.
    func systemDidWake()
}

/// Publishes the preview fixture, for UI work and app work before the real engine exists.
@MainActor
public final class PreviewEngine: MonitorEngine {
    public let store: SnapshotStore

    public init(store: SnapshotStore? = nil) {
        self.store = store ?? SnapshotStore()
    }

    public func start() { store.publish(.preview) }
    public func stop() {}
    public func pause() {}
    public func resume() {}
    public func systemDidWake() {}
}

public enum PanelSize: String, CaseIterable, Sendable {
    case large, medium
}

public enum GlassStyle: String, CaseIterable, Sendable {
    /// NSGlassEffectView .clear (default, per docs/spikes/glass.md).
    case clear
    /// NSGlassEffectView .regular + dark tint.
    case tinted
}

public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
}

public enum TemperatureUnit: String, CaseIterable, Sendable {
    case system, celsius, fahrenheit
}

public enum DisplayMode: String, CaseIterable, Sendable {
    case desktop, menuBar, both
    public static func restored(_ raw: String?) -> Self { raw.flatMap(Self.init(rawValue:)) ?? .both }
    public func title(_ language: AppLanguage) -> String {
        if language == .traditionalChinese {
            return self == .desktop ? "桌面" : self == .menuBar ? "選單列" : "兩者"
        }
        return self == .desktop ? "Desktop" : self == .menuBar ? "Menu bar" : "Both"
    }
}

public struct MenuBarMoons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue & 7 }
    public static let cpu = Self(rawValue: 1)
    public static let gpu = Self(rawValue: 2)
    public static let ram = Self(rawValue: 4)
    public static let all: Self = [.cpu, .gpu, .ram]
    public static func restored(_ raw: Int?) -> Self { raw.map(Self.init(rawValue:)) ?? .all }
}

public enum MenuBarMoon: String, CaseIterable, Sendable {
    case cpu, gpu, ram
    public var selection: MenuBarMoons {
        switch self { case .cpu: return .cpu; case .gpu: return .gpu; case .ram: return .ram }
    }
    public var title: String { rawValue.uppercased() }
}

/// User-chosen presentation options, persisted by the app in UserDefaults.
public struct DisplayOptions: Equatable, Sendable {
    public var size: PanelSize
    public var glass: GlassStyle
    public var language: AppLanguage
    public var temperatureUnit: TemperatureUnit
    public var displayMode: DisplayMode
    public var menuBarMoons: MenuBarMoons

    public init(size: PanelSize = .large, glass: GlassStyle = .clear, language: AppLanguage = .english,
                temperatureUnit: TemperatureUnit = .system, displayMode: DisplayMode = .both, menuBarMoons: MenuBarMoons = .all) {
        self.size = size
        self.glass = glass
        self.language = language
        self.temperatureUnit = temperatureUnit
        self.displayMode = displayMode
        self.menuBarMoons = menuBarMoons
    }
}
