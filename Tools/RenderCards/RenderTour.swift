import AppKit
import SwiftUI
import MonitorCore
import MonitorUI

@MainActor
func renderTour() throws {
    _ = NSApplication.shared
    let output=URL(fileURLWithPath:"docs/wave5/onboarding",isDirectory:true)
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let fixtures: [(String,TourCopy,Int)] = [
        ("1-moons",.moons,0),("1-minimal",.minimal,0),("1-hidden",.hidden,0),("1-parked",.parked,0),("1-icon",.icon,0),
        ("2-popover",.popover,1),("3-panel",.panel,2),("3-occluded",.panel,2),("4-settings",.settings,3),("4-hidden",.settingsHidden,3),("5-mode",.mode,4)]
    for (name,copy,index) in fixtures {
        for language in AppLanguage.allCases {
            for setting in ["default","reduceTransparency","increaseContrast"] {
                for bright in [false,true] {
                    let hidden = copy == .hidden || copy == .parked || copy == .settingsHidden
                    let plan = TourState(mode: hidden ? .menuBar : .both, hidden: hidden, panelVisible: true)
                    let step: TourStep = copy == .settingsHidden ? .settings : TourStep.allCases[index]
                    let runtimeIndex = plan.steps.firstIndex(of: step) ?? 0
                    let card=CoachMarkView(copy:copy,language:language,index:runtimeIndex,count:plan.steps.count,mode:.constant(hidden ? .menuBar : .both),
                        occluded:name == "3-occluded",increaseContrast:setting == "increaseContrast")
                    // Offline deterministic approximation of regular tinted glass. Runtime uses NSGlassEffectView.
                    let renderer=ImageRenderer(content:card
                        .background(Color(red:0.11,green:0.12,blue:0.15).opacity(setting == "reduceTransparency" ? 1 : 0.85),in:RoundedRectangle(cornerRadius:18))
                        .padding(12).background(bright ? Color(red:0.86,green:0.92,blue:0.96) : Color(red:0.23,green:0.31,blue:0.44)))
                    renderer.scale=2
                    guard let image=renderer.cgImage else { fatalError("tour rendering failed") }
                    let bitmap=NSBitmapImageRep(cgImage:image)
                    let suffix=setting == "default" ? "" : "-"+setting
                    let file="tour-\(name)-\(language.rawValue)\(suffix)\(bright ? "-bright" : "").png"
                    try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(file))
                    print("\(file): \(image.width) × \(image.height) px")
                }
            }
        }
    }
}
