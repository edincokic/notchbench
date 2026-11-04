//
//  JobsAndPortsManager.swift
//  boringNotch
//
//  Keeps the Jobs & Ports tab up to date. Refreshes every few seconds,
//  but only while the tab is on screen.
//

import AppKit
import Defaults
import Foundation

@MainActor
final class JobsAndPortsManager: ObservableObject {
    static let shared = JobsAndPortsManager()

    @Published private(set) var jobs: [ScheduledJob] = []
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var helperUnavailable = false
    /// Ids of jobs/ports with an action in progress (shows a spinner).
    @Published private(set) var busyIDs: Set<String> = []

    private let refreshInterval: Duration = .seconds(5)
    private var refreshTask: Task<Void, Never>?
    private var viewers = 0

    private init() {}

    // MARK: - What the tab shows

    var visibleJobs: [ScheduledJob] {
        let hidden = Set(Defaults[.hiddenJobLabels])
        return jobs
            .filter { !hidden.contains($0.label) }
            .sorted(by: Self.jobOrder)
    }

    var visiblePorts: [ListeningPort] {
        let hidden = Set(Defaults[.hiddenPortProcesses])
        return ports.filter { !hidden.contains($0.process) }
    }

    /// Running first, then failed, then whatever runs soonest.
    private static func jobOrder(_ a: ScheduledJob, _ b: ScheduledJob) -> Bool {
        func rank(_ job: ScheduledJob) -> Int {
            switch job.status {
            case .running: return 0
            case .failed: return 1
            case .idle: return 2
            case .notLoaded: return 3
            case .disabled: return 4
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        switch (a.nextRun, b.nextRun) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    // MARK: - Refreshing

    /// Call when the tab appears. Pair with `stopAutoRefresh()`.
    func startAutoRefresh() {
        viewers += 1
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.refreshInterval ?? .seconds(5))
            }
        }
    }

    func stopAutoRefresh() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        async let jobsData = XPCHelperClient.shared.listScheduledJobs()
        async let portsData = XPCHelperClient.shared.listListeningPorts()
        let (jobsResult, portsResult) = await (jobsData, portsData)

        helperUnavailable = jobsResult == nil && portsResult == nil
        let decoder = JSONDecoder()
        if let data = jobsResult, let decoded = try? decoder.decode([ScheduledJob].self, from: data), decoded != jobs {
            jobs = decoded
        }
        if let data = portsResult, let decoded = try? decoder.decode([ListeningPort].self, from: data), decoded != ports {
            ports = decoded
        }
        hasLoaded = true
    }

    // MARK: - Job actions

    func run(_ job: ScheduledJob) {
        perform(id: job.id) { await XPCHelperClient.shared.runJob(job.label) }
    }

    func stop(_ job: ScheduledJob) {
        perform(id: job.id) { await XPCHelperClient.shared.stopJob(job.label) }
    }

    func openLog(_ job: ScheduledJob) {
        Task { _ = await XPCHelperClient.shared.openJobLog(job.label) }
    }

    func hide(_ job: ScheduledJob) {
        Defaults[.hiddenJobLabels].append(job.label)
        objectWillChange.send()
    }

    // MARK: - Port actions

    func openInBrowser(_ port: ListeningPort) {
        guard let url = URL(string: "http://localhost:\(port.port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyURL(_ port: ListeningPort) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://localhost:\(port.port)", forType: .string)
    }

    func stopProcess(_ port: ListeningPort) {
        perform(id: port.id) {
            await XPCHelperClient.shared.stopProcessListening(onPort: port.port, pid: port.pid)
        }
    }

    func hide(_ port: ListeningPort) {
        Defaults[.hiddenPortProcesses].append(port.process)
        objectWillChange.send()
    }

    // MARK: - Helpers

    private func perform(id: String, _ action: @escaping () async -> Bool) {
        busyIDs.insert(id)
        Task {
            _ = await action()
            // Give launchd / the process a moment, then show the new state.
            try? await Task.sleep(for: .milliseconds(700))
            await refresh()
            busyIDs.remove(id)
        }
    }
}
