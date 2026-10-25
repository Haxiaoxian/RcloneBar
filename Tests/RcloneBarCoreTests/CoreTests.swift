import Foundation
import XCTest
@testable import RcloneBarCore

final class ProgressTests: XCTestCase {
    func stats(bytes: Int64 = 0, total: Int64 = 0, transfers: Int = 0, totalTransfers: Int = 0, eta: Double? = nil,
               transferring: [String] = [], listed: Int? = nil, checks: Int = 0) -> CoreStats {
        var s = CoreStats()
        s.bytes = bytes
        s.totalBytes = total
        s.transfers = transfers
        s.totalTransfers = totalTransfers
        s.eta = eta
        s.listed = listed
        s.checks = checks
        s.speed = transferring.isEmpty ? 0 : 1_000_000
        s.transferring = transferring.map { CoreStats.Transfer(name: $0, size: 100, bytes: 10, percentage: 10, speed: 1, eta: nil, srcFs: nil, dstFs: nil) }
        return s
    }

    func testScanningWithoutTotalsHasNoFractionOrETA() {
        var t = ProgressTracker()
        let p = t.update(running: true, starting: false, stopRequested: false, stats: stats(listed: 120, checks: 3),
                         logPhase: nil, textStats: nil)
        XCTAssertEqual(p.activity, .scanning)
        XCTAssertNil(p.fraction, "未知进度不能显示为 0% 或 100%")
        XCTAssertNil(p.eta)
        XCTAssertNil(p.etaText)
        XCTAssertNil(p.totalBytes)
        XCTAssertEqual(p.listed, 120)
    }

    func testTransferringETAUnavailableShowsEstimating() {
        var t = ProgressTracker()
        let p = t.update(running: true, starting: false, stopRequested: false,
                         stats: stats(bytes: 10, total: 1000, transfers: 0, totalTransfers: 3, eta: nil, transferring: ["a"]),
                         logPhase: nil, textStats: nil)
        XCTAssertEqual(p.activity, .transferring)
        XCTAssertEqual(p.fraction!, 0.01, accuracy: 0.0001)
        XCTAssertEqual(p.etaText, "估算中")
    }

    func testGrowingTotalsSuppressETA() {
        var t = ProgressTracker()
        let t0 = Date()
        _ = t.update(running: true, starting: false, stopRequested: false,
                     stats: stats(bytes: 10, total: 1000, totalTransfers: 3, eta: 5, transferring: ["a"]), logPhase: nil, textStats: nil, now: t0)
        let p = t.update(running: true, starting: false, stopRequested: false,
                         stats: stats(bytes: 20, total: 5000, totalTransfers: 9, eta: 5, transferring: ["a"]), logPhase: nil, textStats: nil,
                         now: t0.addingTimeInterval(1))
        XCTAssertTrue(p.totalsGrowing)
        XCTAssertNil(p.eta)
        XCTAssertEqual(p.etaText, "估算中")
        let later = t.update(running: true, starting: false, stopRequested: false,
                             stats: stats(bytes: 30, total: 5000, totalTransfers: 9, eta: 5, transferring: ["a"]), logPhase: nil, textStats: nil,
                             now: t0.addingTimeInterval(10))
        XCTAssertFalse(later.totalsGrowing)
        XCTAssertEqual(later.eta, 5)
    }

    func testFullTransferButStillRunningIsFinishingNotSuccess() {
        var t = ProgressTracker()
        let p = t.update(running: true, starting: false, stopRequested: false,
                         stats: stats(bytes: 1000, total: 1000, transfers: 3, totalTransfers: 3), logPhase: nil, textStats: nil)
        XCTAssertEqual(p.activity, .finishing)
        XCTAssertEqual(p.fraction, 1)
        XCTAssertNil(p.etaText)
    }

    func testLogPhaseOverridesToFinishing() {
        var t = ProgressTracker()
        let p = t.update(running: true, starting: false, stopRequested: false,
                         stats: stats(bytes: 10, total: 1000, totalTransfers: 3, transferring: []), logPhase: .updatingListings, textStats: nil)
        XCTAssertEqual(p.activity, .finishing)
    }

