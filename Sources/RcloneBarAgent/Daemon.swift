import Foundation
import RcloneBarCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 后台服务日志（有大小上限，滚动一份）。
final class AgentLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(url: URL) { self.url = url }

    func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(Redactor.redact(message))\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = LogReader.fileSize(url), size > 1_000_000 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        }
        if ProcessInfo.processInfo.environment["RCLONEBAR_LOG_STDERR"] == "1" {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

/// 一组任务的调度状态。
final class JobWorker {
    let job: JobConfig
    let executor: JobExecutor
    var rt: JobRuntime
    var logOffsets: [String: UInt64] = [:]
    var sawBisync = false
    var lastRCPoll = Date.distantPast
    var lastBwCheck = Date.distantPast
    var rcVerified = false
    var checkedTransfers = false
    /// 本轮退出码从哪里取：执行器（我们启动的 / launchd 管理的），或拿不到
    var exitFromExecutor = true
    var startRequestedAt: Date?

    init(job: JobConfig, executor: JobExecutor, saved: JobRuntime?) {
        self.job = job
        self.executor = executor
        var r = saved ?? JobRuntime()
        // 运行中的字段在重启后重新确认
        r.phase = .idle
        r.stopRequestedAt = nil
        r.interruptSignals = 0
        r.notice = nil
        self.rt = r
    }

    var isIdle: Bool { rt.phase == .idle }
}

final class Daemon {
    let paths: AppPaths
    let log: AgentLog
    var settings: SyncSettings
    var settingsMTime: Date?
    var workers: [JobWorker] = []
    var credentials: RCCredentials?
    var rcClients: [Int: RCClient] = [:]
    var commandResults: [CommandResult] = []
    let startedAt = Date()
    var lastStateWrite = Date.distantPast
    var lastWrittenState: AgentState?
    var lastProcScan = Date.distantPast
    var procs: [ProcessEntry] = []
    var stopping = false
    let tick: TimeInterval
    /// 仅用于自动化测试：以秒为单位覆盖同步间隔
    let testIntervalSeconds: TimeInterval?

    var interval: TimeInterval { testIntervalSeconds ?? settings.interval }

    init(paths: AppPaths) {
        self.paths = paths
        self.log = AgentLog(url: paths.agentLogFile)
        self.settings = JSONStore.read(SyncSettings.self, from: paths.settingsFile) ?? SyncSettings()
        self.settingsMTime = JSONStore.modificationDate(paths.settingsFile)
        self.tick = Double(ProcessInfo.processInfo.environment["RCLONEBAR_TICK"] ?? "") ?? 1.0
        self.testIntervalSeconds = Double(ProcessInfo.processInfo.environment["RCLONEBAR_TEST_INTERVAL_SECONDS"] ?? "")
    }

    // MARK: 启动

    func run() async -> Int32 {
        do { try paths.ensureBaseDirectories() } catch {
            log.write("无法创建目录：\(error)")
            return 1
        }
        guard let lockFD = acquireLock() else {
            log.write("另一个后台服务实例正在运行，本实例退出。")
            return 0
        }
        defer { close(lockFD) }

        guard let jobsFile = JSONStore.read(JobsFile.self, from: paths.jobsFile) else {
            log.write("未找到 \(paths.jobsFile.path)，请先在 App 中完成接入。")
            return 0
        }
        credentials = try? RCCredentials.loadOrCreate(paths: paths)
        let saved = JSONStore.read(AgentState.self, from: paths.stateFile)
        let now = Date()
        for (i, job) in jobsFile.jobs.enumerated() {
            let exec: JobExecutor = job.launchMode == .launchd ? LaunchdExecutor(job: job) : DirectExecutor(job: job)
            let w = JobWorker(job: job, executor: exec, saved: saved?.jobs[job.id])
            // 错开首次运行，避免登录后同时启动
            let stagger = testIntervalSeconds.map { min($0, 15) } ?? 15
            let earliest = now.addingTimeInterval(stagger + Double(i) * stagger)
            if let n = w.rt.nextRunAt, n > earliest { } else { w.rt.nextRunAt = earliest }
            workers.append(w)
        }
        installSignalHandlers()
        log.write("后台服务启动（版本 \(RcloneBarVersion.current)，pid \(getpid())，间隔 \(settings.intervalMinutes) 分钟，任务：\(workers.map(\.job.displayName).joined(separator: "、"))）")

        // 接续：后台服务重启时，已在运行的同步不受影响，这里重新接上
        for w in workers { adoptIfRunning(w, now: Date(), startup: saved?.jobs[w.job.id]) }
        for w in workers where w.isIdle { applyEnvironmentIfNeeded(w) }

        while !stopping {
            await loopOnce()
            let active = workers.contains { !$0.isIdle }
            let interval = active ? tick : min(tick * 2, 2)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        writeState(force: true)
        log.write("后台服务退出（正在运行的同步不受影响）")
        return 0
    }

    private func acquireLock() -> Int32? {
        let fd = open(paths.agentLockFile.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    private var signalSources: [DispatchSourceSignal] = []

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in self?.stopping = true }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: 主循环

    func loopOnce() async {
        let now = Date()
        reloadSettingsIfChanged()
        for cmd in ControlChannel.drain(paths: paths) { handle(cmd, now: now) }

        let active = workers.contains { !$0.isIdle }
        if active || now.timeIntervalSince(lastProcScan) >= 3 {
            procs = ProcessScanner.list { ProcessScanner.isRcloneName($0) }
            lastProcScan = now
        }
        for w in workers { await tickWorker(w, now: now) }
        writeState(force: false)
    }

    func reloadSettingsIfChanged() {
        let m = JSONStore.modificationDate(paths.settingsFile)
        guard m != settingsMTime else { return }
        settingsMTime = m
        guard let new = JSONStore.read(SyncSettings.self, from: paths.settingsFile) else { return }
        let old = settings
        settings = new
        if old.intervalMinutes != new.intervalMinutes {
            log.write("同步间隔改为 \(new.intervalMinutes) 分钟")
            let now = Date()
            for w in workers where w.isIdle {
                let base = w.rt.lastFinishedAt ?? now
                w.rt.nextRunAt = max(base.addingTimeInterval(interval), now.addingTimeInterval(5))
            }
        }
        if old.pausedAll != new.pausedAll || old.pausedJobs != new.pausedJobs {
            log.write("自动调度：\(new.pausedAll ? "全部暂停" : (new.pausedJobs.isEmpty ? "全部运行" : "暂停 \(new.pausedJobs.joined(separator: ","))"))")
        }
        if old.runEnvironment() != new.runEnvironment() {
            log.write("传输设置已更新：\(new.runEnvironment().map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))")
            for w in workers {
                if w.isIdle { applyEnvironmentIfNeeded(w) } else { w.rt.settingsPendingNextRun = true }
                w.lastBwCheck = .distantPast // 限速立即通过 RC 调整
            }
        }
    }

    func desiredEnvironment(_ job: JobConfig) -> [String: String] {
        rcEnvironment(port: job.rcPort, htpasswdPath: paths.htpasswdFile.path).merging(settings.runEnvironment()) { $1 }
    }

    func applyEnvironmentIfNeeded(_ w: JobWorker) {
        let env = desiredEnvironment(w.job)
        let fp = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        guard w.rt.appliedEnvFingerprint != fp else { w.rt.settingsPendingNextRun = false; return }
        do {
            if try w.executor.applyEnvironment(env) { log.write("\(w.job.displayName)：已更新执行器环境（下一轮生效）") }
            w.rt.appliedEnvFingerprint = fp
            w.rt.settingsPendingNextRun = false
        } catch {
            log.write("\(w.job.displayName)：更新执行器环境失败：\(error)")
            w.rt.notice = "设置写入后台任务失败：\(error)"
        }
    }

    // MARK: 命令

    func handle(_ cmd: ControlCommand, now: Date) {
        if now.timeIntervalSince(cmd.createdAt) > ControlChannel.expiry {
            record(cmd, false, "命令已过期，未执行")
            return
        }
        let targets = cmd.jobID.map { id in workers.filter { $0.job.id == id } } ?? workers
        if targets.isEmpty { record(cmd, false, "未知任务 \(cmd.jobID ?? "")"); return }
        var messages: [String] = []
        var accepted = false
        for w in targets {
            let name = w.job.displayName
            switch cmd.action {
            case .syncNow:
                if !w.isIdle {
                    messages.append("\(name) 正在同步，已忽略重复请求")
                } else if !BisyncMatcher.bisyncProcesses(for: w.job, in: freshProcs()).isEmpty {
                    messages.append("\(name) 已有另一个 bisync 在运行，未重复启动")
                } else {
                    startRun(w, trigger: .manual, now: now)
                    accepted = true
                    messages.append("已开始同步\(name)")
                }
            case .stop:
                if w.isIdle {
                    messages.append("\(name) 当前没有运行中的同步")
                } else if w.rt.stopRequestedAt != nil {
                    messages.append("\(name) 已在安全结束中")
                } else {
                    w.rt.stopRequestedAt = now
                    w.rt.phase = .stopping
                    accepted = true
                    log.write("\(name)：收到安全结束请求")
                    sendInterruptIfPossible(w)
                    messages.append("正在安全结束\(name)本轮同步")
                }
            case .forceInterrupt:
                if w.isIdle {
                    messages.append("\(name) 当前没有运行中的同步")
                } else if w.rt.stopRequestedAt == nil || w.rt.interruptSignals == 0 {
                    messages.append("请先使用“安全结束本轮”")
                } else if let pid = w.rt.rclonePID {
                    ProcessScanner.sendSignal(SIGINT, to: pid)
                    w.rt.interruptSignals += 1
                    accepted = true
                    log.write("\(name)：再次发送中断信号（立即结束）pid \(pid)")
                    messages.append("已再次发送中断信号，\(name) 将立即结束；下一轮会重新检查")
                } else {
                    messages.append("\(name) 尚未找到 rclone 进程")
                }
            }
        }
        record(cmd, accepted, messages.joined(separator: "；"))
        writeState(force: true)
    }

    private func record(_ cmd: ControlCommand, _ accepted: Bool, _ message: String) {
        commandResults.append(CommandResult(commandID: cmd.id, action: cmd.action, jobID: cmd.jobID, at: Date(), accepted: accepted, message: message))
        if commandResults.count > 20 { commandResults.removeFirst(commandResults.count - 20) }
        log.write("命令 \(cmd.action.rawValue)(\(cmd.jobID ?? "全部"))：\(message)")
    }

    private func freshProcs() -> [ProcessEntry] {
        procs = ProcessScanner.list { ProcessScanner.isRcloneName($0) }
        lastProcScan = Date()
        return procs
    }

    // MARK: 每组任务

    func tickWorker(_ w: JobWorker, now: Date) async {
        switch w.rt.phase {
        case .idle:
            let external = BisyncMatcher.bisyncProcesses(for: w.job, in: procs)
            if !external.isEmpty {
                adoptIfRunning(w, now: now, startup: nil)
                return
            }
            guard let next = w.rt.nextRunAt else {
                w.rt.nextRunAt = now.addingTimeInterval(interval)
                return
            }
            if now >= next {
                if settings.isPaused(w.job.id) {
                    // 暂停期间不启动；恢复后按计划时间（已过则尽快）运行
                    return
                }
                if !BisyncMatcher.bisyncProcesses(for: w.job, in: freshProcs()).isEmpty {
                    adoptIfRunning(w, now: now, startup: nil)
                    return
                }
                startRun(w, trigger: .scheduled, now: now)
            }
        case .starting:
            if let pid = w.executor.runningPID() {
                w.rt.jobPID = pid
                w.rt.phase = w.rt.stopRequestedAt != nil ? .stopping : .running
                log.write("\(w.job.displayName)：执行器已运行 pid \(pid)")
            } else if let started = w.startRequestedAt, now.timeIntervalSince(started) > 2.5 {
                // 很快就结束的一轮（或启动失败）
                await finishRun(w, now: now)
            }
        case .running, .stopping:
            await monitorRunning(w, now: now)
        }
    }

    func startRun(_ w: JobWorker, trigger: RunTrigger, now: Date) {
        applyEnvironmentIfNeeded(w)
        w.rt.runID = UUID().uuidString
        w.rt.trigger = trigger
        w.rt.runStartedAt = now
        w.rt.stopRequestedAt = nil
        w.rt.interruptSignals = 0
        w.rt.rclonePID = nil
        w.rt.jobPID = nil
        w.rt.lastStats = nil
        w.rt.effectiveTransfers = nil
        w.rt.effectiveBwlimit = nil
        w.rt.rcEnabled = true
        w.rt.notice = nil
        w.sawBisync = false
        w.rcVerified = false
        w.checkedTransfers = false
        w.lastBwCheck = .distantPast
        w.exitFromExecutor = true
        w.logOffsets = Dictionary(uniqueKeysWithValues: w.job.logFiles.map { ($0, LogReader.fileSize(URL(fileURLWithPath: $0)) ?? 0) })
        w.startRequestedAt = now
        do {
            try w.executor.start(environment: desiredEnvironment(w.job))
            w.rt.phase = .starting
            log.write("\(w.job.displayName)：开始\(trigger.label)同步")
        } catch {
            log.write("\(w.job.displayName)：启动失败：\(error)")
            w.rt.phase = .idle
            finalize(w, verdict: RunVerdict(outcome: .failed, summary: "无法启动同步：\(error)", category: .other, evidence: []),
                     exitCode: nil, analysis: LogAnalysis(), now: now)
        }
    }

    /// 发现已在运行的 bisync（后台服务重启、或由外部启动）
    func adoptIfRunning(_ w: JobWorker, now: Date, startup: JobRuntime?) {
        var pid: Int32?
        var isLaunchd = false
        if w.job.launchMode == .launchd, let p = w.executor.runningPID() {
            pid = p
            isLaunchd = true
        }
        let bisync = BisyncMatcher.bisyncProcesses(for: w.job, in: freshProcs())
        if pid == nil { pid = bisync.first?.pid }
        guard let pid else { return }
        let sameRun = startup?.jobPID == pid && startup?.runStartedAt != nil
        w.rt.phase = (sameRun && startup?.stopRequestedAt != nil) ? .stopping : .running
        w.rt.jobPID = pid
        w.rt.rclonePID = bisync.first?.pid
        w.rt.runID = sameRun ? (startup?.runID ?? UUID().uuidString) : UUID().uuidString
        w.rt.runStartedAt = sameRun ? startup?.runStartedAt : now
        w.rt.trigger = sameRun ? .adopted : .external
        w.rt.rcEnabled = sameRun ? (startup?.rcEnabled ?? false) : false
        w.rt.stopRequestedAt = sameRun ? startup?.stopRequestedAt : nil
        w.rt.interruptSignals = sameRun ? (startup?.interruptSignals ?? 0) : 0
        w.sawBisync = !bisync.isEmpty
        w.rcVerified = false
        // direct 模式下重启后已没有子进程句柄；launchd 模式由 launchd 记录退出码
        w.exitFromExecutor = isLaunchd
        w.logOffsets = Dictionary(uniqueKeysWithValues: w.job.logFiles.map { ($0, LogReader.fileSize(URL(fileURLWithPath: $0)) ?? 0) })
        if !isLaunchd && w.job.launchMode == .launchd {
            w.rt.notice = "检测到不是由 RcloneBar 启动的 bisync（pid \(pid)），本轮只读取日志与状态"
        }
        log.write("\(w.job.displayName)：接续正在运行的同步 pid \(pid)（\(w.rt.trigger?.label ?? "")）")
    }

    func monitorRunning(_ w: JobWorker, now: Date) async {
        guard let jobPID = w.rt.jobPID else {
            w.rt.phase = .starting
            return
        }
        let alive = ProcessScanner.isAlive(jobPID)
        // 找到真正执行 bisync 的 rclone 进程（可能是脚本的子进程）
        var candidates = ProcessScanner.descendants(of: jobPID, in: procs)
        if let me = procs.first(where: { $0.pid == jobPID }) { candidates.append(me) }
        let rclone = candidates.first { ProcessScanner.isRcloneName($0.name) && BisyncMatcher.isBisync($0.arguments) }
            ?? BisyncMatcher.bisyncProcesses(for: w.job, in: procs).first
        if let r = rclone {
            if w.rt.rclonePID != r.pid { w.rcVerified = false; w.checkedTransfers = false }
            w.rt.rclonePID = r.pid
            w.sawBisync = true
        } else if let rp = w.rt.rclonePID, !ProcessScanner.isAlive(rp) {
            w.rt.rclonePID = nil
        }

        if w.rt.stopRequestedAt != nil && w.rt.interruptSignals == 0 { sendInterruptIfPossible(w) }

        if let rp = w.rt.rclonePID, now.timeIntervalSince(w.lastRCPoll) >= 2 {
            w.lastRCPoll = now
            await pollRC(w, rclonePID: rp, now: now)
        }

        if !alive { await finishRun(w, now: now) }
    }

    func sendInterruptIfPossible(_ w: JobWorker) {
        guard let pid = w.rt.rclonePID, ProcessScanner.isAlive(pid) else {
            w.rt.notice = "已请求安全结束，等待 rclone 进程出现后发送中断信号"
            return
        }
        // 只向 rclone 发送 SIGINT：bisync 会停止领取新任务、在宽限期内完成或取消进行中的传输并保存状态
        if ProcessScanner.sendSignal(SIGINT, to: pid) {
            w.rt.interruptSignals = 1
            w.rt.notice = "已发送中断信号，bisync 正在收尾（通常不超过 90 秒）"
            log.write("\(w.job.displayName)：向 rclone pid \(pid) 发送 SIGINT（安全结束）")
        }
    }

    private func rcClient(_ port: Int) -> RCClient? {
        guard let c = credentials else { return nil }
        if let existing = rcClients[port] { return existing }
        let client = RCClient(port: port, credentials: c, timeout: 1.5)
        rcClients[port] = client
        return client
    }

    func pollRC(_ w: JobWorker, rclonePID: Int32, now: Date) async {
        guard let c = rcClient(w.job.rcPort) else { return }
        do {
            if !w.rcVerified {
                let pid = try await c.pid()
                guard pid == rclonePID else {
                    w.rt.notice = "RC 端口 \(w.job.rcPort) 上的进程（pid \(pid)）不是本组任务，已忽略"
                    return
                }
                w.rcVerified = true
                w.rt.rcEnabled = true
            }
            let s = try await c.stats()
            w.rt.lastStats = s.sample
            if !w.checkedTransfers {
                w.checkedTransfers = true
                w.rt.effectiveTransfers = try? await c.effectiveTransfers()
            }
            // 限速：设置开启时保持与设置一致（可即时生效，也覆盖脚本自带的 --bwlimit）
            if let want = settings.bwlimitRate, now.timeIntervalSince(w.lastBwCheck) >= 5 {
                w.lastBwCheck = now
                let current = try await c.bwlimit()
                if !BwlimitCompare.equivalent(current, want) {
                    let applied = try await c.setBwlimit(want)
                    log.write("\(w.job.displayName)：限速调整为 \(applied)")
                    w.rt.effectiveBwlimit = applied
                } else {
                    w.rt.effectiveBwlimit = current
                }
            }
        } catch RCError.notReachable {
            // 刚启动时 RC 可能还没监听；或脚本没有继承环境变量
            if let start = w.rt.runStartedAt, now.timeIntervalSince(start) > 20, w.rt.trigger != .external {
                w.rt.rcEnabled = false
                w.rt.notice = "本轮 rclone 未开启 RC（脚本可能未继承环境变量），显示日志信息"
            }
        } catch {
            // 其他错误不影响同步本身
        }
    }

    func finishRun(_ w: JobWorker, now: Date) async {
        var exit: Int32? = nil
        if w.exitFromExecutor {
            exit = w.executor.lastExitCode()
            if exit == nil, w.job.launchMode == .launchd {
                try? await Task.sleep(nanoseconds: 300_000_000)
                exit = w.executor.lastExitCode()
            }
        }
        var lines: [String] = []
        for f in w.job.logFiles {
            lines += LogReader.readSince(URL(fileURLWithPath: f), offset: w.logOffsets[f] ?? 0)
        }
        let analysis = LogAnalyzer.analyze(lines)
        var probe: BisyncListings.Probe?
        if let wd = w.job.bisyncWorkdir, let base = BisyncListings.locate(job: w.job, searchDirs: [URL(fileURLWithPath: wd)], maxDepth: 0)?.baseName {
            probe = BisyncListings.probe(workdir: wd, baseName: base)
        }
        let evidence = RunEvidence(
            startedAt: w.rt.runStartedAt ?? now, exitCode: exit,
            exitCodeIsRclone: w.executor.exitCodeIsRclone && w.exitFromExecutor,
            log: analysis, logLineCount: lines.count, listing: probe,
            legacyStatus: LegacyStatus.load(URL(fileURLWithPath: w.job.statusFile)),
            stopRequested: w.rt.stopRequestedAt != nil, sawBisyncProcess: w.sawBisync,
            scriptHasRecover: w.job.scriptHasRecover, rcErrors: w.rt.lastStats?.errors)
        let verdict = RunEvaluator.evaluate(evidence)
        finalize(w, verdict: verdict, exitCode: exit, analysis: analysis, now: now)
    }

    func finalize(_ w: JobWorker, verdict: RunVerdict, exitCode: Int32?, analysis: LogAnalysis, now: Date) {
        let record = RunRecord(
            id: w.rt.runID ?? UUID().uuidString, jobID: w.job.id, trigger: w.rt.trigger ?? .scheduled,
            startedAt: w.rt.runStartedAt ?? now, finishedAt: now, outcome: verdict.outcome, exitCode: exitCode,
            summary: verdict.summary, errors: Array(analysis.errorLines.suffix(20)), conflicts: analysis.conflicts,
            bytes: w.rt.lastStats?.bytes, transfers: w.rt.lastStats?.transfers, rcEnabled: w.rt.rcEnabled,
            evidence: verdict.evidence)
        do { try RunHistory.append(record, to: paths.runsFile) } catch { log.write("写入运行记录失败：\(error)") }
        log.write("\(w.job.displayName)：本轮结束 —— \(verdict.outcome.label)：\(verdict.summary)（\(verdict.evidence.joined(separator: "，"))）")

        w.rt.lastOutcome = verdict.outcome
        w.rt.lastSummary = verdict.summary
        w.rt.lastFinishedAt = now
        if verdict.outcome == .success {
            w.rt.lastSuccessAt = now
            w.rt.consecutiveFailures = 0
        } else if verdict.outcome.isFailure {
            w.rt.consecutiveFailures += 1
        }
        w.rt.phase = .idle
        w.rt.jobPID = nil
        w.rt.rclonePID = nil
        w.rt.stopRequestedAt = nil
        w.rt.interruptSignals = 0
        w.rt.runStartedAt = nil
        w.rt.notice = nil
        w.startRequestedAt = nil
        w.rt.nextRunAt = now.addingTimeInterval(interval)
        applyEnvironmentIfNeeded(w)
        writeState(force: true)
    }

    // MARK: 状态文件

    func writeState(force: Bool) {
        let now = Date()
        var jobs: [String: JobRuntime] = [:]
        for w in workers { jobs[w.job.id] = w.rt }
        var state = AgentState(agentPID: getpid(), agentVersion: RcloneBarVersion.current, startedAt: startedAt, updatedAt: now,
                               appliedIntervalMinutes: settings.intervalMinutes, jobs: jobs, commandResults: commandResults)
        let active = workers.contains { !$0.isIdle }
        let changed: Bool = {
            guard var last = lastWrittenState else { return true }
            last.updatedAt = state.updatedAt
            return last != state
        }()
        let due = now.timeIntervalSince(lastStateWrite) >= (active ? 1 : 5)
        guard force || (changed && now.timeIntervalSince(lastStateWrite) >= 0.5) || due else { return }
        state.updatedAt = now
        do {
            try JSONStore.write(state, to: paths.stateFile)
            lastWrittenState = state
            lastStateWrite = now
        } catch {
            log.write("写入状态失败：\(error)")
        }
    }
}
