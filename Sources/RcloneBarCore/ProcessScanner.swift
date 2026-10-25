import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    /// 完整 argv（仅对需要的进程读取）；以数组保存，中文与空格路径不会被拆错。
    public var arguments: [String]
}

/// 列出当前用户的进程。macOS 用 sysctl(KERN_PROC_ALL / KERN_PROCARGS2)，Linux 用 /proc。
public enum ProcessScanner {
    /// - Parameter wantArguments: 根据进程名决定是否读取 argv（读取 argv 有额外开销）
    public static func list(wantArguments: (String) -> Bool = { _ in true }) -> [ProcessEntry] {
        #if canImport(Darwin)
        return darwinList(wantArguments: wantArguments)
        #else
        return linuxList(wantArguments: wantArguments)
        #endif
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    @discardableResult
    public static func sendSignal(_ signal: Int32, to pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, signal) == 0
    }

    /// 某个进程的所有后代
    public static func descendants(of root: Int32, in entries: [ProcessEntry]) -> [ProcessEntry] {
        var children: [Int32: [ProcessEntry]] = [:]
        for e in entries { children[e.ppid, default: []].append(e) }
        var result: [ProcessEntry] = []
        var queue = [root]
        var seen: Set<Int32> = [root]
        while let p = queue.popLast() {
            for c in children[p] ?? [] where !seen.contains(c.pid) {
                seen.insert(c.pid)
                result.append(c)
                queue.append(c.pid)
            }
        }
        return result
    }

    public static func isRcloneName(_ name: String) -> Bool {
        name == "rclone" || name.hasPrefix("rclone")
    }

    // MARK: Darwin

    #if canImport(Darwin)
    private static func darwinList(wantArguments: (String) -> Bool) -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / stride
        var result: [ProcessEntry] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            var p = procs[i]
            let pid = p.kp_proc.p_pid
            if pid <= 0 { continue }
            let name = withUnsafeBytes(of: &p.kp_proc.p_comm) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                let len = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[0..<len], as: UTF8.self)
            }
            let args = wantArguments(name) ? (arguments(of: pid) ?? []) : []
            result.append(ProcessEntry(pid: pid, ppid: p.kp_eproc.e_ppid, name: name, arguments: args))
        }
        return result
    }

    public static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var idx = MemoryLayout<Int32>.size
        // 跳过 exec_path 及其后的填充 NUL
        while idx < size && buffer[idx] != 0 { idx += 1 }
        while idx < size && buffer[idx] == 0 { idx += 1 }
        var args: [String] = []
        while args.count < Int(argc) && idx < size {
            let start = idx
            while idx < size && buffer[idx] != 0 { idx += 1 }
            args.append(String(decoding: buffer[start..<idx], as: UTF8.self))
            idx += 1
        }
        return args
    }
    #else
    private static func linuxList(wantArguments: (String) -> Bool) -> [ProcessEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: "/proc") else { return [] }
        let myUID = getuid()
        var result: [ProcessEntry] = []
        for n in names {
            guard let pid = Int32(n) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: "/proc/\(n)"),
                  let owner = attrs[.ownerAccountID] as? NSNumber, owner.uint32Value == myUID else { continue }
            guard let stat = try? String(contentsOfFile: "/proc/\(n)/stat", encoding: .utf8),
                  let open = stat.firstIndex(of: "("), let close = stat.lastIndex(of: ")") else { continue }
            let name = String(stat[stat.index(after: open)..<close])
            let rest = stat[stat.index(close, offsetBy: 2)...].split(separator: " ")
            let ppid = rest.count > 1 ? Int32(rest[1]) ?? 0 : 0
            let args = wantArguments(name) ? (arguments(of: pid) ?? []) : []
            result.append(ProcessEntry(pid: pid, ppid: ppid, name: name, arguments: args))
        }
        return result
    }

    public static func arguments(of pid: Int32) -> [String]? {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty else { return nil }
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }
    #endif
}

/// 判断某个 rclone 进程是否为针对指定任务目录的 bisync。
public enum BisyncMatcher {
    public static func normalize(_ path: String) -> String {
        var p = path.precomposedStringWithCanonicalMapping
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func isBisync(_ args: [String]) -> Bool {
        args.dropFirst().prefix(8).contains("bisync") || args.contains("bisync")
    }

    public static func matches(_ args: [String], job: JobConfig) -> Bool {
        guard isBisync(args) else { return false }
        let local = normalize(job.localPath)
        let remote = normalize(job.remotePath)
        return args.contains { arg in
            let a = normalize(arg)
            return a == local || a == remote
        }
    }

    /// 当前用户下处理该任务目录的所有 bisync 进程
    public static func bisyncProcesses(for job: JobConfig, in entries: [ProcessEntry]) -> [ProcessEntry] {
        entries.filter { ProcessScanner.isRcloneName($0.name) && matches($0.arguments, job: job) }
    }
}
