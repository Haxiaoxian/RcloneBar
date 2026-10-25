import Foundation

public enum InstallError: Error, CustomStringConvertible {
    case blocked([String])
    case failed(String)

    public var description: String {
        switch self {
        case .blocked(let r): return "无法继续：\n" + r.map { "  - " + $0 }.joined(separator: "\n")
        case .failed(let s): return "执行失败：\(s)"
        }
    }
}

/// 接管（安全交接）与回退。
///
/// 接管后的结构：
/// - com.zhuke.rclonebar.agent：唯一调度者，按设置的间隔用 launchctl kickstart 启动任务；
/// - com.zhuke.rclone-bisync.{vault,projects}：保留为“执行器”（仍运行原 sync.py），
///   去掉 StartInterval/RunAtLoad 等自动调度键，并注入 RC 相关环境变量。
/// 这样保留了原有脚本的全部参数、日志位置与系统授权（完全磁盘访问等）。
public struct Installer {
    public let paths: AppPaths
    public let useLaunchctl: Bool
    public let log: (String) -> Void

    public init(paths: AppPaths = AppPaths(), useLaunchctl: Bool = Launchctl.isAvailable, log: @escaping (String) -> Void = { print($0) }) {
        self.paths = paths
        self.useLaunchctl = useLaunchctl
        self.log = log
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: paths.installRecordFile.path) }

    // MARK: 接管

    public func install(agentBinary: URL, jobs inputJobs: [JobConfig], agentVersion: String, dryRun: Bool) throws {
        let fm = FileManager.default
        try paths.ensureBaseDirectories()
        let report = Inspector.inspect(paths: paths, jobs: inputJobs)
        if !report.blockers.isEmpty { throw InstallError.blocked(report.blockers) }
        if report.anyJobRunning {
            throw InstallError.blocked(["当前有同步正在运行。为避免中断，请等待本轮结束后再接管（不会强行重启正在运行的同步）。"])
        }
        for w in report.warnings { log("⚠︎ " + w) }

        if isInstalled {
            log("已接管过，只更新后台服务程序与 plist，不再改动原 LaunchAgent。")
            try installAgent(binary: agentBinary, dryRun: dryRun)
            return
        }

        // 1. 备份（不触碰 bisync 历史、访问检查标记与备份目录）
        let stamp = Self.stamp()
        let backup = paths.backupsDir.appendingPathComponent("handoff-\(stamp)", isDirectory: true)
        log("备份现有配置到：\(backup.path)")
        if !dryRun {
            try fm.createDirectory(at: backup.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)
            try fm.createDirectory(at: backup.appendingPathComponent("state"), withIntermediateDirectories: true)
            if fm.fileExists(atPath: paths.legacyScript.path) {
                try fm.copyItem(at: paths.legacyScript, to: backup.appendingPathComponent("sync.py"))
            }
        }

        // 2. RC 认证
        if !dryRun { try RCCredentials.loadOrCreate(paths: paths) }
        log("RC 认证：htpasswd 位于 \(paths.htpasswdFile.path)（0600，只含哈希）")

        // 3. 任务定义
        var jobs = inputJobs
        var legacyEntries: [InstallRecord.LegacyEntry] = []
        for i in jobs.indices {
            let r = report.jobs.first { $0.id == jobs[i].id }
            jobs[i].launchMode = .launchd
            jobs[i].bisyncWorkdir = r?.bisyncWorkdir ?? jobs[i].bisyncWorkdir
            jobs[i].scriptHasRecover = report.script?.flags["--recover"]
            for p in [r?.standardOutPath, r?.standardErrorPath].compactMap({ $0 }) where !jobs[i].logFiles.contains(p) {
                jobs[i].logFiles.append(p)
            }
            let plistURL = URL(fileURLWithPath: jobs[i].legacyPlistPath)
            let bak = backup.appendingPathComponent("LaunchAgents/\(plistURL.lastPathComponent)")
            if !dryRun {
                try fm.copyItem(at: plistURL, to: bak)
                let st = URL(fileURLWithPath: jobs[i].statusFile)
                if fm.fileExists(atPath: st.path) {
                    try? fm.copyItem(at: st, to: backup.appendingPathComponent("state/\(jobs[i].id)-status.json"))
                }
            }
            legacyEntries.append(.init(label: jobs[i].legacyLabel, plistPath: plistURL.path, backupPath: bak.path,
                                       wasLoaded: r?.launchdLoaded ?? false, wasDisabled: r?.disabled))
        }

        var settings = JSONStore.read(Settings.self, from: paths.settingsFile) ?? Settings()
        if !fm.fileExists(atPath: paths.settingsFile.path),
           let interval = report.jobs.compactMap(\.startInterval).min() {
            settings.intervalMinutes = max(1, Int((Double(interval) / 60).rounded()))
            log("沿用原同步间隔：\(settings.intervalMinutes) 分钟")
        }
        if !dryRun {
            try JSONStore.write(JobsFile(jobs: jobs), to: paths.jobsFile)
            try JSONStore.write(settings, to: paths.settingsFile)
        }
        log("写入任务定义：\(paths.jobsFile.path)")

        // 4. 把原 LaunchAgent 改为按需执行（失败则逐个恢复）
        var converted: [(JobConfig, URL)] = []
        do {
            for job in jobs {
                let plistURL = URL(fileURLWithPath: job.legacyPlistPath)
                let original = try LaunchAgentPlist.load(plistURL)
                let env = rcEnvironment(port: job.rcPort, htpasswdPath: paths.htpasswdFile.path).merging(settings.runEnvironment()) { $1 }
                let updated = original.onDemand(environment: env)
                log("改写 \(plistURL.lastPathComponent)：移除自动调度键，注入 RC 环境变量（端口 \(job.rcPort)）")
                if dryRun { continue }
                try ensureIdle(job)
                try updated.write(to: plistURL)
                converted.append((job, plistURL))
                if useLaunchctl {
                    if Launchctl.isDisabled(job.legacyLabel) == true {
                        log("\(job.legacyLabel) 原先处于禁用状态，已启用（否则无法按需启动）")
                        _ = Launchctl.enable(job.legacyLabel)
                    }
                    let r = Launchctl.reload(label: job.legacyLabel, plist: plistURL.path)
                    if !r.ok { throw InstallError.failed("重新加载 \(job.legacyLabel) 失败：\(r.stderr)") }
                }
            }
        } catch {
            log("出现错误，正在恢复已改写的 LaunchAgent……")
            for (job, url) in converted {
                if let entry = legacyEntries.first(where: { $0.label == job.legacyLabel }) {
                    _ = try? fm.removeItem(at: url)
                    _ = try? fm.copyItem(at: URL(fileURLWithPath: entry.backupPath), to: url)
                    if useLaunchctl { _ = Launchctl.reload(label: job.legacyLabel, plist: url.path) }
                }
            }
            throw error
        }

        // 5. 后台服务
        try installAgent(binary: agentBinary, dryRun: dryRun)

        if !dryRun {
            let record = InstallRecord(installedAt: Date(), backupDir: backup.path, legacy: legacyEntries, agentVersion: agentVersion)
            try JSONStore.write(record, to: paths.installRecordFile)
        }
        log(dryRun ? "（演练模式，未做任何修改）" : "接管完成。原 LaunchAgent 已不再自动调度，由 RcloneBar 后台服务统一调度。")
    }

    private func ensureIdle(_ job: JobConfig) throws {
        let running = useLaunchctl && Launchctl.info(job.legacyLabel).running
        let bisync = BisyncMatcher.bisyncProcesses(for: job, in: ProcessScanner.list { ProcessScanner.isRcloneName($0) })
        if running || !bisync.isEmpty {
            throw InstallError.blocked(["\(job.displayName) 刚刚开始了一轮同步，已停止接管以免中断它。请稍后重试。"])
        }
    }

    public func installAgent(binary: URL, dryRun: Bool) throws {
        let fm = FileManager.default
        let target = paths.installedAgentBinary
        log("安装后台服务程序：\(target.path)")
        if !dryRun {
            try fm.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
            if binary.standardizedFileURL.path != target.standardizedFileURL.path {
                let tmp = paths.binDir.appendingPathComponent(".rclonebar-agent.new")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: binary, to: tmp)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
                if rename(tmp.path, target.path) != 0 { throw InstallError.failed("无法替换 \(target.path)") }
            }
        }
        var env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        // 测试用的隔离变量（正常使用时不存在）
        for key in ["RCLONEBAR_HOME", "RCLONEBAR_AGENT_LABEL", "RCLONEBAR_RCLONE", "RCLONEBAR_TICK"] {
            if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { env[key] = v }
        }
        let dict: [String: Any] = [
            "Label": AppPaths.agentLabel,
            "ProgramArguments": [target.path, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "AbandonProcessGroup": true,
            "EnvironmentVariables": env,
            "StandardOutPath": paths.logsDir.appendingPathComponent("agent.stdout.log").path,
            "StandardErrorPath": paths.logsDir.appendingPathComponent("agent.stdout.log").path,
        ]
        log("写入 \(paths.agentPlist.path)")
        if dryRun { return }
        try fm.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
        try LaunchAgentPlist(dict: dict).write(to: paths.agentPlist)
        if useLaunchctl {
            // 后台服务重启不影响正在运行的同步：同步由各自的 LaunchAgent 执行
            let r = Launchctl.reload(label: AppPaths.agentLabel, plist: paths.agentPlist.path)
            if !r.ok { throw InstallError.failed("加载后台服务失败：\(r.stderr)") }
        }
    }

    // MARK: 回退

    public func uninstall(dryRun: Bool) throws {
        let fm = FileManager.default
        guard let record = JSONStore.read(InstallRecord.self, from: paths.installRecordFile) else {
            throw InstallError.blocked(["没有找到接管记录（\(paths.installRecordFile.path)），无需回退。"])
        }
        let jobs = JSONStore.read(JobsFile.self, from: paths.jobsFile)?.jobs ?? JobConfig.defaults(paths: paths)
        for job in jobs {
            let running = (useLaunchctl && Launchctl.info(job.legacyLabel).running)
                || !BisyncMatcher.bisyncProcesses(for: job, in: ProcessScanner.list { ProcessScanner.isRcloneName($0) }).isEmpty
            if running { throw InstallError.blocked(["\(job.displayName) 正在同步。请等待结束，或先在菜单中“安全结束本轮”。"]) }
        }
        let stamp = Self.stamp()
        let undoDir = paths.backupsDir.appendingPathComponent("rollback-\(stamp)", isDirectory: true)
        log("停止 RcloneBar 后台服务")
        if !dryRun {
            try fm.createDirectory(at: undoDir, withIntermediateDirectories: true)
            if useLaunchctl { _ = Launchctl.bootout(AppPaths.agentLabel) }
            if fm.fileExists(atPath: paths.agentPlist.path) {
                try fm.moveItem(at: paths.agentPlist, to: undoDir.appendingPathComponent(paths.agentPlist.lastPathComponent))
            }
        }
        for entry in record.legacy {
            log("恢复 \(entry.label) 原始 plist：\(entry.backupPath) → \(entry.plistPath)")
            if dryRun { continue }
            let url = URL(fileURLWithPath: entry.plistPath)
            if fm.fileExists(atPath: url.path) {
                try? fm.copyItem(at: url, to: undoDir.appendingPathComponent(url.lastPathComponent))
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: entry.backupPath))
            try JSONStore.writeAtomically(data, to: url, permissions: 0o644)
            if useLaunchctl {
                if entry.wasLoaded {
                    let r = Launchctl.reload(label: entry.label, plist: url.path)
                    if !r.ok { log("⚠︎ 重新加载 \(entry.label) 失败：\(r.stderr)") }
                } else {
                    _ = Launchctl.bootout(entry.label)
                }
                if entry.wasDisabled == true { _ = Launchctl.disable(entry.label) }
            }
        }
        if !dryRun {
            try fm.moveItem(at: paths.installRecordFile, to: undoDir.appendingPathComponent("install.json"))
            if fm.fileExists(atPath: paths.jobsFile.path) {
                try fm.moveItem(at: paths.jobsFile, to: undoDir.appendingPathComponent("jobs.json"))
            }
        }
        log(dryRun ? "（演练模式，未做任何修改）" : "已回退：原 LaunchAgent 已恢复为接管前的配置（含原有自动调度）。回退前的文件保存在 \(undoDir.path)")
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
