import Foundation

/// 接入前检查：只读，汇总现有脚本、LaunchAgent、进程、状态与历史。
public struct ScriptSummary: Codable, Sendable {
    public var path: String
    public var size: Int
    public var modified: Date?
    public var flags: [String: Bool]
    public var mentionsPaths: [String: Bool]
    public var usesCustomEnv: Bool
    public var setsRC: Bool
}

public struct JobInspection: Codable, Sendable {
    public var id: String
    public var displayName: String
    public var localPath: String
    public var localExists: Bool
    public var remotePath: String
    public var plistPath: String
    public var plistFound: Bool
    public var label: String
    public var programArguments: [String]
    public var startInterval: Int?
    public var runAtLoad: Bool
    public var hasSchedule: Bool
    public var envKeys: [String]
    public var standardOutPath: String?
    public var standardErrorPath: String?
    public var launchdLoaded: Bool
    public var launchdRunning: Bool
    public var launchdPID: Int32?
    public var lastExitCode: Int32?
    public var disabled: Bool?
    public var runningBisyncPIDs: [Int32]
    public var statusFileExists: Bool
    public var statusSummary: [String]
    public var logFiles: [String]
    public var logTail: [String]
    public var bisyncWorkdir: String?
    public var bisyncBaseName: String?
    public var listingModified: Date?
    public var lockFilePresent: Bool
    public var managedByRcloneBar: Bool
}

public struct InspectionReport: Codable, Sendable {
    public var generatedAt: Date
    public var rclonePath: String?
    public var rcloneVersion: String?
    public var rcFlagsSupported: Bool
    public var rcloneConfigExists: Bool
    public var script: ScriptSummary?
    public var jobs: [JobInspection]
    public var agentInstalled: Bool
    public var agentLoaded: Bool
    public var agentRunning: Bool
    public var warnings: [String]
    public var blockers: [String]

    public var anyJobRunning: Bool { jobs.contains { $0.launchdRunning || !$0.runningBisyncPIDs.isEmpty } }
}

public enum Inspector {
    public static let scriptFlags = ["--resync", "--force", "--recover", "--resilient", "--check-access", "--max-delete",
                                     "--backup-dir1", "--backup-dir2", "--backup-dir", "--conflict-resolve", "--conflict-loser",
                                     "--conflict-suffix", "--workdir", "--use-json-log", "--bwlimit", "--transfers", "--log-file",
                                     "--max-lock", "--filters-file", "--create-empty-src-dirs", "-v", "--verbose", "--log-level", "--stats"]

