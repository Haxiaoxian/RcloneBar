import Foundation
import XCTest
@testable import RcloneBarCore

/// 在临时“家目录”里模拟现有的 LaunchAgent + sync.py，验证接管与回退（不调用 launchctl）。
final class InstallerTests: XCTestCase {
    var home: URL!
    var paths: AppPaths!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("rb-install-\(UUID().uuidString)")
        paths = AppPaths(home: home)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.launchAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.legacyBase.appendingPathComponent("state/vault"), withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.legacyBase.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Documents/主仓库"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Documents/项目"), withIntermediateDirectories: true)
        try Data("""
        import subprocess
        cmd = ["/opt/homebrew/bin/rclone", "bisync", "/Users/zhuke/Documents/主仓库", "onedrive:其他/Obsidian/主仓库", "--resilient", "--recover", "--check-access", "--max-delete", "50"]
        subprocess.run(cmd)
        """.utf8).write(to: paths.legacyScript)
        for id in ["vault", "projects"] {
            let plist: [String: Any] = [
                "Label": "com.zhuke.rclone-bisync.\(id)",
                "ProgramArguments": ["/usr/bin/python3", paths.legacyScript.path, id],
                "StartInterval": 300,
                "RunAtLoad": true,
                "StandardOutPath": paths.legacyBase.appendingPathComponent("logs/\(id).launchd.log").path,
                "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: paths.launchAgentsDir.appendingPathComponent("com.zhuke.rclone-bisync.\(id).plist"))
        }
        // 伪 rclone，只回答 version / help flags rc
        let fake = home.appendingPathComponent("fake-rclone")
        try Data("#!/bin/sh\nif [ \"$1\" = version ]; then echo 'rclone v1.75.2'; else echo '--rc-addr --rc-htpasswd'; fi\n".utf8).write(to: fake)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("RCLONEBAR_RCLONE", fake.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("RCLONEBAR_RCLONE")
        try? FileManager.default.removeItem(at: home)
    }

    func testInstallAndRollback() throws {
        let fm = FileManager.default
        let vaultPlist = paths.launchAgentsDir.appendingPathComponent("com.zhuke.rclone-bisync.vault.plist")
        let originalBytes = try Data(contentsOf: vaultPlist)
        let fakeAgent = home.appendingPathComponent("agent-binary")
        try Data("#!/bin/sh\n".utf8).write(to: fakeAgent)

        var log: [String] = []
        let installer = Installer(paths: paths, useLaunchctl: false) { log.append($0) }

        // 演练模式不改任何文件
        try installer.install(agentBinary: fakeAgent, jobs: JobConfig.defaults(paths: paths), agentVersion: "t", dryRun: true)
        XCTAssertEqual(try Data(contentsOf: vaultPlist), originalBytes)
        XCTAssertFalse(fm.fileExists(atPath: paths.jobsFile.path))

        try installer.install(agentBinary: fakeAgent, jobs: JobConfig.defaults(paths: paths), agentVersion: "t", dryRun: false)
        let converted = try LaunchAgentPlist.load(vaultPlist)
        XCTAssertNil(converted.startInterval, "接管后原 LaunchAgent 不再自动调度")
        XCTAssertFalse(converted.runAtLoad)
        XCTAssertEqual(converted.programArguments, ["/usr/bin/python3", paths.legacyScript.path, "vault"], "保留原有执行命令")
        XCTAssertEqual(converted.environment["RCLONE_RC_ADDR"], "127.0.0.1:55721")
        XCTAssertEqual(converted.environment["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertNil(converted.environment["RCLONE_RC_PASS"], "plist 中不能有明文口令")
        let projects = try LaunchAgentPlist.load(paths.launchAgentsDir.appendingPathComponent("com.zhuke.rclone-bisync.projects.plist"))
        XCTAssertEqual(projects.environment["RCLONE_RC_ADDR"], "127.0.0.1:55722", "两组任务使用不同 RC 端口")

        let htpasswd = try String(contentsOf: paths.htpasswdFile, encoding: .utf8)
        let cred = try XCTUnwrap(RCCredentials.load(paths: paths))
        XCTAssertTrue(htpasswd.hasPrefix("rclonebar:{SHA}"))
        XCTAssertFalse(htpasswd.contains(cred.password))
        let perm = (try fm.attributesOfItem(atPath: paths.credentialFile.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perm, 0o600)

        let settings = try XCTUnwrap(JSONStore.read(SyncSettings.self, from: paths.settingsFile))
        XCTAssertEqual(settings.intervalMinutes, 5, "沿用原 300 秒间隔")
        let jobs = try XCTUnwrap(JSONStore.read(JobsFile.self, from: paths.jobsFile))
        XCTAssertEqual(jobs.jobs.first?.scriptHasRecover, true)
        XCTAssertTrue(fm.fileExists(atPath: paths.agentPlist.path))
        XCTAssertTrue(fm.fileExists(atPath: paths.installedAgentBinary.path))
        let record = try XCTUnwrap(JSONStore.read(InstallRecord.self, from: paths.installRecordFile))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record.legacy[0].backupPath)), originalBytes, "备份与原文件一致")

        try installer.uninstall(dryRun: false)
        XCTAssertEqual(try Data(contentsOf: vaultPlist), originalBytes, "回退后恢复为原始 plist")
        XCTAssertFalse(fm.fileExists(atPath: paths.agentPlist.path))
        XCTAssertFalse(fm.fileExists(atPath: paths.installRecordFile.path))
    }

    func testInspectionReport() throws {
        let report = Inspector.inspect(paths: paths, jobs: JobConfig.defaults(paths: paths))
        XCTAssertTrue(report.blockers.isEmpty, "\(report.blockers)")
        XCTAssertEqual(report.jobs.count, 2)
        XCTAssertEqual(report.jobs[0].startInterval, 300)
        XCTAssertEqual(report.script?.flags["--recover"], true)
        XCTAssertEqual(report.script?.flags["--resync"], false)
        let text = Inspector.text(report)
        XCTAssertTrue(text.contains("主仓库"))
    }
}
