//
//  JobsAndPortsModels.swift
//  boringNotch
//
//  Scheduled jobs (LaunchAgents + crontab) and listening ports, as sent by the helper,
//  plus the code that turns schedules into readable text and next-run times.
//

import Foundation

struct ScheduledJob: Identifiable, Decodable, Equatable {
    let id: String
    let source: String          // "launchd" or "cron"
    let label: String
    let command: String
    let loaded: Bool
    let keepAlive: Bool
    let runAtLoad: Bool
    let disabled: Bool
    let hasLog: Bool
    let startInterval: Int?
    let calendarIntervals: [[String: Int]]?
    let cronSchedule: String?
    let pid: Int?
    let lastExitStatus: Int?

    var isCron: Bool { source == "cron" }
    var isRunning: Bool { pid != nil }

    /// Non-zero exit, ignoring "stopped by SIGTERM/SIGKILL" which we cause ourselves.
    var hasFailed: Bool {
        guard !isRunning, let status = lastExitStatus else { return false }
        return status != 0 && status != -15 && status != -9
    }

    /// "com.myapp.scout" → "myapp.scout"
    var displayName: String {
        if isCron {
            return command.split(separator: " ").first.map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? command
        }
        for prefix in ["com.", "io.", "org.", "net.", "dev.", "app."] where label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        return label
    }

    enum Status {
        case running, failed, idle, notLoaded, disabled
    }

    var status: Status {
        if isRunning { return .running }
        // Switching a job off doesn't unload it, so "disabled" only matters once it isn't loaded.
        if !loaded { return disabled ? .disabled : .notLoaded }
        if hasFailed { return .failed }
        return .idle
    }

    // MARK: Schedule text

    var scheduleDescription: String {
        if isCron, let cron = cronSchedule {
            return CronSchedule.describe(cron)
        }
        var parts: [String] = []
        if keepAlive { parts.append("Always on") }
        if let interval = startInterval { parts.append("Every \(Self.describeInterval(interval))") }
        if let calendar = calendarIntervals, !calendar.isEmpty { parts.append(Self.describeCalendar(calendar)) }
        if parts.isEmpty { parts.append(runAtLoad ? "At login" : "Manual") }
        return parts.joined(separator: " · ")
    }

    var nextRun: Date? {
        let now = Date()
        if isCron, let cron = cronSchedule {
            return CronSchedule.nextRun(cron, after: now)
        }
        guard let calendar = calendarIntervals else { return nil }
        return calendar.compactMap { Self.nextDate(for: $0, after: now) }.min()
    }

