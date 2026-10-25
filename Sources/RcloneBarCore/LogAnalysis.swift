import Foundation

/// 有限内存地读取日志文件尾部或指定偏移之后的内容。
public enum LogReader {
    public static func fileSize(_ url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value
    }

    /// 读取文件末尾最多 maxBytes 字节，返回最后 maxLines 行。
    public static func tailLines(_ url: URL, maxBytes: Int = 256 * 1024, maxLines: Int = 400) -> [String] {
        guard let size = fileSize(url), size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do { try handle.seek(toOffset: start) } catch { return [] }
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() } // 第一行可能被截断
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(maxLines))
    }

    /// 读取 offset 之后新增的内容（最多 maxBytes，超出时只保留末尾）。
    public static func readSince(_ url: URL, offset: UInt64, maxBytes: Int = 2 * 1024 * 1024) -> [String] {
        guard let size = fileSize(url) else { return [] }
        // 文件被轮转或截断时从头读
        let from = size < offset ? 0 : offset
        guard size > from, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let start = size - from > UInt64(maxBytes) ? size - UInt64(maxBytes) : from
        do { try handle.seek(toOffset: start) } catch { return [] }
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if start > from, !lines.isEmpty { lines.removeFirst() }
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

/// 去掉日志中可能出现的令牌、口令等敏感信息。
public enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)(Bearer\s+)([A-Za-z0-9\-\._~\+/]+=*)"#),
        try! NSRegularExpression(pattern: #"(?i)(Basic\s+)([A-Za-z0-9\+/]+=*)"#),
        try! NSRegularExpression(pattern: #"(?i)("?(?:access_token|refresh_token|token|client_secret|password|pass|rc_pass)"?\s*[:=]\s*"?)([^"\s,}]+)"#),
    ]

    public static func redact(_ s: String) -> String {
        var out = s
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1***")
        }
        return out
    }
}

public enum LogLevel: String, Codable, Sendable {
    case debug, info, notice, warning, error, critical, other
}

public struct LogLine: Equatable, Sendable {
    public var time: Date?
    public var level: LogLevel
    public var message: String
    public var raw: String
}

public enum LogParser {
    private static let textRE = try! NSRegularExpression(
        pattern: #"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)?\s+(DEBUG|INFO|NOTICE|WARNING|ERROR|CRITICAL|ALERT|EMERGENCY)\s*:\s?(.*)$"#)
    private static let ansiRE = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

    private static let textDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()

    public static func stripANSI(_ s: String) -> String {
        ansiRE.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    public static func parse(_ rawLine: String) -> LogLine {
        let raw = stripANSI(rawLine)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // JSON 日志（--use-json-log）
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let msg = (obj["msg"] as? String) ?? (obj["message"] as? String) ?? trimmed
            let object = obj["object"] as? String
            let level = levelFrom((obj["level"] as? String) ?? "")
            var time: Date?
            if let t = obj["time"] as? String { time = DateParsing.parse(t) }
            let full = (object.map { "\($0): " } ?? "") + msg
            return LogLine(time: time, level: level, message: full, raw: raw)
        }
        let ns = raw as NSString
        if let m = textRE.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let time = textDateFormatter.date(from: ns.substring(with: m.range(at: 1)))
            return LogLine(time: time, level: levelFrom(ns.substring(with: m.range(at: 2))), message: ns.substring(with: m.range(at: 3)), raw: raw)
        }
        return LogLine(time: nil, level: .other, message: raw, raw: raw)
    }

    static func levelFrom(_ s: String) -> LogLevel {
        switch s.lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "notice": return .notice
        case "warning", "warn": return .warning
        case "error": return .error
        case "critical", "alert", "emergency", "fatal": return .critical
        default: return .other
        }
    }
}

/// bisync 的阶段标记（这些行多为 INFO 级别，脚本未开 -v 时可能不存在，只作为补充依据）。
public enum PhaseMarker: String, Codable, Sendable {
    case listing, checkingDiffs, checkingAccess, applying, noChanges, updatingListings, validating, gracefulShutdown, finished
}

public enum ErrorCategory: String, Codable, Sendable {
    case auth, network, resyncRequired, safetyAbort, accessCheck, lockHeld, retryableAbort, other

    public var label: String {
        switch self {
        case .auth: return "需要重新授权 OneDrive"
        case .network: return "网络异常"
        case .resyncRequired: return "bisync 要求人工处理（--resync）"
        case .safetyAbort: return "触发删除保护，已中止"
        case .accessCheck: return "访问检查标记缺失"
        case .lockHeld: return "存在 bisync 锁文件"
        case .retryableAbort: return "本轮中止，下轮可自动重试"
        case .other: return "同步错误"
        }
    }
}

/// rclone 文本统计块（-P / --stats 输出）的解析结果。
public struct TextStats: Equatable, Sendable {
    public var bytes: Int64?
    public var totalBytes: Int64?
    public var speed: Double?
    public var eta: Double?
    public var transfers: Int?
    public var totalTransfers: Int?
    public var checks: Int?
    public var totalChecks: Int?
    public var listed: Int?
    public var time: Date?
}

