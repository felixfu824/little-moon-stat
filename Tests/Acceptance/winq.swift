// Window metadata for one pid (no pixels): winq window <pid> | winq screens | winq thermal
import AppKit
import CoreGraphics
let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "screens":
    for s in NSScreen.screens { print("screen frame=\(s.frame) visible=\(s.visibleFrame)") }
case "thermal":
    let t = ProcessInfo.processInfo.thermalState
    print(["nominal", "fair", "serious", "critical"][t.rawValue])
case "window":
    let pid = Int32(a[2])!
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    let displays: [CGRect] = { var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n); return ids.prefix(Int(n)).map { CGDisplayBounds($0) } }()
    var found = false
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if r.width < 50 { continue }
        found = true
        print("id=\(w[kCGWindowNumber as String] ?? 0) layer=\(w[kCGWindowLayer as String] ?? "?") onscreen=\((w[kCGWindowIsOnscreen as String] as? Bool) ?? false) x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height)) inside=\(displays.contains { $0.contains(r) })")
    }
    if !found { print("none") }
default: print("usage: winq window <pid> | screens | thermal"); exit(2)
}
