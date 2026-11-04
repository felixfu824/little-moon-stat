import Foundation
import Darwin
import MonitorCore
import Samplers

struct Options {
    var seconds = 30.0
    var json = false
    var fault = ""
    var sensorReport: String?
    var pauseAt: Double?
    var wakeAt: Double?
    var resumeAfter = 2.0
    init() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let flag = args.removeFirst()
            if flag == "--sensor-report", !args.isEmpty { sensorReport = args.removeFirst(); continue }
            if flag == "--fault", !args.isEmpty { fault += (fault.isEmpty ? "" : ",") + args.removeFirst(); continue }
            if flag == "--json" { json = true; continue }
            guard ["--seconds", "--pause-at", "--wake-at", "--resume-after"].contains(flag),
                  !args.isEmpty, let value = Double(args.removeFirst()), value.isFinite, value >= 0 else {
                throw NSError(domain: "EngineDump", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Usage: EngineDump [--sensor-report PATH] --seconds N [--json] [--pause-at N] [--resume-after N] [--wake-at N]"])
            }
            switch flag {
            case "--seconds": seconds = value
            case "--pause-at": pauseAt = value
            case "--wake-at": wakeAt = value
            default: resumeAfter = value
            }
        }
        guard seconds > 0 else { throw NSError(domain: "EngineDump", code: 2, userInfo: [NSLocalizedDescriptionKey: "--seconds must be positive"]) }
    }
}

func usageSeconds(_ who: Int32) -> Double {
    var usage = rusage()
    guard getrusage(who, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

@MainActor
final class DumpSession {
    let options: Options
    let store: SnapshotStore
    let engine: SamplingEngine
    let start = ProcessInfo.processInfo.systemUptime
    let initialSelf = usageSeconds(RUSAGE_SELF)
    let initialChildren = usageSeconds(RUSAGE_CHILDREN)
    var finished = false
    var publications = 0
    var previousKey: String?
    var repeatedKeys = 0

    init(options: Options) {
        self.options = options
        store = SnapshotStore()
        engine = SamplingEngine(store: store, faults: FaultConfiguration(options.fault))
    }
    func run() {
        engine.onPublish = { [weak self] snapshot in self?.emit(snapshot) }
        engine.start()
        if let pauseAt = options.pauseAt {
            after(pauseAt) { session in
                session.event("pause")
                session.engine.pause()
                session.after(session.options.resumeAfter) { $0.event("resume"); $0.engine.resume() }
            }
        }
        if let wakeAt = options.wakeAt { after(wakeAt) { $0.event("wake"); $0.engine.systemDidWake() } }
        after(options.seconds) { $0.finish() }
    }
    func after(_ seconds: Double, _ action: @escaping @MainActor (DumpSession) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.finished else { return }
            action(self)
        }
    }
    func emit(_ s: Snapshot) {
        publications += 1
        let key = displayKey(s)
        if key == previousKey { repeatedKeys += 1 }
        previousKey = key
        if options.json {
            func nullable(_ value: Any?) -> Any { value ?? NSNull() }
            func temperature(_ value: TempStat?) -> Any {
                guard let value else { return NSNull() }
                return ["peak": value.peak, "average": value.average, "sensorCount": value.sensorCount] as [String: Any]
            }
            var row: [String: Any] = ["type": "snapshot", "elapsed": elapsed, "timestamp": s.timestamp.timeIntervalSince1970,
                "machineName": s.machineName, "chipName": s.chipName, "cpuPercent": nullable(s.cpuPercent),
                "gpuPercent": nullable(s.gpuPercent), "cpuTemp": temperature(s.cpuTemp), "gpuTemp": temperature(s.gpuTemp),
                "thermal": nullable(s.thermal?.rawValue),
                "topProcesses": s.topProcesses.map { ["pid": $0.pid, "name": $0.name, "cpuPercent": $0.cpuPercent,
                                                       "residentBytes": $0.residentBytes] as [String: Any] }]
            row["status"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s.status))) ?? NSNull()
            row["memory"] = s.memory.map { ["wired": $0.wired, "active": $0.active, "compressed": $0.compressed,
                                          "used": $0.used, "total": $0.total] } ?? (NSNull() as Any)
            row["disk"] = s.disk.map { ["volumeName": $0.volumeName, "total": $0.total,
                                       "free": $0.free, "used": $0.used] as [String: Any] } ?? (NSNull() as Any)
            json(row)
        } else {
            func value(_ n: Double?) -> String { n.map { String(format: "%.1f", $0) } ?? "—" }
            let rows = s.topProcesses.map { "\($0.name)(\($0.pid)) \(value($0.cpuPercent))%" }.joined(separator: " | ")
            print(String(format: "%.2fs", elapsed), "CPU \(value(s.cpuPercent))% GPU \(value(s.gpuPercent))%",
                  "temps \(value(s.cpuTemp?.peak))/\(value(s.gpuTemp?.peak))°",
                  "memory \(s.memory.map { String($0.used) } ?? "—") disk-free \(s.disk.map { String($0.free) } ?? "—")",
                  s.thermal?.rawValue ?? "—", rows)
        }
        fflush(stdout)
    }
    var elapsed: Double { ProcessInfo.processInfo.systemUptime - start }
    func json(_ row: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
    }
    func event(_ name: String) {
        if options.json { json(["type": "event", "event": name, "elapsed": elapsed]) }
        else { print(String(format: "%.2fs", elapsed), name) }
        fflush(stdout)
    }
    func finish() {
        engine.stop()
        finished = true
        let seconds = elapsed
        let own = usageSeconds(RUSAGE_SELF) - initialSelf
        let children = usageSeconds(RUSAGE_CHILDREN) - initialChildren
        if options.json {
            json(["type": "summary", "seconds": seconds, "selfCPUSeconds": own, "childrenCPUSeconds": children,
                  "oneCorePercent": (own + children) / seconds * 100,
                  "publications": publications, "repeatedDisplayKeys": repeatedKeys])
        } else {
            print(String(format: "CPU self=%.6fs children=%.6fs / %.3fs = %.4f%% of one core; publications=%d repeatedKeys=%d",
                         own, children, seconds, (own + children) / seconds * 100, publications, repeatedKeys))
        }
        fflush(stdout)
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

do {
    let options = try Options()
    if let path = options.sensorReport {
        let cancellation = SensorReportCancellation()
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        let report = try SensorReportRunner(cancellation: cancellation) { phase, fraction in
            fputs("Sensor Report: \(phase) \(Int(fraction * 100))%\n", stderr)
        }.run()
        try report.write(to: URL(fileURLWithPath: path))
        print(report.summary)
    } else { MainActor.assumeIsolated {
        let session = DumpSession(options: options)
        session.run()
        CFRunLoopRun()
        withExtendedLifetime(session) {}
    } }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(2)
}
