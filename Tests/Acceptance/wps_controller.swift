import AppKit
import MonitorCore
import MonitorUI

@main struct ControllerCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        for missing in [false, true] {
            var snapshot = Snapshot.preview
            if missing { snapshot.cpuTemp=nil; snapshot.gpuTemp=nil; snapshot.memory=nil }
            let store = SnapshotStore(); store.publish(snapshot)
            var options = DisplayOptions(language:.english,temperatureUnit:.celsius,displayMode:.menuBar)
            let controller = MoonStatusController(store:store,options:options)
            let button = controller.item.button!
            let image = button.image
            let english = button.accessibilityLabel()
            options.language = .traditionalChinese
            controller.update(options)
            let chinese = button.accessibilityLabel()
            precondition(english != chinese)
            precondition(chinese == MoonModel.accessibility(cpu:snapshot.cpuTemp?.peak,gpu:snapshot.gpuTemp?.peak,
                unit:.celsius,language:.traditionalChinese,ram:missing ? nil:58,moons:.all))
            precondition(button.image === image, "language must reuse the cached pixels")
            print("PASS controller language-only accessibility missing=\(missing)")
            NSStatusBar.system.removeStatusItem(controller.item)
        }
    }
}
func log(_ message: String) { print(message) }
