import Foundation

/// RC 认证信息：
/// - credential.json（0600）保存明文口令，仅供 App 访问 RC 时读取，从不显示或写入日志；
/// - htpasswd（0600）只保存 {SHA} 哈希，供 rclone 通过 RCLONE_RC_HTPASSWD 读取，
///   这样口令既不出现在命令行参数，也不出现在 LaunchAgent plist 或环境变量里。
public struct RCCredentials: Codable, Sendable {
    public var user: String
    public var password: String

    public static let defaultUser = "rclonebar"

    public static func load(paths: AppPaths) -> RCCredentials? {
        JSONStore.read(RCCredentials.self, from: paths.credentialFile)
    }

    @discardableResult
    public static func loadOrCreate(paths: AppPaths) throws -> RCCredentials {
        try paths.ensureBaseDirectories()
        if let existing = load(paths: paths), FileManager.default.fileExists(atPath: paths.htpasswdFile.path) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        let password = bytes.map { String(format: "%02x", $0) }.joined()
        let cred = RCCredentials(user: defaultUser, password: password)
        try JSONStore.write(cred, to: paths.credentialFile, permissions: 0o600)
        try JSONStore.writeAtomically(Data(cred.htpasswdLine().utf8), to: paths.htpasswdFile, permissions: 0o600)
        return cred
    }

    public func htpasswdLine() -> String {
        let digest = SHA1.hash(Array(password.utf8))
        return "\(user):{SHA}\(Data(digest).base64EncodedString())\n"
    }

    public var basicAuthHeader: String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }
}

/// 极简 SHA-1（仅用于 htpasswd {SHA} 格式；口令是 192 位随机数，不依赖哈希强度）。
public enum SHA1 {
    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var msg = message
        let ml = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((ml >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<80 {
                let v = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (v << 1) | (v >> 31)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        var out: [UInt8] = []
        for h in [h0, h1, h2, h3, h4] {
            out += [UInt8(h >> 24), UInt8((h >> 16) & 0xff), UInt8((h >> 8) & 0xff), UInt8(h & 0xff)]
        }
        return out
    }
}
