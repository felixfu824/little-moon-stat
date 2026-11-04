import AppKit

// Accessory app (no Dock icon). All behaviour lives in AppDelegate; see SwapPoints.swift for the
// engine and card hooks.
MainActor.assumeIsolated {
    guard let instance = SingleInstance() else { exit(0) }
    withExtendedLifetime(instance) {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
