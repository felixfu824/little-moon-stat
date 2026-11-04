import Foundation
import Darwin
import MonitorCore

/// Spawns `/bin/ps` with `posix_spawn` and returns its stdout. Cheaper than `Foundation.Process`.
public enum PSRunner {
    public struct Result {
        public var output: String
        public var startNanos: UInt64
        public var endNanos: UInt64
        /// Midpoint of the spawn: the best estimate of when ps read the kernel's process table.
        public var midNanos: UInt64 { startNanos / 2 + endNanos / 2 }
    }

    public struct Outcome {
        public var result: Result?
        public var fault: MetricFault?
    }

    public enum Scope {
        case all                 // -ax: every process (~36 ms CPU for 1800 pids without comm)
        case users([UInt32])     // -U: only these real uids; cost scales with matches
        case pid(Int32)          // -p: ONE pid (~1.8 ms). `-p a,b` is pathological (~140 ms): never use it.
    }

    /// Column order is pid, rss (KB), time, [lstart], [comm]. `comm` doubles the cost of a full scan.
    public static func run(_ scope: Scope, withName: Bool, withStartTime: Bool = false) -> Result? {
        runStatus(scope, withName: withName, withStartTime: withStartTime).result
    }

    public static func runStatus(_ scope: Scope, withName: Bool, withStartTime: Bool = false,
                                 executable: String? = nil, timeout: Double = 1.5, onSpawn: ((pid_t) -> Void)? = nil) -> Outcome {
        let cols = "pid=,rss=,time=" + (withStartTime ? ",lstart=" : "") + (withName ? ",comm=" : "")
        var args = ["ps", "-ww"]
        switch scope {
        case .all: args += ["-axo", cols]
        case .users(let uids):
            if uids.isEmpty { return Outcome(result: nil, fault: .psUnavailable) }
            args += ["-U", uids.map(String.init).joined(separator: ","), "-o", cols]
        case .pid(let pid): args += ["-p", String(pid), "-o", cols]
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return Outcome(result: nil, fault: .psUnavailable) }
        let readFD = fds[0], writeFD = fds[1]
        // Close-on-exec for our read end; the child gets stdout via dup2.
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        // Keep lstart in English while letting ps emit readable UTF-8 comm
        // paths. The C locale vis-escapes non-ASCII bytes (including M-/),
        // which can otherwise be mistaken for path separators.
        let envp: [UnsafeMutablePointer<CChar>?] = [strdup("LC_ALL=en_US.UTF-8"), strdup("PATH=/usr/bin:/bin"), nil]
        defer { envp.forEach { free($0) } }

        let start = monotonicNanos()
        var pid: pid_t = 0
        let path = executable ?? ProcessInfo.processInfo.environment["MAC_MONITOR_PS_EXECUTABLE"] ?? "/bin/ps"
        let rc = posix_spawn(&pid, path, &actions, nil, cArgs, envp)
        close(writeFD)
        guard rc == 0 else { close(readFD); return Outcome(result: nil, fault: .psUnavailable) }

        onSpawn?(pid)
        var data = Data()
        data.reserveCapacity(128 * 1024)
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = start + UInt64(max(0.01, timeout) * 1e9)
        var timedOut = false
        var transportFailed = false
        _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
        while true {
            let now = monotonicNanos()
            if now >= deadline { timedOut = true; break }
            var descriptor = pollfd(fd: readFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = Int32(max(1, (deadline - now) / 1_000_000))
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { transportFailed = true; break }
            if ready == 0 { timedOut = true; break }
            let n = read(readFD, &buf, buf.count)
            if n > 0 { data.append(contentsOf: buf[0..<n]) }
            else if n == 0 { break }
            else if errno == EINTR || errno == EAGAIN { continue }
            else { transportFailed = true; break }
        }
        close(readFD)
        var status: Int32 = 0
        // EOF does not guarantee child exit. Never block waitpid beyond the same deadline.
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || (waited < 0 && errno != EINTR) { break }
            if waited < 0 { continue }
            if timedOut || monotonicNanos() >= deadline {
                timedOut = true
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                break
            }
            var unused = pollfd(fd: -1, events: 0, revents: 0)
            _ = poll(&unused, 0, 1)
        }
        if timedOut { return Outcome(result: nil, fault: .timeout) }
        if transportFailed { return Outcome(result: nil, fault: .psUnavailable) }
        let end = monotonicNanos()
        // `ps -p` exits 1 when some pids vanished but still prints the rest, so ignore the status.
        let output = String(decoding: data, as: UTF8.self)
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Darwin ps exits 1 for an exited PID. A signal/other exit is a real failure.
            if case .pid = scope, status == 0 || status == (1 << 8) {
                return Outcome(result: Result(output: "", startNanos: start, endNanos: end), fault: nil)
            }
            return Outcome(result: nil, fault: .psUnavailable)
        }
        return Outcome(result: Result(output: output, startNanos: start, endNanos: end), fault: nil)
    }
}
