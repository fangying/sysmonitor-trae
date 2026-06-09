import Foundation
@preconcurrency import ArgumentParser
import SysMonitorCore

@main
struct SysMonitor: ParsableCommand, @unchecked Sendable {
    static let configuration = CommandConfiguration(
        commandName: "sysmonitor",
        abstract: "A command-line system information monitor tool for macOS.",
        version: "1.0.0"
    )

    @Option(name: .shortAndLong, help: "Interval in seconds for periodic monitoring. If omitted, runs once.")
    var interval: Double?

    func run() throws {
        if let interval = interval {
            guard interval > 0 else {
                throw ValidationError("--interval must be greater than 0.")
            }

            while true {
                printStats()
                Thread.sleep(forTimeInterval: interval)
                print("")
            }
        } else {
            printStats()
        }
    }

    func printStats() {
        let snapshot = HardwareMonitor.shared.snapshot(at: Date())
        let report = MonitorReportFormatter().string(from: snapshot)
        print(report)
    }
}
