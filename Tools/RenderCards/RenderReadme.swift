import AppKit
import SwiftUI
import MonitorCore
import MonitorUI

/// README hero assets (`RenderCards --readme`). Fully offline: a generated wallpaper, our own views and no
/// screen capture. The only "menu bar" content is our moons plus generic system glyphs and a fixed clock.
@MainActor
func renderReadme() throws {
    _ = NSApplication.shared
    let output = URL(fileURLWithPath: "docs/readme", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func write(_ cg: CGImage, _ name: String) throws {
        let bitmap = NSBitmapImageRep(cgImage: cg)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        print("\(output.path)/\(name): \(cg.width) × \(cg.height) px")
    }

    // A calm, warm-ish workload so the moons show a visible but friendly colour. Generic macOS process names only.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let stamp = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9, minute: 41))!
    var snapshot = Snapshot.preview
    snapshot.timestamp = stamp
    snapshot.cpuPercent = 34; snapshot.gpuPercent = 27
    snapshot.cpuTemp = TempStat(peak: 72, average: 61, sensorCount: 23)
    snapshot.gpuTemp = TempStat(peak: 63, average: 58, sensorCount: 84)
    snapshot.topProcesses = [
        ProcRow(pid: 401, name: "WindowServer", cpuPercent: 21.4, residentBytes: 1_100_000_000),
        ProcRow(pid: 512, name: "mds_stores", cpuPercent: 12.8, residentBytes: 480_000_000),
        ProcRow(pid: 188, name: "coreaudiod", cpuPercent: 6.3, residentBytes: 38_000_000),
    ]
    let options = DisplayOptions(size: .large, glass: .clear, language: .english, temperatureUnit: .celsius)

    let sceneW: CGFloat = 1100, sceneH: CGFloat = 744, barH: CGFloat = 32
    let popoverW: CGFloat = 360, popoverH: CGFloat = 634
    let panelW: CGFloat = 360, panelH: CGFloat = 333

    // Menu bar moons, drawn at 1.35x so they stay legible when GitHub scales the hero to ~830 px.
    let moonsScale: CGFloat = 1.35
    let moonsImage = TwinMoonsRenderer.image(
        cpuText: DisplayFormat.temperature(72, unit: .celsius), gpuText: DisplayFormat.temperature(63, unit: .celsius),
        cpuStep: MoonModel.step(72), gpuStep: MoonModel.step(63), dark: true, scale: 6, ramText: DisplayFormat.percent(58),
        ramStep: MenuBarStepHysteresis.step(58, start: 0, span: 100), ramColourStep: MoonModel.step(58))
    let moonsW = TwinMoonsRenderer.width * moonsScale, moonsH = 22 * moonsScale

    let glassFill = Color(red: 0.08, green: 0.10, blue: 0.17).opacity(0.62)
    func glass<V: View>(_ view: V, radius: CGFloat = 26) -> some View {
        view
            .background(glassFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.10)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.38), radius: 26, x: 0, y: 14)
    }
    func pill(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 12, weight: .semibold)).tracking(0.2)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75))
    }

    let clockW: CGFloat = 86
    let moonsRight = sceneW - 16 - clockW - 14 - 26 - 14 - 22 - 20   // clock, battery, wifi, then a gap
    let moonsCenterX = moonsRight - moonsW / 2
    let popoverX = min(sceneW - 28 - popoverW / 2, moonsCenterX + 40)  // right-aligned under the moons

    let panelCenter = CGPoint(x: 232, y: 150 + panelH / 2)

    let hero = ZStack(alignment: .topLeading) {
        Wallpaper().frame(width: sceneW, height: sceneH)

        // Menu bar
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.26)).frame(width: sceneW, height: barH)
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: sceneW, height: 0.5).offset(y: barH - 0.5)
            Image(nsImage: moonsImage).resizable().interpolation(.high).frame(width: moonsW, height: moonsH)
                .position(x: moonsCenterX, y: barH / 2)
            Image(systemName: "wifi").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                .position(x: sceneW - 16 - clockW - 14 - 26 - 14 - 11, y: barH / 2)
            Image(systemName: "battery.75percent").font(.system(size: 15, weight: .regular)).foregroundStyle(.white.opacity(0.9))
                .position(x: sceneW - 16 - clockW - 14 - 13, y: barH / 2)
            Text("Thu 9:41").font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                .frame(width: clockW, alignment: .trailing).position(x: sceneW - 16 - clockW / 2, y: barH / 2)
        }

        // Desktop panel (the large card on the wallpaper layer)
        glass(MonitorCard(store: SnapshotStore(snapshot: snapshot), options: options)
            .environment(\.colorScheme, .dark).frame(width: panelW, height: panelH))
            .position(panelCenter)

        // Popover
        glass(MoonPopover(snapshot: snapshot, options: options, cost: 0.6)
            .environment(\.colorScheme, .dark).frame(width: popoverW, height: popoverH))
            .position(x: popoverX, y: barH + 10 + popoverH / 2)

        // Labels
        pill("Desktop panel, under your windows").position(x: panelCenter.x, y: panelCenter.y + panelH / 2 + 28)
        pill("Click the moons for the full readout", symbol: "arrow.up.right")
            .position(x: popoverX - popoverW / 2 - 148, y: barH + 36)
        pill("Moons in the menu bar").position(x: popoverX, y: barH + 10 + popoverH + 26)
    }
    .frame(width: sceneW, height: sceneH)
    .clipped()

    let renderer = ImageRenderer(content: hero)
    renderer.scale = 1.5
    guard let cg = renderer.cgImage else { fatalError("hero rendering failed") }
    try write(cg, "hero.png")

    // Strip: the moon fills and warms from white to red as it heats up.
    let temps: [Double] = [40, 52, 62, 72, 84, 96]
    let stripW: CGFloat = 1100, stripH: CGFloat = 150
    let cellScale: CGFloat = 2.3
    let cells = temps.map { t -> (Image, CGFloat) in
        let ns = TwinMoonsRenderer.image(cpuText: DisplayFormat.temperature(t, unit: .celsius), gpuText: "", cpuStep: MoonModel.step(t), gpuStep: nil,
                                         dark: true, scale: 8, moons: .cpu)
        return (Image(nsImage: ns), TwinMoonsRenderer.width(for: .cpu) * cellScale)
    }
    let strip = ZStack {
        Wallpaper().frame(width: stripW, height: stripH)
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    cell.0.resizable().interpolation(.high).frame(width: cell.1, height: 22 * cellScale)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 28)
            HStack(spacing: 10) {
                Text("cool").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Capsule().fill(LinearGradient(colors: [.white, Color(red: 1, green: 0.74, blue: 0.40), Color(red: 1, green: 0.34, blue: 0.28)],
                                              startPoint: .leading, endPoint: .trailing)).frame(height: 3)
                Text("hot").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 60)
        }
    }
    .frame(width: stripW, height: stripH).clipped()
    let stripRenderer = ImageRenderer(content: strip)
    stripRenderer.scale = 1.5
    guard let stripImage = stripRenderer.cgImage else { fatalError("strip rendering failed") }
    try write(stripImage, "moon-ramp.png")
}

/// Generated dusk wallpaper: deep indigo to violet with soft glows. Not derived from any Apple wallpaper.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.12, blue: 0.30), Color(red: 0.20, green: 0.15, blue: 0.40), Color(red: 0.36, green: 0.20, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.45).opacity(0.38), .clear],
                           center: UnitPoint(x: 0.10, y: 1.02), startRadius: 10, endRadius: 620)
            RadialGradient(colors: [Color(red: 0.30, green: 0.62, blue: 0.95).opacity(0.30), .clear],
                           center: UnitPoint(x: 0.88, y: 0.02), startRadius: 10, endRadius: 560)
            RadialGradient(colors: [Color(red: 0.55, green: 0.40, blue: 0.85).opacity(0.22), .clear],
                           center: UnitPoint(x: 0.52, y: 0.60), startRadius: 10, endRadius: 420)
        }
    }
}
