// Live key-name-only inventories from our own Sensor Reports; see docs/wave4/reports.
import Testing
@testable import Samplers

let liveChipFixtures: [ChipFixture] = [
    ChipFixture(name: "pro-m5-max live", chip: "Apple M5 Max", keys: "TAOL TB0T TB1T TB2T TCDX TCHP TCMb TD00 TD01 TD02 TD03 TD04 TD10 TD11 TD12 TD13 TD14 TD20 TD21 TD22 TD23 TD24 TDBP TDEL TDER TDTC TDTP TDVx TDeL TDeR TH0a TH0b TH0x TH1a TH1b TMVR TN00 TN01 TN02 TN03 TN04 TN05 TN06 TN07 TPD0 TPD1 TPD2 TPD3 TPD4 TPD5 TPD6 TPD7 TPD8 TPD9 TPDX TPDa TPDb TPDc TPDd TPMP TPSP TRD0 TRD1 TRD2 TRD3 TRD4 TRD5 TRD6 TRD7 TRD8 TRD9 TRDX TRDa TRDb TRDc TRDd TRDe TS0P TSVR TSWR TSXR TTPD TUD0 TUD1 TUD2 TUD3 TUD4 TUD5 TUD6 TUD7 TUD8 TUD9 TUDX TUDa TUDb TUDc TUDd TUDe TV01 TV02 TV03 TV04 TV05 TV06 TV07 TV08 TV11 TV12 TV13 TV14 TVA0 TVD0 TVDA TVDG TVDM TVDP TVDc TVMD TVMR TVMX TVMr TVN1 TVN2 TVN3 TVN4 TVN5 TVN6 TVN7 TVN8 TVNN TVS0 TVS1 TVS2 TVS3 TVV0 TVmS TVms TW0P Ta00 Ta04 Ta08 Ta0K Ta0O Ta0R TaLP TaLT TaLW TaRF TaRT TaRW TaTP Tf04 Tf06 Tf08 Tf09 Tf0A Tf0B Tf14 Tf16 Tf18 Tf19 Tf1A Tf1B TfC1 TfC3 TfC5 TfC6 TfC7 TfC8 TfC9 TfCA Tg08 Tg0C Tg0O Tg0R Tg0U Tg0X Tg0a Tg0d Tg0g Tg0j Tg12 Tg16 Tg1I Tg1M Tg1Q Tg1U Tg1Y Tg1c Tg1k Tg1o Tg1x Tg29 Tg2D Tg2P Tg2T Tg2X Tg2b Tg2f Tg2j Tg2n Tg2r Tg3B Tg3F Tg3R Tg3V Tg3Z Tg3d Tg3h Tg3l Tg3t Tg3x Tg43 Tg4D Tg4G Tg4P Tg4S Tg4V Tg4Y Tg4b Tg4e Tg4h Tg4k Tg50 Tg53 Tg5C Tg5F Tg5I Tg5L Tg5O Tg5R Tg5Y Tg5b Tg5h Tg5q Tg5t Tg63 Tg66 Tg69 Tg6C Tg6F Tg6I Tg6L Tg6O Tg6e Tg6h Tg6q Tg6t Tg6w Tg70 Tg73 Tg76 Tg7C Tg7F Tg7L Tm00 Tm04 Tm08 Tm0C Tm0G Tm0K Tm0O Tm0R Tm0U Tm0X Tm0a Tm0d Tm0g Tm0j Tm0m Tm0p Tm0u Tm0y Tm1E Tm1I Tm1M Tm1Q Tm1U Tm1Y Tm1c Tm1g Tm1k Tm1o Tm1s Tm1x Tm21 Tm25 Tm29 Tm2D Tm2H Tm2L Tm2P Tm2T Tm2j Tm2n Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y Tp1E Tp1I Tp1Q Tp1U Tp1g Ts00 Ts04 Ts08 Ts0C Ts0G Ts0K Ts0O Ts0P Ts0R Ts0U Ts0X Ts0a Ts0d Ts0g Ts1P Tz11 Tz12 Tz13 Tz14 Tz15 Tz16 Tz17 Tz18 Tz1j", forbiddenCPU: "Tf04 Tf06 Tf08 Tf09 Tf0A Tf0B Tf14 Tf16 Tf18 Tf19 Tf1A Tf1B TfC1 TfC3 TfC5 TfC6 TfC7 TfC8 TfC9 TfCA Tg08 Tg0C Tg0O Tg0R Tg0U Tg0X Tg0a Tg0d Tg0g Tg0j Tg12 Tg16 Tg1I Tg1M Tg1Q Tg1U Tg1Y Tg1c Tg1k Tg1o Tg1x Tg29 Tg2D Tg2P Tg2T Tg2X Tg2b Tg2f Tg2j Tg2n Tg2r Tg3B Tg3F Tg3R Tg3V Tg3Z Tg3d Tg3h Tg3l Tg3t Tg3x Tg43 Tg4D Tg4G Tg4P Tg4S Tg4V Tg4Y Tg4b Tg4e Tg4h Tg4k Tg50 Tg53 Tg5C Tg5F Tg5I Tg5L Tg5O Tg5R Tg5Y Tg5b Tg5h Tg5q Tg5t Tg63 Tg66 Tg69 Tg6C Tg6F Tg6I Tg6L Tg6O Tg6e Tg6h Tg6q Tg6t Tg6w Tg70 Tg73 Tg76 Tg7C Tg7F Tg7L", forbiddenGPU: "Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y Tp1E Tp1I Tp1Q Tp1U Tp1g"),
    ChipFixture(name: "air-m3 live", chip: "Apple M3", keys: "T5SP TAOL TB0T TB1T TB2T TCHP TCMb TCMz TDBP TDeL TH0T TH0x TIOP TMVR TPD0 TPD1 TPD2 TPD3 TPD4 TPD5 TPD6 TPD7 TPDX TPMP TPSP TRD0 TRD1 TRD2 TRD3 TRD4 TRD5 TRD6 TRD7 TRDX TSCD TVA0 TVD0 TVMD TVS0 TVS1 TVSx TVs1 TW0P Ta04 Ta05 Ta08 Ta09 Te04 Te05 Te06 Te0K Te0L Te0M Te0O Te0P Tg0C Tg0D Tg0O Tg0P Tg0W Tg0X Tg0a Tg0b Tg0i Tg0j Tg0u Tg0v Th00 Th01 Th02 Th08 Th09 Th0A Tm0B Tp00 Tp01 Tp02 Tp04 Tp05 Tp06 Tp08 Tp09 Tp0A Tp0C Tp0D Tp0E Tp0G Tp0H Tp0I Tp0K Tp0L Tp0M Tp0O Tp0P Tp0Q Tp0S Tp0T Tp0U Tp0W Tp0X Tp0Y Tp0a Tp0b Tp0c Tp0e Tp0f Tp0g Tp0i Tp0j Tp0k Tp0m Tp0n Tp0o Tp0q Tp0r Tp0s Tp0u Tp0v Tp0w Tp0y Tp0z Tp10 Tp12 Tp13 Tp14 Tp16 Tp17 Tp18 Tp1E Tp1F Tp1H Tp1I Tp1K Tp1L Ts0G Ts0H Ts0I Ts0K Ts0L Ts0M Ts0P Ts0S Ts0T Ts0U Ts0W Ts0X Ts1P Tz11 Tz12 Tz13 Tz14 Tz15 Tz16 Tz17 Tz18 Tz1j", forbiddenCPU: "Tg0C Tg0D Tg0O Tg0P Tg0W Tg0X Tg0a Tg0b Tg0i Tg0j Tg0u Tg0v", forbiddenGPU: "Te04 Te05 Te06 Te0K Te0L Te0M Te0O Te0P Tp00 Tp01 Tp02 Tp04 Tp05 Tp06 Tp08 Tp09 Tp0A Tp0C Tp0D Tp0E Tp0G Tp0H Tp0I Tp0K Tp0L Tp0M Tp0O Tp0P Tp0Q Tp0S Tp0T Tp0U Tp0W Tp0X Tp0Y Tp0a Tp0b Tp0c Tp0e Tp0f Tp0g Tp0i Tp0j Tp0k Tp0m Tp0n Tp0o Tp0q Tp0r Tp0s Tp0u Tp0v Tp0w Tp0y Tp0z Tp10 Tp12 Tp13 Tp14 Tp16 Tp17 Tp18 Tp1E Tp1F Tp1H Tp1I Tp1K Tp1L"),
 ]

@Test(arguments: liveChipFixtures) func replayOurMachines(f: ChipFixture) {
    replayChipInventory(f: f)
    let selected = SMCSensorSelection.select(inventory: f.inventory, chipName: f.chip)
    let previousCPU: Set<String>
    let previousGPU: Set<String>
    if f.chip == "Apple M3" {
        previousCPU = Set(["Te05", "Te0L", "Te0P", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D"]).intersection(f.inventory)
        previousGPU = Set(["Tg0C", "Tg0D", "Tg0O", "Tg0P", "Tg0W", "Tg0X", "Tg0a", "Tg0b", "Tg0i", "Tg0j", "Tg0u", "Tg0v"]).intersection(f.inventory)
    } else {
        previousCPU = Set(["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]).intersection(f.inventory)
        previousGPU = Set(f.inventory.filter { $0.hasPrefix("Tg") })
    }
    // Equality of the sets proves both peak and average are unchanged for every
    // possible simultaneous reading, including sentinels, on these inventories.
    #expect(selected.cpuKeys == previousCPU)
    #expect(selected.gpuKeys == previousGPU)
    #expect(selected.cpuSource == .chipMap && selected.gpuSource == .chipMap)
}
