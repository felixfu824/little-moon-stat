// WP-D spike: can an unprivileged process see WindowServer's CPU? Compare libproc, ps and hybrid.
//   SpikeProcs --seconds 20 [--method hybrid|ps|libproc]   top 5 every 2 s
//   SpikeProcs --survey                libproc visibility survey
//   SpikeProcs --cost [--interval 2]   per-call wall + CPU cost of each method
//   SpikeProcs --resolution            % quantisation of the ps TIME column at 2 s and 3 s
//   SpikeProcs --compare               top-5 of each method vs `top` over the same window
import Foundation
import Darwin
import MonitorCore
import Samplers

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func ownCPU() -> Double { // seconds, self + children
    var s = rusage(), c = rusage()
    getrusage(RUSAGE_SELF, &s); getrusage(RUSAGE_CHILDREN, &c)
    func t(_ r: rusage) -> Double {
        Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
    }
    return t(s) + t(c)
}
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
func fmt(_ rows: [ProcRow]) -> String {
    rows.map { String(format: "%@(%d) %.1f%%", $0.name, $0.pid, $0.cpuPercent) }.joined(separator: " | ")
}

func makeSource(_ name: String) -> ProcessSource {
    switch name {
    case "libproc": return LibprocProcessSource()
    case "hybrid": return HybridProcessSource(discoveryEvery: 5)       // tiered (recommended)
    case "hybrid1": return HybridProcessSource(discoveryEvery: 1)      // scan all unreadable pids every read
    case "hybrid10": return HybridProcessSource(discoveryEvery: 10)
    case "hybrid3": return HybridProcessSource(discoveryEvery: 3)
    default: return PSProcessSource()
    }
}

// MARK: survey
if flag("--survey") {
    let src = LibprocProcessSource()
    guard let reading = src.read() else { print("libproc read failed"); exit(1) }
    let s = src.lastSurvey
    print("total pids: \(s.totalPids), readable: \(s.readable), unreadable: \(s.unreadablePids.count)")
    for (e, n) in s.failuresByErrno.sorted(by: { $0.key < $1.key }) {
        print("  errno \(e) (\(String(cString: strerror(e)))): \(n)")
    }
    // proc_name / proc_pidpath fail for these pids, so identify them via ps.
    let named = s.unreadablePids.compactMap { src.name(for: $0) }.count
    print("  proc_name resolves for \(named)/\(s.unreadablePids.count) unreadable pids")
    guard let ps = PSRunner.run(.all, withName: true) else { print("ps failed"); exit(1) }
    let psEntries = PSParsing.parse(ps.output, atNanos: 0)
    print("ps lists \(psEntries.count) pids; libproc listed \(s.totalPids)")
    let names = s.unreadablePids.sorted().map { "\($0):\(psEntries[$0]?.name ?? "?")" }
    print("  unreadable by libproc, first 12 of \(names.count) (pid:name via ps): " + names.prefix(12).joined(separator: " "))
    for target in ["WindowServer", "kernel_task", "launchd"] {
        if let e = psEntries.values.first(where: { $0.name == target }) {
            print("  \(target) pid \(e.pid): libproc \(reading.entries[e.pid] != nil ? "readable" : "NOT readable")")
        } else { print("  \(target): not in ps") }
    }
    exit(0)
}

// MARK: cost
if flag("--cost") {
    let interval = Double(arg("--interval") ?? "2") ?? 2
    let calls = Int(arg("--calls") ?? "15") ?? 15
    for method in (arg("--methods") ?? "libproc,ps,hybrid1,hybrid").split(separator: ",").map(String.init) {
        let sampler = ProcessSampler(source: makeSource(method))
        _ = sampler.sampleProcesses(limit: 5)
        var wall: [Double] = [], cpu: [Double] = []
        for _ in 0..<calls {
            Thread.sleep(forTimeInterval: interval)
            let c0 = ownCPU(), w0 = now()
            _ = sampler.sampleProcesses(limit: 5)
            wall.append(now() - w0); cpu.append(ownCPU() - c0)
        }
        let mw = wall.reduce(0, +) / Double(calls) * 1000
        let mc = cpu.reduce(0, +) / Double(calls) * 1000
        print(String(format: "%-8@ calls=%d wall/call=%.2f ms  cpu/call(self+children)=%.2f ms  amortised@%.0fs=%.3f%% of one core  (max wall %.1f ms)",
                     method as NSString, calls, mw, mc, interval, mc / (interval * 1000) * 100, (wall.max() ?? 0) * 1000))
    }
    exit(0)
}

