import Foundation
import Darwin
import Metal
import IOKit
import MonitorCore

/// Shared by CLI and menu flow. No subprocess loads, files or network operations.
/// Cancellation is checked between small CPU batches and bounded Metal dispatches.
public final class SensorReportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

public enum SensorReportError: LocalizedError {
    case cancelled, thermal, unavailable, metal(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sensor report cancelled."
        case .thermal: return "Sensor report stopped: thermal state is serious or critical."
        case .unavailable: return "No SMC float temperatures are readable. Run outside the sandbox on a supported Mac."
        case .metal(let detail): return "GPU load unavailable: \(detail)"
        }
    }
}

public struct SensorReport: Codable, Sendable {
    public struct Machine: Codable, Sendable {
        public let model: String
        public let productName: String
        public let chipName: String
        public let logicalCores: Int
        public let physicalCores: Int
        public let macOS: String
        public let osBuild: String
        public let appVersion: String
        public let appCommit: String
    }
    public struct Reading: Codable, Sendable {
        public let key: String
        public let idle: Double?
        public let cpuLoaded: Double?
        public let gpuIdle: Double?
        public let gpuLoaded: Double?
        public let cpuDelta: Double?
        public let gpuDelta: Double?
        enum CodingKeys: String, CodingKey { case key, idle, cpuLoaded, gpuIdle, gpuLoaded, cpuDelta, gpuDelta }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(idle, forKey: .idle)
            try c.encode(cpuLoaded, forKey: .cpuLoaded)
            try c.encode(gpuIdle, forKey: .gpuIdle)
            try c.encode(gpuLoaded, forKey: .gpuLoaded)
            try c.encode(cpuDelta, forKey: .cpuDelta)
            try c.encode(gpuDelta, forKey: .gpuDelta)
        }
    }
    public struct Verdict: Codable, Sendable {
        public let status: String
        public let cpuLoadRise: Double?
        public let gpuLoadRise: Double?
        public let contradictingKeys: [String]
        public let unavailableKeys: [String]
    }
    public let unreadableKeys: [String]
    public let appStatus: SnapshotStatus?
    public let hvVMMPresent: Bool
    public let schemaVersion: Int
    public let summary: String
    public let generatedAt: Date
    public let machine: Machine
    public let selection: SMCSensorSelection
    public let readings: [Reading]
    public let cpuVerdict: Verdict
    public let gpuVerdict: Verdict
    public let gpuDeviceUtilizationPercent: [Double]
    public let thermalStates: [String]
    public let phaseSeconds: [String: Double]
    public let method: String

    enum CodingKeys: String, CodingKey { case unreadableKeys, appStatus, hvVMMPresent, schemaVersion, summary, generatedAt, machine, selection, readings, cpuVerdict, gpuVerdict, gpuDeviceUtilizationPercent, thermalStates, phaseSeconds, method }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unreadableKeys, forKey: .unreadableKeys)
        try c.encode(appStatus, forKey: .appStatus)
        try c.encode(hvVMMPresent, forKey: .hvVMMPresent)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(summary, forKey: .summary)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(machine, forKey: .machine)
        try c.encode(selection, forKey: .selection)
        try c.encode(readings, forKey: .readings)
        try c.encode(cpuVerdict, forKey: .cpuVerdict)
        try c.encode(gpuVerdict, forKey: .gpuVerdict)
        try c.encode(gpuDeviceUtilizationPercent, forKey: .gpuDeviceUtilizationPercent)
        try c.encode(thermalStates, forKey: .thermalStates)
        try c.encode(phaseSeconds, forKey: .phaseSeconds)
        try c.encode(method, forKey: .method)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // Pure: require a complete selected family and a positive, larger response
    // to its intended load. No successful verdict for missing/constant sensors.
    static func verdict(keys: Set<String>, readings: [Reading], cpu: Bool) -> Verdict {
        let selected = readings.filter { keys.contains($0.key) }
        let valid = selected.filter { reading in
            reading.cpuDelta != nil && reading.gpuDelta != nil &&
                [reading.idle, reading.cpuLoaded, reading.gpuLoaded].allSatisfy {
                    guard let value = $0 else { return false }
                    return value.isFinite && (0.5...150).contains(value)
                }
        }
        let unavailable = keys.subtracting(valid.map(\.key)).sorted()
        let c = valid.isEmpty ? nil : valid.map { $0.cpuDelta! }.reduce(0, +) / Double(valid.count)
        let g = valid.isEmpty ? nil : valid.map { $0.gpuDelta! }.reduce(0, +) / Double(valid.count)
        let contradictions = valid.filter { cpu ? $0.cpuDelta! <= $0.gpuDelta! : $0.gpuDelta! <= $0.cpuDelta! }.map(\.key).sorted()
        let status: String
        if keys.count < 2 || !unavailable.isEmpty { status = "inconclusive" }
        else if let c, let g, cpu ? (c > 0 && c > g) : (g > 0 && g > c) { status = "pass" }
        else { status = "fail" }
        return Verdict(status: status, cpuLoadRise: c, gpuLoadRise: g, contradictingKeys: contradictions, unavailableKeys: unavailable)
    }
}

