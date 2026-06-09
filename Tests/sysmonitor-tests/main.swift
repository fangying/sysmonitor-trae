import Foundation
import SysMonitorCore

@main
struct SysMonitorTestRunner {
    static func main() {
        do {
            try testFormatterIncludesCPUCoreTemperaturesAndFanSpeeds()
            try testFormatterKeepsReadableSectionsWhenSensorsAreUnavailable()
            try testSysmonitorExecutablePrintsRequiredSections()
            print("All sysmonitor tests passed.")
        } catch {
            fputs("sysmonitor tests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testFormatterIncludesCPUCoreTemperaturesAndFanSpeeds() throws {
        let snapshot = MonitorSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_718_000_000),
            cpuCoreTemperatures: [
                TemperatureReading(label: "CPU Core 0", celsius: 52.4, source: "TC0C"),
                TemperatureReading(label: "CPU Core 1", celsius: 53.1, source: "TC1C"),
            ],
            fanSpeeds: [
                FanReading(label: "Fan 0", rpm: 0, source: "F0Ac"),
                FanReading(label: "Fan 1", rpm: 2184, source: "F1Ac")
            ]
        )

        let output = MonitorReportFormatter().string(from: snapshot)

        try expect(output.contains("CPU Core Temperatures"), "Formatter must include CPU core temperatures section")
        try expect(output.contains("CPU Core 0: 52.4 °C"), "Formatter must include first core temperature")
        try expect(output.contains("CPU Core 1: 53.1 °C"), "Formatter must include second core temperature")
        try expect(output.contains("CPU Fan Speeds"), "Formatter must include CPU fan speeds section")
        try expect(output.contains("Fan 0: 0 RPM"), "Formatter must include zero RPM fan speed in RPM")
        try expect(output.contains("Fan 1: 2184 RPM"), "Formatter must include non-zero fan speed in RPM")
    }

    private static func testFormatterKeepsReadableSectionsWhenSensorsAreUnavailable() throws {
        let snapshot = MonitorSnapshot(timestamp: Date(timeIntervalSince1970: 0), cpuCoreTemperatures: [], fanSpeeds: [])
        let output = MonitorReportFormatter().string(from: snapshot)

        try expect(output.contains("CPU Core Temperatures"), "Unavailable report must still include CPU core temperatures header")
        try expect(output.contains("CPU Fan Speeds"), "Unavailable report must still include CPU fan speeds header")
        try expect(output.contains("CPU core temperature: unavailable"), "Unavailable report must show missing CPU core temperature clearly")
        try expect(output.contains("CPU fan speed: unavailable"), "Unavailable report must show missing CPU fan speed clearly")
    }

    private static func testSysmonitorExecutablePrintsRequiredSections() throws {
        let executable = URL(fileURLWithPath: ".build/debug/sysmonitor")
        let task = Process()
        task.executableURL = executable

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()
        task.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        try expect(task.terminationStatus == 0, "sysmonitor executable must exit successfully. stderr: \(errorOutput)")
        try expect(output.contains("CPU Core Temperatures"), "Executable output must include CPU core temperatures header")
        try expect(output.contains("CPU Fan Speeds"), "Executable output must include CPU fan speeds header")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure(message: message)
        }
    }
}

private struct TestFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
