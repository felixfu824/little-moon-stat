import AppKit
import MonitorCore

@main struct TourSettingsCheck {
    @MainActor static func main() {
        guard let domain = ProcessInfo.processInfo.environment["MAC_MONITOR_SETTINGS_DOMAIN"],
              domain.hasPrefix("com.felixfu.MacMonitorPanel.wpz-child-") else {
            fatalError("runner must allocate an explicit isolated child domain")
        }
        let defaults = UserDefaults(suiteName: domain)!
        // Parent owns deletion after this writer exits; flush before then.
        defer { defaults.synchronize() }
        defaults.set("medium",forKey:"size"); defaults.set("both",forKey:"displayMode")
        let settings=Settings(defaults:defaults)
        precondition(settings.tourVersion == 0 && settings.tourOutcome == nil && settings.tourDate == 0)
        settings.recordTour("started")
        let restored=Settings(defaults:defaults)
        precondition(restored.tourVersion == 1 && restored.tourOutcome == "started" && restored.tourDate > 0)
        for outcome in ["abandoned","completed","skipped"] {
            restored.recordTour(outcome)
            precondition(settings.tourVersion == 1 && settings.tourOutcome == outcome)
        }
        settings.resetTour()
        precondition(settings.tourVersion == 0 && settings.tourOutcome == nil && settings.tourDate == 0)
        precondition(settings.options.size == .medium && settings.options.displayMode == .both)
        print("PASS tour persistence and reset preserve existing install settings")
    }
}