public struct LogAnalysis: Equatable, Sendable {
    public var lastPhase: PhaseMarker?
    public var sawSuccess = false
    public var sawResyncRequired = false
    /// 找不到上一轮的 listing（历史缺失或参数变化导致文件名不同）
    public var sawMissingListings = false
    public var sawRetryableAbort = false
    public var sawAbort = false
    public var sawGracefulOK = false
    public var sawGracefulFailed = false
    public var sawCritical = false
    public var conflicts = 0
    public var errorLines: [String] = []
    public var category: ErrorCategory?
    public var textStats: TextStats?
    public var lastTime: Date?
    public var lastSuccessTime: Date?
    public var retryAttempts = 0

    public init() {}
}

public enum LogAnalyzer {
    private static let authNeedles = ["invalid_grant", "couldn't fetch token", "failed to refresh token", "token expired",
                                      "unauthenticated", "aadsts", "invalidauthenticationtoken", "re-authenticate", "rclone config reconnect",
                                      "401 unauthorized", "error 401", "authentication failed", "token has been revoked"]
    private static let networkNeedles = ["no such host", "dial tcp", "connection reset", "connection refused", "i/o timeout",
                                         "tls handshake timeout", "network is unreachable", "context deadline exceeded",
                                         "temporary failure in name resolution", "unexpected eof", "503 service unavailable", "504 gateway",
                                         "toomanyrequests", "429 too many requests", "server misbehaving", "no route to host"]

    public static func analyze(_ rawLines: [String]) -> LogAnalysis {
        var a = LogAnalysis()
        var pendingStats = TextStats()
        var inStatsBlock = false
        var flags = Set<ErrorCategory>()
        for raw in rawLines {
            let line = LogParser.parse(raw)
            if let t = line.time { a.lastTime = t }
            let msg = line.message
            let lower = msg.lowercased()

            // 文本统计块：以 "Transferred:" 开头的多行
            if parseStatsLine(msg, into: &pendingStats) {
                inStatsBlock = true
                pendingStats.time = line.time ?? a.lastTime
                a.textStats = pendingStats
                continue
            } else if inStatsBlock && line.level == .other && msg.trimmingCharacters(in: .whitespaces).isEmpty {
                inStatsBlock = false
                pendingStats = TextStats()
            }

            if msg.contains("Building Path1 and Path2 listings") { a.lastPhase = .listing; resetRunFlags(&a); flags.removeAll() }
            else if msg.contains("checking for diffs") { a.lastPhase = .checkingDiffs }
            else if msg.contains("Checking access health") { a.lastPhase = .checkingAccess }
            else if msg.contains("Applying changes") { a.lastPhase = .applying }
            else if msg.contains("No changes found") { a.lastPhase = .noChanges }
            else if msg.contains("Updating listings") { a.lastPhase = .updatingListings }
            else if msg.contains("Validating listings") { a.lastPhase = .validating }
            else if msg.contains("Attempting to gracefully shutdown") { a.lastPhase = .gracefulShutdown }

            if msg.contains("Bisync successful") {
                a.sawSuccess = true
                a.lastPhase = .finished
                a.lastSuccessTime = line.time ?? a.lastTime
            }
            if msg.contains("Graceful shutdown completed successfully") { a.sawGracefulOK = true }
            if msg.contains("Graceful shutdown failed") { a.sawGracefulFailed = true }
            if msg.contains("Must run --resync to recover") { a.sawResyncRequired = true }
            if msg.contains("cannot find prior Path1 or Path2 listings") { a.sawMissingListings = true }
            if msg.contains("Error is retryable without --resync") { a.sawRetryableAbort = true }
            if msg.contains("Bisync aborted") { a.sawAbort = true; a.lastPhase = .finished }
            if msg.contains("Bisync critical error") { a.sawCritical = true }
            if msg.contains("New or changed in both paths") { a.conflicts += 1 }
            if msg.contains("Safety abort") || lower.contains("too many deletes") { flags.insert(.safetyAbort) }
            if (msg.contains("--check-access") && lower.contains("failed")) || msg.contains("Access test failed") { flags.insert(.accessCheck) }
            if lower.contains("prior lock file found") { flags.insert(.lockHeld) }
            if lower.contains("retrying as --resilient") || (lower.contains("attempt ") && lower.contains("failed with")) { a.retryAttempts += 1 }

            let important = line.level == .error || line.level == .critical || line.level == .notice || line.level == .other
            if important && authNeedles.contains(where: { lower.contains($0) }) { flags.insert(.auth) }
            if line.level == .error || line.level == .critical {
                a.errorLines.append(Redactor.redact(line.raw))
                if a.errorLines.count > 30 { a.errorLines.removeFirst(a.errorLines.count - 30) }
                if networkNeedles.contains(where: { lower.contains($0) }) { flags.insert(.network) } else { flags.insert(.other) }
            }
        }
        if a.sawResyncRequired || a.sawMissingListings { flags.insert(.resyncRequired) }
        if a.sawRetryableAbort { flags.insert(.retryableAbort) }
        // 优先级：授权 > 需要人工处理 > 删除保护 > 访问检查 > 锁 > 网络 > 可重试中止 > 其他
        let priority: [ErrorCategory] = [.auth, .resyncRequired, .safetyAbort, .accessCheck, .lockHeld, .network, .retryableAbort, .other]
        a.category = priority.first { flags.contains($0) }
        return a
    }