    func testRunningWithoutDataIsNotTransferring() {
        var t = ProgressTracker()
        let p = t.update(running: true, starting: false, stopRequested: false, stats: nil, logPhase: nil, textStats: nil)
        XCTAssertEqual(p.activity, .runningNoDetail)
        XCTAssertNil(p.fraction)
    }

    func testNotRunningIsIdle() {
        var t = ProgressTracker()
        let p = t.update(running: false, starting: false, stopRequested: false, stats: stats(bytes: 1, total: 1), logPhase: nil, textStats: nil)
        XCTAssertEqual(p.activity, .idle)
    }

    func testStopRequestedShowsStopping() {
        var t = ProgressTracker()
        let p = t.update(running: true, starting: false, stopRequested: true, stats: stats(transferring: ["a"]), logPhase: nil, textStats: nil)
        XCTAssertEqual(p.activity, .stopping)
    }

    func testOverallPriority() {
        let r = OverallStateResolver.resolve([
            .init(activity: .idle, lastOutcome: .failed, lastErrorCategory: .other, paused: false),
            .init(activity: .transferring, lastOutcome: .success, lastErrorCategory: nil, paused: false),
        ], agentAvailable: true, allPaused: false)
        XCTAssertEqual(r, .transferring)
        let e = OverallStateResolver.resolve([
            .init(activity: .idle, lastOutcome: .retryableFailure, lastErrorCategory: .network, paused: false),
        ], agentAvailable: true, allPaused: false)
        XCTAssertEqual(e, .error("网络异常或可重试错误"))
        let p = OverallStateResolver.resolve([.init(activity: .idle, lastOutcome: .success, lastErrorCategory: nil, paused: true)],
                                             agentAvailable: true, allPaused: true)
        XCTAssertEqual(p, .paused)
    }
}

final class LogTests: XCTestCase {
    func testParseTextLine() {
        let l = LogParser.parse("2026/10/25 00:48:30 ERROR : 文件 64.bin: Failed to copy: x")
        XCTAssertEqual(l.level, .error)
        XCTAssertEqual(l.message, "文件 64.bin: Failed to copy: x")
        XCTAssertNotNil(l.time)
    }

