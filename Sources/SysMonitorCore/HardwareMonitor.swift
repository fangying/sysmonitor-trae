import Foundation
import IOKit

public protocol MonitorDataProviding: Sendable {
    func snapshot(at date: Date) -> MonitorSnapshot
}

public final class HardwareMonitor: MonitorDataProviding, @unchecked Sendable {
    public static let shared = HardwareMonitor()

    public init() {}

    public func snapshot(at date: Date = Date()) -> MonitorSnapshot {
        MonitorSnapshot(
            timestamp: date,
            cpuCoreTemperatures: readCPUTemperatures(),
            fanSpeeds: readFanSpeeds()
        )
    }

    func readCPUTemperatures() -> [TemperatureReading] {
        let hidReadings = readCPUTemperaturesFromHID()
        if !hidReadings.isEmpty {
            return hidReadings
        }

        return readCPUTemperaturesFromSMC()
    }

    func readFanSpeeds() -> [FanReading] {
        let smcReadings = readFanSpeedsFromSMC()
        if !smcReadings.isEmpty {
            return smcReadings
        }

        let registryReadings = readFanSpeedsFromIORegistry()
        if !registryReadings.isEmpty {
            return registryReadings
        }

        return []
    }

    private func readCPUTemperaturesFromHID() -> [TemperatureReading] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return []
        }

        let matching = ["PrimaryUsagePage": 0xff00] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(client, matching)

        guard let unmanagedServices = IOHIDEventSystemClientCopyServices(client) else {
            return []
        }

        let services = unmanagedServices.takeRetainedValue()
        let count = CFArrayGetCount(services)
        var readings: [TemperatureReading] = []
        var seenProducts = Set<String>()

        for index in 0..<count {
            let rawService = CFArrayGetValueAtIndex(services, index)
            let service = unsafeBitCast(rawService, to: IOHIDServiceClientRef.self)

            guard
                let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString),
                let productName = nameRef.takeUnretainedValue() as? String,
                SensorNameNormalizer.isLikelyCPUSensor(productName),
                let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0)
            else {
                continue
            }

            let celsius = IOHIDEventGetFloatValue(event, 15 << 16)
            guard SensorNameNormalizer.isReasonableTemperature(celsius) else {
                continue
            }

            guard seenProducts.insert(productName).inserted else {
                continue
            }

            readings.append(
                TemperatureReading(
                    label: SensorNameNormalizer.cpuTemperatureLabel(for: productName, fallbackIndex: readings.count),
                    celsius: celsius,
                    source: productName
                )
            )
        }

        return readings.sorted(by: SensorNameNormalizer.temperatureSort)
    }

    private func readFanSpeedsFromIORegistry() -> [FanReading] {
        let classNames = ["AppleARMIODevice", "AppleFan", "AppleSMCFanControl"]
        var results: [FanReading] = []
        var seen = Set<String>()

        for className in classNames {
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(Self.mainPort, IOServiceMatching(className), &iterator)
            guard result == KERN_SUCCESS else {
                continue
            }

            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }

                guard let rpm = registryRPM(for: service), rpm > 0 else {
                    continue
                }

                let source = registryStringProperty(service, key: "name")
                    ?? registryStringProperty(service, key: "Product")
                    ?? "fan"
                let label = SensorNameNormalizer.fanLabel(for: source, fallbackIndex: results.count)
                let dedupeKey = "\(label)-\(rpm)"

                guard seen.insert(dedupeKey).inserted else {
                    continue
                }

                results.append(FanReading(label: label, rpm: rpm, source: source))
            }
        }

        return results.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func readCPUTemperaturesFromSMC() -> [TemperatureReading] {
        guard let smc = SMCConnection() else {
            return []
        }

        var results: [TemperatureReading] = []

        for coreIndex in 0..<10 {
            let key = "TC\(coreIndex)C"
            guard let celsius = smc.readTemperature(forKey: key), SensorNameNormalizer.isReasonableTemperature(celsius) else {
                continue
            }

            results.append(
                TemperatureReading(
                    label: "CPU Core \(coreIndex)",
                    celsius: celsius,
                    source: key
                )
            )
        }

        if !results.isEmpty {
            return results
        }

        let fallbackKeys: [(String, String)] = [
            ("TC0P", "CPU Core Package"),
            ("TC0E", "CPU Core Efficiency Cluster"),
            ("TC0F", "CPU Core Performance Cluster"),
            ("TC0D", "CPU Core Die"),
        ]

        for (key, label) in fallbackKeys {
            guard let celsius = smc.readTemperature(forKey: key), SensorNameNormalizer.isReasonableTemperature(celsius) else {
                continue
            }

            results.append(TemperatureReading(label: label, celsius: celsius, source: key))
        }

        return results
    }

    private func readFanSpeedsFromSMC() -> [FanReading] {
        guard let smc = SMCConnection(), let fanCount = smc.readFanCount() else {
            return []
        }

        var results: [FanReading] = []
        for fanIndex in 0..<fanCount {
            let key = String(format: "F%dAc", fanIndex)
            guard let rpm = smc.readFanSpeed(forKey: key), rpm >= 0 else {
                continue
            }

            results.append(FanReading(label: "Fan \(fanIndex)", rpm: rpm, source: key))
        }

        return results
    }

    private func registryRPM(for service: io_service_t) -> Int? {
        let keys = ["fan-speed", "current-speed", "target-speed"]
        for key in keys {
            if let rpm = registryNumericProperty(service, key: key) {
                return rpm
            }
        }
        return nil
    }

    private func registryNumericProperty(_ service: io_service_t, key: String) -> Int? {
        let flags = UInt32(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let property = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, flags) else {
            return nil
        }

        if let number = property as? NSNumber {
            return number.intValue
        }

        if let data = property as? Data {
            switch data.count {
            case 1:
                return Int(data[0])
            case 2:
                return Int(data.withUnsafeBytes { $0.load(as: UInt16.self) })
            case 4:
                return Int(data.withUnsafeBytes { $0.load(as: UInt32.self) })
            default:
                return nil
            }
        }

        return nil
    }

    private func registryStringProperty(_ service: io_service_t, key: String) -> String? {
        let flags = UInt32(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let property = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, flags) else {
            return nil
        }

        if let value = property as? String {
            return value
        }

        if let data = property as? Data {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }

        return nil
    }

    static var mainPort: mach_port_t {
        if #available(macOS 12.0, *) {
            return kIOMainPortDefault
        }

        return mach_port_t(MACH_PORT_NULL)
    }
}