    static func describeInterval(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "\(seconds) s"
        case 60: return "minute"
        case ..<3600: return "\(seconds / 60) min"
        case 3600: return "hour"
        case ..<86400 where seconds % 3600 == 0: return "\(seconds / 3600) h"
        case ..<86400: return "\(seconds / 60) min"
        case 86400: return "day"
        default: return "\(seconds / 86400) days"
        }
    }

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func time(_ entry: [String: Int]) -> String {
        let hour = entry["Hour"].map { String(format: "%02d", $0) } ?? "**"
        let minute = entry["Minute"].map { String(format: "%02d", $0) } ?? "**"
        return "\(hour):\(minute)"
    }

    /// Also used for crontab, which numbers weekdays the same way.
    static func describeWeekdays(_ days: [Int]) -> String {
        // launchd uses 0 and 7 for Sunday
        let sorted = Array(Set(days.map { $0 % 7 })).sorted()
        if sorted == [1, 2, 3, 4, 5] { return "Mon–Fri" }
        if sorted == [1, 2, 3, 4, 5, 6] { return "Mon–Sat" }
        if sorted == [0, 6] { return "Weekends" }
        if sorted.count == 7 { return "Daily" }
        return sorted.map { weekdayNames[$0] }.joined(separator: ", ")
    }

    static func describeCalendar(_ entries: [[String: Int]]) -> String {
        let times = entries.map(time)
        let onlyTimes = entries.allSatisfy { $0["Weekday"] == nil && $0["Day"] == nil && $0["Month"] == nil }

        if onlyTimes {
            if entries.allSatisfy({ $0["Hour"] == nil }), let minute = entries.first?["Minute"] {
                return "Hourly at :\(String(format: "%02d", minute))"
            }
            return "Daily " + shortList(Array(Set(times)).sorted())
        }

        // Same time on several weekdays, e.g. Mon–Fri 09:00
        let weekdays = entries.compactMap { $0["Weekday"] }
        if weekdays.count == entries.count, Set(times).count == 1,
           entries.allSatisfy({ $0["Day"] == nil && $0["Month"] == nil }) {
            return "\(describeWeekdays(weekdays)) \(times[0])"
        }

        return shortList(entries.map { entry in
            var text = ""
            if let weekday = entry["Weekday"] { text += weekdayNames[weekday % 7] + " " }
            if let day = entry["Day"] { text += "day \(day) " }
            return text + time(entry)
        })
    }

    static func shortList(_ items: [String]) -> String {
        items.count <= 3 ? items.joined(separator: ", ") : items.prefix(3).joined(separator: ", ") + " +\(items.count - 3)"
    }

    private static func nextDate(for entry: [String: Int], after date: Date) -> Date? {
        guard !entry.isEmpty else { return nil }
        var components = DateComponents()
        components.minute = entry["Minute"]
        components.hour = entry["Hour"]
        components.day = entry["Day"]
        components.month = entry["Month"]
        // launchd: 0/7 = Sunday … 6 = Saturday. Calendar: 1 = Sunday … 7 = Saturday.
        components.weekday = entry["Weekday"].map { $0 % 7 + 1 }
        if components.minute == nil && components.hour == nil && components.day == nil
            && components.month == nil && components.weekday == nil { return nil }
        if components.minute == nil, components.hour != nil {
            // "every minute of that hour" — first one is :00
            components.minute = 0
        }
        components.second = 0
        return Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }
}

struct ListeningPort: Identifiable, Decodable, Equatable {
    let id: String
    let port: Int
    let pid: Int32
    let process: String
    let address: String
    let commandLine: String
    let workingDirectory: String?

    var isLocalOnly: Bool {
        ["127.0.0.1", "::1", "localhost"].contains(address)
    }

    /// Script runners show the project they belong to, e.g. "node · myapp".
    var displayName: String {
        let runners = ["node", "python", "python3", "Python", "ruby", "bun", "deno", "java", "php", "dotnet", "go"]
        guard runners.contains(where: { process.lowercased().hasPrefix($0.lowercased()) }),
              let project = projectName else { return process }
        return "\(process) · \(project)"
    }

    /// The script's folder ("node /x/myapp/server.mjs" → "myapp"),
    /// or the folder the process runs in ("python server.py" → its working folder).
    private var projectName: String? {
        let args = commandLine.split(separator: " ").dropFirst()
        if let absolute = args.first(where: { $0.hasPrefix("/") }),
           let name = Self.projectFolderName(forScript: String(absolute)) {
            return name
        }
        return workingDirectory.flatMap(Self.usefulFolderName)
    }

    /// Folders that hold a project's installed tools rather than the project itself.
    private static let toolFolders: Set<String> = ["node_modules", ".venv", "venv", "vendor"]

    /// "/x/myapp/server.mjs" → "myapp".
    /// Tools installed in a project belong to the folder above them:
    /// "/x/dashboard/node_modules/.bin/vite" → "dashboard".
    private static func projectFolderName(forScript path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let parts = url.pathComponents
        if let index = parts.firstIndex(where: toolFolders.contains) {
            guard index > 1 else { return nil }
            return usefulFolderName(NSString.path(withComponents: Array(parts[..<index])))
        }
        let folder = url.pathExtension.isEmpty ? url : url.deletingLastPathComponent()
        return usefulFolderName(folder.path)
    }