/// Synchronous diagnostic; call from a utility queue, never the UI/sampling queue.
/// Normal engine sampling continues, using its separate SMC connection.
public final class SensorReportRunner {
    private let reader: SMCDiagnosticReading?
    private let appStatus: SnapshotStatus?
    private var unreadable: Set<String> = []
    // Tests replace bounded load phases and spacing, exercising the same report/median path.
    var diagnosticPhase: ((String, SMCDiagnosticReading) throws -> [String: Double])?
    var diagnosticPause: ((Double) throws -> Void)?
    private let cancellation: SensorReportCancellation
    private let progress: (String, Double) -> Void
    private var thermalStates: [String] = []
    private var utilization: [Double] = []
    private let gpuUsage = GPUUsageSampler()
    private var phaseSeconds: [String: Double] = [:]
    private var sink = 0.0
    private let sinkLock = NSLock()

    public init(cancellation: SensorReportCancellation, appStatus: SnapshotStatus? = nil, reader: SMCDiagnosticReading? = nil, progress: @escaping (String, Double) -> Void = { _, _ in }) {
        self.cancellation = cancellation
        self.appStatus = appStatus; self.reader = reader
        self.progress = progress
    }

    public func run() throws -> SensorReport {
        try check()
        let info = SystemInfo()
        let sampler: SMCDiagnosticReading = reader ?? SMCTemperatureSampler(chipName: info.chipName)
        let inventory = sampler.inventory
        let selection = SMCSensorSelection.select(inventory: inventory, chipName: info.chipName)
        guard !inventory.isEmpty else { throw SensorReportError.unavailable }
        // Compile before baseline measurement so compiler work cannot warm a load phase.
        let metal = diagnosticPhase == nil ? try MetalBurner() : nil
        progress("idle", 0)
        let idle = try phase("idle", sampler)
        guard !idle.isEmpty else { throw SensorReportError.unavailable }
        let cpu = try diagnosticPhase?("cpu", sampler) ?? load(sampler, phase: "cpu", startProgress: 0.08, metal: nil)
        progress("cooldown", 0.40)
        // Retain the GPU pre-load baseline to expose residual CPU heat after cooldown.
        try pause(12)
        let gpuIdle = try phase("gpuIdle", sampler)
        let gpu = try diagnosticPhase?("gpu", sampler) ?? load(sampler, phase: "gpu", startProgress: 0.65, metal: metal)
        try check()
        let readings = inventory.sorted().map { key in
            let idleValue = unreadable.contains(key) ? nil : idle[key]
            let cpuValue = unreadable.contains(key) ? nil : cpu[key]
            let gpuIdleValue = unreadable.contains(key) ? nil : gpuIdle[key]
            let gpuValue = unreadable.contains(key) ? nil : gpu[key]
            return SensorReport.Reading(key: key, idle: idleValue, cpuLoaded: cpuValue, gpuIdle: gpuIdleValue, gpuLoaded: gpuValue,
                                 cpuDelta: delta(cpuValue, idleValue), gpuDelta: delta(gpuValue, idleValue))
        }
        let cpuVerdict = SensorReport.verdict(keys: selection.cpuKeys, readings: readings, cpu: true)
        let gpuVerdict = SensorReport.verdict(keys: selection.gpuKeys, readings: readings, cpu: false)
        let report = SensorReport(unreadableKeys: unreadable.sorted(), appStatus: appStatus, hvVMMPresent: SystemInfo.hvVMMPresent, schemaVersion: 2,
            summary: "\(info.chipName): CPU \(cpuVerdict.status), GPU \(gpuVerdict.status); \(readings.count) float temperature keys; CPU \(selection.cpuSource.rawValue), GPU \(selection.gpuSource.rawValue).",
            generatedAt: Date(), machine: machine(info), selection: selection, readings: readings,
            cpuVerdict: cpuVerdict, gpuVerdict: gpuVerdict, gpuDeviceUtilizationPercent: utilization,
            thermalStates: thermalStates, phaseSeconds: phaseSeconds,
            method: "Five-read medians, 0.5 s spacing. Each load lasts 20 s, hard deadline 25 s; loaded medians use the last five in-load reads. CPU uses all logical cores. GPU uses only finite Metal compute dispatches. Both deltas use the original idle median so family verdicts compare CPU-loaded versus GPU-loaded temperatures on the same baseline; a separate GPU pre-load median after 12 s cooldown is also retained. Verdict compares mean per-key rises over each selected family; individual contradictions are listed. Finite raw values, including powered-down sentinels, are retained; non-finite/unreadable values are null. Verdicts require all three compared phases within 0.5...150 C. Normal app sampling continues on its own queue. No network operations.")
        progress("complete", 1)
        return report
    }