    public static func inspect(paths: AppPaths, jobs: [JobConfig]) -> InspectionReport {
        var warnings: [String] = []
        var blockers: [String] = []

        let rclone = RcloneLocator.find()
        var version: String?
        var rcSupported = false
        if let rclone {
            let v = Shell.run(rclone, ["version"], timeout: 10)
            version = v.stdout.components(separatedBy: "\n").first
            let h = Shell.run(rclone, ["help", "flags", "rc"], timeout: 10)
            rcSupported = h.stdout.contains("--rc-addr") && h.stdout.contains("--rc-htpasswd")
            if !rcSupported { warnings.append("当前 rclone 未报告 --rc-addr / --rc-htpasswd，实时进度可能不可用。") }
        } else {
            blockers.append("未找到 rclone（已检查 \(RcloneLocator.candidates.joined(separator: "、"))）。")
        }
        let confPath = paths.home.appendingPathComponent(".config/rclone/rclone.conf").path
        let confExists = FileManager.default.fileExists(atPath: confPath)
        if !confExists { warnings.append("未找到 \(confPath)（若使用 RCLONE_CONFIG 指定了其他位置可忽略）。") }

        let script = summarizeScript(paths.legacyScript, jobs: jobs)
        if let s = script {
            if s.flags["--resync"] == true { warnings.append("sync.py 中出现 --resync。RcloneBar 不会主动使用它，但请确认脚本不会在普通运行中自动 --resync。") }
            if s.flags["--force"] == true { warnings.append("sync.py 中出现 --force，会绕过删除保护，请确认仅用于人工操作。") }
            if s.flags["--recover"] != true { warnings.append("sync.py 未发现 --recover：安全结束一轮后，下一轮可能需要人工处理。建议在脚本中加入 --recover --resilient。") }
            if s.usesCustomEnv { warnings.append("sync.py 似乎为子进程自定义了环境变量（env=）。若未继承父进程环境，RC 实时进度将无法开启，界面会退回读取日志与状态文件。") }
            if s.setsRC { warnings.append("sync.py 自己设置了 --rc 相关参数，可能与 RcloneBar 注入的 RC 端口冲突。") }
            for (p, found) in s.mentionsPaths where !found { warnings.append("sync.py 中没有直接出现路径“\(p)”，请确认任务定义与脚本一致。") }
        } else {
            warnings.append("未找到 \(paths.legacyScript.path)。")
        }

        let procs = ProcessScanner.list { ProcessScanner.isRcloneName($0) }
        var jobReports: [JobInspection] = []
        for job in jobs {
            let plistURL = URL(fileURLWithPath: job.legacyPlistPath)
            let plist = try? LaunchAgentPlist.load(plistURL)
            let info = Launchctl.info(job.legacyLabel)
            let bisync = BisyncMatcher.bisyncProcesses(for: job, in: procs)
            let status = LegacyStatus.load(URL(fileURLWithPath: job.statusFile))
            var statusSummary: [String] = []
            if let st = status {
                if let s = st.state { statusSummary.append("状态：\(s)") }
                if let d = st.lastSuccess { statusSummary.append("上次成功：\(Formatters.full(d))") }
                if let d = st.lastRun { statusSummary.append("上次运行：\(Formatters.full(d))") }
                if let e = st.lastError { statusSummary.append("错误：\(String(e.prefix(200)))") }
            }
            var logFiles = job.logFiles
            for p in [plist?.standardOutPath, plist?.standardErrorPath].compactMap({ $0 }) where !logFiles.contains(p) { logFiles.append(p) }
            let tail = logFiles.flatMap { LogReader.tailLines(URL(fileURLWithPath: $0), maxBytes: 16 * 1024, maxLines: 8) }.map(Redactor.redact)

            var searchDirs: [URL] = []
            if let w = job.bisyncWorkdir { searchDirs.append(URL(fileURLWithPath: w)) }
            searchDirs += paths.defaultBisyncWorkdirs + [paths.legacyBase]
            let located = BisyncListings.locate(job: job, searchDirs: searchDirs)
            var probe: BisyncListings.Probe?
            if let l = located { probe = BisyncListings.probe(workdir: l.workdir.path, baseName: l.baseName) }

            let managed = plist.map { !$0.hasSchedule && $0.environment["RCLONE_RC_ADDR"] != nil } ?? false
            if plist == nil { blockers.append("未找到 \(job.displayName) 的 LaunchAgent：\(job.legacyPlistPath)") }
            if located == nil { warnings.append("未找到 \(job.displayName) 的 bisync 历史 listing。结果判定将退回到日志与退出码；请勿因此执行 --resync。") }
            if probe?.lockFilePresent == true && bisync.isEmpty { warnings.append("\(job.displayName) 存在 bisync 锁文件但没有 bisync 进程在运行，可能是上次异常退出留下的。bisync 会按 --max-lock 规则处理，RcloneBar 不会删除它。") }
            if !FileManager.default.fileExists(atPath: job.localPath) { warnings.append("本地目录不存在：\(job.localPath)") }

            jobReports.append(JobInspection(
                id: job.id, displayName: job.displayName, localPath: job.localPath,
                localExists: FileManager.default.fileExists(atPath: job.localPath), remotePath: job.remotePath,
                plistPath: job.legacyPlistPath, plistFound: plist != nil, label: job.legacyLabel,
                programArguments: plist?.programArguments ?? [], startInterval: plist?.startInterval,
                runAtLoad: plist?.runAtLoad ?? false, hasSchedule: plist?.hasSchedule ?? false,
                envKeys: (plist?.environment.keys).map { Array($0).sorted() } ?? [],
                standardOutPath: plist?.standardOutPath, standardErrorPath: plist?.standardErrorPath,
                launchdLoaded: info.loaded, launchdRunning: info.running, launchdPID: info.pid,
                lastExitCode: info.lastExitCode, disabled: Launchctl.isDisabled(job.legacyLabel),
                runningBisyncPIDs: bisync.map(\.pid), statusFileExists: status != nil, statusSummary: statusSummary,
                logFiles: logFiles, logTail: tail, bisyncWorkdir: located?.workdir.path, bisyncBaseName: located?.baseName,
                listingModified: probe?.path1Modified, lockFilePresent: probe?.lockFilePresent ?? false,
                managedByRcloneBar: managed))
        }

        let agentInfo = Launchctl.info(AppPaths.agentLabel)
        return InspectionReport(
            generatedAt: Date(), rclonePath: rclone, rcloneVersion: version, rcFlagsSupported: rcSupported,
            rcloneConfigExists: confExists, script: script, jobs: jobReports,
            agentInstalled: FileManager.default.fileExists(atPath: paths.agentPlist.path),
            agentLoaded: agentInfo.loaded, agentRunning: agentInfo.running, warnings: warnings, blockers: blockers)
    }

