// Renders Medium/Large cards for realistic heavy-load fixtures (offline, no screen capture).
// swiftc -O -I .build/release .build/release/{MonitorCore,MonitorUI}.o fixture_render.swift -o fixture_render
import AppKit
import SwiftUI
import MonitorCore
import MonitorUI
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let cases: [(String, Double, Double, Double, Double)] = [
    ("cpu100-t100-g96", 100, 100, 100.4, 96.4),   // values observed on the Pro under load
    ("cpu100-t99-g99", 100, 100, 99.4, 99.4),
    ("cpu98-t100-g60", 98, 41, 100.0, 60),
]
MainActor.assumeIsolated {
    for (name, cpu, gpu, ct, gt) in cases {
        var s = Snapshot.preview
        s.cpuPercent = cpu; s.gpuPercent = gpu
        s.cpuTemp = TempStat(peak: ct, average: ct - 8, sensorCount: 23); s.gpuTemp = TempStat(peak: gt, average: gt - 4, sensorCount: 84)
        for size in PanelSize.allCases {
            let r = ImageRenderer(content: MonitorCard(store: SnapshotStore(snapshot: s), options: DisplayOptions(size: size, language: .english))
                .background(Color(red: 46/255, green: 74/255, blue: 99/255)).environment(\.colorScheme, .dark))
            r.scale = 2
            let png = NSBitmapImageRep(cgImage: r.cgImage!).representation(using: .png, properties: [:])!
            try! png.write(to: out.appendingPathComponent("\(size.rawValue)-\(name).png"))
        }
    }
}
