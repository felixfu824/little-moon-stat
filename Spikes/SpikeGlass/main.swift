import AppKit
import SwiftUI
import ScreenCaptureKit
import QuartzCore

// Standalone spike: no MonitorApp/MonitorCore dependency and no network access.
enum Variant: String, CaseIterable {
    case appkitClear = "appkit-clear", appkitTinted = "appkit-tinted"
    case swiftui, visualeffect
}

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class StripeView: NSView {
    var phase = 0 { didSet { needsDisplay = true } }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Opaque test content shields the whole sampled panel from real desktop content.
        NSColor.black.setFill()
        bounds.fill()
        let colors: [NSColor] = [.white, .black, .systemCyan, .systemOrange]
        let width: CGFloat = 45
        for index in -2...10 {
            colors[((index % 4) + 4) % 4].setFill()
            NSRect(x: CGFloat(index) * width + CGFloat(phase % 4) * 19,
                   y: 0, width: width, height: bounds.height).fill()
        }
    }
}

struct SampleCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("MacBook Pro · M5 Max").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            Text("Thermal OK · 21:29").font(.system(size: 11))
            HStack(spacing: 8) {
                tile("26%", "CPU", "8 performance cores")
                tile("59%", "GPU", "40 cores")
            }
            HStack(spacing: 8) {
                tile("75° max", "CPU Temp", "avg 68°")
                tile("69° max", "GPU Temp", "avg 67°")
            }
            HStack { Text("Memory"); Spacer(); Text("74.4 / 128 GB") }
                .font(.system(size: 12))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.cyan).frame(width: geometry.size.width * 0.58)
                }
            }.frame(height: 6)
            HStack { Text("Disk · Macintosh HD"); Spacer(); Text("379 GB free") }
                .font(.system(size: 11))
            Spacer(minLength: 0)
            // Empty band (y=350...380 from top) is the pixel-diff measurement area.
        }
        .padding(18).frame(width: 360, height: 400)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
    }

    private func tile(_ value: String, _ label: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 21, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 11))
            Text(detail).font(.system(size: 10)).opacity(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(.white.opacity(0.10), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let variant: Variant
    let output: URL?
    var panel: DesktopPanel!
    var backdrop: NSWindow!
    let stripes = StripeView()
    var animation: Timer?
    var records: [[String: Any]] = []
    let start = CACurrentMediaTime()

    init(variant: Variant, output: URL?) {
        self.variant = variant
        self.output = output
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let visible = NSScreen.main!.visibleFrame
        let frame = NSRect(x: visible.midX - 180, y: visible.midY - 200, width: 360, height: 400)
        backdrop = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.level = .init(rawValue: NSWindow.Level.normal.rawValue - 2)
        backdrop.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        backdrop.hasShadow = false
        backdrop.isOpaque = true
        backdrop.title = "SpikeGlass opaque stripes"
        backdrop.contentView = stripes
        backdrop.orderFrontRegardless()

        panel = DesktopPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .init(rawValue: NSWindow.Level.normal.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.title = "SpikeGlass \(variant.rawValue)"

        switch variant {
        case .appkitClear, .appkitTinted:
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
            glass.style = variant == .appkitTinted ? .regular : .clear
            glass.cornerRadius = 26
            if variant == .appkitTinted {
                glass.tintColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.55)
            }
            glass.contentView = NSHostingView(rootView: SampleCard())
            panel.contentView = glass
        case .swiftui:
            panel.contentView = NSHostingView(rootView: SampleCard()
                .glassEffect(.clear, in: .rect(cornerRadius: 26)))
        case .visualeffect:
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            // Use the material's own mask API rather than clipping its backing layer.
            effect.maskImage = NSImage(size: frame.size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26).fill()
                return true
            }
            let host = NSHostingView(rootView: SampleCard())
            host.frame = effect.bounds
            host.autoresizingMask = [.width, .height]
            effect.addSubview(host)
            panel.contentView = effect
        }
        panel.orderFrontRegardless()
        log("launch", ["pid": ProcessInfo.processInfo.processIdentifier,
                       "os": ProcessInfo.processInfo.operatingSystemVersionString,
                       "panelID": panel.windowNumber, "backdropID": backdrop.windowNumber,
                       "panelLevel": panel.level.rawValue, "backdropLevel": backdrop.level.rawValue,
                       "panelStyleMask": panel.styleMask.rawValue,
                       "collectionBehavior": panel.collectionBehavior.rawValue,
                       "screenScale": panel.screen?.backingScaleFactor ?? 0,
                       "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                       "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                       "appearance": panel.effectiveAppearance.name.rawValue])
        startAnimation()
        if output != nil {
            Task {
                do { try await runEvidence() }
                catch {
                    log("error", ["description": String(describing: error)])
                    try? saveRecords()
                    // Do not request Screen Recording permission or retry a denied capture.
                    exit(2)
                }
            }
        }
    }

    func startAnimation() {
        animation = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stripes.phase += 1
            self.stripes.displayIfNeeded()
        }
    }

    func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func runEvidence() async throws {
        try FileManager.default.createDirectory(at: output!, withIntermediateDirectories: true)
        // Checking only; no CGRequestScreenCaptureAccess or permission-grant attempt.
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "SpikeGlass", code: 77,
                          userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission absent; capture stopped without requesting it"])
        }
        try await pause(1.15)
        let firstRequest = CACurrentMediaTime()
        try await capture("live-a")
        try await pause(max(0, 0.5 - (CACurrentMediaTime() - firstRequest)))
        try await capture("live-b")
        animation?.invalidate()
        animation = nil
        try await pause(0.7)
        try await capture("static-a")
        try await pause(0.5)
        try await capture("static-b")
        try await capture("backdrop", backdropOnly: true)

        // Move both by 200 pt; the opaque backdrop continues to shield all of the panel.
        let oldOrigin = panel.frame.origin
        backdrop.setFrameOrigin(NSPoint(x: oldOrigin.x + 200, y: oldOrigin.y))
        panel.setFrameOrigin(NSPoint(x: oldOrigin.x + 200, y: oldOrigin.y))
        log("move", ["dx": 200, "dy": 0, "panelFrame": NSStringFromRect(panel.frame)])
        startAnimation()
        try await pause(0.65)
        let movedRequest = CACurrentMediaTime()
        try await capture("moved-a")
        try await pause(max(0, 0.5 - (CACurrentMediaTime() - movedRequest)))
        try await capture("moved-b")
        animation?.invalidate()
        animation = nil
        try await pause(2)
        try saveRecords()
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            .write(to: output!.appendingPathComponent("ready"))
        log("idle-ready", ["phase": stripes.phase])
        // Remain running with no animation, screenshot tasks, or app timers for external ps sampling.
    }

    func capture(_ name: String, backdropOnly: Bool = false) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownIDs = backdropOnly ? [backdrop.windowNumber] : [panel.windowNumber, backdrop.windowNumber]
        let ownWindows = content.windows.filter {
            ownIDs.contains(Int($0.windowID)) && $0.owningApplication?.processID == getpid()
        }
        guard ownWindows.count == ownIDs.count,
              let screen = panel.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }),
              let backdropWindow = ownWindows.first(where: { Int($0.windowID) == backdrop.windowNumber }) else {
            throw NSError(domain: "SpikeGlass", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Own windows/display not found; refusing broader capture"])
        }
        // Allowlist only these exact two PID-verified windows. No desktop, Dock or other apps.
        let filter = SCContentFilter(display: display, including: ownWindows)
        filter.includeMenuBar = false
        let config = SCStreamConfiguration()
        config.sourceRect = backdropWindow.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        // Match the source's nominal dimensions. Larger output dimensions can be
        // padded rather than scaled by SCScreenshotManager on a 1x display.
        config.width = 360
        config.height = 400
        config.showsCursor = false
        config.ignoreShadowsDisplay = true
        config.captureResolution = .nominal
        let phaseBefore = stripes.phase
        let began = CACurrentMediaTime()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SpikeGlass", code: 2)
        }
        try data.write(to: output!.appendingPathComponent("\(name).png"))
        log("capture", ["name": name, "phaseBefore": phaseBefore, "phaseAfter": stripes.phase,
                        "requestTime": began - start, "duration": CACurrentMediaTime() - began,
                        "includedIDs": ownIDs, "sourceRect": NSStringFromRect(config.sourceRect),
                        "width": image.width, "height": image.height])
    }

    func log(_ event: String, _ fields: [String: Any]) {
        var row = fields
        row["event"] = event
        row["variant"] = variant.rawValue
        row["elapsed"] = CACurrentMediaTime() - start
        records.append(row)
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }

    func saveRecords() throws {
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output!.appendingPathComponent("events.json"))
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first, let variant = Variant(rawValue: first),
      arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--out") else {
    fputs("Usage: SpikeGlass <appkit-clear|appkit-tinted|swiftui|visualeffect> [--out DIRECTORY]\n", stderr)
    exit(64)
}
let output = arguments.count == 3 ? URL(fileURLWithPath: arguments[2], isDirectory: true) : nil
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(variant: variant, output: output)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
