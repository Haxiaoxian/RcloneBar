import Foundation

public enum RCState: Equatable, Sendable {
    case notRunning
    case connected
    /// 本轮启动时没有开启 RC（例如接管前由旧 LaunchAgent 启动的进程）
    case notEnabled
    case unreachable(String)
    /// 端口上的 rclone 不是本组任务的进程
    case mismatch

    public var label: String {
        switch self {
        case .notRunning: return "未运行"
        case .connected: return "实时数据已连接"
        case .notEnabled: return "本轮未开启实时接口，显示日志与状态文件信息"
        case .unreachable(let s): return "实时接口暂不可用（\(s)）"
        case .mismatch: return "实时接口属于其他进程，已忽略"
        }
    }
}

public enum ControlMode: Equatable, Sendable {
    /// 已接管：由 rclonebar-agent 调度
    case managed
    /// 未接管：只读观察现有 LaunchAgent
    case observe
}

public struct JobSnapshot: Equatable, Sendable, Identifiable {
    public var id: String { config.id }
    public var config: JobConfig
    public var progress: JobProgress
    public var running: Bool
    public var runStartedAt: Date?
    public var trigger: RunTrigger?
    public var stopRequested: Bool
    public var paused: Bool
    public var rcState: RCState
    public var lastSuccessAt: Date?
    public var lastSuccessSource: String?
    public var lastOutcome: RunOutcome?
    public var lastFinishedAt: Date?
    public var lastSummary: String?
    public var lastErrorCategory: ErrorCategory?
    public var lastErrors: [String]
    public var nextRunAt: Date?
    public var nextRunEstimated: Bool
    public var notice: String?
    public var settingsNote: String?
    public var consecutiveFailures: Int
}

public struct Snapshot: Equatable, Sendable {
    public var updatedAt: Date
    public var mode: ControlMode
    public var agentAlive: Bool
    public var agentVersion: String?
    public var settings: SyncSettings
    public var jobs: [JobSnapshot]
    public var overall: OverallState
    public var totalSpeed: Double
    public var recentRuns: [RunRecord]
    public var lastCommandResult: CommandResult?

    public var anyActive: Bool { jobs.contains { $0.progress.activity.isActive } }
}

/// 汇总各数据源生成界面快照。非线程安全：在单个后台任务里循环调用。
public final class StatusCollector: @unchecked Sendable {
    public let paths: AppPaths
    private var trackers: [String: ProgressTracker] = [:]
    private var clients: [Int: RCClient] = [:]
    private var credentials: RCCredentials?
    private var verifiedPID: [String: Int32] = [:]
    private var firstSeen: [String: (pid: Int32, at: Date)] = [:]
    private var runsCache: (Date?, [RunRecord]) = (nil, [])
    private var legacyPlistCache: [String: (Date?, LaunchAgentPlist?)] = [:]
    private var listingCache: [String: (at: Date, value: (workdir: String, base: String)?)] = [:]

    public init(paths: AppPaths = AppPaths()) {
        self.paths = paths
    }

    public func jobs() -> [JobConfig] {
        JSONStore.read(JobsFile.self, from: paths.jobsFile)?.jobs ?? JobConfig.defaults(paths: paths)
    }

    private func client(port: Int) -> RCClient? {
        if credentials == nil { credentials = RCCredentials.load(paths: paths) }
        guard let credentials else { return nil }
        if let c = clients[port] { return c }
        let c = RCClient(port: port, credentials: credentials, timeout: 1.5)
        clients[port] = c
        return c
    }

