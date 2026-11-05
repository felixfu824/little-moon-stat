import MonitorCore
import SwiftUI

private let secondary = Color.white.opacity(0.78)
private let memoryColors = [
  Color(red: 90 / 255, green: 162 / 255, blue: 1), Color(red: 1, green: 159 / 255, blue: 10 / 255),
  Color(red: 201 / 255, green: 155 / 255, blue: 1),
]
private let hotColor = Color(red: 1, green: 179 / 255, blue: 64 / 255)

public struct MonitorCard: View {
  private let store: SnapshotStore
  private let options: DisplayOptions
  /// Watch mode (pointer resting on the panel): show each reading as it arrives.
  private let watching: Bool
  public init(store: SnapshotStore, options: DisplayOptions, watching: Bool = false) {
    self.store = store
    self.options = options
    self.watching = watching
  }
  public var body: some View {
    let snapshot = watching ? store.snapshot.forWatching : store.snapshot
    switch options.size {
    case .large: LargeCard(snapshot: snapshot, options: options)
    case .medium: MediumCard(snapshot: snapshot, options: options)
    }
  }
}

private struct CardContent {
  let snapshot: Snapshot
  let options: DisplayOptions
  func word(_ key: L10n) -> String { key.text(options.language) }
  var machine: String {
    snapshot.machineName + " · " + snapshot.chipName.replacingOccurrences(of: "Apple ", with: "")
  }
  var status: String {
    CardFormat.thermal(snapshot.thermal, language: options.language) + " · "
      + CardFormat.time(snapshot.timestamp)
  }
  var thermalColor: Color {
    switch snapshot.thermal {
    case .nominal: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    case .fair: .yellow
    case .serious: .orange
    case .critical: .red
    case nil: secondary
    }
  }
  var diskLabel: String { word(.disk) + " · " + (snapshot.disk?.volumeName ?? CardFormat.missing) }
  var diskValue: String { CardFormat.disk(snapshot.disk, language: options.language) }
  func processLabel(_ row: ProcRow?) -> String {
    guard let row else { return CardFormat.missing }
    return
      "\(row.name), \(CardFormat.percent(row.cpuPercent, decimals: 1)), \(word(.memory)) \(CardFormat.processMemory(row.residentBytes))"
  }
  func row(_ index: Int) -> ProcRow? {
    snapshot.topProcesses.indices.contains(index) ? snapshot.topProcesses[index] : nil
  }
}

private struct CardStyle: ViewModifier {
  func body(content: Content) -> some View {
    content.foregroundStyle(.white).monospacedDigit()
      .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
  }
}

// Compare section inputs before SwiftUI evaluates unchanged text and layout trees.
private struct MetricTile: View, Equatable {
  let value: String
  let label: String
  var average: String? = nil
  var compact = false
  let options: DisplayOptions
  var status: MetricStatus = .live
  var metric: StatusMetric = .cpuPercent
  var spokenValue: String? = nil
  var detail: String? = nil
  var detailSpokenValue: String? = nil
  var detailStatus: MetricStatus = .live
  var detailMetric: StatusMetric = .cpuTemp
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 0 : 2) {
      Text(status.quality == .unavailable ? "—" : value).font(.system(size: compact ? 16 : 18, weight: .semibold)).fixedSize()
        .modifier(StatusDecoration(status: status, metric: metric, language: options.language))
      Group {
        if let detail {
          HStack(spacing: 0) {
            Text(label); Text(" · ")
            Text(detailStatus.quality == .unavailable ? "—" : detail)
              .modifier(StatusDecoration(status: detailStatus, metric: detailMetric, language: options.language))
          }
        } else { Text(label) }
      }.font(.system(size: 11)).foregroundStyle(secondary).fixedSize()
      if let average {
        Text(average).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).fixedSize()
      }
    }
    .frame(maxWidth: .infinity, minHeight: compact ? nil : 51, alignment: .topLeading)
    .padding(.horizontal, 8).padding(.vertical, compact ? 6 : 8)
    .background(
      .white.opacity(options.glass == .clear ? 0.12 : 0.08),
      in: RoundedRectangle(cornerRadius: compact ? 11 : 12)
    )
    .overlay(
      RoundedRectangle(cornerRadius: compact ? 11 : 12).strokeBorder(
        .white.opacity(0.14), lineWidth: 1)
    )
    .accessibilityElement(children: .ignore).accessibilityLabel(
      [label, StatusCopy.accessibility(spokenValue ?? value, status: status, metric: metric, language: options.language), average,
       detail.map { StatusCopy.accessibility(detailSpokenValue ?? $0, status: detailStatus, metric: detailMetric, language: options.language) }].compactMap { $0 }.joined(separator: ", "))
  }
}

