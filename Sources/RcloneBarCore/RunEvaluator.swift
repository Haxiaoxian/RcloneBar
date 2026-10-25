import Foundation

/// 一轮结束后的判定依据。只有 rclone bisync 整轮成功才算成功：
/// - 直接模式：rclone 自身退出码为 0；
/// - 复用脚本模式：bisync 两份 listing 在本轮内更新、日志无 abort/critical，且脚本退出码为 0（或未知）。
public struct RunEvidence: Sendable {
    public var startedAt: Date
    public var exitCode: Int32?
    /// 退出码是否直接来自 rclone（而非外层脚本）
    public var exitCodeIsRclone: Bool
    public var log: LogAnalysis
    public var logLineCount: Int
    public var listing: BisyncListings.Probe?
    public var legacyStatus: LegacyStatus?
    public var stopRequested: Bool
    public var sawBisyncProcess: Bool
    public var scriptHasRecover: Bool?
    public var rcErrors: Int?

    public init(startedAt: Date, exitCode: Int32?, exitCodeIsRclone: Bool, log: LogAnalysis, logLineCount: Int,
                listing: BisyncListings.Probe?, legacyStatus: LegacyStatus?, stopRequested: Bool, sawBisyncProcess: Bool,
                scriptHasRecover: Bool?, rcErrors: Int?) {
        self.startedAt = startedAt
        self.exitCode = exitCode
        self.exitCodeIsRclone = exitCodeIsRclone
        self.log = log
        self.logLineCount = logLineCount
        self.listing = listing
        self.legacyStatus = legacyStatus
        self.stopRequested = stopRequested
        self.sawBisyncProcess = sawBisyncProcess
        self.scriptHasRecover = scriptHasRecover
        self.rcErrors = rcErrors
    }
}

public struct RunVerdict: Equatable, Sendable {
    public var outcome: RunOutcome
    public var summary: String
    public var category: ErrorCategory?
    public var evidence: [String]

    public init(outcome: RunOutcome, summary: String, category: ErrorCategory?, evidence: [String]) {
        self.outcome = outcome
        self.summary = summary
        self.category = category
        self.evidence = evidence
    }
}

public enum RunEvaluator {
    public static func evaluate(_ e: RunEvidence) -> RunVerdict {
        var ev: [String] = []
        if let c = e.exitCode { ev.append("退出码 \(c)\(e.exitCodeIsRclone ? "（rclone）" : "（执行脚本）")") } else { ev.append("退出码未知") }
        let listingOK = e.listing?.updatedSuccessfully(since: e.startedAt)
        if let ok = listingOK { ev.append(ok ? "bisync listing 已在本轮更新" : "bisync listing 未在本轮更新") }
        if e.log.sawSuccess { ev.append("日志：Bisync successful") }
        if e.log.sawAbort { ev.append("日志：Bisync aborted") }
        if e.log.sawCritical { ev.append("日志：critical error") }
        if e.log.conflicts > 0 { ev.append("日志：\(e.log.conflicts) 处冲突") }
        let cat = e.log.category

        if e.stopRequested {
            if e.log.sawGracefulFailed || e.log.sawResyncRequired {
                if e.scriptHasRecover == true {
                    return RunVerdict(outcome: .stoppedByUser, summary: "已结束本轮，但收尾未完全成功；下一轮会借助 --recover 自动恢复，请留意下一轮结果。", category: cat, evidence: ev)
                }
                return RunVerdict(outcome: .needsAttention, summary: "已结束本轮，但 bisync 报告收尾失败。请查看日志；不要自行删除 bisync 历史。", category: .resyncRequired, evidence: ev)
            }
            return RunVerdict(outcome: .stoppedByUser, summary: "已安全结束本轮（未完整同步），下一轮会重新检查并继续。", category: nil, evidence: ev)
        }

        if cat == .auth {
            return RunVerdict(outcome: .authRequired, summary: "OneDrive 授权可能已失效，需要在终端运行 rclone config reconnect onedrive: 重新授权。", category: .auth, evidence: ev)
        }
        if e.log.sawResyncRequired && !e.log.sawRetryableAbort {
            return RunVerdict(outcome: .needsAttention, summary: "bisync 中止并要求人工处理（--resync）。程序不会自动执行 --resync，请先查看日志与备份。", category: .resyncRequired, evidence: ev)
        }
        if cat == .safetyAbort {
            return RunVerdict(outcome: .needsAttention, summary: "删除数量超过保护阈值，bisync 已中止，未做任何删除。请确认是否为预期操作。", category: .safetyAbort, evidence: ev)
        }
        if cat == .accessCheck {
            return RunVerdict(outcome: .needsAttention, summary: "访问检查标记（RCLONE_TEST）检查失败，已中止以保护数据。", category: .accessCheck, evidence: ev)
        }

        let exitOK: Bool? = e.exitCode.map { $0 == 0 }
        let noAbort = !e.log.sawAbort && !e.log.sawCritical

        if e.exitCodeIsRclone, exitOK == true, noAbort {
            return success(e, ev)
        }
        if listingOK == true, noAbort, exitOK != false {
            return success(e, ev)
        }
        if listingOK == nil, exitOK == true, noAbort, e.log.sawSuccess {
            return success(e, ev)
        }
        if listingOK == nil, exitOK == true, noAbort, let st = e.legacyStatus, let m = st.fileModified,
           m >= e.startedAt.addingTimeInterval(-2), st.stateLooksSuccessful == true {
            ev.append("status.json 在本轮更新且表示成功")
            return success(e, ev)
        }

        let failedSignal = exitOK == false || e.log.sawAbort || e.log.sawCritical || !e.log.errorLines.isEmpty
        if failedSignal {
            let retryable = cat == .network || cat == .retryableAbort || cat == .lockHeld || e.log.sawRetryableAbort
            if retryable {
                let what = cat?.label ?? "可重试的错误"
                return RunVerdict(outcome: .retryableFailure, summary: "\(what)。本轮未完成，将在下一次计划时间自动重试。", category: cat, evidence: ev)
            }
            if listingOK == true && exitOK == false && noAbort {
                return RunVerdict(outcome: .unknown, summary: "bisync listing 已更新，但执行脚本退出码为 \(e.exitCode ?? -1)，结果未确认。", category: cat, evidence: ev)
            }
            let first = e.log.errorLines.last.map { "：" + String(LogParser.parse($0).message.prefix(160)) } ?? ""
            return RunVerdict(outcome: .failed, summary: "同步失败\(first)", category: cat ?? .other, evidence: ev)
        }

        if !e.sawBisyncProcess && e.logLineCount == 0 && exitOK == true {
            return RunVerdict(outcome: .skipped, summary: "执行脚本已退出，但未观察到 bisync 运行（可能被脚本跳过）。", category: nil, evidence: ev)
        }
        return RunVerdict(outcome: .unknown, summary: "进程已退出，但无法确认 bisync 是否整轮成功。", category: nil, evidence: ev)
    }

    private static func success(_ e: RunEvidence, _ ev: [String]) -> RunVerdict {
        let summary = e.log.conflicts > 0 ? "同步成功，发现 \(e.log.conflicts) 处冲突（已按 bisync 设置保留冲突副本）。" : "同步成功。"
        return RunVerdict(outcome: .success, summary: summary, category: nil, evidence: ev)
    }
}