    private func delta(_ loaded: Double?, _ idle: Double?) -> Double? {
        guard let loaded, let idle else { return nil }; return loaded - idle
    }
    private func check() throws {
        if cancellation.isCancelled { throw SensorReportError.cancelled }
        let state = ProcessInfo.processInfo.thermalState
        if state == .serious || state == .critical { throw SensorReportError.thermal }
        let name = state == .nominal ? "nominal" : "fair"
        if thermalStates.last != name { thermalStates.append(name) }
    }
    private func pause(_ seconds: Double) throws {
        if let diagnosticPause { try diagnosticPause(seconds); return }
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end { try check(); Thread.sleep(forTimeInterval: 0.1) }
    }
    private func phase(_ name: String, _ sampler: SMCDiagnosticReading) throws -> [String: Double] {
        try diagnosticPhase?(name, sampler) ?? median(sampler)
    }
    func read(_ sampler: SMCDiagnosticReading) throws -> [String: Double] {
        try check()
        let readings = sampler.readAll()
        var values: [String: Double] = [:]
        for (key, result) in readings {
            if case .success(let value) = result, value.isFinite { values[key] = value }
            else { unreadable.insert(key) }
        }
        // Missing rows are failures too: an injected reader cannot silently shrink inventory.
        unreadable.formUnion(sampler.inventory.subtracting(values.keys))
        return values
    }
    static func medians(_ samples: [[String: Double]]) -> [String: Double] {
        let keys = Set(samples.flatMap(\.keys))
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            let values = samples.compactMap { row -> Double? in
                guard let value = row[key], value.isFinite else { return nil }
                return value
            }.sorted()
            // All five reads must be finite. Preserve finite sentinels in the raw
            // report; verdicts independently reject implausible phase values.
            guard values.count == 5 else { return nil }
            return (key, values[2])
        })
    }
    func median(_ sampler: SMCDiagnosticReading) throws -> [String: Double] {
        var samples: [[String: Double]] = []
        for i in 0..<5 { samples.append(try read(sampler)); if i < 4 { try pause(0.5) } }
        return Self.medians(samples)
    }
    private func load(_ sampler: SMCDiagnosticReading, phase: String, startProgress: Double, metal: MetalBurner?) throws -> [String: Double] {
        try check()
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 20
        let hardDeadline = started + 25
        let stop = SensorReportCancellation()
        let group = DispatchGroup()
        defer { stop.cancel(); group.wait() }
        if metal == nil {
            for core in 0..<ProcessInfo.processInfo.activeProcessorCount {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    var value = Double(core) + 0.5
                    while ProcessInfo.processInfo.systemUptime < deadline && !stop.isCancelled && !self.cancellation.isCancelled {
                        for _ in 0..<4096 { value = sin(value) + cos(value) * 1.000001 }
                    }
                    self.sinkLock.lock(); self.sink += value; self.sinkLock.unlock()
                }
            }
        }
        var samples: [[String: Double]] = []
        var nextRead = started
        while ProcessInfo.processInfo.systemUptime < deadline {
            try check()
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextRead {
                let row = try read(sampler)
                samples.append(row); if samples.count > 5 { samples.removeFirst() }
                if metal != nil, let percent = gpuUsage.sampleGPU() { utilization.append(percent) }
                progress(phase, startProgress + min(1, (now - started) / 20) * 0.30)
                nextRead = now + 0.5
            }
            if let metal { try metal.step(cancellation: cancellation, hardDeadline: hardDeadline) }
            else { Thread.sleep(forTimeInterval: 0.02) }
        }
        stop.cancel(); group.wait()
        phaseSeconds[phase] = ProcessInfo.processInfo.systemUptime - started
        return Self.medians(samples)
    }
    private func machine(_ info: SystemInfo) -> SensorReport.Machine {
        func sys(_ key: String) -> String {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }
            var bytes = [UInt8](repeating: 0, count: size)
            guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "unavailable" }
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        func integer(_ key: String) -> Int {
            var value: Int32 = 0; var size = MemoryLayout<Int32>.size
            return sysctlbyname(key, &value, &size, nil, 0) == 0 ? Int(value) : 0
        }
        // Explicit environment metadata works for SSH/source builds; a packaged
        // build may provide these Info keys. Do not guess a commit from the cwd.
        let service = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        var productName = info.machineName
        if service != 0 {
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(service, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if let data = property as? Data { productName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
            else if let name = property as? String { productName = name }
        }
        let bundle = Bundle.main
        return .init(model: sys("hw.model"), productName: productName, chipName: info.chipName,
                     logicalCores: integer("hw.logicalcpu"), physicalCores: integer("hw.physicalcpu"),
                     macOS: ProcessInfo.processInfo.operatingSystemVersionString, osBuild: sys("kern.osversion"),
                     appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0 (source build)",
                     appCommit: ProcessInfo.processInfo.environment["MAC_MONITOR_COMMIT"] ?? bundle.object(forInfoDictionaryKey: "MonitorCommit") as? String ?? "unavailable")
    }
}

