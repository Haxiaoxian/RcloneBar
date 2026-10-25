import SwiftUI
import AppKit
import RcloneBarCore

/// 用示例数据把主要界面渲染成 PNG（浅色 / 深色），用于在没有显示器的 CI 上检查布局。
/// 用法：RcloneBar --render-preview <输出目录>
@MainActor
enum PreviewRenderer {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("--render-preview") }

    static func renderAll() {
        guard let dir = outputDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples: [(String, Snapshot)] = [("active", activeSample()), ("idle", idleSample()), ("error", errorSample()), ("observe", observeSample())]
        for (name, snap) in samples {
            for scheme in [ColorScheme.light, .dark] {
                let model = AppModel(preview: snap)
                let view = PanelView()
                    .environmentObject(model)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                render(view, size: nil, to: dir.appendingPathComponent("panel-\(name)-\(scheme == .dark ? "dark" : "light").png"), scheme: scheme)
            }
        }
        let model = AppModel(preview: activeSample())
        for (i, tab) in [AnyView(GeneralSettings()), AnyView(TransferSettings()), AnyView(ServiceSettings().padding(16))].enumerated() {
            render(tab.environmentObject(model).frame(width: 620, height: 520), size: NSSize(width: 620, height: 520),
                   to: dir.appendingPathComponent("settings-\(i)-light.png"), scheme: .light)
        }
        print("预览已输出到 \(dir.path)")
    }

    private static func render<V: View>(_ view: V, size: NSSize?, to url: URL, scheme: ColorScheme) {
        let host = NSHostingView(rootView: view)
        let fitting = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
        window.orderOut(nil)
    }

    // MARK: 示例数据

    private static var jobs: [JobConfig] { JobConfig.defaults(paths: AppPaths(home: URL(fileURLWithPath: "/Users/zhuke"))) }

    private static func snapshot(_ js: [JobSnapshot], mode: ControlMode = .managed, settings: SyncSettings = SyncSettings()) -> Snapshot {
        let overall = OverallStateResolver.resolve(js.map { .init(activity: $0.progress.activity, lastOutcome: $0.lastOutcome, lastErrorCategory: $0.lastErrorCategory, paused: $0.paused) },
                                                   agentAvailable: true, allPaused: settings.pausedAll)
        return Snapshot(updatedAt: Date(), mode: mode, agentAlive: mode == .managed, agentVersion: RcloneBarVersion.current, settings: settings,
                        jobs: js, overall: overall, totalSpeed: js.compactMap(\.progress.speed).reduce(0, +), recentRuns: [], lastCommandResult: nil)
    }

    static func activeSample() -> Snapshot {
        var p = JobProgress()
        p.activity = .transferring
        p.source = .rc
        p.bytesDone = 412 * 1024 * 1024
        p.totalBytes = 1300 * 1024 * 1024
        p.totalsGrowing = true
        p.filesDone = 37
        p.totalFiles = 128
        p.speed = 3.4 * 1024 * 1024
        p.fraction = 412.0 / 1300.0
        p.currentFiles = [
            CurrentFile(name: "论文摘抄/A1-理论框架/2024 年度综述（修订版）/附件/图表 3 - 长文件名示例.pdf", percentage: 42, size: 8_000_000, speed: 1_000_000),
            CurrentFile(name: "日记/2026/10/25.md", percentage: 90, size: 2000, speed: 100),
        ]
        var s = JobProgress()
        s.activity = .scanning
        s.source = .rc
        s.listed = 18_342
        s.checks = 120
        return snapshot([
            JobSnapshot(config: jobs[0], progress: p, running: true, runStartedAt: Date().addingTimeInterval(-95), trigger: .scheduled,
                        rcState: .connected, lastSuccessAt: Date().addingTimeInterval(-400), lastOutcome: .success,
                        settingsNote: "部分设置（并发数）将在下一轮生效"),
            JobSnapshot(config: jobs[1], progress: s, running: true, runStartedAt: Date().addingTimeInterval(-12), trigger: .manual,
                        rcState: .connected, lastSuccessAt: Date().addingTimeInterval(-3600), lastOutcome: .success),
        ])
    }

    static func idleSample() -> Snapshot {
        var settings = SyncSettings()
        settings.pausedJobs = ["projects"]
        return snapshot([
            JobSnapshot(config: jobs[0], lastSuccessAt: Date().addingTimeInterval(-180), lastOutcome: .success,
                        nextRunAt: Date().addingTimeInterval(120)),
            JobSnapshot(config: jobs[1], paused: true, lastSuccessAt: Date().addingTimeInterval(-7200), lastOutcome: .success),
        ], settings: settings)
    }

    static func errorSample() -> Snapshot {
        snapshot([
            JobSnapshot(config: jobs[0], lastSuccessAt: Date().addingTimeInterval(-86400), lastOutcome: .authRequired,
                        lastFinishedAt: Date().addingTimeInterval(-60),
                        lastSummary: "OneDrive 授权可能已失效，需要在终端运行 rclone config reconnect onedrive: 重新授权。",
                        lastErrorCategory: .auth,
                        lastErrors: ["2026/10/25 09:12:03 ERROR : onedrive root '其他/Obsidian/主仓库': couldn't fetch token: invalid_grant: ***"],
                        nextRunAt: Date().addingTimeInterval(240)),
            JobSnapshot(config: jobs[1], lastSuccessAt: Date().addingTimeInterval(-900), lastOutcome: .retryableFailure,
                        lastFinishedAt: Date().addingTimeInterval(-30), lastSummary: "网络异常。本轮未完成，将在下一次计划时间自动重试。",
                        lastErrorCategory: .network,
                        lastErrors: ["2026/10/25 09:12:30 ERROR : 项目计划.xlsx: Failed to copy: dial tcp: lookup graph.microsoft.com: no such host"],
                        nextRunAt: Date().addingTimeInterval(270), consecutiveFailures: 1),
        ])
    }

    static func observeSample() -> Snapshot {
        snapshot([
            JobSnapshot(config: jobs[0], progress: { var p = JobProgress(); p.activity = .runningNoDetail; return p }(), running: true,
                        runStartedAt: Date().addingTimeInterval(-40), trigger: .external, rcState: .notEnabled,
                        lastSuccessAt: Date().addingTimeInterval(-320), lastSuccessSource: "bisync 历史 listing", lastOutcome: .success),
            JobSnapshot(config: jobs[1], lastSuccessAt: Date().addingTimeInterval(-200), lastOutcome: .success,
                        nextRunAt: Date().addingTimeInterval(100), nextRunEstimated: true),
        ], mode: .observe)
    }
}