private struct UsageBar: View {
  let parts: [(Double, Color)]
  var height: CGFloat = 6
  var body: some View {
    GeometryReader { geo in
      HStack(spacing: 0) {
        ForEach(parts.indices, id: \.self) { index in
          parts[index].1.frame(width: geo.size.width * min(max(parts[index].0, 0), 1))
        }
        Spacer(minLength: 0)
      }
    }
    .frame(height: height).background(.white.opacity(0.18)).clipShape(Capsule())
    .accessibilityHidden(true)
  }
}

private func memoryParts(_ memory: MemoryStat?) -> [(Double, Color)] {
  zip(CardFormat.memoryFractions(memory), memoryColors).map { ($0, $1) }
}
private func diskParts(_ disk: DiskStat?) -> [(Double, Color)] {
  guard let disk, disk.total > 0 else { return [] }
  return [(Double(disk.used) / Double(disk.total), .white)]
}

public struct LargeCard: View {
  private let c: CardContent
  public init(snapshot: Snapshot, options: DisplayOptions) {
    c = CardContent(snapshot: snapshot, options: options)
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LargeHeader(c: c).equatable()
      HStack(alignment: .top, spacing: 6) {
        MetricTile(
          value: CardFormat.percent(c.snapshot.cpuPercent), label: "CPU", options: c.options, status: c.snapshot.status.cpuPercent, metric: .cpuPercent
        ).equatable()
        MetricTile(
          value: CardFormat.percent(c.snapshot.gpuPercent), label: "GPU", options: c.options, status: c.snapshot.status.gpuPercent, metric: .gpuPercent
        ).equatable()
        MetricTile(
          value: DisplayFormat.temperature(c.snapshot.cpuTemp?.peak, unit: c.options.temperatureUnit), label: c.word(.cpuMax),
          average: c.word(.average) + " " + DisplayFormat.temperature(c.snapshot.cpuTemp?.average, unit: c.options.temperatureUnit),
          options: c.options, status: c.snapshot.status.cpuTemp, metric: .cpuTemp,
          spokenValue: c.snapshot.status.cpuTemp.quality == .live ? nil : DisplayFormat.temperatureAccessibility(c.snapshot.cpuTemp?.peak, unit: c.options.temperatureUnit, language: c.options.language)
        ).equatable()
        MetricTile(
          value: DisplayFormat.temperature(c.snapshot.gpuTemp?.peak, unit: c.options.temperatureUnit), label: c.word(.gpuMax),
          average: c.word(.average) + " " + DisplayFormat.temperature(c.snapshot.gpuTemp?.average, unit: c.options.temperatureUnit),
          options: c.options, status: c.snapshot.status.gpuTemp, metric: .gpuTemp,
          spokenValue: c.snapshot.status.gpuTemp.quality == .live ? nil : DisplayFormat.temperatureAccessibility(c.snapshot.gpuTemp?.peak, unit: c.options.temperatureUnit, language: c.options.language)
        ).equatable()
      }
      LargeMemory(c: c).equatable()
      LargeDisk(c: c).equatable()
      Rectangle().fill(.white.opacity(0.18)).frame(height: 1).accessibilityHidden(true)
      VStack(spacing: 6) {
        valueLine(c.word(.topCPU), c.word(.columns), size: 11, secondaryValue: true)
        ForEach(0..<3) { index in ProcessLine(row: c.row(index), c: c, compact: false).equatable() }
      }
    }.padding(16).frame(width: 360).modifier(CardStyle())
  }
}