    /// 新一轮开始时，前一轮的结论不再适用
    private static func resetRunFlags(_ a: inout LogAnalysis) {
        let lastSuccess = a.lastSuccessTime
        let time = a.lastTime
        a = LogAnalysis()
        a.lastSuccessTime = lastSuccess
        a.lastTime = time
        a.lastPhase = .listing
    }

    private static let bytesRE = try! NSRegularExpression(pattern: #"^Transferred:\s+([\d.]+\s*\S*?B)\s*/\s*([\d.]+\s*\S*?B),\s*(?:(\d+)%|-),\s*([\d.]+\s*\S*?B/s),\s*ETA\s*(\S+)"#)
    private static let countRE = try! NSRegularExpression(pattern: #"^(Transferred|Checks):\s+(\d+)\s*/\s*(\d+)(?:,\s*(?:\d+%|-))?(?:,\s*Listed\s+(\d+))?"#)

    @discardableResult
    static func parseStatsLine(_ message: String, into s: inout TextStats) -> Bool {
        let m = message.trimmingCharacters(in: .whitespaces)
        let ns = m as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let r = bytesRE.firstMatch(in: m, range: range) {
            s.bytes = ByteParsing.parse(ns.substring(with: r.range(at: 1)))
            s.totalBytes = ByteParsing.parse(ns.substring(with: r.range(at: 2)))
            s.speed = ByteParsing.parse(ns.substring(with: r.range(at: 4)).replacingOccurrences(of: "/s", with: "")).map(Double.init)
            s.eta = DurationParsing.parseRclone(ns.substring(with: r.range(at: 5)))
            return true
        }
        if let r = countRE.firstMatch(in: m, range: range) {
            let kind = ns.substring(with: r.range(at: 1))
            let done = Int(ns.substring(with: r.range(at: 2)))
            let total = Int(ns.substring(with: r.range(at: 3)))
            if kind == "Transferred" { s.transfers = done; s.totalTransfers = total }
            else { s.checks = done; s.totalChecks = total }
            if r.range(at: 4).location != NSNotFound { s.listed = Int(ns.substring(with: r.range(at: 4))) }
            return true
        }
        return false
    }
}

public enum ByteParsing {
    /// "22.888 MiB" → 字节
    public static func parse(_ s: String) -> Int64? {
        let t = s.replacingOccurrences(of: " ", with: "")
        var numEnd = t.startIndex
        while numEnd < t.endIndex, t[numEnd].isNumber || t[numEnd] == "." { numEnd = t.index(after: numEnd) }
        guard let v = Double(t[t.startIndex..<numEnd]) else { return nil }
        let unit = t[numEnd...].lowercased()
        let mult: Double
        switch unit.first {
        case "k": mult = 1024
        case "m": mult = 1024 * 1024
        case "g": mult = 1024 * 1024 * 1024
        case "t": mult = pow(1024, 4)
        default: mult = 1
        }
        return Int64(v * mult)
    }
}

public enum DurationParsing {
    /// rclone 的 ETA 写法，例如 "17s"、"1m30s"、"2h3m4s"、"-"。
    public static func parseRclone(_ s: String) -> Double? {
        if s == "-" || s.isEmpty { return nil }
        var total = 0.0
        var num = ""
        var any = false
        for ch in s {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard let v = Double(num) else { return nil }
            switch ch {
            case "d": total += v * 86400
            case "h": total += v * 3600
            case "m": total += v * 60
            case "s": total += v
            default: return nil
            }
            num = ""
            any = true
        }
        return any ? total : nil
    }
}

public enum DateParsing {
    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let fallbacks: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = $0
        return f
    }

    public static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let d = isoFull.date(from: t) ?? iso.date(from: t) { return d }
        // Python isoformat 可能带 6 位微秒和时区
        if let plus = t.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) {
            let base = String(t[..<plus.lowerBound])
            let zone = String(t[plus.lowerBound...])
            let trimmedFraction = base.replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
            if let d = iso.date(from: trimmedFraction + zone) { return d }
        }
        for f in fallbacks { if let d = f.date(from: t) { return d } }
        return nil
    }

    public static func fromAny(_ v: Any) -> Date? {
        if let s = v as? String {
            if let d = parse(s) { return d }
            if let n = Double(s) { return fromEpoch(n) }
            return nil
        }
        if let n = v as? NSNumber, !(v is Bool) { return fromEpoch(n.doubleValue) }
        return nil
    }

    static func fromEpoch(_ n: Double) -> Date? {
        if n > 1_000_000_000_000 { return Date(timeIntervalSince1970: n / 1000) }
        if n > 1_000_000_000 { return Date(timeIntervalSince1970: n) }
        return nil
    }
}
