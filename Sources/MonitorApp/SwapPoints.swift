import SwiftUI
import MonitorCore
import MonitorUI
import Samplers

// ============================================================================
// SWAP POINTS — composition root: engine and card factories.
//
//   1. makeEngine : SamplingEngine(store:)      (`--preview-engine` uses PreviewEngine)
//   2. makeCard   : MonitorCard(store:options:)
//
// Nothing else in MonitorApp names a concrete engine or card.
// ============================================================================

/// Production never presents the preview fixture while waiting for a CPU baseline.
@MainActor
func makeStore() -> SnapshotStore {
    if CommandLine.arguments.contains("--preview-engine") { return SnapshotStore(snapshot: .preview) }
    let system = SystemInfo()
    return SnapshotStore(snapshot: Aggregator(machineName: system.machineName, chipName: system.chipName, identityStatus: system.status).snapshot)
}

/// SWAP POINT 1. Returns the engine that fills `store`.
/// `--preview-engine` keeps the static fixture, for deterministic UI checks.
@MainActor
func makeEngine(store: SnapshotStore) -> MonitorEngine {
    if CommandLine.arguments.contains("--preview-engine") {
        return PreviewEngine(store: store)
    }
    let args = CommandLine.arguments
    let specifications = args.indices.filter { args[$0] == "--fault" && $0 + 1 < args.count }.map { args[$0 + 1] }
    return SamplingEngine(store: store, faults: FaultConfiguration((specifications + [ProcessInfo.processInfo.environment["MAC_MONITOR_FAULTS"] ?? ""]).joined(separator: ",")))
}

/// SWAP POINT 2. Returns the SwiftUI card for the current options.
/// The card draws on a transparent background (the app supplies the glass).
@MainActor
@ViewBuilder
func makeCard(store: SnapshotStore, options: DisplayOptions, watching: Bool = false) -> some View {
    MonitorCard(store: store, options: options, watching: watching)
}

/// Presentation visibility changes only the concrete sampler's detail work.
/// The PreviewEngine intentionally has no extra sampling to gate.
@MainActor
func setSamplingDetails(_ enabled: Bool, engine: MonitorEngine) {
    (engine as? SamplingEngine)?.setDetailSampling(enabled)
}

@MainActor
func configurePresentation(_ options: DisplayOptions, engine: MonitorEngine) {
    (engine as? SamplingEngine)?.setPresentationOptions(options)
}
@MainActor
func connectMenuBar(engine: MonitorEngine, handler: @escaping (MenuBarValues?) -> Void) {
    guard let sampling=engine as? SamplingEngine else { return }
    sampling.onPublish = { [weak sampling] _ in handler(sampling?.menuBarValues) }
}

@MainActor
func setWatchSampling(popover: Bool, panel: Bool, engine: MonitorEngine) {
    (engine as? SamplingEngine)?.setWatch(popover: popover, panel: panel)
}
