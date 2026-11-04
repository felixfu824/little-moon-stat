// Offline render of the REAL engine's snapshot (no screen capture). Link against the product objects:
//   swiftc -O -I .build/release .build/release/{MonitorCore,Samplers,MonitorUI}.o liverender.swift -o liverender
// Usage: liverender <seconds> <outdir>
import AppKit
import SwiftUI
import MonitorCore
import Samplers
import MonitorUI

@MainActor func render(_ snapshot: Snapshot, _ outdir: URL) {
    for language in AppLanguage.allCases {
        for size in PanelSize.allCases {
            let options = DisplayOptions(size: size, language: language)
            let r = ImageRenderer(content: MonitorCard(store: SnapshotStore(snapshot: snapshot), options: options)
                .background(Color(red: 46/255, green: 74/255, blue: 99/255))
                .environment(\.colorScheme, .dark))
            r.scale = 2
            guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else { print("render failed"); continue }
            let name = "live-\(size.rawValue)-\(language.rawValue).png"
            try? png.write(to: outdir.appendingPathComponent(name))
            print("\(name) \(cg.width / 2)x\(cg.height / 2) pt")
        }
    }
}

func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "nil" }

let secs = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
let outdir = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
try? FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    let store = SnapshotStore()
    let engine = SamplingEngine(store: store)
    engine.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
        MainActor.assumeIsolated {
            let s = store.snapshot
            print("machine=\(s.machineName) chip=\(s.chipName) thermal=\(s.thermal?.rawValue ?? "nil")")
            print("cpu=\(fmt(s.cpuPercent)) gpu=\(fmt(s.gpuPercent))")
            print("cpuTemp peak=\(fmt(s.cpuTemp?.peak)) avg=\(fmt(s.cpuTemp?.average)) n=\(s.cpuTemp?.sensorCount ?? 0)")
            print("gpuTemp peak=\(fmt(s.gpuTemp?.peak)) avg=\(fmt(s.gpuTemp?.average)) n=\(s.gpuTemp?.sensorCount ?? 0)")
            if let m = s.memory { print("memory wired=\(m.wired) active=\(m.active) compressed=\(m.compressed) used=\(m.used) total=\(m.total)") }
            if let d = s.disk { print("disk name=\(d.volumeName) total=\(d.total) free=\(d.free) used=\(d.used)") }
            for p in s.topProcesses { print("proc pid=\(p.pid) name=\(p.name) cpu=\(fmt(p.cpuPercent)) rss=\(p.residentBytes)") }
            print("time=\(s.timestamp)")
            engine.stop()
            render(s, outdir)
            exit(0)
        }
    }
}
RunLoop.main.run()