    /// The user's real home folder (the app's own home points into its sandbox container).
    private static let realHome: String = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }()

    /// Folder names that don't say which project something is.
    private static let genericFolders: Set<String> = ["bin", "sbin", "MacOS", "lib", "libexec", "share", "Cellar", "homebrew", "usr", "opt", "tmp", ""]

    private static func usefulFolderName(_ path: String) -> String? {
        // Only real paths: lsof can report an error message instead of a folder.
        guard path.hasPrefix("/"), path != "/", path != realHome else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return genericFolders.contains(name) ? nil : name
    }
}

// MARK: - Cron

enum CronSchedule {
    private static let aliases: [String: String] = [
        "@hourly": "0 * * * *",
        "@daily": "0 0 * * *",
        "@midnight": "0 0 * * *",
        "@weekly": "0 0 * * 0",
        "@monthly": "0 0 1 * *",
        "@yearly": "0 0 1 1 *",
        "@annually": "0 0 1 1 *",
    ]

    private static let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    private static let dayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    /// The 5 fields of a schedule, with aliases expanded and month/day names
    /// ("JAN", "MON-FRI") turned into numbers. nil if it isn't a 5-field schedule.
    private static func scheduleFields(_ schedule: String) -> [String]? {
        var f = (aliases[schedule.lowercased()] ?? schedule).split(separator: " ").map(String.init)
        guard f.count == 5 else { return nil }
        f[3] = replacingNames(in: f[3], names: monthNames, firstNumber: 1)
        f[4] = replacingNames(in: f[4], names: dayNames, firstNumber: 0)
        return f
    }

    private static func replacingNames(in field: String, names: [String], firstNumber: Int) -> String {
        var result = field.uppercased()
        for (index, name) in names.enumerated() {
            result = result.replacingOccurrences(of: name, with: String(index + firstNumber))
        }
        return result
    }

    /// "Daily 08:00, 16:00", "Mon–Fri 09:00", "Every 15 min, 09:00–17:59, Mon–Fri", …
    /// Falls back to the schedule itself when it can't be said more simply.
    static func describe(_ schedule: String) -> String {
        if schedule.lowercased() == "@reboot" { return "At startup" }
        guard let f = scheduleFields(schedule),
              let time = describeTime(minute: f[0], hour: f[1]),
              let text = describeDays(time, dom: f[2], month: f[3], dow: f[4]) else { return schedule }
        return text
    }

    /// Either fixed clock times ("08:00, 16:00") or something that repeats during the day ("Every 15 min").
    private enum TimeText {
        case times(String)
        case repeating(String)
    }

    private static func describeTime(minute: String, hour: String) -> TimeText? {
        if minute == "*" && hour == "*" { return .repeating("Every minute") }
        if let step = everyStep(minute) {
            if hour == "*" { return .repeating("Every \(step) min") }
            if let (from, to) = hourRange(hour) {
                return .repeating(String(format: "Every %@ min, %02d:00–%02d:59", step, from, to))
            }
            return nil
        }
        guard let minutes = fixedValues(minute, 0...59) else { return nil }
        if hour == "*" {
            return .repeating("Hourly at " + minutes.map { String(format: ":%02d", $0) }.joined(separator: ", "))
        }
        if let step = everyStep(hour), minutes.count == 1 {
            return .repeating(String(format: "Every %@ h at :%02d", step, minutes[0]))
        }
        if let (from, to) = hourRange(hour), minutes.count == 1 {
            return .repeating(String(format: "Hourly %02d:%02d–%02d:%02d", from, minutes[0], to, minutes[0]))
        }
        guard let hours = fixedValues(hour, 0...23) else { return nil }
        let times = hours.flatMap { h in minutes.map { m in String(format: "%02d:%02d", h, m) } }
        return .times(ScheduledJob.shortList(times))
    }

