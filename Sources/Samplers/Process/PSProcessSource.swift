import Foundation

/// All processes via `/bin/ps -axo` (setuid root, so it sees WindowServer and kernel_task).
/// CPU resolution is 10 ms (the TIME column).
public final class PSProcessSource: ProcessSource {
    public init() {}

    public func read() -> ProcessReading? {
        guard let r = PSRunner.run(.all, withName: true, withStartTime: true) else { return nil }
        let entries = PSParsing.parse(r.output, atNanos: r.midNanos, withStartTime: true)
        return entries.isEmpty ? nil : ProcessReading(entries: entries)
    }

    public func name(for pid: Int32) -> String? { nil } // ps entries always carry a name
}
