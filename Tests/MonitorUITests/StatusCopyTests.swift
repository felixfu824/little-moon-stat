import AppKit
import SwiftUI
import Foundation
import Testing
import MonitorCore
@testable import MonitorUI

@Test(arguments: MetricFault.allCases) func statusReasonsExistInBothLanguages(fault: MetricFault) {
    let status = MetricStatus.unavailable(fault)
    let english = StatusCopy.reason(status, metric: .cpuTemp, language: .english)
    let chinese = StatusCopy.reason(status, metric: .cpuTemp, language: .traditionalChinese)
    #expect(!english.isEmpty && !chinese.isEmpty && english != chinese)
    #expect(english.contains("Temperature sensors") == (fault == .serviceUnavailable))
}
@Test func gpuServiceReasonAndPriorityUseCorrectMetric() {
    let status = MetricStatus.unavailable(.serviceUnavailable)
    #expect(StatusCopy.reason(status, metric: .gpuPercent, language: .english) == "GPU usage not reported by this Mac")
    #expect(StatusCopy.reason(status, metric: .gpuPercent, language: .traditionalChinese) == "此 Mac 不回報 GPU 使用率")
    var snapshot = Snapshot.preview
    snapshot.status.processes = .estimated(.libprocOnly, fault: .psUnavailable)
    snapshot.status.cpuTemp = .estimated(.genericFamily, fault: .unknownChip)
    #expect(snapshot.status.statusLine?.metric == .cpuTemp)
}
@Test func approximateAndUnavailableAccessibilityFollowLanguageAndUnits() {
    let estimated = MetricStatus.estimated(.genericFamily, fault: .unknownChip)
    #expect(StatusCopy.temperatureAccessibility(76, status: estimated, metric: .cpuTemp, unit: .celsius, language: .english) == "approximately 76 degrees Celsius, generic sensors")
    #expect(StatusCopy.temperatureAccessibility(76, status: estimated, metric: .cpuTemp, unit: .celsius, language: .traditionalChinese) == "約攝氏76度，通用感測器")
    let absent = MetricStatus.unavailable(.permission)
    #expect(StatusCopy.temperatureAccessibility(nil, status: absent, metric: .gpuTemp, unit: .fahrenheit, language: .english) == "unavailable, Sensors blocked by the app sandbox")
    #expect(StatusCopy.readout("212°F", status: estimated) == "≈ 212°F")
    #expect(StatusCopy.readout("212°F", status: absent) == "—")
    let status = SnapshotStatus(cpuTemp: estimated, gpuTemp: absent)
    let en = MoonModel.accessibility(cpu: 76, gpu: nil, unit: .celsius, language: .english, status: status)
    let zh = MoonModel.accessibility(cpu: 76, gpu: nil, unit: .celsius, language: .traditionalChinese, status: status)
    #expect(en.contains("approximately") && en.contains("unavailable, Sensors blocked"))
    #expect(zh.contains("約攝氏76度，通用感測器") && zh.contains("無資料，App 沙盒"))
}
@Test @MainActor func statusLimbAndUnderlineAreWidthNeutralAndChangePixels() throws {
    let estimated = MetricStatus.estimated(.genericFamily, fault: .unknownChip)
    #expect(StatusCopy.dashed(estimated))
    #expect(!StatusCopy.dashed(.live) && !StatusCopy.dashed(.unavailable(.apiError)))
    let live = TwinMoonsRenderer.image(cpuText: "212°F", gpuText: "212°F", cpuStep: 2, gpuStep: 3, dark: true)
    let fallback = TwinMoonsRenderer.image(cpuText: "212°F", gpuText: "212°F", cpuStep: 2, gpuStep: 3, dark: true, status: SnapshotStatus(cpuTemp: estimated, gpuTemp: estimated))
    #expect(live.size == fallback.size)
    #expect(live.tiffRepresentation != fallback.tiffRepresentation)
    #expect(("212°F" as NSString).size(withAttributes: [.font: TwinMoonsRenderer.numberFont]).width <= TwinMoonsRenderer.labelWidth)
}

@Test @MainActor func desktopEstimatedNumbersChangePixelsWithoutConsumingLayoutSpace() throws {
    var fallback = Snapshot.preview
    fallback.cpuTemp = TempStat(peak: 100, average: 100, sensorCount: 2)
    fallback.gpuTemp = fallback.cpuTemp
    var live = fallback
    live.status = .live
    fallback.status.cpuTemp = .estimated(.genericFamily, fault: .unknownChip)
    fallback.status.gpuTemp = fallback.status.cpuTemp
    for size in PanelSize.allCases {
        let options = DisplayOptions(size: size, temperatureUnit: .fahrenheit)
        let normal = ImageRenderer(content: MonitorCard(store: SnapshotStore(snapshot: live), options: options))
        let estimated = ImageRenderer(content: MonitorCard(store: SnapshotStore(snapshot: fallback), options: options))
        let a = try #require(normal.cgImage), b = try #require(estimated.cgImage)
        #expect(a.width == b.width && a.height == b.height)
        #expect(NSBitmapImageRep(cgImage: a).representation(using: .png, properties: [:]) != NSBitmapImageRep(cgImage: b).representation(using: .png, properties: [:]))
    }
}

@Test func statusAccessibilityRetainsMemoryBreakdownAndProcessResidentMemory() {
    let memory = MemoryStat(wired: 1_073_741_824, active: 2_147_483_648, compressed: 1_073_741_824, total: 8_589_934_592)
    let en = StatusCopy.memoryAccessibility(memory, status: .live, language: .english)
    #expect(en.contains("Wired 1.0 GB") && en.contains("Active 2.0 GB") && en.contains("Compressed 1.0 GB"))
    let zh = StatusCopy.memoryAccessibility(memory, status: .live, language: .traditionalChinese)
    #expect(zh.contains("固定") && zh.contains("使用中") && zh.contains("已壓縮"))
    let row = ProcRow(pid: 7, name: "Safari", cpuPercent: 12.5, residentBytes: 96_000_000)
    let process = StatusCopy.processAccessibility(row, status: .estimated(.libprocOnly, fault: .psUnavailable), language: .english)
    #expect(process.contains("Safari, approximately 12.5%") && process.contains("96 MB") && process.contains("ps unavailable"))
    let absent = StatusCopy.processAccessibility(nil, status: .unavailable(.apiError), language: .english)
    #expect(absent == "unavailable, System call failed; retrying")
}
