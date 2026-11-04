import Foundation
import MonitorCore

public enum TourStep: String, CaseIterable { case moons, popover, panel, settings, mode }
public enum TourOutcome: String { case started, completed, skipped, abandoned, legacy }
public enum TourFlow {
    public static let version = 1
    public static let showWhatsNew = false
}

/// Pure planning, navigation and launch policy. A plan never changes after the tour starts.
public struct TourState {
    public let steps: [TourStep]
    public private(set) var index: Int
    public private(set) var outcome: TourOutcome?
    public var step: TourStep { steps[index] }
    public var isLast: Bool { index == steps.count - 1 }
    public init(mode: DisplayMode, hidden: Bool, panelVisible: Bool, startIndex: Int = 0) {
        steps = TourStep.allCases.filter {
            ($0 != .popover || !hidden) && ($0 != .panel || (mode != .menuBar && panelVisible))
        }
        index = min(max(0, startIndex), steps.count - 1)
    }
    public mutating func start() { outcome = .started }
    public mutating func next() { guard outcome == .started else { return }; if isLast { outcome = .completed } else { index += 1 } }
    public mutating func back() { guard outcome == .started else { return }; index = max(0, index - 1) }
    public mutating func skip() { guard outcome == .started else { return }; outcome = isLast ? .completed : .skipped }
    public mutating func abandon() { if outcome == .started { outcome = .abandoned } }
    public static func restoredOutcome(_ raw: String?) -> TourOutcome? {
        let outcome = raw.flatMap(TourOutcome.init(rawValue:))
        return outcome == .started ? .abandoned : outcome
    }
    public static func launchDecision(version: Int, harnessDomain: Bool, arguments: [String]) -> (run: Bool, reason: String) {
        if arguments.contains("--tour") || arguments.contains("--tour-check") || arguments.contains("--tour-step") {
            return (true, "forced")
        }
        if harnessDomain { return (false, "harness-domain") }
        if arguments.contains(where: { $0.hasPrefix("--") && !$0.hasPrefix("--tour") && $0 != "--reset-tour" }) {
            return (false, "debug-argument")
        }
        return version == 0 ? (true, "first-run") : (false, "already-seen")
    }
}
