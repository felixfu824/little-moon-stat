import SwiftUI
import MonitorCore

public struct MoonPopover: View {
    public let snapshot: Snapshot
    public let options: DisplayOptions
    public var cost: Double?
    private let actionIdentity: ObjectIdentifier?
    public var onMode: (DisplayMode) -> Void
    public var onSettings: () -> Void
    public init(snapshot: Snapshot, options: DisplayOptions, cost: Double? = nil,
                onMode: @escaping (DisplayMode) -> Void = { _ in }, onSettings: @escaping () -> Void = {},
                actionIdentity: ObjectIdentifier? = nil) {
        self.snapshot = snapshot; self.options = options; self.cost = cost; self.onMode = onMode; self.onSettings = onSettings; self.actionIdentity = actionIdentity
    }
    private var zh: Bool { options.language == .traditionalChinese }
    private func text(_ en: String, _ zh: String) -> String { self.zh ? zh : en }
    public var body: some View {
        VStack(spacing: 14) {
            MoonHeader(machineName: snapshot.machineName, chipName: snapshot.chipName,
                       level: snapshot.thermal, language: options.language, thermalStatus: snapshot.status.thermal, identityStatus: snapshot.status.identity).equatable()
            MoonSky(snapshot: snapshot).equatable().frame(height: 178).accessibilityLabel(text("CPU and GPU moons; phase shows peak temperature, stars show load", "CPU 與 GPU 兩個月亮；月相表示峰值溫度，星星表示負載"))
            HStack(spacing: 8) {
                readout("CPU", snapshot.cpuTemp, snapshot.cpuPercent, .cpuTemp, .cpuPercent)
                readout("GPU", snapshot.gpuTemp, snapshot.gpuPercent, .gpuTemp, .gpuPercent)
            }
            if let issue = snapshot.status.statusLine {
                Text((issue.status.quality == .estimated ? "≈ " : "") + StatusCopy.reason(issue.status, metric: issue.metric, language: options.language))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    .transaction { $0.animation = nil }
            }
            MoonMemory(memory: snapshot.memory, language: options.language).equatable()
                .modifier(StatusDecoration(status: snapshot.status.memory, metric: .memory, language: options.language, underline: false))
                .accessibilityElement(children: .combine)
                .modifier(StatusAccessibility(status: snapshot.status.memory) { StatusCopy.memoryAccessibility(snapshot.memory, status: snapshot.status.memory, language: options.language) })
            VStack(spacing: 7) {
                line(text("Disk · ", "磁碟 ") + (snapshot.disk?.volumeName ?? "—"), CardFormat.disk(snapshot.disk, language: options.language))
                DiskShore(disk: snapshot.disk).equatable().frame(height: 6).accessibilityHidden(true)
            }
            .modifier(StatusDecoration(status: snapshot.status.disk, metric: .disk, language: options.language, underline: false))
            .accessibilityElement(children: .combine)
            .modifier(StatusAccessibility(status: snapshot.status.disk) { StatusCopy.accessibility(text("Disk · ", "磁碟 ") + (snapshot.disk?.volumeName ?? "—") + ", " + CardFormat.disk(snapshot.disk, language: options.language), status: snapshot.status.disk, metric: .disk, language: options.language) })
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            VStack(spacing: 7) {
                line(text("Top CPU", "CPU 前三名"), text("% CPU · Memory", "% CPU · 記憶體"), size: 11)
                ForEach(0..<3, id: \.self) { i in
                    MoonProcessRow(row: snapshot.topProcesses.indices.contains(i) ? snapshot.topProcesses[i] : nil, status: snapshot.status.processes, language: options.language).equatable()
                }
            }
            MoonFooter(mode: options.displayMode, language: options.language,
                       onMode: onMode, onSettings: onSettings, actionIdentity: actionIdentity).equatable()
            Text(cost.map { text("This monitor uses \(DisplayFormat.number($0, decimals: 1))% of one CPU core", "本程式佔用單核心 \(DisplayFormat.number($0, decimals: 1))% CPU") }
                 ?? text("Measuring monitor CPU…", "正在測量程式 CPU…"))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).padding(.top, -6)
        }.padding(16).frame(width: 360).foregroundStyle(.white).monospacedDigit()
    }
    private func line(_ label: String, _ value: String, size: CGFloat = 12) -> some View {
        HStack(spacing: 4) { Text(label).foregroundStyle(.white.opacity(0.78)).lineLimit(1); Spacer(minLength: 0); Text(value).lineLimit(1).minimumScaleFactor(0.75) }.font(.system(size: size))
    }
    private func readout(_ label: String, _ stat: TempStat?, _ load: Double?, _ metric: StatusMetric, _ loadMetric: StatusMetric) -> some View {
        MoonReadout(label: label, stat: stat, load: load, unit: options.temperatureUnit, language: options.language, status: snapshot.status[metric], loadStatus: snapshot.status[loadMetric], metric: metric, loadMetric: loadMetric).equatable()
    }

}

