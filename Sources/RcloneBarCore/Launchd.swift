import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }
}

/// 以参数数组执行外部程序（不经过 shell，中文与空格路径安全）。
public enum Shell {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return ShellResult(status: -1, stdout: "", stderr: "无法执行 \(executable)：\(error.localizedDescription)")
        }
        // 先在后台读完输出，避免管道写满导致子进程阻塞
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outBox.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        group.wait()
        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: outBox.data, as: UTF8.self),
                           stderr: String(decoding: errBox.data, as: UTF8.self))
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

public struct LaunchdServiceInfo: Equatable, Sendable {
    public var loaded: Bool
    public var running: Bool
    public var pid: Int32?
    public var lastExitCode: Int32?
    public var runInterval: Int?
    public var runs: Int?

    public static let notLoaded = LaunchdServiceInfo(loaded: false, running: false, pid: nil, lastExitCode: nil, runInterval: nil, runs: nil)
}

/// launchctl 封装（gui/<uid> 域）。
public enum Launchctl {
    public static let path = "/bin/launchctl"
    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }
    public static var domain: String { "gui/\(getuid())" }

    public static func service(_ label: String) -> String { "\(domain)/\(label)" }

    public static func info(_ label: String) -> LaunchdServiceInfo {
        guard isAvailable else { return .notLoaded }
        let r = Shell.run(path, ["print", service(label)], timeout: 5)
        guard r.ok else { return .notLoaded }
        return parsePrint(r.stdout)
    }

    public static func parsePrint(_ text: String) -> LaunchdServiceInfo {
        var info = LaunchdServiceInfo(loaded: true, running: false, pid: nil, lastExitCode: nil, runInterval: nil, runs: nil)
        // 只看服务自身的顶层字段（缩进一个 tab），忽略子字典
        for rawLine in text.components(separatedBy: "\n") {
            guard rawLine.hasPrefix("\t"), !rawLine.hasPrefix("\t\t") else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound])
            let value = String(line[eq.upperBound...])
            switch key {
            case "state": info.running = value == "running"
            case "pid": info.pid = Int32(value)
            case "last exit code":
                info.lastExitCode = Int32(value.split(separator: " ").first ?? "")
            case "runs": info.runs = Int(value)
            case "run interval":
                info.runInterval = Int(value.split(separator: " ").first ?? "")
            default: break
            }
        }
        return info
    }

    /// 启动按需任务（已在运行时不会重复启动）。
    public static func kickstart(_ label: String) -> ShellResult {
        Shell.run(path, ["kickstart", service(label)], timeout: 10)
    }

    public static func bootstrap(plist: String) -> ShellResult {
        Shell.run(path, ["bootstrap", domain, plist], timeout: 15)
    }

    public static func bootout(_ label: String) -> ShellResult {
        Shell.run(path, ["bootout", service(label)], timeout: 30)
    }

    public static func enable(_ label: String) -> ShellResult {
        Shell.run(path, ["enable", service(label)], timeout: 5)
    }

    public static func disable(_ label: String) -> ShellResult {
        Shell.run(path, ["disable", service(label)], timeout: 5)
    }

    /// nil 表示无法判断
    public static func isDisabled(_ label: String) -> Bool? {
        guard isAvailable else { return nil }
        let r = Shell.run(path, ["print-disabled", domain], timeout: 5)
        guard r.ok else { return nil }
        for line in r.stdout.components(separatedBy: "\n") where line.contains("\"\(label)\"") {
            return line.contains("=> disabled") || line.contains("=> true")
        }
        return false
    }

    /// 重新加载某个 plist：仅在任务空闲时调用。
    public static func reload(label: String, plist: String) -> ShellResult {
        if info(label).loaded {
            let out = bootout(label)
            if !out.ok && info(label).loaded { return out }
        }
        var last = bootstrap(plist: plist)
        // bootout 后 launchd 偶尔需要片刻才能再次 bootstrap
        var tries = 0
        while !last.ok && tries < 5 {
            usleep(400_000)
            last = bootstrap(plist: plist)
            tries += 1
        }
        return last
    }
}

/// LaunchAgent plist 的读取与改写（保留未知键）。
public struct LaunchAgentPlist {
    public var dict: [String: Any]

    public static let schedulingKeys = ["StartInterval", "StartCalendarInterval", "KeepAlive", "WatchPaths", "QueueDirectories", "StartOnMount"]

    public init(dict: [String: Any]) { self.dict = dict }

    public static func load(_ url: URL) throws -> LaunchAgentPlist {
        let data = try Data(contentsOf: url)
        guard let d = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return LaunchAgentPlist(dict: d)
    }

    public var label: String? { dict["Label"] as? String }

    public var programArguments: [String] {
        if let args = dict["ProgramArguments"] as? [String], !args.isEmpty { return args }
        if let p = dict["Program"] as? String { return [p] }
        return []
    }

    public var startInterval: Int? { (dict["StartInterval"] as? NSNumber)?.intValue }
    public var runAtLoad: Bool { (dict["RunAtLoad"] as? Bool) ?? false }
    public var environment: [String: String] { (dict["EnvironmentVariables"] as? [String: String]) ?? [:] }
    public var standardOutPath: String? { dict["StandardOutPath"] as? String }
    public var standardErrorPath: String? { dict["StandardErrorPath"] as? String }
    public var workingDirectory: String? { dict["WorkingDirectory"] as? String }
    public var hasSchedule: Bool { Self.schedulingKeys.contains { dict[$0] != nil } || runAtLoad }

    /// 生成“按需执行”的版本：去掉所有自动调度键，保留其余配置，并合并环境变量。
    public func onDemand(environment extra: [String: String], removingEnvKeys: [String] = []) -> LaunchAgentPlist {
        var d = dict
        for k in Self.schedulingKeys { d.removeValue(forKey: k) }
        d["RunAtLoad"] = false
        var env = environment
        for k in removingEnvKeys { env.removeValue(forKey: k) }
        for (k, v) in extra { env[k] = v }
        d["EnvironmentVariables"] = env
        return LaunchAgentPlist(dict: d)
    }

    public func data() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public func write(to url: URL) throws {
        try JSONStore.writeAtomically(try data(), to: url, permissions: 0o644)
    }
}
