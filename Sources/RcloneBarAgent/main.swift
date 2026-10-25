import Foundation
import RcloneBarCore

// rclonebar-agent：RcloneBar 的后台调度服务与命令行工具。
// 菜单栏 App 退出不影响它；它也不会在退出时停止正在运行的同步。

let usage = """
用法：rclonebar-agent <命令> [参数]

  daemon                 以后台服务方式运行（由 LaunchAgent 启动）
  status [--json]        显示两组任务的当前状态
  inspect [--json]       接入前检查：现有脚本、LaunchAgent、进程与同步历史（只读）
  install [--dry-run]    接管：备份并把原 LaunchAgent 改为按需执行，安装后台服务
  uninstall [--dry-run]  回退：恢复原 LaunchAgent，移除后台服务
  sync [任务|all]         立即同步（任务：vault / projects）
  stop [任务|all]         安全结束当前一轮（rclone 正常收尾）
  pause [任务|all]        暂停自动调度（不影响正在运行的一轮）
  resume [任务|all]       恢复自动调度
  version                显示版本
"""

let paths = AppPaths()
var args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
if !args.isEmpty { args.removeFirst() }
let json = args.contains("--json")
let dryRun = args.contains("--dry-run")
let target: String? = args.first { !$0.hasPrefix("--") }.flatMap { $0 == "all" ? nil : $0 }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func currentJobs() -> [JobConfig] {
    JSONStore.read(JobsFile.self, from: paths.jobsFile)?.jobs ?? JobConfig.defaults(paths: paths)
}

func validateTarget() {
    if let t = target, !currentJobs().contains(where: { $0.id == t }) {
        fail("未知任务：\(t)。可用：\(currentJobs().map(\.id).joined(separator: " / ")) / all")
    }
}

func ownExecutable() -> URL {
    if let url = Bundle.main.executableURL { return url.resolvingSymlinksInPath() }
    return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
}

switch command {
case "daemon":
    let code = await Daemon(paths: paths).run()
    exit(code)

case "status":
    let snap = await StatusCollector(paths: paths).collect()
    if json {
        var out: [[String: Any]] = []
        for j in snap.jobs {
            var d: [String: Any] = ["id": j.id, "name": j.config.displayName, "activity": j.progress.activity.rawValue,
                                    "running": j.running, "paused": j.paused, "rc": j.rcState.label]
            if let b = j.progress.bytesDone { d["bytes"] = b }
            if let t = j.progress.totalBytes { d["totalBytes"] = t }
            if let f = j.progress.fraction { d["fraction"] = f }
            if let e = j.progress.eta { d["eta"] = e }
            if let s = j.progress.speed { d["speed"] = s }
            if let o = j.lastOutcome { d["lastOutcome"] = o.rawValue }
            if let ls = j.lastSuccessAt { d["lastSuccess"] = ISO8601DateFormatter().string(from: ls) }
            if let n = j.nextRunAt { d["nextRun"] = ISO8601DateFormatter().string(from: n) }
            out.append(d)
        }
        let obj: [String: Any] = ["mode": snap.mode == .managed ? "managed" : "observe", "agentAlive": snap.agentAlive,
                                  "overall": snap.overall.label, "jobs": out]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("模式：\(snap.mode == .managed ? "已接管（RcloneBar 调度）" : "观察（原 LaunchAgent 调度）")  后台服务：\(snap.agentAlive ? "运行中" : "未运行")")
        print("总体：\(snap.overall.label)")
        for j in snap.jobs {
            let p = j.progress
            var line = "【\(j.config.displayName)】\(p.activity.label)"
            if j.paused { line += "（自动调度已暂停）" }
            if let b = p.bytesDone, p.activity.isActive {
                line += "  \(Formatters.bytes(b))" + (p.totalBytes.map { " / \(Formatters.bytes($0))" } ?? "")
            }
            if let f = p.fraction { line += String(format: "  本轮已知传输量 %.0f%%", f * 100) }
            if let s = p.speed { line += "  \(Formatters.speed(s))" }
            if let e = p.etaText { line += "  剩余 \(e)" }
            print(line)
            print("   上次成功：\(j.lastSuccessAt.map { Formatters.dayTime($0) } ?? "未知")   下次：\(j.paused ? "已暂停" : (j.nextRunAt.map { Formatters.dayTime($0) + (j.nextRunEstimated ? "（估算）" : "") } ?? "—"))")
            if let o = j.lastOutcome, o != .success { print("   最近结果：\(o.label)  \(j.lastSummary ?? "")") }
            if j.running { print("   实时数据：\(j.rcState.label)") }
        }
    }

case "inspect":
    let report = Inspector.inspect(paths: paths, jobs: currentJobs())
    if json {
        let data = try JSONStore.makeEncoder().encode(report)
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(Inspector.text(report))
    }

case "install":
    let installer = Installer(paths: paths)
    do {
        try installer.install(agentBinary: ownExecutable(), jobs: currentJobs(), agentVersion: RcloneBarVersion.current, dryRun: dryRun)
    } catch {
        fail("\(error)")
    }

case "uninstall":
    do { try Installer(paths: paths).uninstall(dryRun: dryRun) } catch { fail("\(error)") }

case "sync", "stop":
    validateTarget()
    guard FileManager.default.fileExists(atPath: paths.jobsFile.path) else { fail("尚未接管，后台服务未运行。") }
    let cmd = ControlCommand(action: command == "sync" ? .syncNow : .stop, jobID: target)
    do { try ControlChannel.send(cmd, paths: paths) } catch { fail("发送命令失败：\(error)") }
    // 等待后台服务回执
    let deadline = Date().addingTimeInterval(6)
    var answered = false
    while Date() < deadline {
        if let st = JSONStore.read(AgentState.self, from: paths.stateFile),
           let r = st.commandResults.first(where: { $0.commandID == cmd.id }) {
            print(r.message)
            answered = true
            break
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    if !answered { fail("后台服务没有响应（命令已排队，服务恢复后 2 分钟内仍会执行）。") }

case "pause", "resume":
    validateTarget()
    var s = JSONStore.read(Settings.self, from: paths.settingsFile) ?? Settings()
    let pause = command == "pause"
    if let t = target {
        s.pausedJobs.removeAll { $0 == t }
        if pause { s.pausedJobs.append(t) }
    } else {
        s.pausedAll = pause
        if !pause { s.pausedJobs = [] }
    }
    do { try JSONStore.write(s, to: paths.settingsFile) } catch { fail("写入设置失败：\(error)") }
    print(pause ? "已暂停自动调度（正在运行的一轮会继续完成）" : "已恢复自动调度")

case "version", "--version":
    print("rclonebar-agent \(RcloneBarVersion.current)")

default:
    print(usage)
}
