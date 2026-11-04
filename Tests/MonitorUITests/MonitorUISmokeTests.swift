import Testing
import MonitorCore
@testable import MonitorUI

@Test func everyStringExistsInBothLanguages() {
    for key in L10n.allCases {
        for language in AppLanguage.allCases { #expect(!key.text(language).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }
}

@Test func binaryMemoryAndDecimalDiskRounding() {
    #expect(CardFormat.gb(1_073_741_824) == "1.0")
    #expect(CardFormat.gb(0) == "0.0")
    #expect(CardFormat.memory(MemoryStat(wired: 0, active: 0, compressed: 0, total: 128 * 1_073_741_824)) == "0.0 / 128 GB")
    #expect(CardFormat.storage(1_000_000_000_000) == "1.0 TB")
    #expect(CardFormat.storage(379_000_000_000) == "379 GB")
    #expect(CardFormat.storage(999_950_000_000) == "1.0 TB")
    #expect(CardFormat.storage(999_500_000) == "1 GB")
    #expect(CardFormat.processMemory(1_200_000_000) == "1.2 GB")
    #expect(CardFormat.processMemory(0) == "0.0 GB")
    #expect(CardFormat.storage(96_000_000) == "96 MB")
    #expect(CardFormat.disk(Snapshot.preview.disk, language: .traditionalChinese) == "已用 1.0 TB · 可用 379 GB")
}

@Test func absentValuesRemainMissing() {
    #expect(CardFormat.percent(nil) == "—")
    #expect(CardFormat.temperature(nil) == "—")
    #expect(CardFormat.gb(nil) == "—")
    #expect(CardFormat.storage(nil) == "—")
    #expect(CardFormat.memory(nil) == "—")
    #expect(CardFormat.disk(nil, language: .english) == "—")
    #expect(CardFormat.thermal(nil, language: .traditionalChinese) == "—")
    #expect(CardFormat.percent(.nan) == "—")
}

@Test func processHighlightThresholdAndUncappedCPU() {
    #expect(!CardFormat.hot(49.9))
    #expect(CardFormat.hot(50))
    #expect(CardFormat.hot(1234.5))
    #expect(CardFormat.percent(1234.5, decimals: 1) == "1234.5%")
}

@Test func thermalTranslations() {
    #expect(CardFormat.thermal(.nominal, language: .english) == "Nominal")
    #expect(CardFormat.thermal(.fair, language: .traditionalChinese) == "尚可")
    #expect(CardFormat.thermal(.serious, language: .traditionalChinese) == "嚴重")
    #expect(CardFormat.thermal(.critical, language: .traditionalChinese) == "危急")
}

@Test func memorySegmentFractionsUseByteTotal() {
    let fractions = CardFormat.memoryFractions(Snapshot.preview.memory)
    #expect(fractions.count == 3)
    // The fixture is in binary GB: 8.8 + 52.3 + 13.3 = 74.4 of 128.
    let expected = [8.8, 52.3, 13.3]
    for index in expected.indices {
        #expect(abs(fractions[index] - expected[index] / 128) < 1e-9)
        #expect(fractions[index] > 0)
    }
    #expect(abs(fractions.reduce(0, +) - 74.4 / 128) < 1e-9)
    #expect(CardFormat.memory(Snapshot.preview.memory) == "74.4 / 128 GB")
    #expect(CardFormat.memoryFractions(nil).isEmpty)
    #expect(CardFormat.memoryFractions(MemoryStat(wired: 1, active: 2, compressed: 3, total: 0)).isEmpty)
    #expect(CardFormat.memoryFractions(MemoryStat(wired: 0, active: 0, compressed: 0, total: 100)) == [0, 0, 0])
    let overfull = CardFormat.memoryFractions(MemoryStat(wired: 50, active: 100, compressed: 50, total: 100))
    #expect(overfull == [0.25, 0.5, 0.25])
}
