import AppKit
import SwiftUI
import MonitorCore
import MonitorUI

/// SwiftUI swallows mouseDown; forward it so the panel can be dragged.
/// Also reports intrinsic-size changes so the panel can follow the card's fitting size.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    var onContentSizeChange: (() -> Void)?
    var settingsMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { settingsMenu?() }
    override func rightMouseDown(with event: NSEvent) { showContextMenu(event) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showContextMenu(event) }
        else { window?.performDrag(with:event) }
    }
    private func showContextMenu(_ event: NSEvent) {
        if let menu=menu(for:event) { NSMenu.popUpContextMenu(menu,with:event,for:self) }
    }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }
}

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the desktop-level glass panel. Configuration is the one measured in docs/spikes/glass.md.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let cornerRadius: CGFloat = 26
    static let tint = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.55)

    private let panel: DesktopPanel
    private let glass = NSGlassEffectView()
    private let host: DraggableHostingView<AnyView>
    private var glassStyle: GlassStyle = .clear
    private var refitScheduled = false
    private var tourHighlight = false
    private var baseRoot: AnyView
    /// True while we move the window ourselves, so `windowDidMove` does not persist it as a user drag.
    private var programmaticMove = false

    /// Called when the window server changes whether any of the panel can be seen.
    var onOcclusionChanged: (() -> Void)?

    /// Called with the new origin after a user drag.
    var onUserMoved: ((NSPoint) -> Void)?

    var settingsMenu: (() -> NSMenu)? {
        get { host.settingsMenu }
        set { host.settingsMenu=newValue }
    }
    /// Resolve the same menu through the hosting view event path, without displaying it.
    func contextMenuForTesting(control: Bool) -> NSMenu? {
        guard let event=NSEvent.mouseEvent(with:control ? .leftMouseDown:.rightMouseDown,
            location:.zero,modifierFlags:control ? .control:[],timestamp:0,windowNumber:panel.windowNumber,
            context:nil,eventNumber:0,clickCount:1,pressure:1) else { return nil }
        return host.menu(for:event)
    }

    var isVisible: Bool { panel.isVisible }
    var isUnoccluded: Bool { panel.occlusionState.contains(.visible) }
    var frame: NSRect { panel.frame }
    var windowNumber: Int { panel.windowNumber }
    var hostView: NSView { host }
    func setLevel(_ level: NSWindow.Level) { panel.level = level }
    func setTourHighlight(_ highlighted: Bool) {
        tourHighlight = highlighted
        host.rootView = highlighted ? AnyView(baseRoot.modifier(TourPanelHighlight()).environment(\.tourHighlighted, true)) : baseRoot
    }

    init(rootView: AnyView, glass style: GlassStyle) {
        baseRoot = rootView
        host = DraggableHostingView(rootView: rootView)
        panel = DesktopPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.title = "Little Moon"
        panel.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: panel)

        host.sizingOptions = [.intrinsicContentSize]
        host.onContentSizeChange = { [weak self] in self?.scheduleRefit() }
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = host
        panel.contentView = glass

        apply(glass: style)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    // MARK: Content and style

    func setRootView(_ view: AnyView) {
        baseRoot = view
        host.rootView = tourHighlight ? AnyView(view.modifier(TourPanelHighlight()).environment(\.tourHighlighted, true)) : view
        host.layoutSubtreeIfNeeded()
        refit()
    }

    func apply(glass style: GlassStyle) {
        glassStyle = style
        // Reduce Transparency: clear glass loses its contrast; fall back to tinted.
        let effective: GlassStyle = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .tinted : style
        switch effective {
        case .clear:
            glass.style = .clear
            glass.tintColor = nil
        case .tinted:
            glass.style = .regular
            glass.tintColor = Self.tint
        }
    }

    @objc private func accessibilityChanged() { apply(glass: glassStyle) }

    // MARK: Sizing

    private func scheduleRefit() {
        guard !refitScheduled else { return }
        refitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refitScheduled = false
            self.refit()
        }
    }

    /// Resize the panel to the card's fitting size, keeping the top-left corner fixed.
    func refit() {
        let size = host.fittingSize
        guard size.width > 1, size.height > 1, size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        setFrame(Self.clamp(frame, preferred: panel.screen), display: true)
        // The bottom-left origin moved with the height; persist it so a relaunch keeps the top edge.
        onUserMoved?(panel.frame.origin)
    }

    private func setFrame(_ frame: NSRect, display: Bool) {
        programmaticMove = true
        panel.setFrame(frame, display: display)
        programmaticMove = false
    }

    // MARK: Show / hide / position

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    /// Place the panel at `origin` (or top-right of the main screen when nil), clamped on-screen.
    func place(origin: NSPoint?) {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize.width > 1 ? host.fittingSize : panel.frame.size
        let target: NSPoint
        if let origin {
            target = origin
        } else {
            target = Self.defaultOrigin(for: size)
        }
        setFrame(Self.clamp(NSRect(origin: target, size: size), preferred: nil), display: true)
    }

    func resetPosition() {
        place(origin: nil)
        onUserMoved?(panel.frame.origin)
    }

    /// Clamp into the visible frame of the screen holding most of the panel (or main).
    func clampToScreen() {
        setFrame(Self.clamp(panel.frame, preferred: nil), display: true)
        onUserMoved?(panel.frame.origin)
    }

    /// Debug only (`--simulate-move-after`): moves the panel the way a user drag would, through the
    /// window-server move path, so `windowDidMove` persists the origin.
    func debugNudge(dx: CGFloat, dy: CGFloat) {
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + dx, y: panel.frame.origin.y + dy))
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        onOcclusionChanged?()
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmaticMove else { return }
        onUserMoved?(panel.frame.origin)
    }

    // MARK: Geometry

    static func defaultOrigin(for size: NSSize) -> NSPoint {
        // Primary display (menu-bar screen): deterministic, unlike NSScreen.main which follows key focus.
        let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 40, y: visible.maxY - size.height - 40)
    }

    /// Visible frame of the screen with the largest overlap with `frame`; falls back to main.
    static func visibleFrame(for frame: NSRect, preferred: NSScreen?) -> NSRect {
        var best: (area: CGFloat, rect: NSRect)?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (area, screen.visibleFrame) }
        }
        if let best { return best.rect }
        return (NSScreen.screens.first ?? preferred)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    static func clamp(_ frame: NSRect, preferred: NSScreen?) -> NSRect {
        let visible = visibleFrame(for: frame, preferred: preferred)
        var out = frame
        out.origin.x = min(max(out.origin.x, visible.minX), max(visible.minX, visible.maxX - out.width))
        out.origin.y = min(max(out.origin.y, visible.minY), max(visible.minY, visible.maxY - out.height))
        return out
    }
}
