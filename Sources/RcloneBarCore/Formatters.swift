import Foundation

/// 中文显示格式。容量与速度使用 1024 进制（与 rclone 一致）。
public enum Formatters {
    public static func bytes(_ v: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, v))
        var i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }
        if i == 0 { return "\(Int(value)) B" }
        return String(format: value >= 100 ? "%.0f" : (value >= 10 ? "%.1f" : "%.2f"), value) + " " + units[i]
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    /// 菜单栏用的紧凑速度，如 "3.2M/s"
    public static func compactSpeed(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var value = max(0, bytesPerSecond)
        var i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }
        return String(format: value >= 10 || i == 0 ? "%.0f" : "%.1f", value) + units[i] + "/s"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) 秒" }
        if s < 3600 { return s % 60 == 0 || s >= 600 ? "\(s / 60) 分钟" : "\(s / 60) 分 \(s % 60) 秒" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// “今天 14:05”“昨天 09:12”“10月3日 08:00”
    public static func dayTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "今天 " + timeFormatter.string(from: date) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "昨天 " + timeFormatter.string(from: date) }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: t) { return "明天 " + timeFormatter.string(from: date) }
        return dateTimeFormatter.string(from: date)
    }

    public static func full(_ date: Date) -> String { fullFormatter.string(from: date) }

    /// “3 分钟前”“刚刚”
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let d = now.timeIntervalSince(date)
        if d < 0 {
            let f = -d
            if f < 60 { return "即将" }
            return Formatters.duration(f) + "后"
        }
        if d < 30 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        return dayTime(date, now: now)
    }

    public static func count(_ n: Int) -> String {
        n >= 10000 ? String(format: "%.1f 万", Double(n) / 10000) : "\(n)"
    }
}
