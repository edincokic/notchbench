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
        if disabled { return .disabled }
        if isRunning { return .running }
        if !loaded { return .notLoaded }
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

    private static func describeWeekdays(_ days: [Int]) -> String {
        // launchd uses 0 and 7 for Sunday
        let sorted = Array(Set(days.map { $0 % 7 })).sorted()
        if sorted == [1, 2, 3, 4, 5] { return "Mon–Fri" }
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

    private static func shortList(_ items: [String]) -> String {
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

    /// Folder of the first script/path argument in the command line.
    private var projectName: String? {
        let args = commandLine.split(separator: " ").dropFirst()
        guard let pathArg = args.first(where: { $0.hasPrefix("/") || $0.hasPrefix("./") || $0.contains(".") && $0.contains("/") }) else {
            return nil
        }
        let url = URL(fileURLWithPath: String(pathArg))
        let folder = url.pathExtension.isEmpty ? url : url.deletingLastPathComponent()
        let name = folder.lastPathComponent
        return name.isEmpty || name == "/" || name == "bin" ? nil : name
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

    static func describe(_ schedule: String) -> String {
        if schedule == "@reboot" { return "At startup" }
        let expression = aliases[schedule] ?? schedule
        let f = expression.split(separator: " ").map(String.init)
        guard f.count == 5 else { return schedule }
        let (minute, hour, dom, month, dow) = (f[0], f[1], f[2], f[3], f[4])
        let restIsAny = dom == "*" && month == "*" && dow == "*"

        if minute == "*" && hour == "*" && restIsAny { return "Every minute" }
        if minute.hasPrefix("*/"), hour == "*", restIsAny { return "Every \(minute.dropFirst(2)) min" }
        if let m = Int(minute), hour == "*", restIsAny { return "Hourly at :\(String(format: "%02d", m))" }
        if let m = Int(minute), hour.hasPrefix("*/"), restIsAny {
            return "Every \(hour.dropFirst(2)) h at :\(String(format: "%02d", m))"
        }
        if let m = Int(minute), let h = Int(hour) {
            let time = String(format: "%02d:%02d", h, m)
            if restIsAny { return "Daily \(time)" }
            if dom == "*", month == "*", dow == "1-5" { return "Mon–Fri \(time)" }
        }
        return expression
    }

    /// Finds the next matching minute by stepping forward (up to ~1 year).
    static func nextRun(_ schedule: String, after date: Date) -> Date? {
        guard schedule != "@reboot" else { return nil }
        let fields = (aliases[schedule] ?? schedule).split(separator: " ").map(String.init)
        guard fields.count == 5,
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
