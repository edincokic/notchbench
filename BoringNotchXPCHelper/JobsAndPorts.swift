//
//  JobsAndPorts.swift
//  BoringNotchXPCHelper
//
//  Reads scheduled jobs (LaunchAgents + crontab) and listening TCP ports for the
//  "Jobs & Ports" tab. Runs in the helper because the main app is sandboxed.
//  Results are sent back as JSON so the app can decode them with its own types.
//

import Foundation

extension BoringNotchXPCHelper {

    // MARK: - Scheduled jobs

    @objc func listScheduledJobs(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let states = Self.launchdStates()
            let overrides = Self.launchdDisabledOverrides()
            var jobs: [[String: Any]] = []

            for (label, plist) in Self.userLaunchAgents() {
                var job: [String: Any] = [
                    "id": "launchd:\(label)",
                    "source": "launchd",
                    "label": label,
                    "command": Self.commandLine(from: plist),
                    "loaded": states[label] != nil,
                    "keepAlive": Self.isKeepAlive(plist["KeepAlive"]),
                    "runAtLoad": plist["RunAtLoad"] as? Bool ?? false,
                    // `launchctl disable` / `enable` win over the plist's own setting.
                    "disabled": overrides[label] ?? (plist["Disabled"] as? Bool ?? false),
                    "hasLog": Self.logPath(from: plist) != nil,
                ]
                if let interval = plist["StartInterval"] as? Int {
                    job["startInterval"] = interval
                }
                if let calendar = Self.calendarIntervals(plist["StartCalendarInterval"]) {
                    job["calendarIntervals"] = calendar
                }
                if let state = states[label] {
                    if let pid = state.pid { job["pid"] = pid }
                    job["lastExitStatus"] = state.status
                }
                jobs.append(job)
            }

            for (index, entry) in Self.cronEntries().enumerated() {
                jobs.append([
                    "id": "cron:\(index)",
                    "source": "cron",
                    "label": entry.command,
                    "command": entry.command,
                    "cronSchedule": entry.schedule,
                    "loaded": true,
                    "keepAlive": false,
                    "runAtLoad": false,
                    "disabled": false,
                    "hasLog": false,
                ])
            }

            reply(try? JSONSerialization.data(withJSONObject: jobs))
        }
    }

    @objc func runJob(_ label: String, with reply: @escaping (Bool) -> Void) {
        guard Self.isUserAgent(label) else { reply(false); return }
        // -k restarts the job if it is already running.
        let result = Self.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
        reply(result.status == 0)
    }

    @objc func stopJob(_ label: String, with reply: @escaping (Bool) -> Void) {
        guard let plist = Self.userLaunchAgents()[label] else { reply(false); return }
        let service = "gui/\(getuid())/\(label)"
        // launchd restarts "keep alive" jobs as soon as they exit, so those are unloaded instead.
        // They stay stopped until the user loads them again or logs in again.
        let result = Self.isKeepAlive(plist["KeepAlive"])
            ? Self.run("/bin/launchctl", ["bootout", service])
            : Self.run("/bin/launchctl", ["kill", "SIGTERM", service])
        reply(result.status == 0)
    }

    /// Loads an agent from ~/Library/LaunchAgents, which turns its schedule on.
    /// If it was switched off (`launchctl disable`), it is switched back on first,
    /// because launchd refuses to load a disabled job.
    @objc func loadJob(_ label: String, with reply: @escaping (Bool) -> Void) {
        guard let file = Self.userLaunchAgentFiles()[label] else { reply(false); return }
        let domain = "gui/\(getuid())"
        if Self.isLoaded(label) { reply(true); return }
        if Self.launchdDisabledOverrides()[label] == true || Self.userLaunchAgents()[label]?["Disabled"] as? Bool == true {
            _ = Self.run("/bin/launchctl", ["enable", "\(domain)/\(label)"])
        }
        let result = Self.run("/bin/launchctl", ["bootstrap", domain, file.path])
        reply(result.status == 0 || Self.isLoaded(label))
    }

    private static func isLoaded(_ label: String) -> Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    /// Label → true when switched off with `launchctl disable`, false when switched on with `launchctl enable`.
    /// These overrides win over the plist's own "Disabled" key.
    private static func launchdDisabledOverrides() -> [String: Bool] {
        let output = run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]).output
        var result: [String: Bool] = [:]
        // Lines look like:  "com.example.job" => disabled   (older macOS: => true / => false)
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            result[label] = value == "disabled" || value == "true"
        }
        return result
    }

    @objc func openJobLog(_ label: String, with reply: @escaping (Bool) -> Void) {
        guard let plist = Self.userLaunchAgents()[label],
              let path = Self.logPath(from: plist),
              FileManager.default.fileExists(atPath: path) else {
            reply(false)
            return
        }
        let result = Self.run("/usr/bin/open", ["-a", "Console", path])
        reply(result.status == 0)
    }

    // MARK: - Listening ports

    @objc func listListeningPorts(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ports = Self.listeningPorts()
            let pids = Set(ports.map(\.pid))
            let commandLines = Self.commandLines(for: pids)
            let folders = Self.workingDirectories(for: pids)
            let result: [[String: Any]] = ports.map { port in
                [
                    "id": "\(port.pid):\(port.port)",
                    "port": port.port,
                    "pid": port.pid,
                    "process": port.process,
                    "address": port.address,
                    "commandLine": commandLines[port.pid] ?? port.process,
                    "workingDirectory": folders[port.pid] ?? "",
                ]
            }
            reply(try? JSONSerialization.data(withJSONObject: result))
        }
    }

    @objc func stopProcessListening(onPort port: Int, pid: Int32, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Only stop a process that really is listening on that port right now.
            guard Self.listeningPorts().contains(where: { $0.pid == pid && $0.port == port }) else {
                reply(false)
                return
            }
            reply(kill(pid, SIGTERM) == 0)
        }
    }

    // MARK: - LaunchAgents

    private static var launchAgentsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    /// Label → plist contents for every agent in ~/Library/LaunchAgents.
    private static func userLaunchAgents() -> [String: [String: Any]] {
        readLaunchAgents().mapValues(\.plist)
    }

    /// Label → plist file for every agent in ~/Library/LaunchAgents.
    private static func userLaunchAgentFiles() -> [String: URL] {
        readLaunchAgents().mapValues(\.file)
    }

    private static func readLaunchAgents() -> [String: (file: URL, plist: [String: Any])] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: launchAgentsFolder, includingPropertiesForKeys: nil)) ?? []
        var result: [String: (file: URL, plist: [String: Any])] = [:]
        for file in files where file.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            result[label] = (file, plist)
        }
        return result
    }

    private static func isUserAgent(_ label: String) -> Bool {
        userLaunchAgents()[label] != nil
    }

    /// Label → (pid, last exit status) from `launchctl list`.
    private static func launchdStates() -> [String: (pid: Int?, status: Int)] {
        let output = run("/bin/launchctl", ["list"]).output
        var result: [String: (pid: Int?, status: Int)] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let label = String(parts[2])
            result[label] = (Int(parts[0]), Int(parts[1]) ?? 0)
        }
        return result
    }

    private static func commandLine(from plist: [String: Any]) -> String {
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            return args.joined(separator: " ")
        }
        return plist["Program"] as? String ?? ""
    }

    private static func logPath(from plist: [String: Any]) -> String? {
        (plist["StandardOutPath"] as? String) ?? (plist["StandardErrorPath"] as? String)
    }

    private static func isKeepAlive(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        // A dictionary means "keep alive under some conditions".
        return value is [String: Any]
    }

    private static func calendarIntervals(_ value: Any?) -> [[String: Int]]? {
        if let single = value as? [String: Int] { return [single] }
        if let many = value as? [[String: Int]] { return many }
        return nil
    }

    // MARK: - Cron

    private static func cronEntries() -> [(schedule: String, command: String)] {
        let result = run("/usr/bin/crontab", ["-l"])
        guard result.status == 0 else { return [] }
        var entries: [(String, String)] = []
        for rawLine in result.output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if line.hasPrefix("@"), fields.count >= 2 {
                entries.append((String(fields[0]), fields.dropFirst().joined(separator: " ")))
            } else if fields.count >= 6, !fields[0].contains("=") {
                entries.append((fields.prefix(5).joined(separator: " "), fields.dropFirst(5).joined(separator: " ")))
            }
        }
        return entries
    }

    // MARK: - Ports

    private struct ListeningPort {
        let pid: Int32
        let process: String
        let port: Int
        let address: String
    }

    private static func listeningPorts() -> [ListeningPort] {
        // -F gives one field per line: p<pid>, c<command>, n<address:port>
        let output = run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).output
        var pid: Int32 = 0
        var process = ""
        var seen = Set<String>()
        var result: [ListeningPort] = []

        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value) ?? 0
            case "c":
                process = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                var address = String(value[..<colon])
                if address.hasPrefix("[") { address = String(address.dropFirst().dropLast()) }
                // The same port is usually listed twice (IPv4 and IPv6).
                let key = "\(pid):\(port)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(ListeningPort(pid: pid, process: process, port: port, address: address))
            default:
                continue
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// pid → full command line, e.g. "node ~/Projects/myapp/server.mjs".
    private static func commandLines(for pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = run("/bin/ps", ["-o", "pid=,args=", "-p", list]).output
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<space]) else { continue }
            result[pid] = trimmed[space...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// pid → folder the process is running in (tells which project a server belongs to).
    private static func workingDirectories(for pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = run("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-Fpn"]).output
        var result: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst()) ?? 0
            } else if line.hasPrefix("n") {
                // When macOS won't reveal the folder, lsof prints an error here instead of a path.
                let path = String(line.dropFirst())
                if path.hasPrefix("/") { result[pid] = path }
            }
        }
        return result
    }

    // MARK: - Running commands

    /// Runs a command and returns its exit status and output. Also used by SystemStats.swift.
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
