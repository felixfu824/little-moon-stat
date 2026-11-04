import AppKit
import MonitorUI

struct TourAnchor {
    let view: NSView
    let kind: TourAnchorKind
    var frame: NSRect { view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero }
    var screen: NSRect { view.window?.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero }
    var usable: Bool { view.window?.isVisible == true && frame.width > 1 && NSScreen.screens.contains { $0.frame.intersects(frame) } }
}

@MainActor
struct TourAnchors {
    let moons: MoonStatusController
    let panel: PanelController
    var itemAvailable: Bool { !moons.hidden && !moons.parkedByOrganizer && item?.usable == true }
    var item: TourAnchor? { moons.anchorView.map { TourAnchor(view: $0, kind: .item) } }
    var desktop: TourAnchor { TourAnchor(view: panel.hostView, kind: .panel) }
    var popover: TourAnchor? { moons.popoverContentView.map { TourAnchor(view: $0, kind: .popover) } }
    func resolve(_ step: TourStep) -> TourAnchor? {
        if step == .panel && desktop.usable { return desktop }
        if step == .popover, let popover, popover.usable { return popover }
        if itemAvailable { return item }
        if desktop.usable { return desktop }
        if let popover, popover.usable { return popover }
        return nil
    }
}