    public func collect(now: Date = Date()) async -> Snapshot {
        let fm = FileManager.default
        let managed = fm.fileExists(atPath: paths.installRecordFile.path) && fm.fileExists(atPath: paths.jobsFile.path)
        let jobs = self.jobs()
        let settings = JSONStore.read(SyncSettings.self, from: paths.settingsFile) ?? SyncSettings()
        let state = JSONStore.read(AgentState.self, from: paths.stateFile)
        let agentAlive = state.map { $0.isFresh(now: now) && ProcessScanner.isAlive($0.agentPID) } ?? false
        let procs = ProcessScanner.list { ProcessScanner.isRcloneName($0) }

        let runsMTime = JSONStore.modificationDate(paths.runsFile)
        if runsMTime != runsCache.0 { runsCache = (runsMTime, RunHistory.recent(from: paths.runsFile, limit: 100)) }
        let runs = runsCache.1

        var snaps: [JobSnapshot] = []
        for job in jobs {
            snaps.append(await collectJob(job, managed: managed, agentAlive: agentAlive, state: state, settings: settings,
                                          procs: procs, runs: runs, now: now))
        }
        let overall = OverallStateResolver.resolve(
            snaps.map { .init(activity: $0.progress.activity, lastOutcome: $0.lastOutcome, lastErrorCategory: $0.lastErrorCategory, paused: $0.paused) },
            agentAvailable: !managed || agentAlive, allPaused: managed && settings.pausedAll)
        return Snapshot(updatedAt: now, mode: managed ? .managed : .observe, agentAlive: agentAlive,
                        agentVersion: state?.agentVersion, settings: settings, jobs: snaps, overall: overall,
                        totalSpeed: snaps.compactMap(\.progress.speed).reduce(0, +), recentRuns: runs,
                        lastCommandResult: state?.commandResults.last)
    }

