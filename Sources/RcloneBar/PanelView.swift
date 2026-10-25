import SwiftUI
import AppKit
import RcloneBarCore

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snap = model.snapshot {
                if snap.mode == .observe {
                    Banner(symbol: "eye", text: "观察模式：当前仍由原 LaunchAgent 调度。可立即同步和安全结束；暂停、间隔与限速需在“设置 → 后台服务”中接管后使用。")
                } else if !snap.agentAlive {
                    Banner(symbol: "exclamationmark.circle", text: "后台服务未运行，自动调度已停止。可在“设置 → 后台服务”中启动。", tint: .orange)
                } else if model.installedAgentVersionMismatch {
                    Banner(symbol: "arrow.down.circle", text: "后台服务版本与 App 不一致，可在“设置 → 后台服务”中更新。", tint: .orange)
                }
                ForEach(snap.jobs) { job in
                    JobCardView(job: job)
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在读取状态…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            if let toast = model.toast {
                Text(toast)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 380)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }

    private var header: some View {
        let state = model.snapshot?.overall ?? .idle
        let style = StatusStyle.overall(state)
        return HStack(spacing: 10) {
            Image(systemName: style.symbol)
                .font(.title2)
                .foregroundStyle(style.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(style.text).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.syncAll()
            } label: {
                Label("同步全部", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.regular)
            .keyboardShortcut("r")
            .help("立即同步两组任务（已在运行的任务不会重复启动）")
        }
    }

    private var subtitle: String {
        guard let snap = model.snapshot else { return "" }
        var parts: [String] = []
        if snap.mode == .managed {
            parts.append(model.allPaused ? "自动同步已暂停" : "每 \(model.settings.intervalMinutes) 分钟自动同步")
        } else {
            parts.append("原 LaunchAgent 调度")
        }
        if snap.totalSpeed > 0 { parts.append(Formatters.speed(snap.totalSpeed)) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                open(WindowID.settings)
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            Button {
                open(WindowID.history)
            } label: {
                Label("运行记录", systemImage: "list.bullet.rectangle")
            }
            Spacer()
            Menu {
                if model.isManaged {
                    Button(model.allPaused ? "恢复全部自动同步" : "暂停全部自动同步") { model.togglePauseAll() }
                    Divider()
                }
                Button("打开 RcloneBar 备份目录") { model.openFolder(model.paths.backupsDir) }
                Button("打开原后台目录（rclone-bisync）") { model.openFolder(model.paths.legacyBase) }
                Divider()
                Button("退出 RcloneBar 界面（后台同步继续）") { model.quitInterface() }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