// MARK: debug the hybrid's internal state
if flag("--debug-hybrid") {
    let h = HybridProcessSource(discoveryEvery: Int(arg("--every") ?? "5") ?? 5)
    for i in 0..<8 {
        guard let r = h.read() else { print("read failed"); break }
        let ws = r.entries.values.first { $0.name == "WindowServer" || $0.pid == 601 }
        print("read \(i): entries=\(r.entries.count) unreadable=\(h.lastSurvey.unreadablePids.count) discovery=\(h.lastWasDiscovery) watch=\(h.lastWatchCount) pid601=\(ws.map { String(format: "%.2fs", $0.cpuSeconds) } ?? "absent")")
        Thread.sleep(forTimeInterval: 2)
    }
    exit(0)
}

// MARK: kernel_task estimate (neither libproc nor ps lists pid 0)
// Idea: kernel_task CPU ~= host-wide busy CPU - sum of every process's CPU over the same window.
if flag("--kernel-task") {
    func hostBusySeconds() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy = 0.0
        for c in 0..<Int(cpuCount) {
            let base = c * Int(CPU_STATE_MAX)
            busy += Double(info[base + Int(CPU_STATE_USER)]) + Double(info[base + Int(CPU_STATE_SYSTEM)]) + Double(info[base + Int(CPU_STATE_NICE)])
        }
        return busy / Double(sysconf(_SC_CLK_TCK))
    }
    let src = PSProcessSource()
    for round in 1...Int(arg("--rounds") ?? "5")! {
        let topProc = Process()
        topProc.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        topProc.arguments = ["-l", "2", "-s", "2", "-stats", "pid,cpu,command", "-n", "10", "-o", "cpu"]
        let pipe = Pipe(); topProc.standardOutput = pipe
        guard let r0 = src.read(), let h0 = hostBusySeconds() else { print("read failed"); exit(1) }
        let w0 = now()
        try? topProc.run()
        Thread.sleep(forTimeInterval: 2.0)
        guard let r1 = src.read(), let h1 = hostBusySeconds() else { print("read failed"); exit(1) }
        let wall = now() - w0
        var sum = 0.0
        for (pid, c) in r1.entries { if let p = r0.entries[pid], c.cpuSeconds >= p.cpuSeconds { sum += c.cpuSeconds - p.cpuSeconds } }
        let residual = (h1 - h0 - sum) / wall * 100
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        topProc.waitUntilExit()
        let last = out.components(separatedBy: "\nPID ").last ?? ""
        let kt = last.split(separator: "\n").first { $0.contains("kernel_task") }.map(String.init) ?? "(not in top-3)"
        print(String(format: "round %d: host busy %.0f%%  sum(procs) %.0f%%  residual %.1f%%   top says: %@",
                     round, (h1 - h0) / wall * 100, sum / wall * 100, residual, kt.trimmingCharacters(in: .whitespaces) as NSString))
    }
    exit(0)
}

// MARK: resolution
if flag("--resolution") {
    print("ps TIME is centiseconds: smallest nonzero reading is 0.01 s of CPU.")
    for dt in [1.0, 2.0, 3.0] {
        print(String(format: "  cadence %.0f s -> %% step = %.2f%% of one core", dt, 0.01 / dt * 100))
    }
    exit(0)
}

