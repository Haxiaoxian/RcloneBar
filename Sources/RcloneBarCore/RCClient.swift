import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// rclone `core/stats` 的返回值（字段均可缺失，按 v1.75 实测结构解码）。
public struct CoreStats: Decodable, Equatable, Sendable {
    public struct Transfer: Decodable, Equatable, Sendable {
        public var name: String
        public var size: Int64?
        public var bytes: Int64?
        public var percentage: Int?
        public var speed: Double?
        public var eta: Double?
        public var srcFs: String?
        public var dstFs: String?
    }

    public var bytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var transfers: Int = 0
    public var totalTransfers: Int = 0
    public var checks: Int = 0
    public var totalChecks: Int = 0
    public var listed: Int?
    public var deletes: Int = 0
    public var renames: Int = 0
    public var errors: Int = 0
    public var fatalError: Bool = false
    public var retryError: Bool = false
    public var lastError: String?
    public var speed: Double = 0
    public var eta: Double?
    public var elapsedTime: Double = 0
    public var transferring: [Transfer] = []
    public var checking: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case bytes, totalBytes, transfers, totalTransfers, checks, totalChecks, listed, deletes, renames, errors,
             fatalError, retryError, lastError, speed, eta, elapsedTime, transferring, checking
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num<T: BinaryInteger>(_ key: CodingKeys) -> T? {
            if let v = try? c.decodeIfPresent(Int64.self, forKey: key) { return T(v) }
            if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return T(v) }
            return nil
        }
        bytes = num(.bytes) ?? 0
        totalBytes = num(.totalBytes) ?? 0
        transfers = num(.transfers) ?? 0
        totalTransfers = num(.totalTransfers) ?? 0
        checks = num(.checks) ?? 0
        totalChecks = num(.totalChecks) ?? 0
        listed = num(.listed)
        deletes = num(.deletes) ?? 0
        renames = num(.renames) ?? 0
        errors = num(.errors) ?? 0
        fatalError = (try? c.decodeIfPresent(Bool.self, forKey: .fatalError)) ?? false
        retryError = (try? c.decodeIfPresent(Bool.self, forKey: .retryError)) ?? false
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        speed = (try? c.decodeIfPresent(Double.self, forKey: .speed)) ?? 0
        eta = try? c.decodeIfPresent(Double.self, forKey: .eta)
        elapsedTime = (try? c.decodeIfPresent(Double.self, forKey: .elapsedTime)) ?? 0
        transferring = (try? c.decodeIfPresent([Transfer].self, forKey: .transferring)) ?? []
        checking = (try? c.decodeIfPresent([String].self, forKey: .checking)) ?? []
    }

    public var sample: StatsSample {
        StatsSample(at: Date(), bytes: bytes, totalBytes: totalBytes, transfers: transfers, totalTransfers: totalTransfers, errors: errors)
    }
}

public enum RCError: Error, Equatable, CustomStringConvertible {
    case notReachable(String)
    case unauthorized
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case .notReachable(let s): return "无法连接 RC（\(s)）"
        case .unauthorized: return "RC 认证失败"
        case .http(let code, let msg): return "RC 返回 HTTP \(code)：\(msg)"
        case .badResponse: return "RC 返回内容无法解析"
        }
    }
}

/// 访问某一组任务的 rclone RC 接口。只连接 127.0.0.1。
public final class RCClient: @unchecked Sendable {
    public let port: Int
    private let credentials: RCCredentials
    private let session: URLSession

    public init(port: Int, credentials: RCCredentials, timeout: TimeInterval = 2) {
        self.port = port
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        #if os(macOS)
        config.connectionProxyDictionary = [:] // 本地回环地址，不走系统代理
        #endif
        self.session = URLSession(configuration: config)
    }

    deinit { session.invalidateAndCancel() }

    public func call(_ method: String, params: [String: Any] = [:]) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(method)") else { throw RCError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req) { data, response, error in
                if let error {
                    cont.resume(throwing: RCError.notReachable(error.localizedDescription))
                } else if let data, let response {
                    cont.resume(returning: (data, response))
                } else {
                    cont.resume(throwing: RCError.badResponse)
                }
            }
            task.resume()
        }
        guard let http = response as? HTTPURLResponse else { throw RCError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw RCError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            throw RCError.http(http.statusCode, msg)
        }
        return data
    }

    public func stats() async throws -> CoreStats {
        let data = try await call("core/stats")
        do { return try JSONDecoder().decode(CoreStats.self, from: data) } catch { throw RCError.badResponse }
    }

    public func pid() async throws -> Int32 {
        let data = try await call("core/pid")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value else { throw RCError.badResponse }
        return pid
    }

    /// 读取当前限速（rate 字段，如 "10Mi:off"）。
    public func bwlimit() async throws -> String {
        let data = try await call("core/bwlimit")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = obj["rate"] as? String else { throw RCError.badResponse }
        return rate
    }

    /// 立即修改当前进程的限速（正在进行的传输即时生效）。
    @discardableResult
    public func setBwlimit(_ rate: String) async throws -> String {
        let data = try await call("core/bwlimit", params: ["rate": rate])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let applied = obj["rate"] as? String else { throw RCError.badResponse }
        return applied
    }

    /// 读取进程实际生效的并发传输数（用于确认设置是否被脚本参数覆盖）。
    public func effectiveTransfers() async throws -> Int? {
        let data = try await call("options/get", params: ["blocks": "main"])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let main = obj["main"] as? [String: Any] else { return nil }
        return (main["Transfers"] as? NSNumber)?.intValue
    }
}

/// 比较 rclone 返回的限速与期望值（rclone 会把 "512k" 规范化为 "512Ki"）。
public enum BwlimitCompare {
    public static func normalize(_ rate: String) -> String {
        rate.lowercased()
            .replacingOccurrences(of: "i", with: "")
            .replacingOccurrences(of: "b", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    public static func bytesPerSecond(_ side: String) -> Int64? {
        let s = normalize(side)
        if s == "off" || s.isEmpty { return -1 }
        let units: [Character: Int64] = ["k": 1 << 10, "m": 1 << 20, "g": 1 << 30, "t": 1 << 40]
        if let last = s.last, let mult = units[last], let v = Double(s.dropLast()) { return Int64(v * Double(mult)) }
        if let v = Double(s) { return Int64(v * 1024) } // rclone 默认单位为 KiB
        return nil
    }

    public static func equivalent(_ a: String, _ b: String) -> Bool {
        func pair(_ r: String) -> (Int64?, Int64?) {
            let parts = r.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 { return (bytesPerSecond(parts[0]), bytesPerSecond(parts[1])) }
            let v = bytesPerSecond(r)
            return (v, v)
        }
        let pa = pair(a), pb = pair(b)
        return pa.0 == pb.0 && pa.1 == pb.1
    }
}
