import Foundation
import Darwin

/// Only one Ampere process may manage charge control on a Mac. With fast
/// user switching two logged-in accounts can each be running the app, and
/// once both have granted admin access both are authorized. Left alone they
/// would fight: each launch cleanup retires the other's watchdog and rewrites
/// the charging key, and both keep enforcing their own bounds. The process
/// that started first keeps control; a later one stands by until it is gone.
enum InstanceGuard {
    struct Instance: Equatable {
        let pid: pid_t
        let uid: uid_t
        let startSeconds: Int
        let startMicroseconds: Int32

        /// Earlier start wins; the PID breaks ties deterministically.
        func startedBefore(_ other: Instance) -> Bool {
            if startSeconds != other.startSeconds { return startSeconds < other.startSeconds }
            if startMicroseconds != other.startMicroseconds {
                return startMicroseconds < other.startMicroseconds
            }
            return pid < other.pid
        }

        /// How the panel names the process that holds charge control.
        var owner: String {
            if uid == getuid() { return "another copy of Ampere in this account" }
            if let entry = getpwuid(uid) {
                return "Ampere running as \(String(cString: entry.pointee.pw_name))"
            }
            return "Ampere running as uid \(uid)"
        }
    }

    /// The process name as the kernel reports it: the executable's file
    /// name, truncated to 16 characters.
    static let processName = "Ampere"

    /// Every process on this Mac with the app's name, for every user.
    static func runningInstances(named name: String = processName) -> [Instance] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Headroom: processes can start between the size query and the read.
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = table.count * stride
        guard sysctl(&mib, UInt32(mib.count), &table, &size, nil, 0) == 0 else { return [] }
        return table.prefix(size / stride).compactMap { entry in
            var comm = entry.kp_proc.p_comm
            let capacity = MemoryLayout.size(ofValue: comm)
            let command = withUnsafePointer(to: &comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            guard command == name else { return nil }
            let start = entry.kp_proc.p_un.__p_starttime
            return Instance(pid: entry.kp_proc.p_pid, uid: entry.kp_eproc.e_ucred.cr_uid,
                            startSeconds: start.tv_sec, startMicroseconds: start.tv_usec)
        }
    }

    /// The running instance that outranks this process, or nil when this
    /// process should manage charge control. A process that cannot find
    /// itself in the table (a test host, for instance) never stands by.
    static func competingInstance() -> Instance? {
        let instances = runningInstances()
        let me = getpid()
        guard let mine = instances.first(where: { $0.pid == me }) else { return nil }
        return instances.filter { $0.pid != me && $0.startedBefore(mine) }
            .min { $0.startedBefore($1) }
    }
}