/// Same ALU workload as docs/research/gpuload.swift, run as finite
/// dispatches (1M threads × 20K iterations) so cancel/25 s deadline never waits
/// for an unbounded stream of research dispatches. No CPU burner in GPU phase.
private final class MetalBurner {
    let pipeline: MTLComputePipelineState
    let queue: MTLCommandQueue
    let buffer: MTLBuffer
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(length: 1048576 * 4, options: .storageModePrivate) else {
            throw SensorReportError.metal("Metal device or allocation unavailable")
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void burn(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = float(id) * 0.0001;
            for (int i = 0; i < 20000; i++) { x = fma(x, 1.000001, 0.0000001); x = sin(x) + cos(x); }
            out[id] = x;
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "burn") else { throw SensorReportError.metal("kernel unavailable") }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch { throw SensorReportError.metal(error.localizedDescription) }
        self.queue = queue; self.buffer = buffer
    }
    func step(cancellation: SensorReportCancellation, hardDeadline: Double) throws {
        guard !cancellation.isCancelled else { throw SensorReportError.cancelled }
        guard ProcessInfo.processInfo.systemUptime < hardDeadline else { throw SensorReportError.metal("25 s hard stop") }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw SensorReportError.metal("command allocation failed") }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1048576, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        // At most one finite command in flight. Stop submitting immediately on
        // cancellation; Metal has no API to cancel an already committed command.
        while command.status != .completed && command.status != .error {
            if cancellation.isCancelled { throw SensorReportError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= hardDeadline { throw SensorReportError.metal("25 s hard stop") }
            Thread.sleep(forTimeInterval: 0.001)
        }
        if command.status == .error { throw SensorReportError.metal(command.error?.localizedDescription ?? "execution failed") }
    }
}
