import Foundation

/// 现有 sync.py 写出的 status.json 结构未知，这里用宽松的启发式读取，只取能确定的字段。
public struct LegacyStatus: Equatable, Sendable {
    public var fileModified: Date?
    public var state: String?
    public var lastSuccess: Date?
    public var lastRun: Date?
    public var lastError: String?
    public var exitCode: Int?
    public var running: Bool?
    /// 扁平化后的字段（已去掉敏感键），用于详情展示
    public var fields: [(String, String)]

    public static func == (a: LegacyStatus, b: LegacyStatus) -> Bool {
        a.fileModified == b.fileModified && a.state == b.state && a.lastSuccess == b.lastSuccess && a.lastRun == b.lastRun
            && a.lastError == b.lastError && a.exitCode == b.exitCode && a.running == b.running
            && a.fields.map { $0.0 + "=" + $0.1 } == b.fields.map { $0.0 + "=" + $0.1 }
    }

    /// state 文本看起来是否表示成功
    public var stateLooksSuccessful: Bool? {
        guard let s = state?.lowercased() else { return nil }
        if ["ok", "success", "succeeded", "successful", "done", "completed", "成功", "idle"].contains(s) { return true }
        if s.contains("fail") || s.contains("error") || s.contains("abort") || s.contains("失败") { return false }
        return nil
    }

    public static func load(_ url: URL) -> LegacyStatus? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var flat: [(String, Any)] = []
        flatten(obj, prefix: "", into: &flat)
        return parse(flat: flat, modified: JSONStore.modificationDate(url))
    }

    static let sensitive = ["token", "secret", "password", "pass", "auth", "key"]

    static func flatten(_ v: Any, prefix: String, into out: inout [(String, Any)], depth: Int = 0) {
        guard depth < 4 else { return }
        if let d = v as? [String: Any] {
            for k in d.keys.sorted() {
                let lower = k.lowercased()
                if sensitive.contains(where: { lower.contains($0) }) { continue }
                flatten(d[k]!, prefix: prefix.isEmpty ? k : "\(prefix).\(k)", into: &out, depth: depth + 1)
            }
        } else if let a = v as? [Any] {
            if let last = a.last { flatten(last, prefix: prefix + "[-1]", into: &out, depth: depth + 1) }
        } else {
            out.append((prefix, v))
        }
    }

    static func parse(flat: [(String, Any)], modified: Date?) -> LegacyStatus {
        var s = LegacyStatus(fileModified: modified, fields: [])
        for (key, value) in flat {
            let k = key.lowercased()
            let leaf = k.split(separator: ".").last.map(String.init) ?? k
            let str: String = {
                if let b = value as? Bool { return b ? "true" : "false" }
                if let n = value as? NSNumber { return n.stringValue }
                return Redactor.redact(String(describing: value))
            }()
            s.fields.append((key, String(str.prefix(300))))

            if leaf.contains("success") && !leaf.contains("count"), let d = DateParsing.fromAny(value) {
                if s.lastSuccess == nil || d > s.lastSuccess! { s.lastSuccess = d }
            } else if ["last_run", "lastrun", "last_run_at", "started", "started_at", "start_time", "finished", "finished_at",
                       "end_time", "ended_at", "updated", "updated_at", "timestamp", "time", "last_finished"].contains(leaf),
                      let d = DateParsing.fromAny(value) {
                if s.lastRun == nil || d > s.lastRun! { s.lastRun = d }
            } else if ["state", "status", "result", "phase", "last_result"].contains(leaf), let t = value as? String {
                s.state = t
            } else if ["exit_code", "exitcode", "returncode", "return_code", "rc", "code"].contains(leaf), let n = value as? NSNumber, !(value is Bool) {
                s.exitCode = n.intValue
            } else if ["running", "is_running", "in_progress"].contains(leaf), let b = value as? Bool {
                s.running = b
            } else if leaf.contains("error") || leaf == "message" || leaf == "detail" {
                if let t = value as? String, !t.isEmpty { s.lastError = Redactor.redact(String(t.prefix(2000))) }
            }
        }
        return s
    }
}
