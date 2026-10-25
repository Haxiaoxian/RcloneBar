import Foundation

// MARK: - 任务配置（jobs.json，由接入程序生成，后台服务读取）

public enum LaunchMode: String, Codable, Sendable {
    /// 复用现有 LaunchAgent（sync.py）作为“执行器”，由 rclonebar-agent 通过 launchctl kickstart 按需启动。
    case launchd
    /// 由 rclonebar-agent 直接启动命令（用于测试或没有旧脚本的情况）。
    case direct
}

public struct DirectCommand: Codable, Hashable, Sendable {
    public var program: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    /// stdout/stderr 追加写入的文件
    public var logFile: String?

    public init(program: String, arguments: [String], environment: [String: String] = [:], workingDirectory: String? = nil, logFile: String? = nil) {
        self.program = program
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.logFile = logFile
    }
}

public struct JobConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var localPath: String
    public var remotePath: String
    public var legacyLabel: String
    public var legacyPlistPath: String
    public var statusFile: String
    public var logFiles: [String]
    public var rcPort: Int
    public var launchMode: LaunchMode
    public var direct: DirectCommand?
    /// 接入检查时发现的 bisync 工作目录（存放历史 listing）
    public var bisyncWorkdir: String?
    /// 接入检查时在脚本中发现了 --recover（安全结束后下一轮可自动恢复）
    public var scriptHasRecover: Bool?

    public init(id: String, displayName: String, localPath: String, remotePath: String, legacyLabel: String,
                legacyPlistPath: String, statusFile: String, logFiles: [String], rcPort: Int,
                launchMode: LaunchMode = .launchd, direct: DirectCommand? = nil, bisyncWorkdir: String? = nil,
                scriptHasRecover: Bool? = nil) {
        self.id = id
        self.displayName = displayName
        self.localPath = localPath
        self.remotePath = remotePath
        self.legacyLabel = legacyLabel
        self.legacyPlistPath = legacyPlistPath
        self.statusFile = statusFile
        self.logFiles = logFiles
        self.rcPort = rcPort
        self.launchMode = launchMode
        self.direct = direct
        self.bisyncWorkdir = bisyncWorkdir
        self.scriptHasRecover = scriptHasRecover
    }

    /// 默认的两组任务（来自现有环境描述；接入检查会再次核对）。
    public static func defaults(paths: AppPaths) -> [JobConfig] {
        let docs = paths.home.appendingPathComponent("Documents")
        let legacy = paths.legacyBase
        return [
            JobConfig(
                id: "vault", displayName: "主仓库",
                localPath: docs.appendingPathComponent("主仓库").path,
                remotePath: "onedrive:其他/Obsidian/主仓库",
                legacyLabel: "com.zhuke.rclone-bisync.vault",
                legacyPlistPath: paths.launchAgentsDir.appendingPathComponent("com.zhuke.rclone-bisync.vault.plist").path,
                statusFile: legacy.appendingPathComponent("state/vault/status.json").path,
                logFiles: [legacy.appendingPathComponent("logs/vault.log").path],
                rcPort: 55721
            ),
            JobConfig(
                id: "projects", displayName: "项目",
                localPath: docs.appendingPathComponent("项目").path,
                remotePath: "onedrive:项目",
                legacyLabel: "com.zhuke.rclone-bisync.projects",
                legacyPlistPath: paths.launchAgentsDir.appendingPathComponent("com.zhuke.rclone-bisync.projects.plist").path,
                statusFile: legacy.appendingPathComponent("state/projects/status.json").path,
                logFiles: [legacy.appendingPathComponent("logs/projects.log").path],
                rcPort: 55722
            ),
        ]
    }
}

public struct JobsFile: Codable, Sendable {
    public var version: Int
    public var jobs: [JobConfig]
    public var createdAt: Date

    public init(jobs: [JobConfig], createdAt: Date = Date()) {
        self.version = 1
        self.jobs = jobs
        self.createdAt = createdAt
    }
}

// MARK: - 设置（settings.json，由 App 写入，后台服务读取）

public struct SyncSettings: Codable, Equatable, Sendable {
    public static let intervalChoices = [1, 5, 10, 30, 60]

