import Foundation

// The source/quality contract for every metric.
// Owner's intent: when a metric cannot be measured reliably, use a more generic source or show it as
// unavailable; never show a wrong number confidently.

/// How far a displayed value can be trusted. Precedence per metric: unavailable > estimated > live.
public enum MetricQuality: String, Sendable, Codable, CaseIterable {
    case live, estimated, unavailable
}

/// Where a value came from. The estimated rungs are `genericFamily`, `libprocOnly` and `builtInDefault`.
public enum MetricSource: String, Sendable, Codable, CaseIterable {
    case chipMap, genericFamily            // temperatures
    case hostProcessorInfo, ioAccelerator, hostStatistics, volumeCapacity, processInfo
    case libprocAndPS, libprocOnly         // processes
    case deviceTree, sysctl, builtInDefault // identity
    case none

    /// A value from this source is a fallback rung, shown as estimated.
    public var isFallback: Bool { self == .genericFamily || self == .libprocOnly || self == .builtInDefault }
}

public enum MetricFault: String, Sendable, Codable, CaseIterable {
    case firstSample, apiError, serviceUnavailable, permission, virtualMachine, outOfRange, nonFinite,
         stuck, jump, familyMissing, wakeTransient, timeout, psUnavailable, unknownChip
}

public struct MetricStatus: Sendable, Equatable, Codable {
    public var quality: MetricQuality
    public var source: MetricSource
    public var fault: MetricFault?

    public init(quality: MetricQuality, source: MetricSource, fault: MetricFault? = nil) {
        self.quality = quality
        self.source = source
        self.fault = fault
    }

    /// Default for fixtures and code paths that predate the contract.
    public static let live = MetricStatus(quality: .live, source: .none)
    public static func live(_ source: MetricSource) -> Self { Self(quality: .live, source: source) }
    public static func estimated(_ source: MetricSource, fault: MetricFault? = nil) -> Self {
        Self(quality: .estimated, source: source, fault: fault)
    }
    public static func unavailable(_ fault: MetricFault, source: MetricSource = .none) -> Self {
        Self(quality: .unavailable, source: source, fault: fault)
    }

    /// Compact form for publication keys and `STATUS` log lines: `quality:fault` (`-` when no fault).
    public var key: String { "\(quality.rawValue):\(fault?.rawValue ?? "-")" }
}

/// The metrics a status can attach to, in status-line priority order (WP-V §5).
public enum StatusMetric: String, Sendable, CaseIterable {
    case cpuTemp, gpuTemp, cpuPercent, gpuPercent, processes, memory, disk, thermal, identity
}

/// One status per Snapshot metric.
public struct SnapshotStatus: Sendable, Equatable, Codable {
    public var cpuPercent: MetricStatus
    public var gpuPercent: MetricStatus
    public var cpuTemp: MetricStatus
    public var gpuTemp: MetricStatus
    public var memory: MetricStatus
    public var disk: MetricStatus
    public var processes: MetricStatus
    public var thermal: MetricStatus
    public var identity: MetricStatus

    public init(cpuPercent: MetricStatus = .live, gpuPercent: MetricStatus = .live, cpuTemp: MetricStatus = .live,
                gpuTemp: MetricStatus = .live, memory: MetricStatus = .live, disk: MetricStatus = .live,
                processes: MetricStatus = .live, thermal: MetricStatus = .live, identity: MetricStatus = .live) {
        self.cpuPercent = cpuPercent
        self.gpuPercent = gpuPercent
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.memory = memory
        self.disk = disk
        self.processes = processes
        self.thermal = thermal
        self.identity = identity
    }

    public static let live = SnapshotStatus()

    public subscript(metric: StatusMetric) -> MetricStatus {
        get {
            switch metric {
            case .cpuPercent: return cpuPercent
            case .gpuPercent: return gpuPercent
            case .cpuTemp: return cpuTemp
            case .gpuTemp: return gpuTemp
            case .memory: return memory
            case .disk: return disk
            case .processes: return processes
            case .thermal: return thermal
            case .identity: return identity
            }
        }
        set {
            switch metric {
            case .cpuPercent: cpuPercent = newValue
            case .gpuPercent: gpuPercent = newValue
            case .cpuTemp: cpuTemp = newValue
            case .gpuTemp: gpuTemp = newValue
            case .memory: memory = newValue
            case .disk: disk = newValue
            case .processes: processes = newValue
            case .thermal: thermal = newValue
            case .identity: identity = newValue
            }
        }
    }

    /// The single highest-priority non-live metric for the popover status line (identity excluded), or nil.
    public var statusLine: (metric: StatusMetric, status: MetricStatus)? {
        for metric in StatusMetric.allCases where metric != .identity {
            let status = self[metric]
            if status.quality != .live { return (metric, status) }
        }
        return nil
    }

    /// `quality:fault` per metric, in `StatusMetric` order.
    public var keys: [String] { StatusMetric.allCases.map { self[$0].key } }
}

/// One sampler read. `value == nil` is a miss; `fault` says why (or, with a value, why it is estimated).
public struct Sample<Value: Sendable>: Sendable {
    public var value: Value?
    public var source: MetricSource
    public var fault: MetricFault?

    public init(value: Value?, source: MetricSource, fault: MetricFault? = nil) {
        self.value = value
        self.source = source
        self.fault = fault
    }

    public static func failure(_ fault: MetricFault, source: MetricSource = .none) -> Self {
        Self(value: nil, source: source, fault: fault)
    }

    /// Quality of this read on its own: nil value → unavailable; a fallback source or a fault → estimated.
    public var quality: MetricQuality {
        guard value != nil else { return .unavailable }
        return source.isFallback || fault != nil ? .estimated : .live
    }
}