private func valueLine(
  _ label: String, _ value: String, size: CGFloat = 12, secondaryValue: Bool = false
) -> some View {
  HStack(spacing: 4) {
    Text(label).foregroundStyle(secondary).lineLimit(1).truncationMode(.middle)
    Spacer(minLength: 0)
    Text(value).foregroundStyle(secondaryValue ? secondary : .white).fixedSize()
  }.font(.system(size: size))
}

private struct ProcessLine: View, Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.compact == rhs.compact && lhs.c.options == rhs.c.options && lhs.row == rhs.row && lhs.c.snapshot.status.processes == rhs.c.snapshot.status.processes
  }
  let row: ProcRow?
  let c: CardContent
  let compact: Bool
  var body: some View {
    HStack(spacing: 4) {
      Text(row?.name ?? CardFormat.missing).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 0)
      if row != nil {
        HStack(spacing: 0) {
          Text(CardFormat.percent(row?.cpuPercent, decimals: compact ? 0 : 1))
            .modifier(StatusDecoration(status: c.snapshot.status.processes, metric: .processes, language: c.options.language))
            .foregroundStyle(row.map { CardFormat.hot($0.cpuPercent) } == true ? hotColor : .white)
          if !compact {
            Text(
              " · " + (row.map { CardFormat.processMemory($0.residentBytes) } ?? CardFormat.missing)
            ).foregroundStyle(secondary)
          }
        }.fixedSize()
      }
    }.font(.system(size: compact ? 12 : 13))
      .accessibilityElement(children: .ignore).accessibilityLabel(StatusCopy.accessibility(c.processLabel(row), status: c.snapshot.status.processes, metric: .processes, language: c.options.language))
  }
}

public struct MediumCard: View {
  private let c: CardContent
  public init(snapshot: Snapshot, options: DisplayOptions) {
    c = CardContent(snapshot: snapshot, options: options)
  }
  public var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 8) {
        MediumHeader(c: c).equatable()
        HStack(spacing: 6) {
          MetricTile(
            value: CardFormat.percent(c.snapshot.cpuPercent),
            label: c.snapshot.status.cpuTemp.quality == .unavailable ? c.word(.cpuMax) : "CPU", compact: true,
            options: c.options, status: c.snapshot.status.cpuPercent, metric: .cpuPercent,
            detail: DisplayFormat.temperature(c.snapshot.cpuTemp?.peak, unit: c.options.temperatureUnit), detailSpokenValue: DisplayFormat.temperatureAccessibility(c.snapshot.cpuTemp?.peak, unit: c.options.temperatureUnit, language: c.options.language), detailStatus: c.snapshot.status.cpuTemp, detailMetric: .cpuTemp
          ).equatable()
          MetricTile(
            value: CardFormat.percent(c.snapshot.gpuPercent),
            label: c.snapshot.status.gpuTemp.quality == .unavailable ? c.word(.gpuMax) : "GPU", compact: true,
            options: c.options, status: c.snapshot.status.gpuPercent, metric: .gpuPercent,
            detail: DisplayFormat.temperature(c.snapshot.gpuTemp?.peak, unit: c.options.temperatureUnit), detailSpokenValue: DisplayFormat.temperatureAccessibility(c.snapshot.gpuTemp?.peak, unit: c.options.temperatureUnit, language: c.options.language), detailStatus: c.snapshot.status.gpuTemp, detailMetric: .gpuTemp
          ).equatable()
        }
        MediumStorage(c: c).equatable()
      }.frame(width: 150)
      Rectangle().fill(.white.opacity(0.18)).frame(width: 1).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 7) {
        Text(c.word(.topCPU)).font(.system(size: 11)).foregroundStyle(secondary)
        ForEach(0..<3) { index in ProcessLine(row: c.row(index), c: c, compact: true).equatable() }
        Spacer(minLength: 0)
        Text(c.status).font(.system(size: 11)).foregroundStyle(secondary).fixedSize()
          .modifier(StatusDecoration(status: c.snapshot.status.thermal, metric: .thermal, language: c.options.language, underline: false))
          .modifier(StatusAccessibility(status: c.snapshot.status.thermal) { StatusCopy.accessibility(c.status, status: c.snapshot.status.thermal, metric: .thermal, language: c.options.language) })
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(.horizontal, 16).padding(.vertical, 14).frame(width: 360, height: 170).modifier(
      CardStyle())
  }
}