    private func collectJob(_ job: JobConfig, managed: Bool, agentAlive: Bool, state: AgentState?, settings: SyncSettings,
                            procs: [ProcessEntry], runs: [RunRecord], now: Date) async -> JobSnapshot {
        let bisync = BisyncMatcher.bisyncProcesses(for: job, in: procs)
        let rt = (managed && agentAlive) ? state?.jobs[job.id] : nil
        let lastRun = runs.first { $0.jobID == job.id }

        var running = !bisync.isEmpty
        var starting = false
        var stopRequested = false
        var runStartedAt: Date?
        var trigger: RunTrigger?
        if let rt {
            running = running || rt.phase != .idle
            starting = rt.phase == .starting || (rt.phase == .running && bisync.isEmpty && rt.rclonePID == nil)
            stopRequested = rt.stopRequestedAt != nil && rt.phase != .idle
            runStartedAt = rt.runStartedAt
            trigger = rt.trigger
        }
        if running && runStartedAt == nil {
            let pid = bisync.first?.pid ?? -1
            if firstSeen[job.id]?.pid != pid { firstSeen[job.id] = (pid, now) }
            runStartedAt = firstSeen[job.id]?.at
            trigger = trigger ?? .external
        } else if !running {
            firstSeen[job.id] = nil
        }

        // 每轮新的统计历史
        let runKey = rt?.runID ?? bisync.first.map { "pid-\($0.pid)" }
        if trackers[job.id]?.runKey != runKey {
            var t = ProgressTracker()
            t.reset(runKey: runKey)
            trackers[job.id] = t
            verifiedPID[job.id] = nil
        }

        // RC：只在有 bisync 进程时尝试，并核对 core/pid 防止数据串组
        var stats: CoreStats?
        var rcState: RCState = running ? .notEnabled : .notRunning
        if running, !bisync.isEmpty, let c = client(port: job.rcPort) {
            do {
                if verifiedPID[job.id] == nil {
                    let pid = try await c.pid()
                    let allowed = Set(bisync.map(\.pid))
                    if allowed.contains(pid) { verifiedPID[job.id] = pid } else { throw RCError.badResponse }
                }
                stats = try await c.stats()
                rcState = .connected
            } catch RCError.badResponse {
                rcState = .mismatch
            } catch RCError.notReachable(let msg) {
                let enabled = rt?.rcEnabled ?? false
                rcState = enabled ? .unreachable(Self.shortReason(msg)) : .notEnabled
                verifiedPID[job.id] = nil
            } catch {
                rcState = .unreachable(String(describing: error))
                verifiedPID[job.id] = nil
            }
        }

        // 日志：只读末尾，按时间过滤到本轮
        var logPhase: PhaseMarker?
        var textStats: TextStats?
        var tailAnalysis: LogAnalysis?
        if running {
            let lines = job.logFiles.flatMap { LogReader.tailLines(URL(fileURLWithPath: $0), maxBytes: 96 * 1024, maxLines: 600) }
            let since = (runStartedAt ?? now).addingTimeInterval(-3)
            let current = lines.filter { l in LogParser.parse(l).time.map { $0 >= since } ?? false }
            let a = LogAnalyzer.analyze(current)
            logPhase = a.lastPhase
            textStats = a.textStats
        } else if !managed || rt == nil {
            let lines = job.logFiles.flatMap { LogReader.tailLines(URL(fileURLWithPath: $0), maxBytes: 64 * 1024, maxLines: 400) }
            tailAnalysis = LogAnalyzer.analyze(lines)
        }

        var tracker = trackers[job.id] ?? ProgressTracker()
        let progress = tracker.update(running: running, starting: starting, stopRequested: stopRequested, stats: stats,
                                      logPhase: logPhase, textStats: stats == nil ? textStats : nil, now: now)
        trackers[job.id] = tracker

        // 历史结果
        var snap = JobSnapshot(config: job, progress: progress, running: running, runStartedAt: runStartedAt, trigger: trigger,
                               stopRequested: stopRequested, paused: managed && settings.isPaused(job.id), rcState: rcState,
                               lastSuccessAt: nil, lastSuccessSource: nil, lastOutcome: nil, lastFinishedAt: nil,
                               lastSummary: nil, lastErrorCategory: nil, lastErrors: [], nextRunAt: nil,
                               nextRunEstimated: false, notice: rt?.notice, settingsNote: nil,
                               consecutiveFailures: rt?.consecutiveFailures ?? 0)
        if let rt {
            snap.lastSuccessAt = rt.lastSuccessAt
            snap.lastSuccessSource = "RcloneBar 记录"
            snap.lastOutcome = rt.lastOutcome
            snap.lastFinishedAt = rt.lastFinishedAt
            snap.lastSummary = rt.lastSummary
            snap.nextRunAt = snap.paused ? nil : rt.nextRunAt
            if rt.settingsPendingNextRun { snap.settingsNote = "部分设置（并发数）将在下一轮生效" }
            if let eff = rt.effectiveTransfers, let want = settings.transfers, eff != want, running {
                snap.settingsNote = "本轮实际并发 \(eff)（脚本参数优先，设置 \(want) 未生效）"
            }
        }
        if let lastRun {
            snap.lastErrors = lastRun.outcome.isFailure || lastRun.outcome == .unknown ? lastRun.errors : []
            if snap.lastOutcome == nil {
                snap.lastOutcome = lastRun.outcome
                snap.lastSummary = lastRun.summary
                snap.lastFinishedAt = lastRun.finishedAt
            }
            if snap.lastSuccessAt == nil, let s = runs.first(where: { $0.jobID == job.id && $0.outcome == .success }) {
                snap.lastSuccessAt = s.finishedAt
                snap.lastSuccessSource = "RcloneBar 记录"
            }
        }
        if snap.lastOutcome?.isFailure == true {
            snap.lastErrorCategory = lastRun.flatMap { r in r.errors.isEmpty ? nil : LogAnalyzer.analyze(r.errors).category }
                ?? (snap.lastOutcome == .authRequired ? .auth : nil)
        }

        // 未接管（或后台服务不可用）时：从旧状态文件、日志与 bisync listing 推断
        if rt == nil {
            let legacy = LegacyStatus.load(URL(fileURLWithPath: job.statusFile))
            var success: (Date, String)?
            if let d = legacy?.lastSuccess { success = (d, "status.json") }
            if let a = tailAnalysis, let d = a.lastSuccessTime, d > (success?.0 ?? .distantPast) { success = (d, "日志") }
            if let l = listing(for: job, now: now) {
                let probe = BisyncListings.probe(workdir: l.workdir, baseName: l.base)
                if let p1 = probe.path1Modified, let p2 = probe.path2Modified, min(p1, p2) > (success?.0 ?? .distantPast) {
                    success = (min(p1, p2), "bisync 历史 listing")
                }
            }
            if snap.lastSuccessAt == nil || (success?.0 ?? .distantPast) > snap.lastSuccessAt! {
                snap.lastSuccessAt = success?.0
                snap.lastSuccessSource = success?.1
            }
            if !running, let a = tailAnalysis, let lastTime = a.lastTime, lastTime > (snap.lastSuccessAt ?? .distantPast),
               a.sawAbort || a.sawCritical || !a.errorLines.isEmpty {
                snap.lastOutcome = a.category == .auth ? .authRequired : (a.category == .network || a.category == .retryableAbort ? .retryableFailure : .failed)
                snap.lastErrorCategory = a.category
                snap.lastErrors = a.errorLines
                snap.lastSummary = a.category?.label
                snap.lastFinishedAt = lastTime
            } else if !running, legacy?.stateLooksSuccessful == false {
                snap.lastOutcome = .failed
                snap.lastSummary = legacy?.lastError ?? "状态文件显示上次运行失败"
                snap.lastErrors = legacy?.lastError.map { [$0] } ?? []
            } else if snap.lastOutcome == nil, snap.lastSuccessAt != nil {
                snap.lastOutcome = .success
            }
            // 估算下次运行
            if !managed, let plist = legacyPlist(job), let interval = plist.startInterval {
                let base = [JSONStore.modificationDate(URL(fileURLWithPath: job.statusFile)),
                            job.logFiles.compactMap { JSONStore.modificationDate(URL(fileURLWithPath: $0)) }.max(),
                            runStartedAt].compactMap { $0 }.max()
                if let base {
                    var next = base.addingTimeInterval(TimeInterval(interval))
                    while next < now { next = next.addingTimeInterval(TimeInterval(interval)) }
                    snap.nextRunAt = next
                    snap.nextRunEstimated = true
                }
            }
            if managed && !agentAlive { snap.notice = "后台服务未运行或无响应，自动调度暂停中" }
        }
        return snap
    }

