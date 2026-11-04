// WP-U helper: window METADATA only (no pixels) for one pid, including small status-item windows.
// statusq <pid>   -> one line per window: id layer onscreen x y w h insideScreen
// statusq env     -> screens, lock state, Thaw running
import AppKit
import CoreGraphics
let a = CommandLine.arguments
let displays: [CGRect] = { var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n); return ids.prefix(Int(n)).map { CGDisplayBounds($0) } }()
if a.count > 1 && a[1] == "env" {
    for d in displays { print("display \(d)") }
    let s = (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
    print("locked=\(s["CGSSessionScreenIsLocked"] as? Bool ?? false)")
    print("thaw=\(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.stonerl.Thaw").isEmpty)")
    print("thermal=\(["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue])")
    exit(0)
}
guard a.count > 1, let pid = Int32(a[1]) else { print("usage: statusq <pid> | env"); exit(2) }
let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
var found = false
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    found = true
    print("id=\(w[kCGWindowNumber as String] ?? 0) layer=\(w[kCGWindowLayer as String] ?? "?") onscreen=\((w[kCGWindowIsOnscreen as String] as? Bool) ?? false) x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height)) inside=\(displays.contains { $0.contains(r) })")
}
if !found { print("none") }
