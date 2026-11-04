import AppKit
import SwiftUI
import MonitorCore
import MonitorUI

@main
struct RenderCards {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--status") { try renderStatus(); return }
        if CommandLine.arguments.contains("--tour") { try renderTour(); return }
        if CommandLine.arguments.contains("--menubar") { try renderMenuBar(); return }
        if CommandLine.arguments.contains("--readme") { try renderReadme(); return }
        let output = URL(fileURLWithPath: "docs/wave2/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var empty = Snapshot.preview
        empty.cpuPercent = nil; empty.gpuPercent = nil
        empty.cpuTemp = nil; empty.gpuTemp = nil; empty.memory = nil; empty.disk = nil
        empty.thermal = nil; empty.topProcesses = []
        var stress = Snapshot.preview
        stress.cpuPercent = 100; stress.gpuPercent = 100
        stress.cpuTemp = TempStat(peak: 125, average: 103, sensorCount: 23)
        stress.gpuTemp = TempStat(peak: 119, average: 101, sensorCount: 84)
        stress.memory = MemoryStat(wired: 0, active: 0, compressed: 0, total: 128 * 1_073_741_824)
        stress.disk = DiskStat(volumeName: "A very long startup volume name for truncation", total: 1_379_000_000_000, free: 0)
        stress.topProcesses = [
            ProcRow(pid: 1, name: "An extremely long process name (Background Renderer Helper)", cpuPercent: 1234.5, residentBytes: 0),
            ProcRow(pid: 2, name: "Traditional Chinese 程序名稱很長的背景工作程序", cpuPercent: 50, residentBytes: 2_800_000_000),
            ProcRow(pid: 3, name: "Another extraordinarily long process name", cpuPercent: 49.9, residentBytes: 96_000_000)
        ]
        stress.thermal = .critical
        for (fixture, snapshot) in [("preview", Snapshot.preview), ("all-nil", empty), ("stress", stress)] {
            for language in AppLanguage.allCases {
                for size in PanelSize.allCases {
                    let options = DisplayOptions(size: size, language: language)
                    let store = SnapshotStore(snapshot: snapshot)
                    let renderer = ImageRenderer(content: MonitorCard(store: store, options: options)
                        .background(Color(red: 46/255, green: 74/255, blue: 99/255))
                        .environment(\.colorScheme, .dark))
                    renderer.scale = 2
                    guard let cgImage = renderer.cgImage else { fatalError("ImageRenderer failed") }
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
                    let name = "\(size.rawValue)-\(language.rawValue)-\(fixture).png"
                    try data.write(to: output.appendingPathComponent(name))
                    print("\(name): \(cgImage.width) × \(cgImage.height) px; \(cgImage.width / 2) × \(cgImage.height / 2) pt")
                }
            }
        }
    }
    @MainActor static func renderMenuBar() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: "docs/wave4/menubar", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func write(_ cg: CGImage, _ name: String) throws {
            let bitmap = NSBitmapImageRep(cgImage: cg)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            print("\(output.path)/\(name): \(cg.width) × \(cg.height)")
        }
        let pairs: [(Double, Double, Double)] = [(48,45,34),(60,55,48),(70,64,58),(78,72,71),(88,83,84),(97,94,96)]
        for unit in [TemperatureUnit.celsius, .fahrenheit] {
            for dark in [true, false] {
                for (i,pair) in pairs.enumerated() {
                    let image = TwinMoonsRenderer.image(cpuText: DisplayFormat.temperature(pair.0, unit: unit), gpuText: DisplayFormat.temperature(pair.1, unit: unit), cpuStep: MoonModel.step(pair.0), gpuStep: MoonModel.step(pair.1), dark: dark, scale: 3, ramText: DisplayFormat.percent(pair.2),
                        ramStep: MenuBarStepHysteresis.step(pair.2,start:0,span:100),ramColourStep:MoonModel.step(pair.2))
                    let renderer = ImageRenderer(content: Image(nsImage: image).frame(width: TwinMoonsRenderer.width, height: 22)
                        .background(dark ? Color(red: 43/255, green: 63/255, blue: 99/255) : Color(red: 220/255, green: 235/255, blue: 245/255)))
                    renderer.scale = 3
                    try write(renderer.cgImage!, "status-\(dark ? "dark" : "light")-\(unit.rawValue)-\(i).png")
                }
            }
        }
        for mask in 0...7 {
            let moons=MenuBarMoons(rawValue:mask)
            let name=MenuBarMoon.allCases.filter { moons.contains($0.selection) }.map(\.rawValue).joined(separator:"-")
            for dark in [true,false] {
                for unit in [TemperatureUnit.celsius,.fahrenheit] {
                    let image=TwinMoonsRenderer.image(cpuText:DisplayFormat.temperature(76,unit:unit),gpuText:DisplayFormat.temperature(63,unit:unit),
                        cpuStep:MoonModel.step(76),gpuStep:MoonModel.step(63),dark:dark,scale:3,ramText:"58%",
                        ramStep:MenuBarStepHysteresis.step(58,start:0,span:100),ramColourStep:MoonModel.step(58),moons:moons)
                    let renderer=ImageRenderer(content:Image(nsImage:image).frame(width:TwinMoonsRenderer.width(for:moons),height:22)
                        .background(dark ? Color(red:43/255,green:63/255,blue:99/255):Color(red:220/255,green:235/255,blue:245/255)))
                    renderer.scale=3
                    try write(renderer.cgImage!,"subset-\(dark ? "dark":"light")-\(unit.rawValue)-\(name.isEmpty ? "none":name).png")
                }
            }
        }
        for language in AppLanguage.allCases {
            for glass in GlassStyle.allCases {
                for unit in [TemperatureUnit.celsius, .fahrenheit] {
                    let options = DisplayOptions(glass: glass, language: language, temperatureUnit: unit)
                    let renderer=ImageRenderer(content:MoonPopover(snapshot:.preview,options:options,cost:0.6)
                        .background(glass == .clear ? Color(red:0.23,green:0.31,blue:0.44):Color(red:0.11,green:0.12,blue:0.15))
                        .clipShape(RoundedRectangle(cornerRadius:26)).environment(\.colorScheme,.dark))
                    renderer.scale=2
                    try write(renderer.cgImage!, "popover-\(language.rawValue)-\(glass.rawValue)-\(unit.rawValue).png")
                }
            }
        }
        var worst = Snapshot.preview
        worst.cpuTemp = TempStat(peak: 100, average: 100, sensorCount: 1)
        worst.gpuTemp = worst.cpuTemp
        for size in PanelSize.allCases {
            for unit in [TemperatureUnit.celsius, .fahrenheit] {
                let renderer = ImageRenderer(content: MonitorCard(store: SnapshotStore(snapshot: worst), options: DisplayOptions(size: size, language: .traditionalChinese, temperatureUnit: unit))
                    .background(Color(red: 0.18, green: 0.29, blue: 0.39)).environment(\.colorScheme, .dark))
                renderer.scale = 2
                try write(renderer.cgImage!, "desktop-\(size.rawValue)-zh-Hant-\(unit.rawValue)-worst.png")
            }
        }
    }

}
