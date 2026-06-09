import Foundation

public struct TemperatureReading: Equatable, Sendable {
    public let label: String
    public let celsius: Double
    public let source: String

    public init(label: String, celsius: Double, source: String) {
        self.label = label
        self.celsius = celsius
        self.source = source
    }
}

public struct FanReading: Equatable, Sendable {
    public let label: String
    public let rpm: Int
    public let source: String

    public init(label: String, rpm: Int, source: String) {
        self.label = label
        self.rpm = rpm
        self.source = source
    }
}

public struct MonitorSnapshot: Equatable, Sendable {
    public let timestamp: Date
    public let cpuCoreTemperatures: [TemperatureReading]
    public let fanSpeeds: [FanReading]

    public init(timestamp: Date, cpuCoreTemperatures: [TemperatureReading], fanSpeeds: [FanReading]) {
        self.timestamp = timestamp
        self.cpuCoreTemperatures = cpuCoreTemperatures
        self.fanSpeeds = fanSpeeds
    }
}

public struct MonitorReportFormatter: Sendable {
    public init() {}

    public func string(from snapshot: MonitorSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: snapshot.timestamp)

        var lines: [String] = [
            "sysmonitor snapshot @ \(timestamp)",
            String(repeating: "=", count: 48),
            "CPU Core Temperatures",
        ]

        if snapshot.cpuCoreTemperatures.isEmpty {
            lines.append("  • CPU core temperature: unavailable")
        } else {
            for reading in snapshot.cpuCoreTemperatures {
                let formattedTemperature = String(format: "%.1f °C", reading.celsius)
                lines.append("  • \(reading.label): \(formattedTemperature)")
            }
        }

        lines.append("")
        lines.append("CPU Fan Speeds")

        if snapshot.fanSpeeds.isEmpty {
            lines.append("  • CPU fan speed: unavailable")
        } else {
            for fan in snapshot.fanSpeeds {
                lines.append("  • \(fan.label): \(fan.rpm) RPM")
            }
        }

        return lines.joined(separator: "\n")
    }
}
