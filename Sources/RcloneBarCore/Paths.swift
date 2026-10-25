import Foundation

/// 所有文件位置集中在这里。测试时可通过环境变量 `RCLONEBAR_HOME` 把“家目录”指向临时目录，
/// 这样不会碰到真实的 ~/Library 与 ~/Documents。
public struct AppPaths: Sendable {
    /// 后台服务的 LaunchAgent 标签（自动化测试可用 RCLONEBAR_AGENT_LABEL 改用隔离的标签）
    public static var agentLabel: String {
        let env = ProcessInfo.processInfo.environment["RCLONEBAR_AGENT_LABEL"] ?? ""
        return env.isEmpty ? "com.zhuke.rclonebar.agent" : env
    }

    public let home: URL

    public init(home: URL? = nil) {
        if let home {
            self.home = home
        } else if let override = ProcessInfo.processInfo.environment["RCLONEBAR_HOME"], !override.isEmpty {
            self.home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.home = FileManager.default.homeDirectoryForCurrentUser
        }
    }

    public var applicationSupport: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
    public var launchAgentsDir: URL { home.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }

    // 现有（旧）后台目录，只读接入
    public var legacyBase: URL { applicationSupport.appendingPathComponent("rclone-bisync", isDirectory: true) }
    public var legacyScript: URL { legacyBase.appendingPathComponent("sync.py") }

    // RcloneBar 自己的目录
    public var base: URL { applicationSupport.appendingPathComponent("RcloneBar", isDirectory: true) }
    public var settingsFile: URL { base.appendingPathComponent("settings.json") }
    public var jobsFile: URL { base.appendingPathComponent("jobs.json") }
    public var stateFile: URL { base.appendingPathComponent("agent-state.json") }
    public var runsFile: URL { base.appendingPathComponent("runs.jsonl") }
    public var installRecordFile: URL { base.appendingPathComponent("install.json") }
    public var controlDir: URL { base.appendingPathComponent("control", isDirectory: true) }
    public var backupsDir: URL { base.appendingPathComponent("backups", isDirectory: true) }
    public var rcDir: URL { base.appendingPathComponent("rc", isDirectory: true) }
    public var htpasswdFile: URL { rcDir.appendingPathComponent("htpasswd") }
    public var credentialFile: URL { rcDir.appendingPathComponent("credential.json") }
    public var logsDir: URL { base.appendingPathComponent("logs", isDirectory: true) }
    public var agentLogFile: URL { logsDir.appendingPathComponent("agent.log") }
    public var agentLockFile: URL { base.appendingPathComponent("agent.lock") }
    public var binDir: URL { base.appendingPathComponent("bin", isDirectory: true) }
    public var installedAgentBinary: URL { binDir.appendingPathComponent("rclonebar-agent") }
    public var agentPlist: URL { launchAgentsDir.appendingPathComponent("\(AppPaths.agentLabel).plist") }

    /// rclone bisync 默认工作目录（macOS: ~/Library/Caches/rclone/bisync，Linux: ~/.cache/rclone/bisync）
    public var defaultBisyncWorkdirs: [URL] {
        [
            home.appendingPathComponent("Library/Caches/rclone/bisync", isDirectory: true),
            home.appendingPathComponent(".cache/rclone/bisync", isDirectory: true),
        ]
    }

    public func ensureBaseDirectories() throws {
        let fm = FileManager.default
        for dir in [base, controlDir, backupsDir, logsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: rcDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rcDir.path)
    }

    /// 把 "~/..." 展开为当前 home 下的绝对路径。
    public func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }
}

public enum RcloneLocator {
    /// 优先使用用户给出的 Homebrew 路径，其次常见位置。
    public static let candidates = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"]

    public static func find() -> String? {
        if let override = ProcessInfo.processInfo.environment["RCLONEBAR_RCLONE"], FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