    private static func describeDays(_ time: TimeText, dom: String, month: String, dow: String) -> String? {
        switch (dom, month, dow) {
        case ("*", "*", "*"):
            switch time {
            case .times(let t): return "Daily \(t)"
            case .repeating(let r): return r
            }
        case ("*", "*", _):
            guard let days = values(dow, 0...7) else { return nil }
            let d = ScheduledJob.describeWeekdays(Array(days))
            switch time {
            case .times(let t): return "\(d) \(t)"
            case .repeating(let r): return d == "Daily" ? r : "\(r), \(d)"
            }
        case (_, "*", "*"):
            guard let days = fixedValues(dom, 1...31), days.count <= 4 else { return nil }
            let list = days.map(String.init).joined(separator: ", ")
            let label = days.count == 1 ? "day \(list)" : "days \(list)"
            switch time {
            case .times(let t): return "Monthly on \(label) at \(t)"
            case .repeating(let r): return "\(r), on \(label)"
            }
        case (_, _, "*"):
            guard let day = Int(dom), let m = Int(month), (1...12).contains(m), case .times(let t) = time else { return nil }
            return "Yearly on \(monthNames[m - 1].capitalized) \(day) at \(t)"
        default:
            return nil
        }
    }

    /// "*/15" → "15"
    private static func everyStep(_ field: String) -> String? {
        guard field.hasPrefix("*/"), Int(field.dropFirst(2)) != nil else { return nil }
        return String(field.dropFirst(2))
    }

    /// "9-17" → (9, 17)
    private static func hourRange(_ field: String) -> (Int, Int)? {
        let bounds = field.split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2, !field.contains(","), !field.contains("/"), bounds[0] < bounds[1] else { return nil }
        return (bounds[0], bounds[1])
    }

    /// Exact values like "0", "8,16" or "1-5" (no "*" or steps), sorted.
    private static func fixedValues(_ field: String, _ range: ClosedRange<Int>) -> [Int]? {
        guard !field.contains("*"), !field.contains("/"), let set = values(field, range) else { return nil }
        return set.sorted()
    }

    /// Finds the next matching minute by stepping forward (up to ~1 year).
    static func nextRun(_ schedule: String, after date: Date) -> Date? {
        guard schedule.lowercased() != "@reboot", let fields = scheduleFields(schedule),
              let minutes = values(fields[0], 0...59),
              let hours = values(fields[1], 0...23),
              let days = values(fields[2], 1...31),
              let months = values(fields[3], 1...12),
              let weekdays = values(fields[4], 0...7).map({ Set($0.map { $0 % 7 }) }) else { return nil }

        let calendar = Calendar.current
        let dayIsAny = fields[2] == "*"
        let weekdayIsAny = fields[4] == "*"
        // Start at the beginning of the next whole minute.
        guard var current = calendar.dateInterval(of: .minute, for: date)?.start.addingTimeInterval(60) else { return nil }

        for _ in 0..<(366 * 24 * 60) {
            let c = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: current)
            let dayMatches = days.contains(c.day!)
            let weekdayMatches = weekdays.contains(c.weekday! - 1)
            // Cron rule: if both day and weekday are set, either may match.
            let dateMatches = (dayIsAny || weekdayIsAny) ? (dayMatches && weekdayMatches) : (dayMatches || weekdayMatches)
            if months.contains(c.month!) && dateMatches && hours.contains(c.hour!) && minutes.contains(c.minute!) {
                return current
            }
            // Skip whole hours/days when they can't match, to keep this fast.
            if !months.contains(c.month!) || !dateMatches {
                current = calendar.startOfDay(for: current).addingTimeInterval(86400)
            } else if !hours.contains(c.hour!) {
                current = calendar.date(bySettingHour: c.hour!, minute: 0, second: 0, of: current)!.addingTimeInterval(3600)
            } else {
                current = current.addingTimeInterval(60)
            }
        }
        return nil
    }

    /// Parses "*", "5", "1-5", "1,3,5", "*/15", "0-30/10".
    private static func values(_ field: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var result = Set<Int>()
        for part in field.split(separator: ",") {
            let pieces = part.split(separator: "/")
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            let base = pieces[0]
            var lower = range.lowerBound
            var upper = range.upperBound
            if base != "*" {
                let bounds = base.split(separator: "-").compactMap { Int($0) }
                guard let first = bounds.first else { return nil }
                lower = first
                upper = bounds.count == 2 ? bounds[1] : (pieces.count == 2 ? range.upperBound : first)
            }
            guard lower <= upper else { return nil }
            result.formUnion(stride(from: lower, through: upper, by: step))
        }
        return result
    }
}
