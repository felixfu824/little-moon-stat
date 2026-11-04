// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMonitorPanel",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MacMonitorPanel", targets: ["MonitorApp"]),
    ],
    targets: [
        // Shared contracts: snapshot model, sampling engine, metric status.
        .target(name: "MonitorCore"),
        // Hardware samplers. One subdirectory per sampler (SMC/, Process/, ...).
        .target(name: "Samplers", dependencies: ["MonitorCore"]),
        // SwiftUI cards, theme, localization.
        .target(name: "MonitorUI", dependencies: ["MonitorCore"]),
        // AppKit shell: desktop-level panel, status item, settings.
        .executableTarget(name: "MonitorApp", dependencies: ["MonitorCore", "Samplers", "MonitorUI"]),

        // Risk spikes: standalone executables that proved each sampling route.
        .executableTarget(name: "SpikeGlass", path: "Spikes/SpikeGlass", exclude: ["analyze.py", "run-evidence.sh"]),

        .executableTarget(name: "SpikeSMC", dependencies: ["Samplers"], path: "Spikes/SpikeSMC"),
        .executableTarget(name: "SpikeProcs", dependencies: ["Samplers"], path: "Spikes/SpikeProcs"),

        // Wave-2 tools.
        // Runs the real engine headless and prints Snapshot JSON + its own CPU cost.
        .executableTarget(name: "EngineDump", dependencies: ["MonitorCore", "Samplers"], path: "Tools/EngineDump"),
        // Renders MonitorUI cards to PNG offline (no screen capture needed).
        .executableTarget(name: "RenderCards", dependencies: ["MonitorCore", "MonitorUI"], path: "Tools/RenderCards"),

        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
        .testTarget(name: "SamplersTests", dependencies: ["Samplers"]),
        .testTarget(name: "MonitorUITests", dependencies: ["MonitorCore", "MonitorUI"]),
    ],
    swiftLanguageModes: [.v5]
)
