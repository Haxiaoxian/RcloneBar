import SwiftUI
import AppKit
import RcloneBarCore

struct JobCardView: View {
    @EnvironmentObject var model: AppModel
    let job: JobSnapshot
    @State private var filesExpanded = false

    private var p: JobProgress { job.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            titleRow
            if p.activity.isActive {
                progressSection
            } else {
                idleSection
            }
            if let o = job.lastOutcome, o.isFailure || o == .unknown, !p.activity.isActive {
                errorBox(o)
            }
            if let note = job.notice ?? job.settingsNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }

    // MARK: 标题

    private var titleRow: some View {
        HStack(spacing: 6) {
            Text(job.config.displayName).font(.headline)
            if job.paused {
                Label("已暂停", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if p.activity.isActive {
                Badge(style: StatusStyle.activity(p.activity))
            } else if let o = job.lastOutcome {
                Badge(style: StatusStyle.outcome(o))
            } else {
                Badge(style: StatusStyle.activity(.idle))
            }
        }
    }

    // MARK: 运行中

    @ViewBuilder
    private var progressSection: some View {
        if let f = p.fraction {
            ProgressView(value: f)
                .progressViewStyle(.linear)
            HStack {
                Text(p.activity == .finishing ? "传输完成，正在校验或收尾" : "本轮已知传输量 \(Int((f * 100).rounded(.down)))%")
                if p.totalsGrowing { Text("· 总量仍在增加").foregroundStyle(.orange) }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
            Text(indeterminateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 3) {
            if let done = p.bytesDone, done > 0 || p.totalBytes != nil {
                InfoRow(title: "已传输", value: Formatters.bytes(done) + (p.totalBytes.map { " / \(Formatters.bytes($0))（当前已知）" } ?? ""))
            }
            if let fd = p.filesDone, let tf = p.totalFiles {
                InfoRow(title: "文件", value: "\(Formatters.count(fd)) / \(Formatters.count(tf))（当前已知）")
            }
            if p.activity == .scanning, let checks = p.checks, checks > 0 {
                InfoRow(title: "已比对", value: Formatters.count(checks) + (p.totalChecks.map { " / \(Formatters.count($0))" } ?? ""))
            }
            if let s = p.speed {
                InfoRow(title: "速度", value: Formatters.speed(s))
            }
            if let eta = p.etaText {
                InfoRow(title: "剩余", value: eta)
            }
            if let started = job.runStartedAt {
                InfoRow(title: "开始于", value: Formatters.dayTime(started) + (job.trigger.map { "（\($0.label)）" } ?? ""))
            }
            if job.rcState != .connected {
                InfoRow(title: "数据来源", value: p.source == .log ? "日志（\(job.rcState.label)）" : job.rcState.label)
            }
            if p.errorsThisRun > 0 {
                InfoRow(title: "本轮错误", value: "\(p.errorsThisRun) 个（rclone 可能会自动重试）" + (p.lastErrorThisRun.map { "：\($0.prefix(80))" } ?? ""))
            }
        }

        if !p.currentFiles.isEmpty {
            DisclosureGroup(isExpanded: $filesExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(p.currentFiles.prefix(8)) { f in
                        HStack(alignment: .top, spacing: 4) {
                            Text(f.name)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if let pct = f.percentage { Text("\(pct)%").font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
                            Button {
                                model.copy(f.name)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("复制路径")
                        }
                    }
                }
                .padding(.top, 2)
            } label: {
                HStack(spacing: 4) {
                    Text("正在处理：").foregroundStyle(.secondary)
                    Text(p.currentFiles.first?.name ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if p.currentFiles.count > 1 { Text("等 \(p.currentFiles.count) 个").foregroundStyle(.secondary) }
                }
                .font(.caption)
            }
        }
    }

    private var indeterminateText: String {
        switch p.activity {
        case .scanning:
            var parts = ["正在扫描和比较，总量尚未确定"]
            if let l = p.listed, l > 0 { parts.append("已列出 \(Formatters.count(l)) 项") }
            return parts.joined(separator: " · ")
        case .starting: return "正在启动 rclone…"
        case .stopping: return "已请求安全结束，bisync 正在收尾"
        case .finishing: return "正在校验或收尾"
        case .runningNoDetail: return "正在运行（暂无实时进度）"
        default: return p.activity.label
        }
    }

    // MARK: 空闲

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            InfoRow(title: "上次成功", value: job.lastSuccessAt.map { "\(Formatters.dayTime($0))（\(Formatters.relative($0))）" } ?? "暂无记录")
            InfoRow(title: "下次同步", value: nextRunText)
        }
    }

    private var nextRunText: String {
        if job.paused { return "自动调度已暂停（可手动立即同步）" }
        guard let n = job.nextRunAt else { return model.isManaged ? "—" : "由原 LaunchAgent 决定" }
        let rel = n < Date() ? "即将开始" : Formatters.relative(n)
        return "\(Formatters.dayTime(n))（\(rel)）" + (job.nextRunEstimated ? " 估算" : "")
    }

    private func errorBox(_ o: RunOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: StatusStyle.outcome(o).symbol)
                Text(o.label + (job.lastFinishedAt.map { " · " + Formatters.dayTime($0) } ?? ""))
                Spacer()
                Button("复制详情") { model.copy(model.errorDetails(job)) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(StatusStyle.outcome(o).color)
            if let s = job.lastSummary {
                Text(s).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let last = job.lastErrors.last {
                Text(LogParser.parse(last).message)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if o == .retryableFailure {
                Text("这类错误通常会在下一轮自动恢复。").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .background(StatusStyle.outcome(o).color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: 操作

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.sync(job)
            } label: {
                Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(job.running)
            .help(job.running ? "正在同步中" : "立即开始一轮同步")

            if model.isManaged {
                Button {
                    model.togglePause(job)
                } label: {
                    Label(job.paused ? "恢复自动" : "暂停自动", systemImage: job.paused ? "play.circle" : "pause.circle")
                }
                .help(job.paused ? "恢复自动调度" : "暂停自动调度：不再启动新的一轮，正在进行的一轮会继续完成")
            }

            Spacer()

            Menu {
                Button("安全结束本轮") { model.stop(job) }
                    .disabled(!job.running || job.stopRequested)
                if model.isManaged && job.stopRequested {
                    Button("立即中断（不等待收尾）…") { model.forceInterrupt(job) }
                }
                Divider()
                Button("打开本地目录") { model.openLocal(job) }
                Button("打开 OneDrive 网页") { model.openWeb(job) }
                Button("在访达中显示日志") { model.openLog(job) }
                if job.lastOutcome?.isFailure == true {
                    Divider()
                    Button("复制错误详情") { model.copy(model.errorDetails(job)) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}