enum SensorNameNormalizer {
    private static let digitRegex = try! NSRegularExpression(pattern: #"(\d+)"#)

    static func isLikelyCPUSensor(_ rawName: String) -> Bool {
        let name = rawName.lowercased()

        if name.contains("battery") || name.contains("gas gauge") {
            return false
        }

        return name.contains("cpu")
            || name.contains("core")
            || name.contains("pmu tdie")
            || name.contains("pmu tdev")
            || name.contains("pacc")
            || name.contains("eacc")
    }

    static func isReasonableTemperature(_ celsius: Double) -> Bool {
        celsius > 0 && celsius < 120
    }

    static func cpuTemperatureLabel(for rawName: String, fallbackIndex: Int) -> String {
        let lowered = rawName.lowercased()
        let index = firstInteger(in: rawName) ?? fallbackIndex

        if lowered.contains("core") {
            return "CPU Core \(index)"
        }

        if lowered.contains("tdie") {
            return index == fallbackIndex ? "CPU Core Die" : "CPU Core Die \(index)"
        }

        if lowered.contains("pacc") {
            return "CPU Core Performance Sensor \(index)"
        }

        if lowered.contains("eacc") {
            return "CPU Core Efficiency Sensor \(index)"
        }

        if lowered.contains("tdev") {
            return "CPU Core Sensor \(index)"
        }

        return "CPU Core Sensor \(fallbackIndex)"
    }

    static func fanLabel(for rawName: String, fallbackIndex: Int) -> String {
        let name = rawName.lowercased()
        if name.contains("left") {
            return "Fan Left"
        }
        if name.contains("right") {
            return "Fan Right"
        }
        return "Fan \(fallbackIndex)"
    }

    static func temperatureSort(lhs: TemperatureReading, rhs: TemperatureReading) -> Bool {
        let leftIndex = firstInteger(in: lhs.label) ?? Int.max
        let rightIndex = firstInteger(in: rhs.label) ?? Int.max
        if leftIndex != rightIndex {
            return leftIndex < rightIndex
        }
        return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
    }

    static func firstInteger(in string: String) -> Int? {
        let range = NSRange(string.startIndex..., in: string)
        guard let match = digitRegex.firstMatch(in: string, range: range), let matchRange = Range(match.range(at: 1), in: string) else {
            return nil
        }

        return Int(string[matchRange])
    }
}

// IOHID Private API Declarations
typealias IOHIDEventSystemClientRef = UnsafeMutableRawPointer
typealias IOHIDServiceClientRef = UnsafeMutableRawPointer
typealias IOHIDEventRef = UnsafeMutableRawPointer

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?

@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClientRef, _ match: CFDictionary?) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClientRef) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClientRef, _ property: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClientRef, _ type: Int64, _ options: Int32, _ options2: Int64) -> IOHIDEventRef?