    public var intervalMinutes: Int = 5
    public var pausedAll: Bool = false
    public var pausedJobs: [String] = []
    /// 关闭时不干预限速（沿用脚本自身参数）
    public var bandwidthControlEnabled: Bool = false
    /// KiB/s，0 表示不限
    public var uploadLimitKiB: Int = 0
    public var downloadLimitKiB: Int = 0
    /// nil 表示沿用脚本默认
    public var transfers: Int? = nil
    public var showSpeedInMenuBar: Bool = true
    public var notifyFailures: Bool = true
    public var notifyConflicts: Bool = true
    public var notifyAuth: Bool = true
    /// 每组任务的 OneDrive 网页地址（可选）
    public var webURLs: [String: String] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case intervalMinutes, pausedAll, pausedJobs, bandwidthControlEnabled, uploadLimitKiB, downloadLimitKiB,
             transfers, showSpeedInMenuBar, notifyFailures, notifyConflicts, notifyAuth, webURLs
    }

    // 字段缺失时使用默认值，便于以后增加设置项而不破坏旧文件。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SyncSettings()
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        pausedAll = try c.decodeIfPresent(Bool.self, forKey: .pausedAll) ?? d.pausedAll
        pausedJobs = try c.decodeIfPresent([String].self, forKey: .pausedJobs) ?? d.pausedJobs
        bandwidthControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .bandwidthControlEnabled) ?? d.bandwidthControlEnabled
        uploadLimitKiB = try c.decodeIfPresent(Int.self, forKey: .uploadLimitKiB) ?? d.uploadLimitKiB
        downloadLimitKiB = try c.decodeIfPresent(Int.self, forKey: .downloadLimitKiB) ?? d.downloadLimitKiB
        transfers = try c.decodeIfPresent(Int.self, forKey: .transfers)
        showSpeedInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showSpeedInMenuBar) ?? d.showSpeedInMenuBar
        notifyFailures = try c.decodeIfPresent(Bool.self, forKey: .notifyFailures) ?? d.notifyFailures
        notifyConflicts = try c.decodeIfPresent(Bool.self, forKey: .notifyConflicts) ?? d.notifyConflicts
        notifyAuth = try c.decodeIfPresent(Bool.self, forKey: .notifyAuth) ?? d.notifyAuth
        webURLs = try c.decodeIfPresent([String: String].self, forKey: .webURLs) ?? d.webURLs
    }

    public var interval: TimeInterval { TimeInterval(max(1, intervalMinutes) * 60) }

    public func isPaused(_ jobID: String) -> Bool { pausedAll || pausedJobs.contains(jobID) }

    /// rclone --bwlimit 的 "上传:下载" 写法；nil 表示不干预。
    public var bwlimitRate: String? {
        guard bandwidthControlEnabled else { return nil }
        if uploadLimitKiB <= 0 && downloadLimitKiB <= 0 { return "off" }
        func side(_ v: Int) -> String { v > 0 ? "\(v)k" : "off" }
        return "\(side(uploadLimitKiB)):\(side(downloadLimitKiB))"
    }

    /// 在下一轮启动时注入给 rclone 的环境变量（RC 相关变量另外添加）。
    public func runEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        if let t = transfers, t > 0 { env["RCLONE_TRANSFERS"] = String(t) }
        if let rate = bwlimitRate { env["RCLONE_BWLIMIT"] = rate }
        return env
    }
}

/// 给某组任务的 rclone 进程开启独立 RC：只监听 127.0.0.1，使用 htpasswd 认证（文件中只有哈希，不含明文）。
public func rcEnvironment(port: Int, htpasswdPath: String) -> [String: String] {
    [
        "RCLONE_RC": "true",
        "RCLONE_RC_ADDR": "127.0.0.1:\(port)",
        "RCLONE_RC_HTPASSWD": htpasswdPath,
    ]
}

// MARK: - 后台服务运行状态（agent-state.json，由后台服务写入，App 读取）

public enum RuntimePhase: String, Codable, Sendable {
    case idle, starting, running, stopping
}

public enum RunTrigger: String, Codable, Sendable {
    case scheduled, manual, external, adopted

    public var label: String {
        switch self {
        case .scheduled: return "定时"
        case .manual: return "手动"
        case .external: return "外部启动"
        case .adopted: return "接续"
        }
    }
}

public enum RunOutcome: String, Codable, Sendable {
    case success
    case stoppedByUser
    case retryableFailure
    case failed
    case needsAttention
    case authRequired
    case skipped
    case unknown

    public var label: String {
        switch self {
        case .success: return "成功"
        case .stoppedByUser: return "已手动结束"
        case .retryableFailure: return "可重试的错误"
        case .failed: return "失败"
        case .needsAttention: return "需要处理"
        case .authRequired: return "需要重新授权"
        case .skipped: return "未执行"
        case .unknown: return "结果未知"
        }
    }

    public var isFailure: Bool {
        switch self {
        case .retryableFailure, .failed, .needsAttention, .authRequired: return true
        default: return false
        }
    }
}

public struct StatsSample: Codable, Equatable, Sendable {
    public var at: Date
    public var bytes: Int64
    public var totalBytes: Int64
    public var transfers: Int
    public var totalTransfers: Int
    public var errors: Int

    public init(at: Date, bytes: Int64, totalBytes: Int64, transfers: Int, totalTransfers: Int, errors: Int) {
        self.at = at
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.transfers = transfers
        self.totalTransfers = totalTransfers
        self.errors = errors
    }
}