private struct LargeHeader: View, Equatable {
  let c: CardContent
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.c.options == rhs.c.options && lhs.c.machine == rhs.c.machine
      && floor(lhs.c.snapshot.timestamp.timeIntervalSince1970 / 60)
        == floor(rhs.c.snapshot.timestamp.timeIntervalSince1970 / 60)
      && lhs.c.snapshot.thermal == rhs.c.snapshot.thermal && lhs.c.snapshot.status.thermal == rhs.c.snapshot.status.thermal && lhs.c.snapshot.status.identity == rhs.c.snapshot.status.identity
  }
  var body: some View {
    HStack(spacing: 8) {
      Circle().fill(c.thermalColor).frame(width: 8, height: 8).accessibilityHidden(true)
      Text(c.machine).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(
        0.8)
        .modifier(StatusDecoration(status: c.snapshot.status.identity, metric: .identity, language: c.options.language, underline: false))
      Spacer(minLength: 0)
      Text(c.status).font(.system(size: 11)).foregroundStyle(secondary).fixedSize()
        .modifier(StatusDecoration(status: c.snapshot.status.thermal, metric: .thermal, language: c.options.language, underline: false))
        .modifier(StatusAccessibility(status: c.snapshot.status.thermal) { StatusCopy.accessibility(c.status, status: c.snapshot.status.thermal, metric: .thermal, language: c.options.language) })
    }.accessibilityElement(children: .combine)
  }
}

private struct MediumHeader: View, Equatable {
  let c: CardContent
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.c.options == rhs.c.options && lhs.c.machine == rhs.c.machine
      && floor(lhs.c.snapshot.timestamp.timeIntervalSince1970 / 60)
        == floor(rhs.c.snapshot.timestamp.timeIntervalSince1970 / 60)
      && lhs.c.snapshot.thermal == rhs.c.snapshot.thermal && lhs.c.snapshot.status.thermal == rhs.c.snapshot.status.thermal && lhs.c.snapshot.status.identity == rhs.c.snapshot.status.identity
  }
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(c.thermalColor).frame(width: 8, height: 8).accessibilityHidden(true)
      Text(c.snapshot.chipName.replacingOccurrences(of: "Apple ", with: "")).font(
        .system(size: 13, weight: .semibold)
      ).lineLimit(1)
    }.accessibilityElement(children: .ignore).accessibilityLabel(c.machine + ", " + c.status)
  }
}