    static func summarizeScript(_ url: URL, jobs: [JobConfig]) -> ScriptSummary? {
        guard let data = try? Data(contentsOf: url), data.count < 4 * 1024 * 1024 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        // 去掉注释行，避免把注释里的示例当成实际参数
        let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        var flags: [String: Bool] = [:]
        for f in scriptFlags {
            flags[f] = code.contains("\"\(f)\"") || code.contains("'\(f)'") || code.contains("\(f)=") || code.contains("\(f) ")
        }
        var mentions: [String: Bool] = [:]
        for j in jobs {
            for p in [j.localPath, j.remotePath] {
                let tail = p.components(separatedBy: "/").suffix(2).joined(separator: "/")
                mentions[p] = code.contains(p) || code.contains(tail)
            }
        }
        let customEnv = code.range(of: #"env\s*=\s*(?!os\.environ|None|\{\s*\*\*os\.environ)"#, options: .regularExpression) != nil
        let setsRC = code.contains("--rc-addr") || code.contains("\"--rc\"") || code.contains("'--rc'")
        return ScriptSummary(path: url.path, size: data.count, modified: JSONStore.modificationDate(url), flags: flags,
                             mentionsPaths: mentions, usesCustomEnv: customEnv, setsRC: setsRC)
    }

    /// 便于复制的中文文本报告（不含任何令牌或口令）。
    public static func text(_ r: InspectionReport) -> String {
        var s: [String] = []
        s.append("RcloneBar 接入检查  \(Formatters.full(r.generatedAt))")
        s.append("rclone：\(r.rclonePath ?? "未找到")  \(r.rcloneVersion ?? "")")
        s.append("RC 参数支持：\(r.rcFlagsSupported ? "是" : "否/未知")")
        s.append("后台服务：\(r.agentInstalled ? "已安装" : "未安装")\(r.agentLoaded ? "，已加载" : "")\(r.agentRunning ? "，运行中" : "")")
        if let sc = r.script {
            s.append("")
            s.append("脚本：\(sc.path)（\(Formatters.bytes(Int64(sc.size)))\(sc.modified.map { "，修改于 " + Formatters.full($0) } ?? "")）")
            let present = sc.flags.filter(\.value).map(\.key).sorted()
            s.append("  发现参数：\(present.isEmpty ? "无" : present.joined(separator: " "))")
        }
        for j in r.jobs {
            s.append("")
            s.append("【\(j.displayName)】\(j.localPath)  ⇄  \(j.remotePath)")
            s.append("  LaunchAgent：\(j.plistFound ? j.plistPath : "未找到")")
            if j.plistFound {
                s.append("  命令：\(j.programArguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))")
                s.append("  调度：\(j.startInterval.map { "每 \($0) 秒" } ?? "无 StartInterval")\(j.runAtLoad ? "，登录时运行" : "")\(j.managedByRcloneBar ? "（已由 RcloneBar 接管，按需执行）" : "")")
                if !j.envKeys.isEmpty { s.append("  环境变量：\(j.envKeys.joined(separator: ", "))") }
            }
            s.append("  launchd：\(j.launchdLoaded ? "已加载" : "未加载")\(j.launchdRunning ? "，运行中 pid \(j.launchdPID ?? 0)" : "")\(j.lastExitCode.map { "，上次退出码 \($0)" } ?? "")\(j.disabled == true ? "，已禁用" : "")")
            s.append("  bisync 进程：\(j.runningBisyncPIDs.isEmpty ? "无" : j.runningBisyncPIDs.map(String.init).joined(separator: ", "))")
            s.append("  bisync 历史：\(j.bisyncWorkdir.map { "\($0)/\(j.bisyncBaseName ?? "")" } ?? "未找到")\(j.listingModified.map { "，更新于 " + Formatters.full($0) } ?? "")\(j.lockFilePresent ? "，存在锁文件" : "")")
            s.append("  状态文件：\(j.statusFileExists ? j.statusSummary.joined(separator: "；") : "未找到")")
            if !j.logTail.isEmpty {
                s.append("  日志末尾：")
                for l in j.logTail.suffix(5) { s.append("    " + String(l.prefix(200))) }
            }
        }
        if !r.blockers.isEmpty {
            s.append("")
            s.append("无法接管的原因：")
            for b in r.blockers { s.append("  ✕ " + b) }
        }
        if !r.warnings.isEmpty {
            s.append("")
            s.append("注意事项：")
            for w in r.warnings { s.append("  ⚠︎ " + w) }
        }
        return s.joined(separator: "\n")
    }
}
