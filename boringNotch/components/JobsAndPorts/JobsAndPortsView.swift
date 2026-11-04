//
//  JobsAndPortsView.swift
//  boringNotch
//
//  The Jobs & Ports tab: scheduled jobs on the left, listening ports on the right.
//

import AppKit
import Defaults
import SwiftUI

struct JobsAndPortsView: View {
    @ObservedObject var manager = JobsAndPortsManager.shared
    // Redraw when items are hidden or shown again
    @Default(.hiddenJobLabels) private var hiddenJobLabels
    @Default(.hiddenPortProcesses) private var hiddenPortProcesses

    var body: some View {
        HStack(spacing: 10) {
            panel(title: "Scheduled", icon: "clock.arrow.circlepath", count: manager.visibleJobs.count) {
                if manager.visibleJobs.isEmpty {
                    placeholder(manager.hasLoaded ? "No scheduled jobs" : "Loading…")
                } else {
                    ForEach(manager.visibleJobs) { JobRow(job: $0) }
                }
            }
            panel(title: "Ports", icon: "network", count: manager.visiblePorts.count) {
                if manager.visiblePorts.isEmpty {
                    placeholder(manager.hasLoaded ? "Nothing listening" : "Loading…")
                } else {
                    ForEach(manager.visiblePorts) { PortRow(port: $0) }
                }
            }
        }
        .overlay {
            if manager.helperUnavailable {
                Text("Couldn't reach the Boring Notch helper")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Capsule().fill(Color.red.opacity(0.7)))
            }
        }
        .onAppear { manager.startAutoRefresh() }
        .onDisappear { manager.stopAutoRefresh() }
    }

    private func panel<Content: View>(title: String, icon: String, count: Int,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    content()
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
    }
}

// MARK: - Job row

private struct JobRow: View {
    let job: ScheduledJob
    @ObservedObject var manager = JobsAndPortsManager.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(job.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(job.status == .failed ? .red.opacity(0.9) : .gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if manager.busyIDs.contains(job.id) {
                ProgressView().controlSize(.mini)
            } else if isHovering && !job.isCron {
                actions
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isHovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { menu }
        .help(job.command)
    }

    private var subtitle: String {
        var parts = [job.scheduleDescription]
        switch job.status {
        case .running:
            if let pid = job.pid { parts.append("running · pid \(pid)") }
        case .failed:
            parts.append("failed (exit \(job.lastExitStatus ?? 0))")
        case .notLoaded:
            parts.append("not loaded")
        case .disabled:
            parts.append("disabled")
        case .idle:
            break
        }
        if job.status != .running, let next = job.nextRun {
            parts.append("next \(Self.format(next))")
        }
        return parts.joined(separator: " · ")
    }

    private var statusDot: some View {
        let color: Color = switch job.status {
        case .running: .green
        case .failed: .red
        case .idle: .gray
        case .notLoaded, .disabled: .orange
        }
        return Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: job.status == .running ? .green.opacity(0.7) : .clear, radius: 3)
    }

    private var actions: some View {
        HStack(spacing: 3) {
            RowButton(icon: job.isRunning ? "arrow.clockwise" : "play.fill",
                      help: job.isRunning ? "Restart" : "Run now") { manager.run(job) }
            if job.isRunning {
                RowButton(icon: "stop.fill", help: "Stop") { manager.stop(job) }
            }
            if job.hasLog {
                RowButton(icon: "doc.text", help: "Open log") { manager.openLog(job) }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !job.isCron {
            Button(job.isRunning ? "Restart" : "Run Now") { manager.run(job) }
            if job.isRunning { Button("Stop") { manager.stop(job) } }
            if job.hasLog { Button("Open Log") { manager.openLog(job) } }
            Divider()
        }
        Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.command, forType: .string)
        }
        if !job.isCron {
            Button("Hide \(job.displayName)") { manager.hide(job) }
        }
    }

    /// "in 25 min", "16:00", "tomorrow 08:00", "Mon 09:00"
    static func format(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds < 3600 { return "in \(max(1, Int(seconds / 60))) min" }
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
    }
}

// MARK: - Port row

private struct PortRow: View {
    let port: ListeningPort
    @ObservedObject var manager = JobsAndPortsManager.shared
    @State private var isHovering = false
    @State private var confirmingStop = false

    var body: some View {
        HStack(spacing: 7) {
            icon
            Text(":\(String(port.port))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(port.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(port.isLocalOnly ? "localhost · pid \(port.pid)" : "all networks · pid \(port.pid)")
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if manager.busyIDs.contains(port.id) {
                ProgressView().controlSize(.mini)
            } else if confirmingStop {
                Button {
                    confirmingStop = false
                    manager.stopProcess(port)
                } label: {
                    Text("Stop?")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.red))
                }
                .buttonStyle(.plain)
            } else if isHovering {
                HStack(spacing: 3) {
                    RowButton(icon: "safari", help: "Open in browser") { manager.openInBrowser(port) }
                    RowButton(icon: "xmark", help: "Stop this process") { askToStop() }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isHovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in Browser") { manager.openInBrowser(port) }
            Button("Copy URL") { manager.copyURL(port) }
            Divider()
            Button("Stop \(port.process)") { askToStop() }
            Button("Hide \(port.process)") { manager.hide(port) }
        }
        .help(port.commandLine)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = NSRunningApplication(processIdentifier: port.pid)?.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
                .frame(width: 16, height: 16)
        }
    }

    /// Stopping needs a second click within a few seconds.
    private func askToStop() {
        confirmingStop = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            confirmingStop = false
        }
    }
}

// MARK: - Small round button

private struct RowButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