    private func listing(for job: JobConfig, now: Date) -> (workdir: String, base: String)? {
        if let cached = listingCache[job.id], now.timeIntervalSince(cached.at) < 300 { return cached.value }
        var dirs: [URL] = []
        if let w = job.bisyncWorkdir { dirs.append(URL(fileURLWithPath: w)) }
        dirs += paths.defaultBisyncWorkdirs + [paths.legacyBase]
        let value = BisyncListings.locate(job: job, searchDirs: dirs).map { (workdir: $0.workdir.path, base: $0.baseName) }
        listingCache[job.id] = (now, value)
        return value
    }

    private func legacyPlist(_ job: JobConfig) -> LaunchAgentPlist? {
        let url = URL(fileURLWithPath: job.legacyPlistPath)
        let m = JSONStore.modificationDate(url)
        if let c = legacyPlistCache[job.id], c.0 == m { return c.1 }
        let p = try? LaunchAgentPlist.load(url)
        legacyPlistCache[job.id] = (m, p)
        return p
    }

    static func shortReason(_ s: String) -> String {
        let lower = s.lowercased()
        if lower.contains("refused") || lower.contains("拒绝") { return "连接被拒绝，rclone 可能尚未开启接口" }
        if lower.contains("timed out") || lower.contains("超时") { return "响应超时" }
        return String(s.prefix(60))
    }
}
