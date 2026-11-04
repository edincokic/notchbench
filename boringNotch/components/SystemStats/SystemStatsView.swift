//
//  SystemStatsView.swift
//  boringNotch
//
//  The System tab: CPU and memory with a 60-second graph, plus the busiest apps.
//

import AppKit
import SwiftUI

struct SystemStatsView: View {
    @ObservedObject var stats = SystemStatsManager.shared
    @State private var sortByMemory = false

    var body: some View {
        HStack(spacing: 10) {
            StatCard(
                title: "CPU",
                icon: "cpu",
                value: percent(stats.cpuUsage),
                detail: "User \(percent(stats.cpuUser)) · System \(percent(stats.cpuSystem))",
                footnote: "\(stats.coreCount) cores",
                fraction: stats.cpuUsage,
                history: stats.cpuHistory
            )
            StatCard(
                title: "Memory",
                icon: "memorychip",
                value: "\(gigabytes(stats.memory.used)) / \(gigabytes(stats.memory.total, decimals: 0)) GB",
                detail: "Apps \(gigabytes(stats.memory.app)) · Wired \(gigabytes(stats.memory.wired)) · Compressed \(gigabytes(stats.memory.compressed))",
                footnote: stats.memory.swapUsed > 0 ? "Swap \(gigabytes(stats.memory.swapUsed)) GB" : "No swap used",
                fraction: stats.memory.fraction,
                history: stats.memoryHistory
            )
            topList
        }
        .onAppear { stats.startSampling() }
        .onDisappear { stats.stopSampling() }
    }

    // MARK: - Busiest apps

    private var sortedProcesses: [TopProcess] {
        let list = sortByMemory
            ? stats.topProcesses.sorted { $0.memoryBytes > $1.memoryBytes }
            : stats.topProcesses.sorted { $0.cpu > $1.cpu }
        return Array(list.prefix(6))
    }

    private var topList: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Top")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                sortButton("CPU", selected: !sortByMemory) { sortByMemory = false }
                sortButton("Memory", selected: sortByMemory) { sortByMemory = true }
            }
            .padding(.bottom, 2)

            if sortedProcesses.isEmpty {
                Text("Loading…")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                Spacer()
            } else {
                ForEach(sortedProcesses) { process in
                    HStack(spacing: 5) {
                        processIcon(process)
                        Text(process.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(sortByMemory ? memoryText(process.memoryBytes) : String(format: "%.0f%%", process.cpu))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.gray)
                    }
                    .help("pid \(process.pid)")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
    }

    private func sortButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(selected ? .white : .gray)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.15 : 0)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func processIcon(_ process: TopProcess) -> some View {
        if let icon = NSRunningApplication(processIdentifier: process.pid)?.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 13, height: 13)
        } else {
            Image(systemName: "gearshape")
                .font(.system(size: 8))
                .foregroundStyle(.gray)
                .frame(width: 13, height: 13)
        }
    }

    // MARK: - Formatting

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func gigabytes(_ bytes: UInt64, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", Double(bytes) / 1_073_741_824)
    }

    private func memoryText(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

// MARK: - CPU / memory card

private struct StatCard: View {
    let title: String
    let icon: String
    let value: String
    let detail: String
    let footnote: String
    let fraction: Double
    let history: [Double]

    /// Green when calm, orange when busy, red when nearly full.
    private var color: Color {
        switch fraction {
        case ..<0.6: .green
        case ..<0.85: .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: value)
            }
            .foregroundStyle(.white)

            HistoryGraph(values: history, color: color)
                .frame(maxHeight: .infinity)

            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(footnote)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
    }
}

/// A filled line graph of the last 60 seconds (values 0...1).
private struct HistoryGraph: View {
    let values: [Double]
    let color: Color
    private let slots = 60

    var body: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(slots - 1)
            let start = CGFloat(slots - values.count) * step
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + CGFloat(index) * step,
                        y: geo.size.height * (1 - CGFloat(min(max(value, 0), 1))))
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04))
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
