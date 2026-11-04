import SwiftUI
import MonitorCore

/// Compatibility for the wave-1 app shell until it adopts MonitorCard.
public struct PlaceholderCard: View {
    private let snapshot: Snapshot
    public init(snapshot: Snapshot) { self.snapshot = snapshot }
    public var body: some View { LargeCard(snapshot: snapshot, options: DisplayOptions()) }
}
