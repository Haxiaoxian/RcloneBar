import SwiftUI
import AppKit
import RcloneBarCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
            TransferSettings()
                .tabItem { Label("传输", systemImage: "speedometer") }
            NotificationSettings()
                .tabItem { Label("通知", systemImage: "bell") }
            ServiceSettings()
                .tabItem { Label("后台服务", systemImage: "gearshape.2") }
        }
        .padding(16)
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// 未接管时，影响后台任务的设置不可用
struct ManagedOnlyNote: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.isManaged {
            Label("当前为观察模式，以下设置需要在“后台服务”中接管后才会作用于后台同步。", systemImage: "eye")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - 同步

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            ManagedOnlyNote()
            ScheduleSection()
            MenuBarSection()
            WebURLSection()
        }
        .formStyle(.grouped)
    }
}

struct ScheduleSection: View {
    @EnvironmentObject var model: AppModel

    private var intervalChoices: [Int] {
        var c = SyncSettings.intervalChoices
        if !c.contains(model.settings.intervalMinutes) { c.append(model.settings.intervalMinutes) }
        return c.sorted()
    }

    var body: some View {
        Section("自动同步") {
            Picker("同步间隔", selection: model.binding(\.intervalMinutes)) {
                ForEach(intervalChoices, id: \.self) { m in
                    Text(m == 60 ? "1 小时" : "\(m) 分钟").tag(m)
                }
            }
            .disabled(!model.isManaged)
            Hint("修改后立即生效：按“上一轮结束时间 + 新间隔”重新计算下次同步时间。")

            Toggle("暂停全部自动同步", isOn: model.pausedAllBinding)
                .disabled(!model.isManaged)
            ForEach(model.jobs) { job in
                Toggle("暂停“\(job.config.displayName)”自动同步", isOn: model.pausedBinding(job))
                    .disabled(!model.isManaged)
            }
            Hint("暂停只是不再启动新的一轮：正在进行的同步会继续完成；暂停期间仍可手动“立即同步”。要中途结束当前一轮，请使用卡片菜单里的“安全结束本轮”。")
        }
    }
}

struct MenuBarSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("菜单栏") {
            Toggle("传输时在菜单栏显示速度", isOn: model.binding(\.showSpeedInMenuBar))
            Toggle("登录后自动打开 RcloneBar 界面", isOn: model.loginItemBinding)
            Hint("后台同步由独立的后台服务负责，与这个开关无关：即使不打开界面，后台也会按计划同步。")
        }
    }
}

struct WebURLSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("OneDrive 网页地址（可选）") {
            ForEach(model.jobs) { job in
                TextField(job.config.displayName, text: model.webURLBinding(job.id), prompt: Text("https://onedrive.live.com/"))
            }
            Hint("可粘贴对应文件夹在 OneDrive 网页中的地址，“打开 OneDrive 网页”会直接跳转到该文件夹。")
        }
    }
}

// MARK: - 传输

struct TransferSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            ManagedOnlyNote()
            Section("限速") {
                Toggle("由 RcloneBar 控制限速", isOn: model.binding(\.bandwidthControlEnabled))
                    .disabled(!model.isManaged)
                LimitField(title: "上传限速", value: model.limitBinding(\.uploadLimitKiB))
                    .disabled(!model.isManaged || !model.settings.bandwidthControlEnabled)
                LimitField(title: "下载限速", value: model.limitBinding(\.downloadLimitKiB))
                    .disabled(!model.isManaged || !model.settings.bandwidthControlEnabled)
                Hint("填 0 表示不限。正在运行的同步约 5 秒内通过 RC 接口即时生效，之后的每一轮也会沿用。关闭此开关则保持脚本自身的设置。")
            }
            Section("并发") {
                Toggle("自定义并发传输文件数", isOn: model.customTransfersBinding)
                    .disabled(!model.isManaged)
                if model.settings.transfers != nil {
                    Stepper(value: model.transfersBinding, in: 1...32) {
                        Text("同时传输 \(model.settings.transfers ?? 4) 个文件")
                    }
                    .disabled(!model.isManaged)
                }
                Hint("并发数从下一轮开始生效（rclone 不支持在运行中修改）。如果原脚本里固定写了 --transfers，将以脚本为准，卡片上会提示实际值。")
            }
        }
        .formStyle(.grouped)
    }
}

struct LimitField: View {
    let title: String
    let value: Binding<Double>

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text("MB/s").foregroundStyle(.secondary)
        }
    }
}

// MARK: - 通知

struct NotificationSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("系统通知") {
                Toggle("同步失败时通知", isOn: model.binding(\.notifyFailures))
                Toggle("需要重新授权 OneDrive 时通知", isOn: model.binding(\.notifyAuth))
                Toggle("出现冲突时通知", isOn: model.binding(\.notifyConflicts))
                Hint("成功不会发送通知。短暂的网络错误属于可重试错误，连续 3 次未完成才提醒一次。通知由菜单栏界面发出；界面未运行期间的失败会在下次打开时补发。")
                Button("发送测试通知") { model.notifier.sendTest() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 后台服务

struct ServiceSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ServiceStatusBox()
            ServiceButtons()
            HStack(spacing: 8) {
                Button("打开 RcloneBar 目录") { model.openFolder(model.paths.base) }
                Button("打开备份目录") { model.openFolder(model.paths.backupsDir) }
                Button("打开原后台目录") { model.openFolder(model.paths.legacyBase) }
            }
            .buttonStyle(.link)
            ServiceOutput()
        }
    }
}

struct ServiceStatusBox: View {
    @EnvironmentObject var model: AppModel

    private var detail: String {
        if model.isManaged {
            let alive = model.snapshot?.agentAlive == true ? "运行中" : "未运行"
            let version = model.snapshot?.agentVersion.map { "（版本 \($0)）" } ?? ""
            return "后台服务：\(alive)\(version)。原 LaunchAgent 仍执行原 sync.py，但只在后台服务启动时运行；退出界面不会影响后台同步。"
        }
        return "接管前建议先运行“接入检查”。接管会备份原配置，并可随时回退。"
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.isManaged ? "已接管：RcloneBar 后台服务是唯一的调度者" : "观察模式：仍由原 LaunchAgent 每隔固定时间运行",
                      systemImage: model.isManaged ? "checkmark.seal" : "eye")
                    .font(.headline)
                Hint(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ServiceButtons: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button("接入检查") { model.inspect() }
            if model.isManaged {
                Button("回退到原 LaunchAgent…") { model.uninstall() }
                if model.installedAgentVersionMismatch {
                    Button("更新后台服务") { model.updateAgent() }
                }
                if model.snapshot?.agentAlive == true {
                    Button("停止后台服务…") { model.stopAgent() }
                } else {
                    Button("启动后台服务") { model.restartAgent() }
                }
            } else {
                Button("接管（安全交接）…") { model.install() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            if model.serviceBusy { ProgressView().controlSize(.small) }
        }
        .disabled(model.serviceBusy)
    }
}

struct ServiceOutput: View {
    @EnvironmentObject var model: AppModel

    private var text: String {
        model.serviceOutput.isEmpty ? "点击“接入检查”查看现有脚本、LaunchAgent、进程与同步历史（只读，不会显示任何令牌）。" : model.serviceOutput
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("输出").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制") { model.copy(model.serviceOutput) }
                    .buttonStyle(.borderless)
                    .disabled(model.serviceOutput.isEmpty)
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