private struct MemoryTide: View, Equatable {
    // Half-point paint precision avoids re-rasterizing for invisible memory noise.
    private var levels: [Double] { Self.paintLevels(memory) }
    static func paintLevels(_ memory: MemoryStat?) -> [Double] {
        PopoverPresentation.memoryLevels(memory)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.levels == rhs.levels }
    let memory: MemoryStat?
    var body: some View {
        Canvas { ctx, size in
            let positions = levels
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.1)))
            guard positions.count == 3 else { return }
            let wiredY = positions[0], activeY = positions[1], top = positions[2]
            let wiredH = size.height-wiredY, activeH = wiredY-activeY, compH = activeY-top
            var foam = Path(); foam.move(to: CGPoint(x: 0, y: size.height))
            for x in stride(from: 0.0, through: size.width, by: 2) {
                foam.addLine(to: CGPoint(x: x, y: min(size.height, max(0, top + (compH > 0 ? 1.4*sin(x/17) : 0)))))
            }
            foam.addLine(to: CGPoint(x: size.width, y: size.height)); foam.closeSubpath()
            ctx.fill(foam, with: .color(Color(red: 220/255, green: 234/255, blue: 1).opacity(0.85)))
            ctx.fill(Path(CGRect(x: 0, y: activeY, width: size.width, height: activeH+wiredH)), with: .color(Color(red: 111/255, green: 168/255, blue: 1).opacity(0.9)))
            ctx.fill(Path(CGRect(x: 0, y: wiredY, width: size.width, height: wiredH)), with: .color(Color(red: 47/255, green: 95/255, blue: 196/255)))
        }.accessibilityHidden(true)
    }
}

private struct MoonSky: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        MoonModel.step(lhs.snapshot.cpuTemp?.peak) == MoonModel.step(rhs.snapshot.cpuTemp?.peak)
        && MoonModel.step(lhs.snapshot.gpuTemp?.peak) == MoonModel.step(rhs.snapshot.gpuTemp?.peak)
        && litStars(lhs.snapshot) == litStars(rhs.snapshot)
    }
    private static func litStars(_ s: Snapshot) -> UInt64 { PopoverPresentation.starMask(s) }
    let snapshot: Snapshot
    static let stars = PopoverPresentation.stars
    var body: some View {
        ZStack {
            MoonSkyBackdrop().equatable()
            MoonSkyMoons(cpuStep: MoonModel.step(snapshot.cpuTemp?.peak), gpuStep: MoonModel.step(snapshot.gpuTemp?.peak)).equatable()
            MoonSkyStars(mask: Self.litStars(snapshot)).equatable()
        }.clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
    }
}

private struct MoonSkyBackdrop: View, Equatable {
    var body: some View {
        Canvas { ctx, _ in
            var arch = Path(); arch.move(to: CGPoint(x: 0, y: 178)); arch.addLine(to: CGPoint(x: 0, y: 100))
            arch.addCurve(to: CGPoint(x: 328, y: 100), control1: CGPoint(x: 0, y: -33.33), control2: CGPoint(x: 328, y: -33.33))
            arch.addLine(to: CGPoint(x: 328, y: 178)); arch.closeSubpath()
            ctx.fill(arch, with: .linearGradient(Gradient(colors: [Color(red: 11/255, green: 22/255, blue: 48/255), Color(red: 37/255, green: 59/255, blue: 102/255)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 178)))
            ctx.stroke(arch, with: .color(.white.opacity(0.22)), lineWidth: 1)
            var horizon = Path(); horizon.move(to: CGPoint(x: 18,y: 142)); horizon.addLine(to: CGPoint(x: 310,y: 142))
            ctx.stroke(horizon, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1,dash: [1,4]))
            for (cx,label) in [(104.0,"CPU"),(224.0,"GPU")] {
                ctx.draw(Text(label).font(.system(size: 10)).tracking(2).foregroundStyle(.white.opacity(0.75)), at: CGPoint(x: cx,y: 157))
            }
        }
    }
}