@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: IOHIDEventRef, _ field: Int32) -> Double

// SMC structs
struct SMCKeyData_vers_t {
    var data: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCKeyData_t {
    var key: UInt32 = 0
    var vers = SMCKeyData_vers_t()
    var pLimitData = SMCKeyData_vers_t()
    var keyInfo = SMCKeyData_keyInfo_t()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

struct SMCValue {
    let dataSize: UInt32
    let dataType: UInt32
    let bytes: [UInt8]
}

private final class SMCConnection {
    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(HardwareMonitor.mainPort, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            return nil
        }

        var connection: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        guard openResult == kIOReturnSuccess, connection != 0 else {
            return nil
        }

        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    func readTemperature(forKey key: String) -> Double? {
        guard let value = readValue(forKey: key) else {
            return nil
        }

        let type = value.dataTypeString
        if type == "sp78", value.bytes.count >= 2 {
            let raw = Int16(bitPattern: UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
            return Double(raw) / 256.0
        }

        if type == "flt ", value.bytes.count >= 4 {
            let bitPattern = UInt32(value.bytes[0])
                | UInt32(value.bytes[1]) << 8
                | UInt32(value.bytes[2]) << 16
                | UInt32(value.bytes[3]) << 24
            return Double(Float(bitPattern: bitPattern))
        }

        return nil
    }

    func readFanSpeed(forKey key: String) -> Int? {
        guard let value = readValue(forKey: key) else {
            return nil
        }

        let type = value.dataTypeString
        if type == "fpe2", value.bytes.count >= 2 {
            let raw = UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])
            return Int(Double(raw) / 4.0)
        }

        if type == "flt ", value.bytes.count >= 4 {
            let bitPattern = UInt32(value.bytes[0])
                | UInt32(value.bytes[1]) << 8
                | UInt32(value.bytes[2]) << 16
                | UInt32(value.bytes[3]) << 24
            return Int(Float(bitPattern: bitPattern).rounded())
        }

        if type == "ui8 ", let first = value.bytes.first {
            return Int(first)
        }

        return nil
    }

    func readFanCount() -> Int? {
        guard let value = readValue(forKey: "FNum") else {
            return nil
        }

        if value.dataTypeString == "ui8 ", let first = value.bytes.first {
            return Int(first)
        }

        return value.bytes.first.map(Int.init)
    }

    private func readValue(forKey key: String) -> SMCValue? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        let keyDataSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        input.key = fourCC(from: key)
        input.data8 = 9

        let keyInfoResult = IOConnectCallStructMethod(connection, 2, &input, keyDataSize, &output, &outputSize)
        guard keyInfoResult == kIOReturnSuccess else {
            return nil
        }

        guard output.result == 0 else {
            return nil
        }

        let keyInfoDataSize = output.keyInfo.dataSize
        let keyInfoDataType = output.keyInfo.dataType
        input.keyInfo.dataSize = keyInfoDataSize
        input.keyInfo.dataType = keyInfoDataType
        input.data8 = 5
        output = SMCParamStruct()
        outputSize = MemoryLayout<SMCParamStruct>.stride

        let readResult = IOConnectCallStructMethod(connection, 2, &input, keyDataSize, &output, &outputSize)
        guard readResult == kIOReturnSuccess, output.result == 0 else {
            return nil
        }

        let byteMirror = Mirror(reflecting: output.bytes)
        let bytes = byteMirror.children.compactMap { $0.value as? UInt8 }

        return SMCValue(dataSize: keyInfoDataSize, dataType: keyInfoDataType, bytes: bytes)
    }

    private func fourCC(from string: String) -> UInt32 {
        string.utf8.reduce(0) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
    }

    private func fourCCString(from value: UInt32) -> String {
        let scalars: [UnicodeScalar] = [
            UnicodeScalar((value >> 24) & 0xFF),
            UnicodeScalar((value >> 16) & 0xFF),
            UnicodeScalar((value >> 8) & 0xFF),
            UnicodeScalar(value & 0xFF),
        ].compactMap { $0 }
        return String(String.UnicodeScalarView(scalars))
    }
}

extension SMCValue {
    var dataTypeString: String {
        let bytes = [
            UInt8((dataType >> 24) & 0xFF),
            UInt8((dataType >> 16) & 0xFF),
            UInt8((dataType >> 8) & 0xFF),
            UInt8(dataType & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    var pLimitData: (
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var padding0: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var padding1: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8
    ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
