import Testing
@testable import Samplers

@Test func m3CoreMapExcludesGPUCoupledPackageSensors() {
    let map = SMCSensorMap.forChip("Apple M3")
    for key in ["Tp14", "Tp18", "Tp1I", "Tp1F", "Tp1L"] { #expect(!map.isCPU(key)) }
    for key in ["Te05", "Te0L", "Te0P", "Tp01", "Tp05", "Tp09", "Tp0D"] { #expect(map.isCPU(key)) }
    #expect(map.isGPU("Tg0D"))
    #expect(!map.isGPU("Tp14"))
    #expect(SMCSensorMap.forChip("Apple M3 Max").isCPU("Tp0n"))
    #expect(SMCSensorMap.forChip("Apple M3 Pro").isGPU("Tg05"))
}

@Test func chipMapsKeepAssignmentsSeparateAndUnknownChipsEnumerate() {
    #expect(SMCSensorMap.forChip("Apple M1 Ultra").isCPU("Tp0b"))
    #expect(SMCSensorMap.forChip("Apple M2 Max").isCPU("Tp1h"))
    #expect(SMCSensorMap.forChip("Apple M4").isGPU("Tg0G"))
    #expect(SMCSensorMap.forChip("Apple M4").isGPU("Tg1U"))
    #expect(SMCSensorMap.forChip("Apple M4 Max").isGPU("Tg1U"))
    #expect(SMCSensorMap.forChip("Apple M4 Max").isGPU("Tg0G"))
    #expect(SMCSensorMap.forChip("Apple M5 Max").isCPU("Tp0y"))
    #expect(SMCSensorMap.forChip("Apple M5 Max").isGPU("Tg9Z"))
    for chip in ["Apple M10", "Apple M6", "Apple M4 Ultra", "unknown", "Apple M3 Mystery"] {
        let map = SMCSensorMap.forChip(chip)
        #expect(map.isCPU("TpZZ"))
        #expect(map.isGPU("TgZZ"))
        #expect(map.isCPU("Te05"))
    }
}

@Test func adaptiveCadencePreservesRootRefreshBeforeRateExpiry() {
    for cores in [8, 10, 12, 18] {
        let interval = SamplingCadence.processInterval(logicalCoreCount: cores)
        #expect(interval == (cores <= 10 ? 8 : 5))
        let discovery = SamplingCadence.discoveryEvery(processInterval: interval)
        #expect(interval * Double(discovery) <= 25)
        #expect(interval * Double(discovery) < 30)
    }
}
