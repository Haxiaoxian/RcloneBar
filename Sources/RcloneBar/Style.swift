import SwiftUI
import RcloneBarCore

/// 状态的图标形状 + 文字 + 颜色。颜色只是辅助，形状与文字本身就能区分状态。
struct StatusStyle {
    let symbol: String
    let text: String
    let color: Color

    static func overall(_ s: OverallState) -> StatusStyle {
        switch s {
        case .transferring: return .init(symbol: "arrow.up.arrow.down.circle", text: s.label, color: .accentColor)
        case .scanning, .starting: return .init(symbol: "magnifyingglass.circle", text: s.label, color: .accentColor)
        case .finishing: return .init(symbol: "hourglass.circle", text: s.label, color: .accentColor)
        case .stopping: return .init(symbol: "stop.circle", text: s.label, color: .orange)
        case .error(let msg):
            if msg.contains("授权") { return .init(symbol: "person.crop.circle.badge.exclamationmark", text: msg, color: .red) }
            if msg.contains("网络") { return .init(symbol: "wifi.exclamationmark", text: msg, color: .orange) }
            return .init(symbol: "exclamationmark.triangle", text: msg, color: .red)
        case .paused: return .init(symbol: "pause.circle", text: s.label, color: .secondary)
        case .success: return .init(symbol: "checkmark.circle", text: s.label, color: .green)
        case .idle: return .init(symbol: "arrow.triangle.2.circlepath.circle", text: s.label, color: .secondary)
        case .agentDown: return .init(symbol: "exclamationmark.circle", text: s.label, color: .orange)
        }
    }

    static func activity(_ a: Activity) -> StatusStyle {
        switch a {
        case .idle: return .init(symbol: "circle", text: a.label, color: .secondary)
        case .starting: return .init(symbol: "ellipsis.circle", text: a.label, color: .accentColor)
        case .scanning: return .init(symbol: "magnifyingglass", text: a.label, color: .accentColor)
        case .transferring: return .init(symbol: "arrow.up.arrow.down", text: a.label, color: .accentColor)
        case .finishing: return .init(symbol: "hourglass", text: a.label, color: .accentColor)
        case .stopping: return .init(symbol: "stop.circle", text: a.label, color: .orange)
        case .runningNoDetail: return .init(symbol: "ellipsis.circle", text: a.label, color: .accentColor)
        }
    }

    static func outcome(_ o: RunOutcome) -> StatusStyle {
        switch o {
        case .success: return .init(symbol: "checkmark.circle", text: "上次成功", color: .green)
        case .stoppedByUser: return .init(symbol: "stop.circle", text: o.label, color: .secondary)
        case .retryableFailure: return .init(symbol: "arrow.clockwise.circle", text: "可重试错误", color: .orange)
        case .failed: return .init(symbol: "xmark.octagon", text: o.label, color: .red)
        case .needsAttention: return .init(symbol: "exclamationmark.triangle", text: o.label, color: .red)
        case .authRequired: return .init(symbol: "person.crop.circle.badge.exclamationmark", text: o.label, color: .red)
        case .skipped: return .init(symbol: "minus.circle", text: o.label, color: .secondary)
        case .unknown: return .init(symbol: "questionmark.circle", text: o.label, color: .secondary)
        }
    }
}

struct MenuBarLabel: View {
    let snapshot: Snapshot?
    let showSpeed: Bool

    var body: some View {
        let state = snapshot?.overall ?? .idle
        let style = StatusStyle.overall(state)
        HStack(spacing: 3) {
            Image(systemName: style.symbol)
            if let text = shortText(state) {
                Text(text).monospacedDigit()
            }
        }
        .help("RcloneBar：\(style.text)")
        .accessibilityLabel("RcloneBar，\(style.text)")
    }

    private func shortText(_ state: OverallState) -> String? {
        switch state {
        case .transferring:
            guard showSpeed, let s = snapshot?.totalSpeed, s > 0 else { return nil }
            return Formatters.compactSpeed(s)
        case .error(let msg):
            if msg.contains("授权") { return "授权" }
            if msg.contains("网络") { return "网络" }
            return "失败"
        case .paused: return "暂停"
        case .agentDown: return "停止"
        default: return nil
        }
    }
}

struct Badge: View {
    let style: StatusStyle

    var body: some View {
        Label(style.text, systemImage: style.symbol)
            .font(.caption)
            .foregroundStyle(style.color)
            .labelStyle(.titleAndIcon)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }
}