    func testParseJSONLine() {
        let l = LogParser.parse(#"{"time":"2026-10-25T00:48:30.123456+08:00","level":"notice","msg":"Bisync successful","source":"x"}"#)
        XCTAssertEqual(l.level, .notice)
        XCTAssertEqual(l.message, "Bisync successful")
        XCTAssertNotNil(l.time)
    }

    func testStripsANSI() {
        let l = LogParser.parse("2026/10/25 00:48:30 ERROR : \u{1B}[31mBisync aborted. Must run --resync to recover.\u{1B}[0m")
        XCTAssertEqual(l.message, "Bisync aborted. Must run --resync to recover.")
    }

    func testResyncRequiredClassification() {
        let a = LogAnalyzer.analyze([
            "2026/10/25 00:48:30 ERROR : Bisync critical error: chtimes x: no such file or directory",
            "2026/10/25 00:48:30 ERROR : Bisync aborted. Must run --resync to recover.",
        ])
        XCTAssertTrue(a.sawResyncRequired)
        XCTAssertEqual(a.category, .resyncRequired)
    }

    func testRetryableNetwork() {
        let a = LogAnalyzer.analyze([
            "2026/10/25 00:48:30 ERROR : foo: Failed to copy: Post \"https://graph.microsoft.com\": dial tcp: lookup graph.microsoft.com: no such host",
            "2026/10/25 00:48:31 ERROR : Bisync critical error: x",
            "2026/10/25 00:48:31 ERROR : Bisync aborted. Error is retryable without --resync due to --resilient mode.",
        ])
        XCTAssertEqual(a.category, .network)
        XCTAssertTrue(a.sawRetryableAbort)
    }

    func testAuth() {
        let a = LogAnalyzer.analyze([
            "2026/10/25 00:48:30 ERROR : onedrive root '': Failed to get root: couldn't fetch token: invalid_grant: AADSTS70000",
        ])
        XCTAssertEqual(a.category, .auth)
    }

    func testConflictsAndSafety() {
        let a = LogAnalyzer.analyze([
            "2026/10/25 00:48:30 NOTICE: - WARNING  New or changed in both paths  - a.md",
            "2026/10/25 00:48:30 NOTICE: - WARNING  New or changed in both paths  - b.md",
            "2026/10/25 00:48:31 ERROR : Safety abort: too many deletes (>50%, 10 of 12) on Path1 \"x\". Run with --force if desired.",
        ])
        XCTAssertEqual(a.conflicts, 2)
        XCTAssertEqual(a.category, .safetyAbort)
    }

    func testTextStats() {
        var s = TextStats()
        XCTAssertTrue(LogAnalyzer.parseStatsLine("Transferred:   \t   22.888 MiB / 111.580 MiB, 21%, 5.037 MiB/s, ETA 17s", into: &s))
        XCTAssertTrue(LogAnalyzer.parseStatsLine("Checks:               162 / 162, 100%, Listed 202", into: &s))
        XCTAssertTrue(LogAnalyzer.parseStatsLine("Transferred:            4 / 35, 11%", into: &s))
        XCTAssertEqual(s.totalBytes, Int64(111.580 * 1024 * 1024))
        XCTAssertEqual(s.eta, 17)
        XCTAssertEqual(s.listed, 202)
        XCTAssertEqual(s.transfers, 4)
        XCTAssertEqual(s.totalTransfers, 35)
    }

    func testRedaction() {
        let r = Redactor.redact(#"{"access_token":"eyJabc.def","refresh_token":"M.R3_x"} Authorization: Bearer abc.def"#)
        XCTAssertFalse(r.contains("eyJabc"))
        XCTAssertFalse(r.contains("M.R3_x"))
        XCTAssertFalse(r.contains("abc.def"))
    }

    func testDurations() {
        XCTAssertEqual(DurationParsing.parseRclone("1h2m3s"), 3723)
        XCTAssertNil(DurationParsing.parseRclone("-"))
    }
}

final class EvaluatorTests: XCTestCase {
    let start = Date().addingTimeInterval(-60)

    func ev(exit: Int32?, rclone: Bool, lines: [String], listingUpdated: Bool?, stop: Bool = false) -> RunEvidence {
        var probe: BisyncListings.Probe?
        if let u = listingUpdated {
            let m = u ? Date() : start.addingTimeInterval(-3600)
            probe = .init(path1Modified: m, path2Modified: m, errFilesModified: nil, lockFilePresent: false)
        }
        return RunEvidence(startedAt: start, exitCode: exit, exitCodeIsRclone: rclone, log: LogAnalyzer.analyze(lines),
                           logLineCount: lines.count, listing: probe, legacyStatus: nil, stopRequested: stop,
                           sawBisyncProcess: true, scriptHasRecover: true, rcErrors: nil)
    }

    func testScriptExitZeroWithoutListingUpdateIsNotSuccess() {
        let v = RunEvaluator.evaluate(ev(exit: 0, rclone: false, lines: [], listingUpdated: false))
        XCTAssertNotEqual(v.outcome, .success, "进程退出不等于同步成功")
    }

    func testListingUpdatedAndExitZeroIsSuccess() {
        XCTAssertEqual(RunEvaluator.evaluate(ev(exit: 0, rclone: false, lines: [], listingUpdated: true)).outcome, .success)
    }

    func testDirectRcloneExitCode() {
        XCTAssertEqual(RunEvaluator.evaluate(ev(exit: 0, rclone: true, lines: [], listingUpdated: nil)).outcome, .success)
        XCTAssertEqual(RunEvaluator.evaluate(ev(exit: 1, rclone: true, lines: ["2026/10/25 00:48:30 ERROR : boom"], listingUpdated: nil)).outcome, .failed)
    }

    func testRetryable() {
        let v = RunEvaluator.evaluate(ev(exit: 7, rclone: true, lines: [
            "2026/10/25 00:48:30 ERROR : x: dial tcp: i/o timeout",
            "2026/10/25 00:48:31 ERROR : Bisync aborted. Error is retryable without --resync due to --resilient mode.",
        ], listingUpdated: false))
        XCTAssertEqual(v.outcome, .retryableFailure)
    }

    func testResyncNeedsAttentionNeverAuto() {
        let v = RunEvaluator.evaluate(ev(exit: 7, rclone: true, lines: ["2026/10/25 00:48:31 ERROR : Bisync aborted. Must run --resync to recover."], listingUpdated: false))
        XCTAssertEqual(v.outcome, .needsAttention)
        XCTAssertTrue(v.summary.contains("不会自动执行 --resync"))
    }

    func testMissingListingsNeedsAttentionEvenIfRetryable() {
        let v = RunEvaluator.evaluate(ev(exit: 7, rclone: true, lines: [
            "2026/10/25 01:27:04 ERROR : Bisync critical error: cannot find prior Path1 or Path2 listings, likely due to critical error on prior run ",
            "2026/10/25 01:27:04 ERROR : Bisync aborted. Error is retryable without --resync due to --resilient mode.",
        ], listingUpdated: false))
        XCTAssertEqual(v.outcome, .needsAttention)
    }

    func testStoppedByUser() {
        let v = RunEvaluator.evaluate(ev(exit: 130, rclone: true, lines: [], listingUpdated: false, stop: true))
        XCTAssertEqual(v.outcome, .stoppedByUser)
    }

    func testAuth() {
        let v = RunEvaluator.evaluate(ev(exit: 1, rclone: false, lines: ["2026/10/25 00:48:31 ERROR : couldn't fetch token: invalid_grant"], listingUpdated: false))
        XCTAssertEqual(v.outcome, .authRequired)
    }

    func testListingUpdatedButAbortIsNotSuccess() {
        let v = RunEvaluator.evaluate(ev(exit: 0, rclone: false, lines: ["2026/10/25 00:48:31 ERROR : Bisync critical error: x"], listingUpdated: true))
        XCTAssertNotEqual(v.outcome, .success)
    }
}

final class MiscTests: XCTestCase {
    func testSHA1() {
        let hex = SHA1.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "a9993e364706816aba3e25717850c26c9cd0d89d")
        let long = SHA1.hash(Array(String(repeating: "a", count: 1000).utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(long, "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    func testBwlimitRate() {
        var s = SyncSettings()
        XCTAssertNil(s.bwlimitRate)
        s.bandwidthControlEnabled = true
        XCTAssertEqual(s.bwlimitRate, "off")
        s.uploadLimitKiB = 512
        XCTAssertEqual(s.bwlimitRate, "512k:off")
        s.downloadLimitKiB = 2048
        XCTAssertEqual(s.bwlimitRate, "512k:2048k")
        XCTAssertTrue(BwlimitCompare.equivalent("512Ki:2Mi", "512k:2048k"))
        XCTAssertTrue(BwlimitCompare.equivalent("16Mi", "16384k:16384k"))
        XCTAssertFalse(BwlimitCompare.equivalent("10Mi:off", "10M:5M"))
        XCTAssertEqual(s.runEnvironment()["RCLONE_BWLIMIT"], "512k:2048k")
    }

    func testSettingsDecodeWithMissingFields() throws {
        let s = try JSONStore.makeDecoder().decode(SyncSettings.self, from: Data(#"{"intervalMinutes": 10}"#.utf8))
        XCTAssertEqual(s.intervalMinutes, 10)
        XCTAssertTrue(s.notifyFailures)
        XCTAssertNil(s.transfers)
    }

    func testLaunchctlPrintParse() {
        let text = """
        gui/501/com.zhuke.rclone-bisync.vault = {
        \tactive count = 1
        \tpath = /Users/zhuke/Library/LaunchAgents/com.zhuke.rclone-bisync.vault.plist
        \tstate = running
        \tprogram = /usr/bin/python3
        \targuments = {
        \t\tstate = nested
        \t}
        \truns = 12
        \tpid = 4242
        \tlast exit code = 0
        \trun interval = 300 seconds
        }
        """
        let i = Launchctl.parsePrint(text)
        XCTAssertTrue(i.running)
        XCTAssertEqual(i.pid, 4242)
        XCTAssertEqual(i.lastExitCode, 0)
        XCTAssertEqual(i.runInterval, 300)
        XCTAssertEqual(i.runs, 12)
        let n = Launchctl.parsePrint("x = {\n\tstate = not running\n\tlast exit code = (never exited)\n}")
        XCTAssertFalse(n.running)
        XCTAssertNil(n.lastExitCode)
    }

    func testCanonicalListingName() {
        XCTAssertEqual(BisyncListings.canonical("/Users/zhuke/Documents/主仓库"), "Users_zhuke_Documents_主仓库")
        XCTAssertEqual(BisyncListings.canonical("onedrive:其他/Obsidian/主仓库"), "onedrive_其他_Obsidian_主仓库")
        XCTAssertEqual(BisyncListings.canonical("/a b/c"), "a_b_c")
        XCTAssertEqual(BisyncListings.stripConfigSuffix("a{Ab3_x}..b.path1.lst"), "a..b.path1.lst")
    }

    func testPlistOnDemandRemovesScheduleAndKeepsOthers() throws {
        let p = LaunchAgentPlist(dict: ["Label": "x", "ProgramArguments": ["/usr/bin/python3", "/a b/sync.py", "vault"],
                                        "StartInterval": 300, "RunAtLoad": true, "StandardOutPath": "/tmp/o.log",
                                        "EnvironmentVariables": ["PATH": "/opt/homebrew/bin", "RCLONE_TRANSFERS": "9"]])
        let q = p.onDemand(environment: ["RCLONE_RC": "true"], removingEnvKeys: ["RCLONE_TRANSFERS"])
        XCTAssertNil(q.dict["StartInterval"])
        XCTAssertEqual(q.dict["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(q.programArguments, ["/usr/bin/python3", "/a b/sync.py", "vault"])
        XCTAssertEqual(q.standardOutPath, "/tmp/o.log")
        XCTAssertEqual(q.environment, ["PATH": "/opt/homebrew/bin", "RCLONE_RC": "true"])
        XCTAssertFalse(q.hasSchedule)
        let data = try q.data()
        let back = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(back?["Label"] as? String, "x")
    }

    func testBisyncMatcher() {
        let job = JobConfig.defaults(paths: AppPaths(home: URL(fileURLWithPath: "/Users/zhuke")))[0]
        XCTAssertTrue(BisyncMatcher.matches(["/opt/homebrew/bin/rclone", "bisync", "/Users/zhuke/Documents/主仓库/", "onedrive:其他/Obsidian/主仓库"], job: job))
        XCTAssertFalse(BisyncMatcher.matches(["/opt/homebrew/bin/rclone", "bisync", "/Users/zhuke/Documents/项目", "onedrive:项目"], job: job))
        XCTAssertFalse(BisyncMatcher.matches(["/opt/homebrew/bin/rclone", "lsf", "/Users/zhuke/Documents/主仓库"], job: job))
    }

    func testLegacyStatusHeuristics() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("status.json")
        try Data(#"{"state":"failed","last_success":"2026-10-24T10:00:00+08:00","last_run":1761300000,"error":"boom","exit_code":7,"token":"secret"}"#.utf8).write(to: url)
        let s = try XCTUnwrap(LegacyStatus.load(url))
        XCTAssertEqual(s.state, "failed")
        XCTAssertEqual(s.stateLooksSuccessful, false)
        XCTAssertNotNil(s.lastSuccess)
        XCTAssertNotNil(s.lastRun)
        XCTAssertEqual(s.exitCode, 7)
        XCTAssertFalse(s.fields.contains { $0.0 == "token" })
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.bytes(512), "512 B")
        XCTAssertEqual(Formatters.bytes(1536), "1.50 KB")
        XCTAssertEqual(Formatters.compactSpeed(3.2 * 1024 * 1024), "3.2M/s")
        XCTAssertEqual(Formatters.duration(75), "1 分 15 秒")
    }

    func testRunHistoryBounded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("runs.jsonl")
        for i in 0..<50 {
            let r = RunRecord(id: "\(i)", jobID: "vault", trigger: .scheduled, startedAt: Date(), finishedAt: Date(), outcome: .success,
                              exitCode: 0, summary: String(repeating: "x", count: 20_000), errors: [], conflicts: 0, bytes: nil,
                              transfers: nil, rcEnabled: true, evidence: [])
            try RunHistory.append(r, to: url)
        }
        let size = try XCTUnwrap(LogReader.fileSize(url))
        XCTAssertLessThanOrEqual(size, UInt64(RunHistory.maxBytes + 30_000))
        XCTAssertEqual(RunHistory.recent(from: url, limit: 5).first?.id, "49")
    }
}
