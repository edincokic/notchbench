//
//  SystemStats.swift
//  BoringNotchXPCHelper
//
//  Lists the busiest processes for the System tab. Runs in the helper because the
//  sandboxed app can't see other processes. Sent back as JSON.
//

import Foundation

extension BoringNotchXPCHelper {

    @objc func listTopProcesses(with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // pid, %cpu, memory in KB, full path of the program
            let output = Self.run("/bin/ps", ["-Aco", "pid=,pcpu=,rss=,comm="]).output
            var processes: [[String: Any]] = []

            for line in output.split(separator: "\n") {
                let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard fields.count == 4,
                      let pid = Int32(fields[0]),
                      let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                      let rssKB = Int(fields[2]) else { continue }
                processes.append([
                    "pid": pid,
                    "cpu": cpu,
                    "memoryBytes": rssKB * 1024,
                    "name": String(fields[3]),
                ])
            }

            // Keep the top 8 by CPU and the top 8 by memory; the app picks which list to show.
            let byCPU = processes.sorted { ($0["cpu"] as! Double) > ($1["cpu"] as! Double) }.prefix(8)
            let byMemory = processes.sorted { ($0["memoryBytes"] as! Int) > ($1["memoryBytes"] as! Int) }.prefix(8)
            var seen = Set<Int32>()
            let result = (byCPU + byMemory).filter { seen.insert($0["pid"] as! Int32).inserted }
            reply(try? JSONSerialization.data(withJSONObject: result))
        }
    }
}
