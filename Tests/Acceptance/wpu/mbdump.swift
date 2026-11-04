// WP-U acceptance helper: runs the app's real SamplingEngine headless and prints, per publication,
// the panel values (snapshot) next to the menu-bar values (engine.menuBarValues) from the same tick.
// Usage: mbdump <seconds> [closed|open]
//   closed = Menu bar mode with the popover closed (detail sampling off), the cheapest app configuration.
//   open   = detail sampling on (panel or popover visible).
import Foundation
import MonitorCore
import Samplers

@MainActor final class Session {
    let store = SnapshotStore()
    lazy var engine = SamplingEngine(store: store)
    let t0 = ProcessInfo.processInfo.systemUptime
    func run(seconds: Double, details: Bool) {
        engine.setPresentationOptions(DisplayOptions(temperatureUnit: .celsius, displayMode: .menuBar, menuBarMoons: .all))
        engine.setDetailSampling(details)
        engine.onPublish = { [weak self] s in self?.emit(s) }
        engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.engine.stop(); CFRunLoopStop(CFRunLoopGetMain())
        }
    }
    func emit(_ s: Snapshot) {
        func n(_ v: Double?) -> Any { v ?? NSNull() }
        func i(_ v: Int?) -> Any { v ?? NSNull() }
        let m = engine.menuBarValues
        let ram = s.memory.map { Double($0.used) / Double($0.total) * 100 }
        let row: [String: Any] = [
            "t": ProcessInfo.processInfo.systemUptime - t0, "wall": Date().timeIntervalSince1970,
            "cpuPeak": n(s.cpuTemp?.peak), "gpuPeak": n(s.gpuTemp?.peak), "cpuN": n(s.cpuTemp.map { Double($0.sensorCount) }),
            "gpuN": n(s.gpuTemp.map { Double($0.sensorCount) }), "ramPct": n(ram), "cpuPct": n(s.cpuPercent), "gpuPct": n(s.gpuPercent),
            "procs": s.topProcesses.count,
            "mCpu": n(m?.cpu.number), "mCpuStep": i(m?.cpu.phase), "mGpu": n(m?.gpu.number), "mGpuStep": i(m?.gpu.phase),
            "mRam": n(m?.ram.number), "mRamStep": i(m?.ram.phase), "mRamColour": i(m?.ram.colour)]
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!); fflush(stdout)
    }
}

let args = CommandLine.arguments
let seconds = args.count > 1 ? Double(args[1]) ?? 60 : 60
let details = !(args.count > 2 && args[2] == "closed")
MainActor.assumeIsolated {
    let session = Session()
    session.run(seconds: seconds, details: details)
    withExtendedLifetime(session) { CFRunLoopRun() }
}
