import AppKit

public enum TourAnchorKind: String { case item, popover, panel }
public enum CoachMarkPlacement {
    public static func preferredEdge(anchor: CGRect, screen: CGRect, kind: TourAnchorKind) -> NSRectEdge {
        switch kind {
        case .item: return .minY
        case .popover: return anchor.minX - 324 >= screen.minX ? .minX : .minY
        case .panel:
            if anchor.midX > screen.midX { return anchor.minX - 324 >= screen.minX ? .minX : .maxY }
            return anchor.maxX + 324 <= screen.maxX ? .maxX : .maxY
        }
    }
}
