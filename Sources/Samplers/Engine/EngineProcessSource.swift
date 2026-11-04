import Foundation
import MonitorCore

/// Feed the complete process table through ProcessSampler without eagerly resolving
/// thousands of names. Root name resolution can spawn ps; only visible rows need it.
final class EngineProcessSource: ProcessSource, ProcessSourceStatusProviding {
    var psExecutable: String? {
        get { (source as? HybridProcessSource)?.psExecutable }
        set { (source as? HybridProcessSource)?.psExecutable = newValue }
    }
    var metricStatus: MetricStatus { (source as? ProcessSourceStatusProviding)?.metricStatus ?? .live(.libprocAndPS) }
    private let source: ProcessSource
    private var identities: [Int32: UInt64] = [:]
    private var names: [Int32: String] = [:]

    init(source: ProcessSource = HybridProcessSource()) { self.source = source }

    func read() -> ProcessReading? { normalize(source.read()) }

    /// Rebaseline readable processes without advancing the hybrid ps retry clock.
    func readBaseline() -> ProcessReading? {
        if let hybrid = source as? HybridProcessSource { return normalize(hybrid.readBaseline()) }
        return normalize(source.read())
    }

    private func normalize(_ raw: ProcessReading?) -> ProcessReading? {
        guard var reading = raw else { return nil }
        names = names.filter { reading.entries[$0.key]?.startTime == identities[$0.key] }
        identities = reading.entries.mapValues(\.startTime)
        reading.entries = reading.entries.mapValues { original in
            var entry = original
            // A nonnil placeholder prevents ProcessSampler's eager fallback lookup.
            entry.name = entry.name ?? names[entry.pid] ?? ""
            return entry
        }
        return reading
    }

    func name(for pid: Int32) -> String? {
        if let name = source.name(for: pid) {
            names[pid] = name
            return name
        }
        return names[pid]
    }
}