// MARK: compare with top
// `top -l 2 -s 2`: sample 1 takes ~0.5 s of wall time, the second sample's % covers the ~2.5 s between the
// two sample midpoints. We therefore baseline ~0.25 s after launching top and read again 2.5 s later.
if flag("--compare") {
    let rounds = Int(arg("--rounds") ?? "5") ?? 5
    let names = ["libproc", "ps", "hybrid"]
    var overlap: [String: [Int]] = [:]
    var relErr: [String: [Double]] = [:]
    for round in 1...rounds {
        let topProc = Process()
        topProc.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        topProc.arguments = ["-l", "2", "-s", "2", "-o", "cpu", "-stats", "pid,cpu,command", "-n", "8"]
        let pipe = Pipe(); topProc.standardOutput = pipe
        let samplers = names.map { ($0, ProcessSampler(source: makeSource($0))) }
        try? topProc.run()
        let t0 = now()
        Thread.sleep(forTimeInterval: 0.25)
        for (_, s) in samplers { _ = s.sampleProcesses(limit: 5) }
        Thread.sleep(forTimeInterval: max(0, 2.75 - (now() - t0)))
        let results = samplers.map { ($0.0, $0.1.sampleProcesses(limit: 8)) }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        topProc.waitUntilExit()
        var topRows: [(pid: Int32, cpu: Double, name: String)] = []
        if let last = text.components(separatedBy: "\nPID ").last {
            for line in last.split(separator: "\n").dropFirst() {
                let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if f.count == 3, let pid = Int32(f[0]), let cpu = Double(f[1]) { topRows.append((pid, cpu, String(f[2]))) }
            }
        }
        // top shows itself and the kernel_task, which no unprivileged method can read; compare without them.
        let topComparable = topRows.filter { $0.name != "kernel_task" && !$0.name.hasPrefix("top") }
        print("--- round \(round)")
        print("top    : " + topRows.prefix(8).map { String(format: "%@(%d) %.1f", $0.name, $0.pid, $0.cpu) }.joined(separator: " | "))
        for (name, rows) in results {
            let mine = rows.filter { !$0.name.hasPrefix("top") }
            print(String(format: "%-7@: ", name as NSString) + mine.prefix(8).map { String(format: "%@(%d) %.1f", $0.name, $0.pid, $0.cpuPercent) }.joined(separator: " | "))
            let a = Set(mine.prefix(5).map(\.pid)), b = Set(topComparable.prefix(5).map(\.pid))
            overlap[name, default: []].append(a.intersection(b).count)
            for t in topComparable.prefix(5) {
                if let m = mine.first(where: { $0.pid == t.pid }), t.cpu >= 5 { relErr[name, default: []].append(abs(m.cpuPercent - t.cpu) / t.cpu) }
            }
        }
    }
    print("=== summary over \(rounds) rounds (top-5 pid overlap with top, excluding top itself and kernel_task)")
    for name in names {
        let o = overlap[name] ?? [], e = relErr[name] ?? []
        let meanErr = e.isEmpty ? Double.nan : e.reduce(0, +) / Double(e.count) * 100
        print(String(format: "%-7@ overlap per round %@  mean=%.1f/5   mean |%%diff| vs top for shared top-5 pids (>=5%%): %.0f%% (n=%d)",
                     name as NSString, o.map(String.init).joined(separator: ",") as NSString, Double(o.reduce(0, +)) / Double(max(o.count, 1)), meanErr, e.count))
    }
    exit(0)
}

// MARK: default live view
let seconds = Double(arg("--seconds") ?? "20") ?? 20
let method = arg("--method") ?? "hybrid"
let sampler = ProcessSampler(source: makeSource(method))
_ = sampler.sampleProcesses(limit: 5)
let end = now() + seconds
var sawWindowServer = false
while now() < end {
    Thread.sleep(forTimeInterval: 2)
    let rows = sampler.sampleProcesses(limit: 5)
    if rows.contains(where: { $0.name == "WindowServer" && $0.cpuPercent > 0 }) { sawWindowServer = true }
    print(fmt(rows))
}
print("WindowServer seen with non-zero %: \(sawWindowServer) (method \(method))")
