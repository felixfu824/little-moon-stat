import AppKit
import SwiftUI
import MonitorCore
import MonitorUI

/// The About window. Not a panel: a normal titled window with a transparent title bar and glass behind it.
/// Esc and Command-W close it (the app has no main menu, so the window handles both itself).
final class AboutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class AboutWindowController {
    private(set) var window: AboutWindow?
    private var host: NSHostingView<AboutView>?
    private var language: AppLanguage = .english
    private let opener: (URL) -> Void

    init(opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) { self.opener = opener }

    var isVisible: Bool { window?.isVisible == true }

    /// One shared window: showing it again brings the existing one forward.
    func show(language: AppLanguage) {
        self.language = language
        let window = window ?? makeWindow()
        refresh()
        if !window.isVisible { center(window) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Live language change while the window is open.
    func update(language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        refresh()
    }

    func close() { window?.performClose(nil) }

    private func view() -> AboutView {
        AboutView(language: language, versionLine: AboutContent.versionLine(language: language), open: opener)
    }

    private func refresh() {
        guard let host, let window else { return }
        host.rootView = view()
        window.title = MenuText.about.string(language)
        resize(window, host: host)
    }

    private func resize(_ window: NSWindow, host: NSHostingView<AboutView>) {
        let size = host.fittingSize
        guard size.height > 0, window.contentRect(forFrameRect: window.frame).size != size else { return }
        // Keep the top-left corner fixed when the height changes (language switch).
        let top = window.frame.maxY
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    private func makeWindow() -> AboutWindow {
        let host = NSHostingView(rootView: view())
        host.safeAreaRegions = []
        let size = host.fittingSize
        let window = AboutWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled, .closable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.title = MenuText.about.string(language)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.moveToActiveSpace]
        window.level = .normal
        if AboutWindowController.useWindowGlass {
            // Glass behind the whole window. Reduce Transparency is handled by NSGlassEffectView itself.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 26
            glass.contentView = host
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = glass
        } else {
            window.contentView = host
        }
        self.host = host
        self.window = window
        return window
    }

    /// Fallback switch: set to false for a plain system window background (variant A look).
    static let useWindowGlass = true

    private func center(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { window.center(); return }
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                      y: area.midY - window.frame.height / 2 + area.height * 0.08))
    }
}