private struct MoonSkyMoons: View, Equatable {
    let cpuStep: Int?
    let gpuStep: Int?
    private static let cpuPaths = (0...7).map { MoonModel.phase(step: $0, center: CGPoint(x: 104,y: 90), radius: 34) }
    private static let gpuPaths = (0...7).map { MoonModel.phase(step: $0, center: CGPoint(x: 224,y: 90), radius: 29) }
    var body: some View {
        Canvas { ctx, _ in
            for i in 0..<2 {
                let cx = i == 0 ? 104.0 : 224.0, r = i == 0 ? 34.0 : 29.0
                let step = i == 0 ? cpuStep : gpuStep
                let ink = Color(nsColor: MoonModel.ink(step: step, dark: true))
                ctx.fill(Path(ellipseIn: CGRect(x: cx-46,y: 44,width: 92,height: 92)), with: .color(ink.opacity(0.08)))
                let disc = Path(ellipseIn: CGRect(x: cx-r,y: 90-r,width: r*2,height: r*2))
                ctx.fill(disc, with: .color(.white.opacity(0.06))); ctx.stroke(disc, with: .color(.white.opacity(0.32)), lineWidth: 1)
                if let step { ctx.fill((i == 0 ? Self.cpuPaths[step] : Self.gpuPaths[step]), with: .color(ink)) }
                if i == 1 { ctx.stroke(Path(ellipseIn: CGRect(x: cx-40,y: 50,width: 80,height: 80)), with: .color(ink.opacity(0.8)), lineWidth: 1.4) }
            }
        }
    }
}

private struct MoonSkyStars: View, Equatable {
    let mask: UInt64
    var body: some View {
        Canvas { ctx, _ in
            for (i,star) in MoonSky.stars.enumerated() {
                let on = mask & (UInt64(1) << i) != 0, r = on ? 1.3 : 0.8
                ctx.fill(Path(ellipseIn: CGRect(x: star.0-r,y: star.1-r,width: r*2,height: r*2)), with: .color(.white.opacity(on ? 0.95 : 0.22)))
            }
        }
    }
}

private struct DiskShore: View, Equatable {
    let disk: DiskStat?
    var body: some View {
        Canvas { context, size in
            for i in 0..<41 {
                let p = CGRect(x: 0.8 + Double(i) * (size.width-6)/40, y: 0.8, width: 4.4, height: 4.4)
                context.fill(Path(ellipseIn: p), with: .color(.white.opacity(i < PopoverPresentation.diskDots(disk) ? 0.9 : 0.22)))
            }
        }
    }
}

private struct MoonProcessRow: View, Equatable {
    let row: ProcRow?
    let status: MetricStatus
    let language: AppLanguage
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: PopoverPresentation.processSize(row?.cpuPercent ?? 0)))
                .frame(width: 14).foregroundStyle((row?.cpuPercent ?? 0) > 70 ? Color.orange : .white).accessibilityHidden(true)
            Text(row?.name ?? "—").lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Text(StatusCopy.readout(DisplayFormat.percent(row?.cpuPercent, decimals: 1), status: status))
                    .foregroundStyle((row?.cpuPercent ?? 0) > 70 ? Color(red: 1, green: 179/255, blue: 64/255) : .white)
                Text(" · " + DisplayFormat.processMemory(row?.residentBytes)).foregroundStyle(.white.opacity(0.78))
            }.font(.system(size: 13)).fixedSize()
        }.font(.system(size: 13))
            .modifier(StatusDecoration(status: status, metric: .processes, language: language, underline: false))
            .accessibilityElement(children: .combine)
            .modifier(StatusAccessibility(status: status) { StatusCopy.processAccessibility(row, status: status, language: language) })
    }
}

private struct MoonHeader: View, Equatable {
    let machineName: String
    let chipName: String
    let level: ThermalLevel?
    let language: AppLanguage
    var thermalStatus: MetricStatus = .live
    var identityStatus: MetricStatus = .live
    private var thermalColor: Color {
        level == .nominal ? Color(red: 52/255, green: 199/255, blue: 89/255)
        : level == .fair ? Color(red: 1, green: 181/255, blue: 71/255)
        : level == nil ? .gray : Color(red: 1, green: 122/255, blue: 92/255)
    }
    private var thermal: String {
        guard let level else { return "—" }
        if language == .english { return level.rawValue.capitalized }
        return [.nominal: "散熱正常", .fair: "散熱偏高", .serious: "散熱嚴重", .critical: "散熱危急"][level]!
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(machineName + " · " + chipName.replacingOccurrences(of: "Apple ", with: ""))
                .font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .modifier(StatusDecoration(status: identityStatus, metric: .identity, language: language, underline: false))
            Spacer(minLength: 0)
            HStack(spacing: 6) { Circle().fill(thermalColor).frame(width: 7, height: 7); Text(thermal).accessibilityLabel(StatusCopy.accessibility(thermal, status: thermalStatus, metric: .thermal, language: language)) }
                .font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 3).background(.white.opacity(0.14), in: Capsule())
        }
    }
}

