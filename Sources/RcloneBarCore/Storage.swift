import Foundation

public enum JSONStore {
    public static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(T.self, from: data)
    }

    /// 原子写入（先写临时文件再改名），可指定权限。
    public static func write<T: Encodable>(_ value: T, to url: URL, permissions: Int? = nil) throws {
        let data = try makeEncoder().encode(value)
        try writeAtomically(data, to: url, permissions: permissions)
    }

    public static func writeAtomically(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var attrs: [FileAttributeKey: Any]? = nil
        if let permissions { attrs = [.posixPermissions: permissions] }
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: attrs) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// 运行记录：JSON Lines，限制文件大小，读取时只取尾部。
public enum RunHistory {
    public static let maxBytes = 768 * 1024
    public static let keepLines = 400

    public static func append(_ record: RunRecord, to url: URL) throws {
        var line = try JSONStore.makeEncoder(pretty: false).encode(record)
        line.append(0x0A)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try? handle.synchronize()
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            try? trim(url)
        }
    }

    static func trim(_ url: URL) throws {
        let lines = LogReader.tailLines(url, maxBytes: maxBytes, maxLines: keepLines)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try JSONStore.writeAtomically(data, to: url)
    }

    /// 最近的记录（新的在前）
    public static func recent(from url: URL, limit: Int = 100) -> [RunRecord] {
        let decoder = JSONStore.makeDecoder()
        let lines = LogReader.tailLines(url, maxBytes: 512 * 1024, maxLines: limit)
        return lines.reversed().compactMap { try? decoder.decode(RunRecord.self, from: Data($0.utf8)) }
    }
}

/// App → 后台服务的命令通道：一条命令一个文件，原子改名后才可见。
public enum ControlChannel {
    public static let expiry: TimeInterval = 120

    public static func send(_ command: ControlCommand, paths: AppPaths) throws {
        let name = "\(Int(command.createdAt.timeIntervalSince1970 * 1000))-\(command.id).json"
        try JSONStore.write(command, to: paths.controlDir.appendingPathComponent(name))
    }

    /// 读取并删除所有待处理命令（按时间顺序）。
    public static func drain(paths: AppPaths) -> [ControlCommand] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: paths.controlDir.path) else { return [] }
        var result: [ControlCommand] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = paths.controlDir.appendingPathComponent(name)
            defer { try? fm.removeItem(at: url) }
            if let cmd = JSONStore.read(ControlCommand.self, from: url) {
                result.append(cmd)
            }
        }
        return result
    }
}
