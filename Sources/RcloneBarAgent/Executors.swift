import Foundation
import RcloneBarCore

/// 负责“真正启动一轮同步”的执行器。调度由 Daemon 负责。
protocol JobExecutor: AnyObject {
    var job: JobConfig { get }
    /// 退出码是否直接来自 rclone
    var exitCodeIsRclone: Bool { get }
    /// 启动一轮（不等待结束）
    func start(environment: [String: String]) throws
    /// 执行器自身进程（launchd 模式为 sync.py，direct 模式为子进程）是否在运行
    func runningPID() -> Int32?
    /// 一轮结束后的退出码
    func lastExitCode() -> Int32?
    /// 把下一轮需要的环境变量写入执行器（只在空闲时调用）。返回是否有改动。
    func applyEnvironment(_ env: [String: String]) throws -> Bool
}

enum ExecutorError: Error, CustomStringConvertible {
    case launchFailed(String)

    var description: String {
        switch self {
        case .launchFailed(let s): return s
        }
    }
}

/// 复用原有 LaunchAgent：plist 已去掉自动调度键，这里用 kickstart 按需启动。
/// 运行时的“负责进程”仍是原脚本的解释器，所以原有的文件访问授权继续有效。
final class LaunchdExecutor: JobExecutor {
    let job: JobConfig
    let exitCodeIsRclone = false
    private let managedEnvKeys = ["RCLONE_RC", "RCLONE_RC_ADDR", "RCLONE_RC_HTPASSWD", "RCLONE_TRANSFERS", "RCLONE_BWLIMIT"]

    private var runsBeforeStart: Int?

    init(job: JobConfig) { self.job = job }

    func start(environment: [String: String]) throws {
        runsBeforeStart = Launchctl.info(job.legacyLabel).runs
        let r = Launchctl.kickstart(job.legacyLabel)
        if !r.ok {
            throw ExecutorError.launchFailed("launchctl kickstart 失败（\(r.status)）：\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    func runningPID() -> Int32? {
        let info = Launchctl.info(job.legacyLabel)
        return info.running ? info.pid : nil
    }

    func lastExitCode() -> Int32? {
        let info = Launchctl.info(job.legacyLabel)
        guard !info.running else { return nil }
        // launchd 的运行计数没有增加，说明这次 kickstart 并没有真正运行，旧的退出码不能用
        if let before = runsBeforeStart, let now = info.runs, now <= before { return nil }
        return info.lastExitCode
    }

    func applyEnvironment(_ env: [String: String]) throws -> Bool {
        let url = URL(fileURLWithPath: job.legacyPlistPath)
        let current = try LaunchAgentPlist.load(url)
        let updated = current.onDemand(environment: env, removingEnvKeys: managedEnvKeys)
        if NSDictionary(dictionary: current.dict).isEqual(to: updated.dict) { return false }
        try updated.write(to: url)
        let r = Launchctl.reload(label: job.legacyLabel, plist: url.path)
        if !r.ok { throw ExecutorError.launchFailed("重新加载 \(job.legacyLabel) 失败：\(r.stderr)") }
        return true
    }
}

/// 由后台服务直接启动命令（参数数组，不经过 shell）。
final class DirectExecutor: JobExecutor {
    let job: JobConfig
    private var process: Process?
    private var logHandle: FileHandle?

    init(job: JobConfig) { self.job = job }

    var exitCodeIsRclone: Bool {
        guard let program = job.direct?.program else { return false }
        return URL(fileURLWithPath: program).lastPathComponent.hasPrefix("rclone")
    }

    func start(environment: [String: String]) throws {
        guard let cmd = job.direct else { throw ExecutorError.launchFailed("jobs.json 中缺少 direct 命令定义") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.program)
        p.arguments = cmd.arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in cmd.environment { env[k] = v }
        for (k, v) in environment { env[k] = v }
        p.environment = env
        if let wd = cmd.workingDirectory { p.currentDirectoryURL = URL(fileURLWithPath: wd) }
        p.standardInput = FileHandle.nullDevice
        if let logPath = cmd.logFile ?? job.logFiles.first {
            let url = URL(fileURLWithPath: logPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logPath) { _ = FileManager.default.createFile(atPath: logPath, contents: nil) }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            p.standardOutput = h
            p.standardError = h
            logHandle = h
        } else {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        do { try p.run() } catch {
            throw ExecutorError.launchFailed("无法启动 \(cmd.program)：\(error.localizedDescription)")
        }
        process = p
    }

    func runningPID() -> Int32? {
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    func lastExitCode() -> Int32? {
        guard let p = process, !p.isRunning else { return nil }
        try? logHandle?.close()
        logHandle = nil
        return p.terminationStatus
    }

    func applyEnvironment(_ env: [String: String]) throws -> Bool { false }
}
