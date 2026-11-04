// Standalone unit test: link MonitorCore plus production MenuText.swift. No UI is shown.
import AppKit
import MonitorCore

@main struct ReportMenuTests {
    static func main() {
        let target = NSObject()
        let action = NSSelectorFromString("sensorReport")
        var state = SensorReportMenuState()
        let initial = state.item(.english, target: target, action: action)
        precondition(initial.title == "Sensor Report…")
        precondition(initial.action == action && initial.target === target && initial.isEnabled)
        precondition(state.title(.traditionalChinese) == "感測器報告…")
        state.begin()
        precondition(state.status == .running)
        precondition(state.title(.english) == "Cancel Sensor Report (Idle readings 0%)")
        state.update(phase: "cpu", fraction: 0.25)
        precondition(state.title(.english) == "Cancel Sensor Report (CPU load 25%)")
        precondition(state.title(.traditionalChinese) == "取消感測器報告 (CPU 負載 25%)")
        state.update(phase: "cooldown", fraction: 0.4)
        precondition(state.title(.traditionalChinese).contains("冷卻中 40%"))
        state.update(phase: "gpu", fraction: 2)
        precondition(state.title(.english).contains("GPU load 100%"))
        state.cancel()
        precondition(state.status == .cancelling)
        precondition(state.title(.traditionalChinese) == "正在取消感測器報告…")
        precondition(!state.item(.english, target: target, action: action).isEnabled)
        state.update(phase: "gpu", fraction: 0.9)
        precondition(state.title(.english) == "Cancelling Sensor Report…")
        state.finish()
        precondition(state.status == .ready && state.fraction == 0)
        precondition(state.item(.english, target: target, action: action).isEnabled)
        print("PASS report menu item/action/target, en/zh-Hant titles, progress, cancel, finish states (18 assertions)")
    }
}