private struct LargeMemory: View, Equatable {
  let c: CardContent
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.c.options == rhs.c.options && lhs.c.snapshot.memory == rhs.c.snapshot.memory && lhs.c.snapshot.status.memory == rhs.c.snapshot.status.memory
  }
  var body: some View {
    VStack(spacing: 6) {
      valueLine(c.word(.memory), CardFormat.memory(c.snapshot.memory))
        .modifier(StatusDecoration(status: c.snapshot.status.memory, metric: .memory, language: c.options.language, underline: false))
      UsageBar(parts: memoryParts(c.snapshot.memory))
      HStack(spacing: 12) {
        legend(.wired, c.snapshot.memory?.wired, 0)
        legend(.active, c.snapshot.memory?.active, 1)
        legend(.compressed, c.snapshot.memory?.compressed, 2)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.accessibilityElement(children: .combine)
      .modifier(StatusAccessibility(status: c.snapshot.status.memory) { StatusCopy.memoryAccessibility(c.snapshot.memory, status: c.snapshot.status.memory, language: c.options.language) })
  }
  private func legend(_ key: L10n, _ bytes: UInt64?, _ index: Int) -> some View {
    HStack(spacing: 4) {
      Circle().fill(memoryColors[index]).frame(width: 6, height: 6)
      Text(c.word(key) + " " + CardFormat.gb(bytes)).fixedSize()
    }.font(.system(size: 11)).foregroundStyle(secondary)
  }
}

private struct LargeDisk: View, Equatable {
  let c: CardContent
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.c.options == rhs.c.options && lhs.c.snapshot.disk == rhs.c.snapshot.disk && lhs.c.snapshot.status.disk == rhs.c.snapshot.status.disk
  }
  var body: some View {
    VStack(spacing: 6) {
      valueLine(c.diskLabel, c.diskValue)
        .modifier(StatusDecoration(status: c.snapshot.status.disk, metric: .disk, language: c.options.language, underline: false))
      UsageBar(parts: diskParts(c.snapshot.disk))
    }.accessibilityElement(children: .combine)
      .accessibilityLabel(StatusCopy.accessibility(c.diskLabel + ", " + c.diskValue, status: c.snapshot.status.disk, metric: .disk, language: c.options.language))
  }
}

private struct MediumStorage: View, Equatable {
  let c: CardContent
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.c.options == rhs.c.options && lhs.c.snapshot.memory == rhs.c.snapshot.memory && lhs.c.snapshot.status.memory == rhs.c.snapshot.status.memory
      && lhs.c.snapshot.disk == rhs.c.snapshot.disk && lhs.c.snapshot.status.disk == rhs.c.snapshot.status.disk
  }
  var body: some View {
    VStack(spacing: 4) {
      valueLine(c.word(.memory), CardFormat.memory(c.snapshot.memory), size: 11)
        .modifier(StatusDecoration(status: c.snapshot.status.memory, metric: .memory, language: c.options.language, underline: false))
        .accessibilityElement(children: .ignore).accessibilityLabel(StatusCopy.accessibility(memoryLabel, status: c.snapshot.status.memory, metric: .memory, language: c.options.language))
      UsageBar(
        parts: [(CardFormat.memoryFractions(c.snapshot.memory).reduce(0, +), memoryColors[1])],
        height: 5)
      valueLine(c.word(.disk), freeDisk, size: 11)
        .modifier(StatusDecoration(status: c.snapshot.status.disk, metric: .disk, language: c.options.language, underline: false))
        .accessibilityElement(children: .ignore).accessibilityLabel(
          StatusCopy.accessibility(c.diskLabel + ", " + c.diskValue, status: c.snapshot.status.disk, metric: .disk, language: c.options.language))
      UsageBar(parts: diskParts(c.snapshot.disk), height: 5)
    }
  }
  private var memoryLabel: String {
    c.word(.memory) + " " + CardFormat.memory(c.snapshot.memory) + ", " + c.word(.wired) + " "
      + CardFormat.gb(c.snapshot.memory?.wired) + ", " + c.word(.active) + " "
      + CardFormat.gb(c.snapshot.memory?.active) + ", " + c.word(.compressed) + " "
      + CardFormat.gb(c.snapshot.memory?.compressed)
  }
  private var freeDisk: String {
    guard let disk = c.snapshot.disk else { return CardFormat.missing }
    let value = CardFormat.storage(disk.free)
    return c.options.language == .english ? value + " free" : "可用 " + value
  }
}