private struct MoonMemory: View, Equatable {
    let memory: MemoryStat?
    let language: AppLanguage
    private var labels: [String] { [CardFormat.memory(memory), CardFormat.gb(memory?.wired), CardFormat.gb(memory?.active), CardFormat.gb(memory?.compressed)] }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.language == rhs.language && lhs.labels == rhs.labels
        && MemoryTide.paintLevels(lhs.memory) == MemoryTide.paintLevels(rhs.memory)
    }
    private func text(_ en: String, _ zh: String) -> String { language == .english ? en : zh }
    private func line(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) { Text(label).foregroundStyle(.white.opacity(0.78)); Spacer(minLength: 0); Text(value) }.font(.system(size: 12))
    }
    private func legend(_ label: String, _ bytes: UInt64?, _ ink: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(ink).frame(width: 6, height: 6); Text(label + " " + CardFormat.gb(bytes)) }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.78))
    }
    var body: some View {
        VStack(spacing: 6) {
            line(text("Memory", "記憶體"), CardFormat.memory(memory))
            MemoryTide(memory: memory).equatable().frame(height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14)))
            HStack(spacing: 12) {
                legend(text("Wired", "常駐"), memory?.wired, Color(red: 47/255, green: 95/255, blue: 196/255))
                legend(text("Active", "使用中"), memory?.active, Color(red: 111/255, green: 168/255, blue: 1))
                legend(text("Compressed", "壓縮"), memory?.compressed, Color(red: 220/255, green: 234/255, blue: 1))
                Spacer(minLength: 0)
            }
        }
    }
}

private struct MoonFooter: View, Equatable {
    let mode: DisplayMode
    let language: AppLanguage
    let onMode: (DisplayMode) -> Void
    let onSettings: () -> Void
    let actionIdentity: ObjectIdentifier?
    static func == (lhs: Self, rhs: Self) -> Bool {
        // A stable controller identity explicitly guarantees stable action semantics.
        // Public/offline callers without that guarantee do not cache their closures.
        guard let left = lhs.actionIdentity, let right = rhs.actionIdentity else { return false }
        return left == right && lhs.mode == rhs.mode && lhs.language == rhs.language
    }
    private func text(_ en: String, _ zh: String) -> String { language == .english ? en : zh }
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(DisplayMode.allCases, id: \.rawValue) { choice in
                Button { onMode(choice) } label: {
                    Text(choice.title(language)).font(.system(size: 12, weight: mode == choice ? .semibold : .regular))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(.white.opacity(mode == choice ? 0.3 : 0), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(mode == choice ? .isSelected : [])
                }
            }.padding(2).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Button { onMode(.both) } label: { Image(systemName: "pin").frame(width: 32, height: 32) }
                .buttonStyle(.plain).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel(text("Pin to desktop", "釘選到桌面"))
            Button(action: onSettings) { Image(systemName: "gearshape").frame(width: 24, height: 32) }
                .buttonStyle(.plain).accessibilityLabel(text("Settings", "設定"))
        }
    }
}

private struct MoonReadout: View, Equatable {
    let label: String
    let stat: TempStat?
    let load: Double?
    let unit: TemperatureUnit
    let language: AppLanguage
    var status: MetricStatus = .live
    var loadStatus: MetricStatus = .live
    var metric: StatusMetric = .cpuTemp
    var loadMetric: StatusMetric = .cpuPercent
    private var peak: String { StatusCopy.readout(DisplayFormat.temperature(stat?.peak, unit: unit), status: status) }
    private var sub: String { label + " · " + (language == .english ? "avg " : "平均 ") + StatusCopy.readout(DisplayFormat.temperature(stat?.average, unit: unit), status: status) + " · " + StatusCopy.readout(DisplayFormat.percent(load), status: loadStatus) }
    private var step: Int? { MoonModel.step(stat?.peak) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.peak == rhs.peak && lhs.sub == rhs.sub && lhs.step == rhs.step && lhs.status == rhs.status && lhs.loadStatus == rhs.loadStatus && lhs.language == rhs.language }
    var body: some View {
        VStack(spacing: 2) {
            Text(peak).font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color(nsColor: MoonModel.ink(step: step, dark: true)))
            Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.78)).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity)
            .modifier(StatusDecoration(status: status, metric: metric, language: language, underline: false))
            .accessibilityElement(children: .combine)
            .modifier(StatusAccessibility(status: status.quality == .live ? loadStatus : status) {
                label + " " + StatusCopy.temperatureAccessibility(stat?.peak, status: status, metric: metric, unit: unit, language: language)
                    + ", " + (language == .english ? "average " : "平均 ")
                    + StatusCopy.temperatureAccessibility(stat?.average, status: status, metric: metric, unit: unit, language: language)
                    + ", " + StatusCopy.accessibility(DisplayFormat.percent(load), status: loadStatus, metric: loadMetric, language: language)
            })
    }
}
