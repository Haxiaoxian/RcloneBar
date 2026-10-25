import Foundation
import UserNotifications
import RcloneBarCore

/// 系统通知：只在失败、需要重新授权、出现冲突时提醒；成功不提醒。
/// 可重试错误（如短暂断网）连续 3 次才提醒一次，避免每 5 分钟打扰。
@MainActor
final class Notifier {
    private let defaults = UserDefaults.standard
    private let lastKey = "lastNotifiedRunFinishedAt"
    private var authorized: Bool?
    private var observeSeen: [String: Date] = [:]

    private var lastNotified: Date {
        get { (defaults.object(forKey: lastKey) as? Date) ?? .distantPast }
        set { defaults.set(newValue, forKey: lastKey) }
    }

    init() {
        // 首次运行不补发历史记录
        if defaults.object(forKey: lastKey) == nil { lastNotified = Date() }
    }

    func requestAuthorizationIfNeeded() {
        guard authorized == nil else { return }
        authorized = false
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor [weak self] in self?.authorized = granted }
        }
    }

    func process(snapshot: Snapshot, settings: SyncSettings) {
        guard settings.notifyFailures || settings.notifyConflicts || settings.notifyAuth else { return }
        requestAuthorizationIfNeeded()
        let names = Dictionary(uniqueKeysWithValues: snapshot.jobs.map { ($0.id, $0.config.displayName) })
        let failures = Dictionary(uniqueKeysWithValues: snapshot.jobs.map { ($0.id, $0.consecutiveFailures) })

        if snapshot.mode == .managed {
            let fresh = snapshot.recentRuns.filter { $0.finishedAt > lastNotified }.sorted { $0.finishedAt < $1.finishedAt }
            for run in fresh {
                notify(run: run, name: names[run.jobID] ?? run.jobID, consecutive: failures[run.jobID] ?? 0, settings: settings)
            }
            if let last = fresh.last { lastNotified = last.finishedAt }
        } else {
            // 观察模式：根据旧日志 / 状态文件推断出的失败
            for job in snapshot.jobs {
                guard let outcome = job.lastOutcome, outcome.isFailure, let t = job.lastFinishedAt, t > lastNotified else { continue }
                if observeSeen[job.id] == t { continue }
                observeSeen[job.id] = t
                if outcome == .authRequired ? settings.notifyAuth : settings.notifyFailures {
                    post(title: "\(job.config.displayName)：\(outcome.label)", body: job.lastSummary ?? "请打开 RcloneBar 查看日志", id: "observe-\(job.id)-\(t.timeIntervalSince1970)")
                }
            }
        }
    }

    private func notify(run: RunRecord, name: String, consecutive: Int, settings: SyncSettings) {
        switch run.outcome {
        case .authRequired where settings.notifyAuth:
            post(title: "\(name)：需要重新授权 OneDrive", body: run.summary, id: run.id)
        case .failed, .needsAttention:
            if settings.notifyFailures { post(title: "\(name)：同步失败", body: run.summary, id: run.id) }
        case .retryableFailure:
            // 可重试错误：连续 3 次、之后每 12 次提醒一次
            if settings.notifyFailures, consecutive == 3 || (consecutive > 3 && consecutive % 12 == 0) {
                post(title: "\(name)：已连续 \(consecutive) 次未完成", body: run.summary, id: run.id)
            }
        default:
            break
        }
        if run.conflicts > 0, settings.notifyConflicts {
            post(title: "\(name)：发现 \(run.conflicts) 处冲突", body: "bisync 已按设置保留冲突副本，请在本地目录中检查带冲突后缀的文件。", id: run.id + "-conflict")
        }
    }

    func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func sendTest() {
        requestAuthorizationIfNeeded()
        post(title: "RcloneBar 测试通知", body: "通知已开启。同步失败、需要重新授权或出现冲突时会这样提醒；成功不会提醒。", id: UUID().uuidString)
    }
}
