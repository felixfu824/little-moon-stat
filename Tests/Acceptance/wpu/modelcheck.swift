// WP-U acceptance helper: dumps the app's own menu-bar model (MonitorCore + MonitorUI release objects)
// as JSON lines so mockup.py can compare it against an independent re-implementation of the
// mockup's renderVals() JS. Also renders a few status images to PNG for pixel checks.
// Usage: modelcheck <out dir>
import AppKit
import MonitorCore
import MonitorUI

func emit(_ d: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
func rgb255(_ c: NSColor) -> [Int] {
    let s = c.usingColorSpace(.sRGB)!
    return [s.redComponent, s.greenComponent, s.blueComponent].map { Int(($0 * 255).rounded()) }
}
func snap(cpu: Double?, gpu: Double?, ramPct: Double?) -> Snapshot {
    var s = Snapshot.preview
    s.cpuTemp = cpu.map { TempStat(peak: $0, average: $0 - 5, sensorCount: 4) }
    s.gpuTemp = gpu.map { TempStat(peak: $0, average: $0 - 5, sensorCount: 4) }
    let total: UInt64 = 24 * 1_073_741_824
    s.memory = ramPct.map { MemoryStat(wired: 0, active: UInt64(Double(total) * $0 / 100), compressed: 0, total: total) }
    return s
}

@main struct ModelCheck {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // M1 phase grid
        var t = 30.0
        while t <= 110.0001 {
            let s = MoonModel.step(t)!
            emit(["k": "step", "t": (t * 10).rounded() / 10, "step": s, "lit": MoonModel.lit(s)])
            t += 0.1
        }
        // M2 colours per step
        for dark in [true, false] {
            for s in 0...7 {
                emit(["k": "ink", "dark": dark, "step": s, "rgb": rgb255(MoonModel.ink(step: s, dark: dark))])
            }
            emit(["k": "inkNil", "dark": dark, "alpha": MoonModel.ink(step: nil, dark: dark).alphaComponent])
        }
        // M3 RAM phase/colour (engine definitions used by the quantizer)
        var p = 0.0
        while p <= 100.0001 {
            emit(["k": "ram", "p": (p * 10).rounded() / 10,
                  "phase": MenuBarStepHysteresis.step(p, start: 0, span: 100)!,
                  "colour": MenuBarStepHysteresis.step(p)!])
            p += 0.1
        }
        // M5 units
        for loc in ["en_US", "en_GB", "zh_TW", "de_DE"] {
            for pref in ["Celsius", "Fahrenheit", nil] as [String?] {
                emit(["k": "resolve", "locale": loc, "pref": pref ?? "absent",
                      "unit": DisplayFormat.resolvedUnit(.system, locale: Locale(identifier: loc), preference: pref).rawValue])
            }
        }
        for v in [nil, 0.5, 49.6, 50, 75.4, 75.5, 76.5, 99.6, 100, 104.9, 150] as [Double?] {
            for u in TemperatureUnit.allCases {
                emit(["k": "fmt", "v": v.map { $0 as Any } ?? NSNull(), "unit": u.rawValue,
                      "s": DisplayFormat.temperature(v, unit: u)])
            }
        }
        emit(["k": "machineSystemUnit", "unit": DisplayFormat.resolvedUnit(.system).rawValue,
              "AppleTemperatureUnit": UserDefaults.standard.string(forKey: "AppleTemperatureUnit") ?? "absent",
              "locale": Locale.current.identifier])
        // M6 widths
        let font = TwinMoonsRenderer.numberFont
        for s in ["100°C", "212°F", "302°F", "100%", "—", "8°C", "46°F", "0%"] {
            emit(["k": "textw", "s": s, "w": (s as NSString).size(withAttributes: [.font: font]).width])
        }
        emit(["k": "slots", "label": TwinMoonsRenderer.labelWidth, "ram": TwinMoonsRenderer.ramLabelWidth,
              "micro": ["CPU", "GPU", "RAM"].map { ($0 as NSString).size(withAttributes: [.font: TwinMoonsRenderer.microFont]).width }])
        for raw in 0...7 {
            let m = MenuBarMoons(rawValue: raw)
            var sizes = Set<String>()
            for v in stride(from: 0.0, through: 150.0, by: 7.5) {
                for u in [TemperatureUnit.celsius, .fahrenheit] {
                    let img = TwinMoonsRenderer.image(cpuText: DisplayFormat.temperature(v, unit: u), gpuText: DisplayFormat.temperature(v, unit: u),
                        cpuStep: MoonModel.step(v), gpuStep: MoonModel.step(v), dark: true, ramText: DisplayFormat.percent(min(100, v)),
                        ramStep: 3, ramColourStep: 3, moons: m)
                    sizes.insert("\(img.size.width)x\(img.size.height)")
                }
            }
            let img = TwinMoonsRenderer.image(cpuText: "—", gpuText: "—", cpuStep: nil, gpuStep: nil, dark: true, ramText: "—", moons: m)
            sizes.insert("\(img.size.width)x\(img.size.height)")
            emit(["k": "subset", "raw": raw, "width": TwinMoonsRenderer.width(for: m), "imageSizes": Array(sizes).sorted()])
        }
        // M8-M10 quantizer sequences
        func run(_ name: String, _ seq: [(Double?, Double?, Double?)]) {
            var q = MenuBarQuantizer()
            var rows: [[Any]] = []
            for (c, g, r) in seq {
                let v = q.update(snap(cpu: c, gpu: g, ramPct: r))
                rows.append([c ?? NSNull(), v.cpu.number ?? NSNull(), v.cpu.phase ?? NSNull(), g ?? NSNull(), v.gpu.number ?? NSNull(),
                             v.gpu.phase ?? NSNull(), r ?? NSNull(), v.ram.number ?? NSNull(), v.ram.phase ?? NSNull(), v.ram.colour ?? NSNull()])
            }
            emit(["k": "seq", "name": name, "rows": rows])
        }
        var rng = SystemRandomNumberGenerator()
        func noise(_ center: Double, _ amp: Double, _ n: Int) -> [Double] { (0..<n).map { _ in center + Double.random(in: -amp...amp, using: &rng) } }
        for center in [60.0, 72.5, 76.5, 79.4, 85.4] {
            let n = noise(center, 0.9, 200)
            run("noise\(center)", n.map { ($0, $0, nil) })
        }
        for center in [72.5, 76.5, 79.4] {
            let n = noise(center, 0.45, 200)
            run("half\(center)", n.map { ($0, $0, nil) })
        }
        run("ramNoise", noise(57.1, 0.9, 200).map { (nil, nil, $0) })
        run("ramNoiseBoundary", noise(64.3, 0.9, 200).map { (nil, nil, $0) })
        run("sweep", (Array(stride(from: 40.0, through: 100.0, by: 0.25)) + Array(stride(from: 100.0, through: 40.0, by: -0.25))).map { ($0, $0, ($0 - 40) * 100 / 60) })
        run("step2", [70, 70, 70, 72, 72, 74, 74, 70, 68] .map { ($0, $0, nil) })
        run("missing", [(70, 70, 50), (nil, nil, nil), (71, 71, 51)])
        // M12 accessibility
        for lang in AppLanguage.allCases {
            for u in [TemperatureUnit.celsius, .fahrenheit] {
                for raw in 0...7 {
                    emit(["k": "a11y", "lang": lang.rawValue, "unit": u.rawValue, "raw": raw,
                          "s": MoonModel.accessibility(cpu: 76, gpu: 63, unit: u, language: lang, ram: 58, moons: MenuBarMoons(rawValue: raw))])
                }
                emit(["k": "a11yNil", "lang": lang.rawValue, "unit": u.rawValue,
                      "s": MoonModel.accessibility(cpu: nil, gpu: nil, unit: u, language: lang, ram: nil, moons: .all)])
            }
        }
        // M4/M13 pixel renders: CPU-only, scale 8, steps 0/7/nil, dark/light
        for dark in [true, false] {
            for s in [0, 3, 7, -1] {
                let step: Int? = s < 0 ? nil : s
                let img = TwinMoonsRenderer.image(cpuText: step == nil ? "—" : "76°C", gpuText: "", cpuStep: step, gpuStep: nil, dark: dark,
                                                  scale: 8, moons: .cpu)
                let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                let name = "px-\(dark ? "dark" : "light")-\(s < 0 ? "nil" : String(s)).png"
                try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
                // sample: centre (14,11) and right-edge crescent (14+5.6, 11) in points
                func px(_ x: Double, _ y: Double) -> [Int] {
                    let c = rep.colorAt(x: Int(x * 8), y: Int(y * 8))!.usingColorSpace(.sRGB)!
                    return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
                }
                emit(["k": "px", "dark": dark, "step": s, "centre": px(14, 11), "edge": px(19.6, 11), "leftEdge": px(8.4, 11),
                      "label": px(26, 15)])
            }
        }
        // M14: all three moons at mockup "in context" values 76/63/58 both appearances
        for dark in [true, false] {
            var q = MenuBarQuantizer(); let v = q.update(snap(cpu: 76, gpu: 63, ramPct: 58))
            let img = TwinMoonsRenderer.image(cpuText: DisplayFormat.temperature(v.cpu.number, unit: .celsius), gpuText: DisplayFormat.temperature(v.gpu.number, unit: .celsius),
                cpuStep: v.cpu.phase, gpuStep: v.gpu.phase, dark: dark, scale: 6, ramText: DisplayFormat.percent(v.ram.number),
                ramStep: v.ram.phase, ramColourStep: v.ram.colour, moons: .all)
            let rep = NSBitmapImageRep(cgImage: img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("context-\(dark ? "dark" : "light")-76-63-58.png"))
            emit(["k": "context", "dark": dark, "cpu": [v.cpu.number ?? -1, v.cpu.phase ?? -1], "gpu": [v.gpu.number ?? -1, v.gpu.phase ?? -1],
                  "ram": [v.ram.number ?? -1, v.ram.phase ?? -1, v.ram.colour ?? -1]])
        }
    }
}