public struct JobRuntime: Codable, Equatable, Sendable {
    public var phase: RuntimePhase = .idle
    public var runID: String?
    public var trigger: RunTrigger?
    public var jobPID: Int32?
    public var rclonePID: Int32?
    public var runStartedAt: Date?
    public var stopRequestedAt: Date?
    public var interruptSignals: Int = 0
    /// 本轮启动时是否注入了 RC（外部启动/接续的进程可能没有）
    public var rcEnabled: Bool = false
    public var nextRunAt: Date?
    public var lastFinishedAt: Date?
    public var lastSuccessAt: Date?
    public var lastOutcome: RunOutcome?
    public var lastSummary: String?
    public var consecutiveFailures: Int = 0
    /// 已写入执行器（LaunchAgent）的环境变量指纹
    public var appliedEnvFingerprint: String?
    /// 设置已修改但当前一轮仍在运行，下一轮生效
    public var settingsPendingNextRun: Bool = false
    public var lastStats: StatsSample?
    /// 本轮 rclone 实际生效的并发数 / 限速（通过 RC 读取）
    public var effectiveTransfers: Int?
    public var effectiveBwlimit: String?
    public var notice: String?

    public init() {}
}

public struct AgentState: Codable, Equatable, Sendable {
    public var agentPID: Int32
    public var agentVersion: String
    public var startedAt: Date
    public var updatedAt: Date
    public var appliedIntervalMinutes: Int
    public var jobs: [String: JobRuntime]
    public var commandResults: [CommandResult]

    public init(agentPID: Int32, agentVersion: String, startedAt: Date, updatedAt: Date, appliedIntervalMinutes: Int,
                jobs: [String: JobRuntime], commandResults: [CommandResult]) {
        self.agentPID = agentPID
        self.agentVersion = agentVersion
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.appliedIntervalMinutes = appliedIntervalMinutes
        self.jobs = jobs
        self.commandResults = commandResults
    }

    public func isFresh(now: Date = Date(), tolerance: TimeInterval = 15) -> Bool {
        now.timeIntervalSince(updatedAt) < tolerance
    }
}

// MARK: - 运行记录（runs.jsonl，每行一条）

public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var jobID: String
    public var trigger: RunTrigger
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: RunOutcome
    public var exitCode: Int32?
    public var summary: String
    public var errors: [String]
    public var conflicts: Int
    public var bytes: Int64?
    public var transfers: Int?
    public var rcEnabled: Bool
    /// 判定依据（便于排查）
    public var evidence: [String]

    public init(id: String, jobID: String, trigger: RunTrigger, startedAt: Date, finishedAt: Date, outcome: RunOutcome,
                exitCode: Int32?, summary: String, errors: [String], conflicts: Int, bytes: Int64?, transfers: Int?,
                rcEnabled: Bool, evidence: [String]) {
        self.id = id
        self.jobID = jobID
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.exitCode = exitCode
        self.summary = summary
        self.errors = errors
        self.conflicts = conflicts
        self.bytes = bytes
        self.transfers = transfers
        self.rcEnabled = rcEnabled
        self.evidence = evidence
    }
}

// MARK: - 控制命令（App → 后台服务，control/*.json）

public enum ControlAction: String, Codable, Sendable {
    /// 立即同步（忽略自动调度暂停，但不会重复启动）
    case syncNow
    /// 安全结束当前一轮（向 rclone 发送 SIGINT，走 bisync 的正常收尾）
    case stop
    /// 再次发送中断信号：rclone 会立即非正常退出（高级操作）
    case forceInterrupt
}

public struct ControlCommand: Codable, Sendable {
    public var id: String
    public var action: ControlAction
    /// nil 表示全部任务
    public var jobID: String?
    public var createdAt: Date

    public init(action: ControlAction, jobID: String?, createdAt: Date = Date(), id: String = UUID().uuidString) {
        self.id = id
        self.action = action
        self.jobID = jobID
        self.createdAt = createdAt
    }
}

public struct CommandResult: Codable, Equatable, Sendable {
    public var commandID: String
    public var action: ControlAction
    public var jobID: String?
    public var at: Date
    public var accepted: Bool
    public var message: String

    public init(commandID: String, action: ControlAction, jobID: String?, at: Date, accepted: Bool, message: String) {
        self.commandID = commandID
        self.action = action
        self.jobID = jobID
        self.at = at
        self.accepted = accepted
        self.message = message
    }
}

/// 接入记录：接入后写入，回退时据此恢复。
public struct InstallRecord: Codable, Sendable {
    public struct LegacyEntry: Codable, Sendable {
        public var label: String
        public var plistPath: String
        public var backupPath: String
        public var wasLoaded: Bool
        public var wasDisabled: Bool?
    }

    public var installedAt: Date
    public var backupDir: String
    public var legacy: [LegacyEntry]
    public var agentVersion: String
}
