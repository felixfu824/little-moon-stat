import AppKit
import SwiftUI
import MonitorCore

/// Shared by the status image, the popover, offline renders and tests.
public enum MoonModel {
    public static func step(_ temperature: Double?) -> Int? {
        guard let temperature, temperature.isFinite else { return nil }
        return Int((min(1, max(0, (temperature - 50) / 45)) * 7).rounded())
    }
    public static func lit(_ step: Int) -> Double { 0.12 + 0.88 * Double(min(7, max(0, step))) / 7 }
    public static let stops: [Double] = [50, 62, 72, 80, 88, 95]
    private static let dark = [[255,255,255], [255,241,214], [255,208,138], [255,169,77], [255,122,61], [255,59,48]]
    private static let light = [[29,29,31], [74,58,34], [138,90,16], [178,90,0], [194,65,12], [215,0,21]]
    public static func rgb(at temperature: Double, dark: Bool) -> [Int] {
        let ramp = dark ? self.dark : light
        let t = min(95, max(50, temperature))
        for i in 1..<stops.count where t <= stops[i] {
            let k = (t - stops[i-1]) / (stops[i] - stops[i-1])
            return (0..<3).map { Int((Double(ramp[i-1][$0]) + Double(ramp[i][$0] - ramp[i-1][$0]) * k).rounded()) }
        }
        return ramp.last!
    }
    public static func ink(step: Int?, dark: Bool) -> NSColor {
        let c = rgb(at: 50 + 45 * Double(step ?? 0) / 7, dark: dark)
        return NSColor(srgbRed: Double(c[0])/255, green: Double(c[1])/255, blue: Double(c[2])/255, alpha: step == nil ? 0.35 : 1)
    }
    public static func phase(step: Int, center: CGPoint, radius: Double) -> Path {
        let f = lit(step)
        var path = Path()
        for i in 0...64 {
            let a = Double(i) / 64 * .pi
            let p = CGPoint(x: center.x + radius * sin(a), y: center.y - radius * cos(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        for i in (0...64).reversed() {
            let a = Double(i) / 64 * .pi
            path.addLine(to: CGPoint(x: center.x + (1 - 2*f) * radius * sin(a), y: center.y - radius * cos(a)))
        }
        path.closeSubpath()
        return path
    }
    public static func accessibility(cpu: Double?, gpu: Double?, unit: TemperatureUnit, language: AppLanguage, ram: Double? = nil, moons: MenuBarMoons = [.cpu,.gpu], status: SnapshotStatus = .live) -> String {
        var parts: [String] = []
        if moons.contains(.cpu) { parts.append("CPU " + StatusCopy.temperatureAccessibility(cpu,status:status.cpuTemp,metric:.cpuTemp,unit:unit,language:language)) }
        if moons.contains(.gpu) { parts.append("GPU " + StatusCopy.temperatureAccessibility(gpu,status:status.gpuTemp,metric:.gpuTemp,unit:unit,language:language)) }
        if moons.contains(.ram) { parts.append("RAM " + StatusCopy.accessibility(ram.map { DisplayFormat.number($0)+(language == .english ? " percent":"%") } ?? (language == .english ? "unavailable":"無資料"), status: status.memory, metric: .memory, language: language)) }
        return parts.isEmpty ? "Little Moon":parts.joined(separator:", ")

    }
}

public typealias MoonHysteresis = MenuBarStepHysteresis

@MainActor
public enum TwinMoonsRenderer {
    public static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    public static let microFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    public static let labelWidth: CGFloat = ["100°C", "212°F"].map { ($0 as NSString).size(withAttributes: [.font: numberFont]).width }.max()!.rounded(.up)
    public static let ramLabelWidth: CGFloat = ("100%" as NSString).size(withAttributes: [.font:numberFont]).width.rounded(.up)
    public static let width: CGFloat = width(for: .all)
    public static func width(for moons: MenuBarMoons) -> CGFloat {
        let selected=MenuBarMoon.allCases.filter { moons.contains($0.selection) }
        guard !selected.isEmpty else { return 22 }
        return 12+selected.reduce(0) { $0+19+($1 == .ram ? ramLabelWidth:labelWidth) }+CGFloat(selected.count-1)*8
    }
    public static func image(cpuText: String, gpuText: String, cpuStep: Int?, gpuStep: Int?, dark: Bool,
                             labelColor: NSColor? = nil, scale: CGFloat = 2, ramText: String = "—",
                             ramStep: Int? = nil, ramColourStep: Int? = nil, moons: MenuBarMoons = .all, status: SnapshotStatus = .live) -> NSImage {
        var label = labelColor ?? (dark ? NSColor.white : NSColor.black)
        if labelColor == nil {
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { label=NSColor.labelColor.usingColorSpace(.sRGB) ?? label }
        }
        let width=width(for:moons)
        let image=NSImage(size:NSSize(width:width,height:22),flipped:true) { _ in
            if moons.isEmpty {
                NSImage(systemSymbolName:"moon",accessibilityDescription:nil)?
                    .withSymbolConfiguration(.init(paletteColors:[label]))?
                    .draw(in:NSRect(x:3,y:3,width:16,height:16),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
                return true
            }
            var x=6.0
            for moon in MenuBarMoon.allCases where moons.contains(moon.selection) {
                let text=moon == .cpu ? cpuText:moon == .gpu ? gpuText:ramText
                let phase=moon == .cpu ? cpuStep:moon == .gpu ? gpuStep:ramStep
                let colour=moon == .ram ? ramColourStep:phase
                let center=CGPoint(x:x+8,y:11), radius=moon == .cpu ? 6.4:5.3
                let ink=MoonModel.ink(step:colour,dark:dark)
                let disc=NSBezierPath(ovalIn:NSRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
                ink.withAlphaComponent(phase == nil ? 0.05:0.16).setFill(); disc.fill()
                let metricStatus = moon == .cpu ? status.cpuTemp : moon == .gpu ? status.gpuTemp : status.memory
                if StatusCopy.dashed(metricStatus) { disc.setLineDash([2,2],count:2,phase:0) }
                ink.withAlphaComponent(phase == nil ? 0.2:0.55).setStroke(); disc.lineWidth=1; disc.stroke()
                if let phase, let cg=NSGraphicsContext.current?.cgContext {
                    cg.addPath(MoonModel.phase(step:phase,center:center,radius:StatusCopy.dashed(metricStatus) ? radius-1.2 : radius).cgPath); cg.setFillColor(ink.cgColor); cg.fillPath()
                }
                if moon != .cpu {
                    let ring=NSBezierPath(ovalIn:NSRect(x:center.x-7.3,y:center.y-7.3,width:14.6,height:14.6))
                    ring.lineWidth=moon == .ram ? 1.1:1
                    if moon == .ram { ring.setLineDash([1.2,1.35],count:2,phase:0) }
                    else if StatusCopy.dashed(metricStatus) { ring.setLineDash([2,2],count:2,phase:0) }
                    ink.withAlphaComponent(phase == nil ? 0.2:moon == .ram ? 0.95:0.9).setStroke(); ring.stroke()
                }
                (moon.title as NSString).draw(at:CGPoint(x:x+19,y:0.5),withAttributes:[.font:microFont,.foregroundColor:label.withAlphaComponent(0.75)])
                (text as NSString).draw(at:CGPoint(x:x+19,y:8),withAttributes:[.font:numberFont,.foregroundColor:label])
                x += 19+(moon == .ram ? ramLabelWidth:labelWidth)+8
            }
            return true
        }
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(width*scale),pixelsHigh:Int(22*scale),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        context.cgContext.clear(CGRect(x:0,y:0,width:width*scale,height:22*scale)); context.cgContext.scaleBy(x:scale,y:scale)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=context
        image.draw(in:NSRect(origin:.zero,size:image.size),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:false,hints:nil)
        NSGraphicsContext.restoreGraphicsState()
        let raster=NSImage(cgImage:bitmap.cgImage!,size:image.size); raster.isTemplate=false; return raster
    }
}
