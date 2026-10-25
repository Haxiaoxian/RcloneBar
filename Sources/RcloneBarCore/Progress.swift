import Foundation

/// 界面上展示的“当前活动”。注意：进程在运行 ≠ 正在传输；进程退出 ≠ 同步成功。
public enum Activity: String, Codable, Sendable {
    case idle            // 未运行
    case starting        // 已发起，等待 rclone 启动
    case scanning        // 列目录 / 比较差异，总量未知
    case transferring    // 有文件正在传输或传输队列未完成
    case finishing       // 传输已完成，仍在更新 listing、校验或收尾
    case stopping        // 已请求安全结束
    case runningNoDetail // 进程在运行，但没有可用的实时数据（RC 未开启或无响应）

    public var label: String {
        switch self {
        case .idle: return "空闲"
        case .starting: return "正在启动"
        case .scanning: return "正在扫描"
        case .transferring: return "正在传输"
        case .finishing: return "正在校验或收尾"
        case .stopping: return "正在安全结束"
        case .runningNoDetail: return "正在运行"
        }
    }

    public var isActive: Bool { self != .idle }
}

public struct CurrentFile: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var percentage: Int?
    public var size: Int64?
    public var speed: Double?

    public init(name: String, percentage: Int? = nil, size: Int64? = nil, speed: Double? = nil) {
        self.name = name
        self.percentage = percentage
        self.size = size
        self.speed = speed
    }
}

public enum ProgressSource: String, Sendable {
    case rc, log, none
}

public struct JobProgress: Equatable, Sendable {
    public var activity: Activity = .idle
    public var source: ProgressSource = .none
    public var bytesDone: Int64?
    public var totalBytes: Int64?
    /// 已知总量最近仍在增加（文件枚举尚未结束）
    public var totalsGrowing = false
    public var filesDone: Int?
    public var totalFiles: Int?
    public var checks: Int?
    public var totalChecks: Int?
    public var listed: Int?
    public var speed: Double?
    /// 仅当可靠时才有值
    public var eta: TimeInterval?
    /// nil 表示进度未知（界面显示不确定进度条，而不是 0% 或 100%）
    public var fraction: Double?
    public var currentFiles: [CurrentFile] = []
    public var errorsThisRun = 0
    public var lastErrorThisRun: String?

    public init() {}

    /// 有传输活动但 ETA 不可靠时显示“估算中”
    public var etaText: String? {
        guard activity == .transferring else { return nil }
        if let eta { return "约 " + Formatters.duration(eta) }
        return "估算中"
    }
}

/// 根据 RC 统计、日志阶段与运行状态推断进度。带少量历史（总量变化时间），每组任务一个实例。
public struct ProgressTracker: Sendable {
    public private(set) var lastTotalBytes: Int64 = 0
    public private(set) var lastTotalFiles: Int = 0
    public private(set) var lastTotalsChange: Date?
    public private(set) var runKey: String?

    public static let growingWindow: TimeInterval = 5

    public init() {}

    public mutating func reset(runKey: String?) {
        self = ProgressTracker()
        self.runKey = runKey
    }

    /// - Parameters:
    ///   - running: 该组 bisync / 执行器是否仍在运行
    ///   - starting: 已发起但 rclone 尚未出现
    ///   - stopRequested: 用户已请求安全结束
    ///   - stats: RC 统计（nil = 不可用）
    ///   - logPhase: 日志中最近的阶段标记（仅本轮）
    ///   - textStats: 日志文本统计（RC 不可用时的补充）
    public mutating func update(running: Bool, starting: Bool, stopRequested: Bool, stats: CoreStats?,
                                logPhase: PhaseMarker?, textStats: TextStats?, now: Date = Date()) -> JobProgress {
        var p = JobProgress()
        guard running || starting else {
            p.activity = .idle
            return p
        }
        if let stats {
            p.source = .rc
            fill(&p, from: stats, now: now)
            p.activity = Self.activity(from: stats, logPhase: logPhase)
        } else if let t = textStats {
            p.source = .log
            p.bytesDone = t.bytes
            p.totalBytes = (t.totalBytes ?? 0) > 0 ? t.totalBytes : nil
            p.filesDone = t.transfers
            p.totalFiles = (t.totalTransfers ?? 0) > 0 ? t.totalTransfers : nil
            p.checks = t.checks
            p.totalChecks = t.totalChecks
            p.listed = t.listed
            p.speed = t.speed
            noteTotals(bytes: t.totalBytes ?? 0, files: t.totalTransfers ?? 0, now: now)
            p.totalsGrowing = isGrowing(now: now)
            p.activity = Self.activity(fromLog: logPhase, text: t)
            if p.activity == .transferring, let eta = t.eta, eta > 0, !p.totalsGrowing { p.eta = eta }
        } else {
            p.activity = starting ? .starting : (logPhase.map { Self.activity(fromLog: $0, text: nil) } ?? .runningNoDetail)
        }
        if starting && stats == nil && textStats == nil { p.activity = .starting }
        if stopRequested { p.activity = .stopping }

        // 进度条：只有在传输/收尾阶段且已知总量 > 0 时才给出比例
        switch p.activity {
        case .transferring, .finishing, .stopping:
            if let total = p.totalBytes, total > 0, let done = p.bytesDone {
                p.fraction = min(1, max(0, Double(done) / Double(total)))
            } else if let tf = p.totalFiles, tf > 0, let fd = p.filesDone {
                p.fraction = min(1, max(0, Double(fd) / Double(tf)))
            }
        default:
            p.fraction = nil
        }
        if p.activity != .transferring { p.eta = nil }
        return p
    }

