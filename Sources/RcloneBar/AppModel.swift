import SwiftUI
import AppKit
import ServiceManagement
import RcloneBarCore

/// 控制刷新节奏：活动时约 1 秒，空闲时 5 秒；用户操作后立即刷新。
actor RefreshSignal {
    private var nudged = false
    func nudge() { nudged = true }
    func consume() -> Bool {
        defer { nudged = false }
        return nudged
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published var settings: Settings
    @Published var toast: String?
    @Published var loginItemEnabled = false
    @Published var serviceOutput: String = ""
    @Published var serviceBusy = false
    @Published var inspectionText: String = ""

    let paths = AppPaths()
    private let collector: StatusCollector
    private let refresh = RefreshSignal()
    private var loopTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastShownCommandID: String?
    let notifier = Notifier()

    init() {
        collector = StatusCollector(paths: paths)
        settings = JSONStore.read(Settings.self, from: AppPaths().settingsFile) ?? Settings()
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        start()
    }

    var isManaged: Bool { snapshot?.mode == .managed }
    var jobs: [JobSnapshot] { snapshot?.jobs ?? [] }

    // MARK: 刷新循环（在后台执行，不阻塞主线程）

    private func start() {
        let collector = self.collector
        let refresh = self.refresh
        loopTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let snap = await collector.collect()
                await self?.apply(snap)
                let interval: Double = snap.anyActive ? 1 : 5
                var waited = 0.0
                while waited < interval {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    waited += 0.25
                    if await refresh.consume() { break }
                }
            }
        }
    }

    func refreshSoon() {
        Task { await refresh.nudge() }
    }

    private func apply(_ snap: Snapshot) {
        if snapshot != snap { snapshot = snap }
        // 后台服务的命令回执
        if let r = snap.lastCommandResult, r.commandID != lastShownCommandID, Date().timeIntervalSince(r.at) < 10 {
            lastShownCommandID = r.commandID
            show(r.message)
        }
        // 其他地方（例如命令行）修改了设置时同步到界面
        if saveTask == nil, snap.settings != settings, snap.mode == .managed {
            settings = snap.settings
        }
        notifier.process(snapshot: snap, settings: settings)
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: 设置（写入 settings.json，后台服务约 1 秒内读取）

    func updateSettings(_ change: (inout Settings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                try JSONStore.write(self.settings, to: self.paths.settingsFile)
            } catch {
                self.show("保存设置失败：\(error.localizedDescription)")
            }
            self.saveTask = nil
            self.refreshSoon()
        }
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("无法修改登录项：\(error.localizedDescription)")
        }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            show("请在“系统设置 → 通用 → 登录项”中允许 RcloneBar")
        }
    }

    // MARK: 操作

    func syncAll() { sync(nil) }

    func sync(_ job: JobSnapshot?) {
        if isManaged {
            send(.syncNow, job: job)
        } else {
            // 未接管：通过原 LaunchAgent 启动（launchctl kickstart 不会重复启动正在运行的任务）
            let targets = job.map { [$0] } ?? jobs
            Task.detached {
                var msgs: [String] = []
                for j in targets {
                    if j.running { msgs.append("\(j.config.displayName) 正在同步，已忽略"); continue }
                    let r = Launchctl.kickstart(j.config.legacyLabel)
                    msgs.append(r.ok ? "已请求原 LaunchAgent 同步\(j.config.displayName)" : "\(j.config.displayName) 启动失败：\(r.stderr)")
                }
                await MainActor.run { [weak self] in
                    self?.show(msgs.joined(separator: "；"))
                    self?.refreshSoon()
                }
            }
        }
    }

    func togglePause(_ job: JobSnapshot) {
        updateSettings { s in
            if s.pausedJobs.contains(job.id) {
                s.pausedJobs.removeAll { $0 == job.id }
                if s.pausedAll {
                    // 从“全部暂停”中单独恢复某一组
                    s.pausedAll = false
                    s.pausedJobs = jobs.map(\.id).filter { $0 != job.id }
                }
            } else if s.pausedAll {
                s.pausedAll = false
                s.pausedJobs = jobs.map(\.id).filter { $0 != job.id }
            } else {
                s.pausedJobs.append(job.id)
            }
        }
        show(settings.isPaused(job.id) ? "已暂停\(job.config.displayName)的自动调度（正在进行的一轮会继续完成）" : "已恢复\(job.config.displayName)的自动调度")
    }

    var allPaused: Bool { settings.pausedAll || (!jobs.isEmpty && jobs.allSatisfy { settings.isPaused($0.id) }) }

    func togglePauseAll() {
        let pause = !allPaused
        updateSettings { s in
            s.pausedAll = pause
            if !pause { s.pausedJobs = [] }
        }
        show(pause ? "已暂停全部自动调度（正在进行的同步会继续完成）" : "已恢复全部自动调度")
    }

    func stop(_ job: JobSnapshot) {
        let alert = NSAlert()
        alert.messageText = "安全结束“\(job.config.displayName)”的本轮同步？"
        alert.informativeText = "RcloneBar 会向 rclone 发送中断信号，由 bisync 完成或取消进行中的传输并保存状态（通常不超过 90 秒）。本轮不会完整同步，下一轮会重新检查。\n\n这与“暂停自动调度”不同：暂停只是不再启动新的一轮。"
        if job.config.scriptHasRecover == false {
            alert.informativeText += "\n\n注意：接入检查未在脚本中发现 --recover，结束后下一轮可能需要人工处理。"
        }
        alert.addButton(withTitle: "安全结束本轮")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if isManaged {
            send(.stop, job: job)
        } else {
            Task.detached {
                let procs = ProcessScanner.list { ProcessScanner.isRcloneName($0) }
                let pids = BisyncMatcher.bisyncProcesses(for: job.config, in: procs).map(\.pid)
                let ok = pids.map { ProcessScanner.sendSignal(SIGINT, to: $0) }.contains(true)
                await MainActor.run { [weak self] in
                    self?.show(ok ? "已向 rclone 发送中断信号，正在收尾" : "没有找到正在运行的 bisync 进程")
                    self?.refreshSoon()
                }
            }
        }
    }

    func forceInterrupt(_ job: JobSnapshot) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "立即中断“\(job.config.displayName)”？"
        alert.informativeText = "再次发送中断信号会让 rclone 立即退出，不再等待收尾。bisync 可能需要在下一轮借助 --recover 恢复，极端情况下需要人工处理。仅在“安全结束”长时间没有完成时使用。"
        alert.addButton(withTitle: "立即中断")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        send(.forceInterrupt, job: job)
    }

    private func send(_ action: ControlAction, job: JobSnapshot?) {
        let cmd = ControlCommand(action: action, jobID: job?.id)
        let paths = self.paths
        Task.detached {
            do { try ControlChannel.send(cmd, paths: paths) } catch {
                await MainActor.run { [weak self] in self?.show("发送命令失败：\(error.localizedDescription)") }
            }
        }
        if snapshot?.agentAlive == false { show("后台服务未运行：命令已排队，服务恢复后 2 分钟内仍会执行") }
        refreshSoon()
    }

    // MARK: 打开目录 / 网页

    func openLocal(_ job: JobSnapshot) {
        NSWorkspace.shared.open(URL(fileURLWithPath: job.config.localPath, isDirectory: true))
    }

    func webURL(for job: JobSnapshot) -> URL {
        if let s = settings.webURLs[job.id], let u = URL(string: s), !s.isEmpty { return u }
        return URL(string: "https://onedrive.live.com/")!
    }

    func openWeb(_ job: JobSnapshot) { NSWorkspace.shared.open(webURL(for: job)) }

    func openLog(_ job: JobSnapshot) {
        let urls = job.config.logFiles.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { show("还没有日志文件"); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openFolder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            show("目录不存在：\(url.path)")
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("已复制")
    }

    func errorDetails(_ job: JobSnapshot) -> String {
        var lines = ["\(job.config.displayName)：\(job.lastOutcome?.label ?? "")", job.lastSummary ?? ""]
        if let t = job.lastFinishedAt { lines.append("时间：\(Formatters.full(t))") }
        if !job.lastErrors.isEmpty {
            lines.append("")
            lines += job.lastErrors
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 后台服务（接入 / 回退）

    var bundledAgent: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rclonebar-agent")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    var installedAgentVersionMismatch: Bool {
        guard isManaged, let v = snapshot?.agentVersion else { return false }
        return v != RcloneBarVersion.current
    }

    func runAgent(_ args: [String], title: String) {
        guard let agent = bundledAgent else {
            serviceOutput = "未在 App 包内找到 rclonebar-agent（请使用 scripts/build-app.sh 构建的 .app）"
            return
        }
        serviceBusy = true
        serviceOutput = "\(title)……\n"
        Task.detached {
            let r = Shell.run(agent.path, args, timeout: 120)
            let text = (r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.serviceBusy = false
                self.serviceOutput = "\(title)\(r.ok ? "完成" : "未完成")\n\n" + text
                if args.first == "inspect" { self.inspectionText = text }
                self.settings = JSONStore.read(Settings.self, from: self.paths.settingsFile) ?? self.settings
                self.refreshSoon()
            }
        }
    }

    func inspect() { runAgent(["inspect"], title: "接入检查") }

    func install() {
        let alert = NSAlert()
        alert.messageText = "接管现有同步任务？"
        alert.informativeText = """
        将执行：
        1. 备份两个 LaunchAgent、sync.py 与状态文件到 RcloneBar/backups；
        2. 去掉原 LaunchAgent 的自动调度（StartInterval 等），保留原命令、日志与授权，改为由 RcloneBar 后台服务按需启动；
        3. 为两组任务分别开启只监听 127.0.0.1、带认证的 RC 接口（下一轮生效）；
        4. 安装并启动 RcloneBar 后台服务（退出界面后继续调度）。

        不会改动 bisync 历史、访问检查标记、冲突副本或备份；如有同步正在运行会拒绝接管，等它结束后再试。随时可以在此处回退。
        """
        alert.addButton(withTitle: "接管")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runAgent(["install"], title: "接管")
    }

    func uninstall() {
        let alert = NSAlert()
        alert.messageText = "回退到原 LaunchAgent？"
        alert.informativeText = "将停止 RcloneBar 后台服务，并用接管时的备份恢复原 LaunchAgent（恢复每 300 秒等原有调度）。设置与运行记录会保留。如有同步正在运行，请等待结束后再回退。"
        alert.addButton(withTitle: "回退")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runAgent(["uninstall"], title: "回退")
    }

    func updateAgent() { runAgent(["install"], title: "更新后台服务") }

    func restartAgent() {
        Task.detached {
            let info = Launchctl.info(AppPaths.agentLabel)
            let r: ShellResult
            if info.loaded {
                r = Shell.run(Launchctl.path, ["kickstart", "-k", Launchctl.service(AppPaths.agentLabel)])
            } else {
                r = Launchctl.bootstrap(plist: AppPaths().agentPlist.path)
            }
            await MainActor.run { [weak self] in
                self?.show(r.ok ? "后台服务已启动（正在运行的同步不受影响）" : "启动失败：\(r.stderr)")
                self?.refreshSoon()
            }
        }
    }

    func stopAgent() {
        let alert = NSAlert()
        alert.messageText = "停止后台调度服务？"
        alert.informativeText = "停止后不会再自动启动新的同步，直到再次启动服务或重新登录。正在运行的一轮不会被中断。\n\n如果只是想暂时不同步，建议使用“暂停全部自动同步”。"
        alert.addButton(withTitle: "停止服务")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task.detached {
            let r = Launchctl.bootout(AppPaths.agentLabel)
            await MainActor.run { [weak self] in
                self?.show(r.ok ? "后台服务已停止（下次登录时会自动启动）" : "停止失败：\(r.stderr)")
                self?.refreshSoon()
            }
        }
    }

    func quitInterface() {
        NSApp.terminate(nil)
    }
}
