import Foundation
import Darwin

/// `sysctl(KERN_PROC_ALL)`: pid -> real uid for every process, readable or not (~0.6 ms).
/// Used to tell `ps -U` which users own the pids libproc cannot read.
final class KernelProcessTable {
    private var buffer = [UInt8]()

    func realUIDs(of pids: [Int32]) -> Set<UInt32> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        size += 64 * MemoryLayout<kinfo_proc>.stride   // table may grow between the two calls
        if buffer.count < size { buffer = [UInt8](repeating: 0, count: size) }
        var got = buffer.count
        let rc = buffer.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &got, nil, 0) }
        guard rc == 0 else { return [] }
        let want = Set(pids)
        var uids = Set<UInt32>()
        buffer.withUnsafeBytes { raw in
            let procs = raw.bindMemory(to: kinfo_proc.self)
            for i in 0..<(got / MemoryLayout<kinfo_proc>.stride) {
                let pid = procs[i].kp_proc.p_pid
                if want.contains(pid) { uids.insert(procs[i].kp_eproc.e_pcred.p_ruid) }
            }
        }
        return uids
    }
}
