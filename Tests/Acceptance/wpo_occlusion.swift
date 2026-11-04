// Standalone app-lifecycle regression; compile with MonitorApp sources except main.swift.
// Default: order the panel out/in to verify real occlusion notifications and an occluded wake.
// --test-cover: use an owned opaque covering process; exits 3 if AppKit conservatively
// keeps .visible set. No flags are synthesized, and no screen content is captured.
import AppKit
import Foundation

@main
struct OcclusionRegression {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--cover") {
            let values = CommandLine.arguments.suffix(4).map { Double($0)! }
            let window = NSWindow(contentRect: NSRect(x: values[0], y: values[1], width: values[2] + 4, height: values[3] + 4), styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .floating
            window.isOpaque = true
            window.backgroundColor = .black
            window.contentView = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.black.cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                window.orderFrontRegardless()
                log("TEST cover window frame=\(window.frame) visible=\(window.isVisible) opaque=\(window.isOpaque)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { app.terminate(nil) }
            withExtendedLifetime(window) { app.run() }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        var cover: Process?
        let testCover = CommandLine.arguments.contains("--test-cover")
        func panel() -> NSWindow { app.windows.first { $0.title == "Little Moon" }! }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            log("TEST occlusion begin")
            guard testCover else { panel().orderOut(nil); return }
            let frame = panel().frame.insetBy(dx: -64, dy: -64)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--cover", String(Double(frame.origin.x)), String(Double(frame.origin.y)), String(Double(frame.width)), String(Double(frame.height))]
            cover = process
            log("TEST cover begin")
            try! process.run()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard !panel().occlusionState.contains(.visible) else {
                cover?.terminate()
                cover?.waitUntilExit()
                log("TEST cover unverified: AppKit retains .visible despite opaque coverage")
                exit(3)
            }
            log("TEST occluded confirmed")
        }
        // --simulate-wake-after 12 exercises a wake while the panel remains ordered out or covered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            log("TEST occlusion end")
            cover?.terminate()
            cover?.waitUntilExit()
            cover = nil
            if !testCover { panel().orderFrontRegardless() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 17) {
            guard panel().occlusionState.contains(.visible) else { fatalError("uncovered panel still occluded") }
            log("TEST uncovered confirmed")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 23) {
            log("TEST complete")
            app.terminate(nil)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