/// CPU and GPU temperature families are read in one SMC pass but rung down independently.
public struct TemperatureSample: Sendable {
    public var cpu: Sample<TempStat>
    public var gpu: Sample<TempStat>

    public init(cpu: Sample<TempStat>, gpu: Sample<TempStat>) {
        self.cpu = cpu
        self.gpu = gpu
    }
}

// MARK: - Detectors (pure; state resets on wake and on resume after a pause longer than 10 s)

/// Temperatures: a raw family peak that moves more than `threshold` °C between two reads is held for one tick.
/// The read after a hold is always accepted: it either confirms the jump (real) or returns near the held value
/// (the suspect was a glitch and is discarded). Real dies ramp ≤ 25 °C per 2 s, so the cost is one 2 s lag.
public struct JumpGuard: Sendable, Equatable {
    public var threshold: Double
    private var last: Double?
    private var holding = false

    public init(threshold: Double = 40) { self.threshold = threshold }

    public enum Verdict: Sendable, Equatable { case accept, hold }

    /// Feed every non-nil raw read. `.hold` means: treat this tick as a miss with `fault = .jump`.
    public mutating func check(_ peak: Double) -> Verdict {
        guard peak.isFinite else { return .accept }
        guard let previous = last, !holding else {
            holding = false
            last = peak
            return .accept
        }
        if abs(peak - previous) > threshold {
            holding = true
            return .hold
        }
        last = peak
        return .accept
    }

    public mutating func reset() { last = nil; holding = false }
}

/// Temperatures: raw peak and average bit-identical for `windowTicks` consecutive reads while CPU % spanned
/// ≥ `minimumCPUSpan` points, or for `maximumTicks` reads regardless, means a frozen transport.
/// SMC floats carry ≥ 0.01 °C noise, so identical bits for minutes are not a steady machine.
public struct StuckDetector: Sendable, Equatable {
    public var windowTicks: Int
    public var maximumTicks: Int
    public var minimumCPUSpan: Double
    private var lastPeak: Double?
    private var lastAverage: Double?
    private var repeats = 0
    private var cpuLow = Double.infinity
    private var cpuHigh = -Double.infinity
    public private(set) var isStuck = false

    /// Defaults: 90 fast ticks (3 min) with a 25-point CPU swing, or 300 ticks (10 min).
    /// Tests and `verify_app.sh` shorten both via the initializer (the engine may read `MAC_MONITOR_STUCK_TICKS`).
    public init(windowTicks: Int = 90, maximumTicks: Int = 300, minimumCPUSpan: Double = 25) {
        self.windowTicks = windowTicks
        self.maximumTicks = maximumTicks
        self.minimumCPUSpan = minimumCPUSpan
    }

    public enum Event: Sendable, Equatable {
        case normal
        /// Entered the stuck state on this read: show unavailable(.stuck) and reset the sampler once.
        case becameStuck
        /// Still stuck: keep showing unavailable(.stuck); do not reset again.
        case stillStuck
    }

    /// Feed every raw read with the CPU % of the same tick (nil when not sampled).
    public mutating func observe(peak: Double, average: Double, cpuPercent: Double?) -> Event {
        if peak.bitPattern == lastPeak?.bitPattern, average.bitPattern == lastAverage?.bitPattern {
            repeats += 1
        } else {
            lastPeak = peak
            lastAverage = average
            repeats = 1
            cpuLow = .infinity
            cpuHigh = -.infinity
            isStuck = false
        }
        if let cpuPercent, cpuPercent.isFinite {
            cpuLow = min(cpuLow, cpuPercent)
            cpuHigh = max(cpuHigh, cpuPercent)
        }
        let swung = cpuHigh - cpuLow >= minimumCPUSpan
        let stuck = repeats >= maximumTicks || (repeats >= windowTicks && swung)
        guard stuck else { return .normal }
        if isStuck { return .stillStuck }
        isStuck = true
        return .becameStuck
    }

    public mutating func reset() {
        lastPeak = nil
        lastAverage = nil
        repeats = 0
        cpuLow = .infinity
        cpuHigh = -.infinity
        isStuck = false
    }
}

/// Backoff for expensive retries (SMC reopen, IOAccelerator matching, `/bin/ps`), counted in ticks of the
/// owning cadence: no timers, no threads. Attempt k after failure k waits `offsets[k-1]` ticks; the last
/// offset repeats. Default `1, 1, 1, 15, 15, 15, 150` = three immediate retries, three at 30 s, then every 5 min
/// on the 2 s fast tick.
public struct RetrySchedule: Sendable, Equatable {
    public static let standard = [1, 1, 1, 15, 15, 15, 150]
    public let offsets: [Int]
    public private(set) var failures = 0
    private var wait = 0

    public init(offsets: [Int] = RetrySchedule.standard) {
        precondition(!offsets.isEmpty && offsets.allSatisfy { $0 >= 1 }, "offsets must be ≥ 1")
        self.offsets = offsets
    }

    /// True while at least one failure has not been followed by a success.
    public var isBackingOff: Bool { failures > 0 }

    /// Call once per owning tick. True when the expensive operation should be attempted on this tick.
    public mutating func shouldAttempt() -> Bool {
        guard failures > 0 else { return true }
        if wait > 0 { wait -= 1 }
        return wait == 0
    }

    public mutating func recordFailure() {
        wait = offsets[min(failures, offsets.count - 1)]
        failures += 1
    }

    public mutating func recordSuccess() {
        failures = 0
        wait = 0
    }
}
