//
//  SystemStatsManager.swift
//  boringNotch
//
//  CPU and memory usage for the System tab. Reads macOS's own counters
//  (works inside the sandbox); the busiest-apps list comes from the helper.
//  Only samples while the tab is on screen.
//

import Darwin
import Foundation

struct TopProcess: Identifiable, Decodable, Equatable {
    let pid: Int32
    let cpu: Double
    let memoryBytes: Int
    let name: String
    var id: Int32 { pid }
}

struct MemoryUsage: Equatable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0

    /// Same idea as Activity Monitor's "Memory Used".
    var used: UInt64 { app + wired + compressed }
    var fraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
}

@MainActor
final class SystemStatsManager: ObservableObject {
    static let shared = SystemStatsManager()

    /// 0...1
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var cpuUser: Double = 0
    @Published private(set) var cpuSystem: Double = 0
    /// Last 60 samples, oldest first, for the graph.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memory = MemoryUsage()
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var topProcesses: [TopProcess] = []

    let coreCount = ProcessInfo.processInfo.activeProcessorCount

    private let host = mach_host_self()
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var sampleTask: Task<Void, Never>?
    private var viewers = 0
    private var samplesSinceProcessRefresh = 0
    private let historyLength = 60

    private init() {}

    // MARK: - Start / stop

    func startSampling() {
        viewers += 1
        guard sampleTask == nil else { return }
        previousTicks = cpuTicks()
        sampleTask = Task { [weak self] in
            // First reading after a short pause so the CPU number is meaningful.
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopSampling() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        sampleTask?.cancel()
        sampleTask = nil
    }

    // MARK: - Sampling

    private func sample() async {
        if let ticks = cpuTicks(), let previous = previousTicks {
            let user = Double(ticks.user &- previous.user) + Double(ticks.nice &- previous.nice)
            let system = Double(ticks.system &- previous.system)
            let idle = Double(ticks.idle &- previous.idle)
            let total = user + system + idle
            if total > 0 {
                cpuUser = user / total
                cpuSystem = system / total
                cpuUsage = (user + system) / total
            }
            previousTicks = ticks
        } else {
            previousTicks = cpuTicks()
        }
        append(cpuUsage, to: &cpuHistory)

        if let memory = memoryUsage() {
            self.memory = memory
            append(memory.fraction, to: &memoryHistory)
        }

        // The process list costs more, so refresh it every 3 seconds.
        if samplesSinceProcessRefresh == 0 {
            if let data = await XPCHelperClient.shared.listTopProcesses(),
               let processes = try? JSONDecoder().decode([TopProcess].self, from: data) {
                topProcesses = processes
            }
        }
        samplesSinceProcessRefresh = (samplesSinceProcessRefresh + 1) % 3
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength {
            history.removeFirst(history.count - historyLength)
        }
    }

    /// Total CPU ticks across all cores since boot.
    private func cpuTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = load.cpu_ticks
        return (UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3))
    }

    private func memoryUsage() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        var usage = MemoryUsage()
        usage.total = ProcessInfo.processInfo.physicalMemory
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        usage.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        usage.wired = UInt64(stats.wire_count) * page
        usage.compressed = UInt64(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            usage.swapUsed = swap.xsu_used
        }
        return usage
    }
}
