import Foundation

/// bisync 历史 listing 文件定位与状态探测（只读，绝不删除或改名）。
///
/// rclone v1.75 中 listing 基名为 `<canonical(path1)>..<canonical(path2)>`，
/// canonical 规则：去掉首尾的 / 与 \，再把空白、\ / : ? * 替换为 _。
public enum BisyncListings {
    public static func canonical(_ remote: String) -> String {
        var s = remote
        while let f = s.first, f == "/" || f == "\\" { s.removeFirst() }
        while let l = s.last, l == "/" || l == "\\" { s.removeLast() }
        var out = ""
        for ch in s {
            if ch.isWhitespace || "\\/:?*".contains(ch) { out.append("_") } else { out.append(ch) }
        }
        return out
    }

    public static func candidateBaseNames(job: JobConfig) -> [String] {
        let a = canonical(BisyncMatcher.normalize(job.localPath))
        let b = canonical(BisyncMatcher.normalize(job.remotePath))
        return ["\(a)..\(b)", "\(b)..\(a)"]
    }

    /// 在若干候选目录中寻找该任务的 listing，返回 (工作目录, 基名)。
    public static func locate(job: JobConfig, searchDirs: [URL], maxDepth: Int = 4) -> (workdir: URL, baseName: String)? {
        let bases = candidateBaseNames(job: job).map { $0.precomposedStringWithCanonicalMapping }
        let fm = FileManager.default
        var queue: [(URL, Int)] = searchDirs.map { ($0, 0) }
        var seen = Set<String>()
        var best: (URL, String, Date)?
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard seen.insert(dir.path).inserted, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                let n = name.precomposedStringWithCanonicalMapping
                for base in bases where n == base + ".path1.lst" || n == base + ".path1.lst-old" {
                    let url = dir.appendingPathComponent(name)
                    let m = JSONStore.modificationDate(url) ?? .distantPast
                    if best == nil || m > best!.2 { best = (dir, String(name.dropLast(n.hasSuffix("-old") ? 14 : 10)), m) }
                }
                if depth < maxDepth {
                    var isDir: ObjCBool = false
                    let sub = dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue, !name.hasPrefix(".") {
                        queue.append((sub, depth + 1))
                    }
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    public struct Probe: Equatable, Sendable {
        public var path1Modified: Date?
        public var path2Modified: Date?
        public var errFilesModified: Date?
        public var lockFilePresent: Bool

        /// 两份 listing 都在 since 之后更新，且没有更新的 -err 文件
        public func updatedSuccessfully(since: Date) -> Bool {
            guard let p1 = path1Modified, let p2 = path2Modified else { return false }
            let slack: TimeInterval = 2
            guard p1 >= since.addingTimeInterval(-slack), p2 >= since.addingTimeInterval(-slack) else { return false }
            if let e = errFilesModified, e >= since.addingTimeInterval(-slack) { return false }
            return true
        }
    }

    public static func probe(workdir: String, baseName: String) -> Probe {
        let dir = URL(fileURLWithPath: workdir)
        func m(_ suffix: String) -> Date? { JSONStore.modificationDate(dir.appendingPathComponent(baseName + suffix)) }
        let errs = [m(".path1.lst-err"), m(".path2.lst-err")].compactMap { $0 }.max()
        let lock = FileManager.default.fileExists(atPath: dir.appendingPathComponent(baseName + ".lck").path)
        return Probe(path1Modified: m(".path1.lst"), path2Modified: m(".path2.lst"), errFilesModified: errs, lockFilePresent: lock)
    }
}
