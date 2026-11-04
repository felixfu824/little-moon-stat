import AppKit
import SwiftUI
import MonitorCore
import MonitorUI

extension RenderCards {
    @MainActor static func renderStatus() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: "docs/wave5/fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func write<V: View>(_ view: V, _ name: String, scale: CGFloat = 2) throws {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = scale
            guard let cg = renderer.cgImage else { fatalError("Status rendering failed") }
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            try png.write(to: output.appendingPathComponent(name + ".png"))
            print("\(name): \(cg.width) × \(cg.height)")
        }
        for estimated in [true, false] {
            var snapshot = Snapshot.preview
            snapshot.cpuTemp = TempStat(peak: 100, average: 95, sensorCount: 8)
            snapshot.gpuTemp = TempStat(peak: 100, average: 95, sensorCount: 8)
            if estimated {
                snapshot.status.cpuTemp = .estimated(.genericFamily, fault: .unknownChip)
                snapshot.status.gpuTemp = snapshot.status.cpuTemp
                snapshot.status.processes = .estimated(.libprocOnly, fault: .psUnavailable)
                snapshot.topProcesses = [
                    ProcRow(pid: 5011, name: "Safari", cpuPercent: 85.5, residentBytes: 1_200_000_000),
                    ProcRow(pid: 5012, name: "Codex (Server)", cpuPercent: 33.4, residentBytes: 2_800_000_000),
                    ProcRow(pid: 5013, name: "Terminal", cpuPercent: 23.1, residentBytes: 96_000_000)
                ]
            } else {
                snapshot.cpuTemp = nil; snapshot.gpuTemp = nil; snapshot.gpuPercent = nil; snapshot.topProcesses = []
                snapshot.status.cpuTemp = .unavailable(.serviceUnavailable)
                snapshot.status.gpuTemp = snapshot.status.cpuTemp
                snapshot.status.gpuPercent = .unavailable(.serviceUnavailable)
                snapshot.status.processes = .unavailable(.apiError)
            }
            let state = estimated ? "estimated" : "unavailable"
            for language in AppLanguage.allCases {
                let name = "\(state)-\(language.rawValue)"
                for unit in [TemperatureUnit.celsius, .fahrenheit] {
                    for size in PanelSize.allCases {
                        try write(MonitorCard(store: SnapshotStore(snapshot: snapshot), options: DisplayOptions(size: size, language: language, temperatureUnit: unit))
                            .background(Color(red: 0.18, green: 0.29, blue: 0.39)), "desktop-\(size.rawValue)-\(name)-\(unit.rawValue)")
                    }
                    try write(MoonPopover(snapshot: snapshot, options: DisplayOptions(language: language, temperatureUnit: unit), cost: 0.6)
                        .background(Color(red: 0.23, green: 0.31, blue: 0.44)).clipShape(RoundedRectangle(cornerRadius: 26)), "popover-\(name)-\(unit.rawValue)")
                    for dark in [true, false] {
                        let image = TwinMoonsRenderer.image(cpuText: DisplayFormat.temperature(snapshot.cpuTemp?.peak, unit: unit), gpuText: DisplayFormat.temperature(snapshot.gpuTemp?.peak, unit: unit), cpuStep: MoonModel.step(snapshot.cpuTemp?.peak), gpuStep: MoonModel.step(snapshot.gpuTemp?.peak), dark: dark, scale: 3, ramText: "58%", ramStep: 4, ramColourStep: 2, status: snapshot.status)
                        try write(Image(nsImage: image).frame(width: TwinMoonsRenderer.width, height: 22)
                            .background(dark ? Color(red: 0.17, green: 0.25, blue: 0.39) : Color(red: 0.86, green: 0.92, blue: 0.96)), "status-\(name)-\(unit.rawValue)-\(dark ? "dark" : "light")", scale: 3)
                    }
                }
            }
        }
    }
}
