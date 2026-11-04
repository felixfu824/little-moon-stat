import AppKit
import Darwin

/// Hold the descriptor until process exit. Never unlink the file: waiters must
/// always contend on the same inode, including direct executable launches.
final class SingleInstance {
    private let descriptor: Int32

    init?() {
        let isolated = ProcessInfo.processInfo.environment["MAC_MONITOR_SETTINGS_DOMAIN"]
        let directory = isolated.map { FileManager.default.temporaryDirectory.appendingPathComponent($0.filter { $0.isLetter || $0.isNumber || $0 == "." }) }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.felixfu.MacMonitorPanel", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        let fd = open(directory.appendingPathComponent("instance.lock").path,
                          O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        // A concurrent newcomer has not finished launching yet; the file lock
        // chooses its winner. This check also catches an older bundled build
        // that predates the lock, without rejecting the winning newcomer.
        let me = ProcessInfo.processInfo.processIdentifier
        if isolated == nil && NSRunningApplication.runningApplications(withBundleIdentifier: "com.felixfu.MacMonitorPanel")
            .contains(where: { $0.processIdentifier != me && !$0.isTerminated && $0.isFinishedLaunching }) {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
