import AppKit
import Testing
import MonitorCore
@testable import MonitorUI

@Test func quantizedPhasesAndHysteresis() {
    #expect(MoonModel.step(nil) == nil)
    #expect(MoonModel.step(.nan) == nil)
    #expect(MoonModel.step(0) == 0)
    #expect(MoonModel.step(100) == 7)
    for step in 0...7 {
        #expect(MoonModel.step(50 + Double(step)*45/7) == step)
        #expect(abs(MoonModel.lit(step) - (0.12+0.88*Double(step)/7)) < 1e-10)
    }
    var phase = MoonHysteresis()
    let boundary = 50 + 0.5*45/7
    #expect(phase.update(50) == 0)
    #expect(phase.update(boundary+0.9) == 0)
    #expect(phase.update(boundary+1.01) == 1)
    #expect(phase.update(boundary-0.9) == 1)
    #expect(phase.update(boundary-1.01) == 0)
    #expect(phase.update(95) == 7)
    #expect(phase.update(nil) == nil)
    #expect(phase.update(72) == 3)
}

@Test func bothRampsMatchApprovedStops() {
    let dark = [[255,255,255],[255,241,214],[255,208,138],[255,169,77],[255,122,61],[255,59,48]]
    let light = [[29,29,31],[74,58,34],[138,90,16],[178,90,0],[194,65,12],[215,0,21]]
    for i in MoonModel.stops.indices {
        #expect(MoonModel.rgb(at: MoonModel.stops[i], dark: true) == dark[i])
        #expect(MoonModel.rgb(at: MoonModel.stops[i], dark: false) == light[i])
    }
    #expect(MoonModel.rgb(at: 0, dark: true) == dark[0])
    #expect(MoonModel.rgb(at: 200, dark: false) == light[5])
}

@Test @MainActor func statusWidthsAndAccessibility() {
    let width = TwinMoonsRenderer.width
    for unit in [TemperatureUnit.celsius, .fahrenheit] {
        for t in [0.0, 75, 100] {
            let string = DisplayFormat.temperature(t, unit: unit)
            #expect((string as NSString).size(withAttributes: [.font: TwinMoonsRenderer.numberFont]).width <= TwinMoonsRenderer.labelWidth)
            let image = TwinMoonsRenderer.image(cpuText: string, gpuText: string, cpuStep: MoonModel.step(t), gpuStep: nil, dark: true)
            #expect(image.size.width == width)
        }
    }
    #expect(MoonModel.accessibility(cpu: 76, gpu: 63, unit: .celsius, language: .english) == "CPU 76 degrees Celsius, GPU 63 degrees Celsius")
    #expect(MoonModel.accessibility(cpu: 75, gpu: nil, unit: .fahrenheit, language: .traditionalChinese) == "CPU 華氏167度, GPU 無資料")
}


@Test @MainActor func everyMoonSubsetHasStableFixedWidth() {
    for mask in 0...7 {
        let moons=MenuBarMoons(rawValue:mask)
        for dark in [true,false] {
            let image=TwinMoonsRenderer.image(cpuText:"100°C",gpuText:"212°F",cpuStep:7,gpuStep:7,dark:dark,
                ramText:"100%",ramStep:7,ramColourStep:7,moons:moons)
            #expect(image.size.width == TwinMoonsRenderer.width(for:moons))
        }
    }
    #expect(TwinMoonsRenderer.width(for:[.cpu,.gpu]) < TwinMoonsRenderer.width)
    #expect(TwinMoonsRenderer.width(for:.ram) < TwinMoonsRenderer.width(for:.cpu))
    #expect(MoonModel.accessibility(cpu:75,gpu:63,unit:.celsius,language:.english,ram:58,moons:.ram) == "RAM 58 percent")
    #expect(MoonModel.accessibility(cpu:75,gpu:63,unit:.celsius,language:.english,ram:58,moons:[]) == "Little Moon")
}