    private mutating func fill(_ p: inout JobProgress, from s: CoreStats, now: Date) {
        p.bytesDone = s.bytes
        p.totalBytes = s.totalBytes > 0 ? s.totalBytes : nil
        p.filesDone = s.transfers
        p.totalFiles = s.totalTransfers > 0 ? s.totalTransfers : nil
        p.checks = s.checks
        p.totalChecks = s.totalChecks > 0 ? s.totalChecks : nil
        p.listed = s.listed
        p.speed = s.speed > 0 ? s.speed : nil
        p.errorsThisRun = s.errors
        p.lastErrorThisRun = s.lastError.map(Redactor.redact)
        p.currentFiles = s.transferring.map {
            CurrentFile(name: $0.name, percentage: $0.percentage, size: $0.size, speed: $0.speed)
        }
        noteTotals(bytes: s.totalBytes, files: s.totalTransfers, now: now)
        p.totalsGrowing = isGrowing(now: now)
        if let eta = s.eta, eta > 0, !p.totalsGrowing, s.totalBytes > 0 { p.eta = eta }
    }

    private mutating func noteTotals(bytes: Int64, files: Int, now: Date) {
        if bytes != lastTotalBytes || files != lastTotalFiles {
            // 首次出现总量不算“增长中”，此后的变化才算
            if lastTotalBytes > 0 || lastTotalFiles > 0 { lastTotalsChange = now }
            lastTotalBytes = bytes
            lastTotalFiles = files
        }
    }

    private func isGrowing(now: Date) -> Bool {
        guard let t = lastTotalsChange else { return false }
        return now.timeIntervalSince(t) < Self.growingWindow
    }

    public static func activity(from s: CoreStats, logPhase: PhaseMarker?) -> Activity {
        switch logPhase {
        case .updatingListings, .validating: return .finishing
        case .gracefulShutdown: return .stopping
        default: break
        }
        if !s.transferring.isEmpty { return .transferring }
        if s.totalTransfers > 0 && s.transfers + s.errors < s.totalTransfers { return .transferring }
        if s.totalTransfers > 0 { return .finishing } // 传输量已满但进程未结束：仍在校验/收尾
        if logPhase == .applying && !s.checking.isEmpty { return .scanning }
        if logPhase == .noChanges || logPhase == .finished { return .finishing }
        return .scanning
    }

    static func activity(fromLog phase: PhaseMarker?, text: TextStats?) -> Activity {
        switch phase {
        case .listing, .checkingDiffs, .checkingAccess: return .scanning
        case .applying:
            if let t = text, let total = t.totalTransfers, total > 0, (t.transfers ?? 0) >= total { return .finishing }
            return .transferring
        case .noChanges, .updatingListings, .validating, .finished: return .finishing
        case .gracefulShutdown: return .stopping
        case nil:
            guard let t = text else { return .runningNoDetail }
            if let total = t.totalTransfers, total > 0 {
                return (t.transfers ?? 0) >= total ? .finishing : .transferring
            }
            return .scanning
        }
    }
}

// MARK: - 总体状态（菜单栏图标）

public enum OverallState: Equatable, Sendable {
    case transferring, scanning, finishing, stopping, starting
    case error(String)
    case paused
    case success
    case idle
    case agentDown

    public var label: String {
        switch self {
        case .transferring: return "正在传输"
        case .scanning: return "正在扫描"
        case .finishing: return "正在校验或收尾"
        case .stopping: return "正在安全结束"
        case .starting: return "正在启动"
        case .error(let s): return s
        case .paused: return "已暂停自动同步"
        case .success: return "最近一轮同步成功"
        case .idle: return "空闲，等待下一次同步"
        case .agentDown: return "后台服务未运行"
        }
    }
}

public enum OverallStateResolver {
    public struct Input: Sendable {
        public var activity: Activity
        public var lastOutcome: RunOutcome?
        public var lastErrorCategory: ErrorCategory?
        public var paused: Bool
        public init(activity: Activity, lastOutcome: RunOutcome?, lastErrorCategory: ErrorCategory?, paused: Bool) {
            self.activity = activity
            self.lastOutcome = lastOutcome
            self.lastErrorCategory = lastErrorCategory
            self.paused = paused
        }
    }

    public static func resolve(_ jobs: [Input], agentAvailable: Bool, allPaused: Bool) -> OverallState {
        let acts = jobs.map(\.activity)
        if acts.contains(.transferring) { return .transferring }
        if acts.contains(.stopping) { return .stopping }
        if acts.contains(.finishing) { return .finishing }
        if acts.contains(.scanning) || acts.contains(.runningNoDetail) { return .scanning }
        if acts.contains(.starting) { return .starting }
        if let failed = jobs.first(where: { $0.lastOutcome?.isFailure == true }) {
            if failed.lastOutcome == .authRequired || failed.lastErrorCategory == .auth { return .error("需要重新授权") }
            if failed.lastErrorCategory == .network || failed.lastOutcome == .retryableFailure { return .error("网络异常或可重试错误") }
            return .error("同步失败，需要查看")
        }
        if !agentAvailable { return .agentDown }
        if allPaused || (!jobs.isEmpty && jobs.allSatisfy(\.paused)) { return .paused }
        if !jobs.isEmpty && jobs.allSatisfy({ $0.lastOutcome == .success }) { return .success }
        return .idle
    }
}
