import SwiftUI
import AppKit
import RcloneBarCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: String = "all"
    @State private var selection: RunRecord.ID?
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("运行记录").tag(0)
                    Text("日志").tag(1)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Picker("任务", selection: $filter) {
                    Text("全部").tag("all")
                    ForEach(model.jobs) { Text($0.config.displayName).tag($0.id) }
                }
                .fixedSize()
            }
            .padding(10)
            Divider()
            if tab == 0 { runs } else { LogPane(jobID: filter == "all" ? model.jobs.first?.id : filter) }
        }
    }

    private var records: [RunRecord] {
        (model.snapshot?.recentRuns ?? []).filter { filter == "all" || $0.jobID == filter }
    }

    private func name(_ id: String) -> String {
        model.jobs.first { $0.id == id }?.config.displayName ?? id
    }

    private var runs: some View {
        HSplitView {
            List(records, selection: $selection) { r in
                HStack(spacing: 8) {
                    Image(systemName: StatusStyle.outcome(r.outcome).symbol)
                        .foregroundStyle(StatusStyle.outcome(r.outcome).color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(name(r.jobID)).font(.callout.weight(.medium))
                            Text(r.outcome.label).font(.caption).foregroundStyle(StatusStyle.outcome(r.outcome).color)
                            Spacer()
                            Text(Formatters.dayTime(r.finishedAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(r.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tag(r.id)
            }
            .frame(minWidth: 320)
            .overlay {
                if records.isEmpty {
                    Text(model.isManaged ? "还没有运行记录" : "接管后，RcloneBar 会为每一轮记录结果。\n观察模式下请查看“日志”。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let r = records.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Badge(style: StatusStyle.outcome(r.outcome))
                        Spacer()
                        Button("复制详情") { model.copy(text(r)) }
                    }
                    Text(r.summary).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        row("任务", name(r.jobID))
                        row("触发", r.trigger.label)
                        row("开始", Formatters.full(r.startedAt))
                        row("结束", Formatters.full(r.finishedAt))
                        row("耗时", Formatters.duration(r.finishedAt.timeIntervalSince(r.startedAt)))
                        if let b = r.bytes { row("传输量", Formatters.bytes(b)) }
                        if let t = r.transfers { row("文件数", "\(t)") }
                        if r.conflicts > 0 { row("冲突", "\(r.conflicts) 处") }
                        if let c = r.exitCode { row("退出码", "\(c)") }
                        row("判定依据", r.evidence.joined(separator: "；"))
                    }
                    .font(.caption)
                    if !r.errors.isEmpty {
                        Text("错误摘要").font(.caption.weight(.semibold)).padding(.top, 4)
                        Text(r.errors.joined(separator: "\n"))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(12)
            }
        } else {
            Text("选择一条记录查看详情").foregroundStyle(.secondary)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }

    private func text(_ r: RunRecord) -> String {
        var s = ["\(name(r.jobID)) · \(r.outcome.label) · \(Formatters.full(r.finishedAt))", r.summary, "依据：" + r.evidence.joined(separator: "；")]
        if !r.errors.isEmpty { s.append(""); s += r.errors }
        return s.joined(separator: "\n")
    }
}

/// 日志末尾（只读最后 256KB / 400 行，在后台读取）。
struct LogPane: View {
    @EnvironmentObject var model: AppModel
    let jobID: String?
    @State private var lines: [String] = []
    @State private var source = "job"
    @State private var onlyErrors = false

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("", selection: $source) {
                    Text("同步日志").tag("job")
                    Text("后台服务日志").tag("agent")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("只看错误", isOn: $onlyErrors)
                Spacer()
                Button("刷新") { load() }
                Button("复制") { model.copy(shown.joined(separator: "\n")) }
            }
            .padding(.horizontal, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, l in
                            Text(l)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(color(l))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: lines) { _, _ in proxy.scrollTo(shown.count - 1, anchor: .bottom) }
            }
        }
        .padding(.top, 6)
        .onAppear(perform: load)
        .onChange(of: source) { _, _ in load() }
        .onChange(of: jobID) { _, _ in load() }
    }

    private var shown: [String] {
        onlyErrors ? lines.filter { let l = LogParser.parse($0).level; return l == .error || l == .critical } : lines
    }

    private func color(_ line: String) -> Color {
        switch LogParser.parse(line).level {
        case .error, .critical: return .red
        case .notice, .warning: return .primary
        default: return .secondary
        }
    }

    private func load() {
        let files: [String]
        if source == "agent" {
            files = [model.paths.agentLogFile.path]
        } else {
            files = model.jobs.first { $0.id == jobID }?.config.logFiles ?? []
        }
        Task.detached(priority: .utility) {
            let all = files.flatMap { LogReader.tailLines(URL(fileURLWithPath: $0), maxBytes: 256 * 1024, maxLines: 400) }
                .map { Redactor.redact(LogParser.stripANSI($0)) }
            let result = Array(all.suffix(400))
            await MainActor.run { lines = result }
        }
    }
}
