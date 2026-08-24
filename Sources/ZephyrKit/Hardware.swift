import Foundation

// MARK: - Fans

public struct Fan: Identifiable, Hashable, Sendable {
    public let index: Int
    public let name: String
    public let minRPM: Double
    public let maxRPM: Double
    public var currentRPM: Double
    public var targetRPM: Double
    public var isManual: Bool

    public var id: Int { index }

    /// Where the fan sits in its usable range, 0–1.
    public var load: Double {
        let span = maxRPM - minRPM
        guard span > 0 else { return 0 }
        return min(max((currentRPM - minRPM) / span, 0), 1)
    }

    public func rpm(forPercent percent: Double) -> Double {
        let clamped = min(max(percent, 0), 100)
        return minRPM + (maxRPM - minRPM) * clamped / 100
    }

    public func percent(forRPM rpm: Double) -> Double {
        let span = maxRPM - minRPM
        guard span > 0 else { return 0 }
        return min(max((rpm - minRPM) / span * 100, 0), 100)
    }
}

// MARK: - Snapshot

public struct HardwareSnapshot: Sendable {
    public var fans: [Fan]
    public var sensors: [SensorReading]
    public var timestamp: Date

    public init(fans: [Fan] = [], sensors: [SensorReading] = [], timestamp: Date = Date()) {
        self.fans = fans
        self.sensors = sensors
        self.timestamp = timestamp
    }

    public func temperature(for source: CurveSource) -> Double? {
        source.temperature(in: sensors)
    }

    public var hottest: SensorReading? {
        sensors
            .filter { SensorCatalog.thermallyRelevant.contains($0.group) }
            .max { $0.celsius < $1.celsius }
    }

    /// Group summary: the hottest reading per group, ordered for display.
    public var groupSummary: [(group: SensorGroup, reading: SensorReading)] {
        var best: [SensorGroup: SensorReading] = [:]
        for reading in sensors {
            if let existing = best[reading.group], existing.celsius >= reading.celsius { continue }
            best[reading.group] = reading
        }
        return SensorGroup.allCases.compactMap { group in
            best[group].map { (group, $0) }
        }
    }
}

// MARK: - Monitor

/// Discovers fans and thermal sensors once, then polls them cheaply.
public final class HardwareMonitor {

    private let smc: SMC
    private var sensorKeys: [(key: String, name: String, group: SensorGroup)] = []
    private var fanDescriptors: [(index: Int, name: String, min: Double, max: Double)] = []

    public private(set) var fanCount: Int = 0

    public init() throws {
        smc = try SMC()
        discoverFans()
        discoverSensors()
    }

    // MARK: Discovery

    private static func fanName(index: Int, total: Int) -> String {
        if total == 2 { return index == 0 ? "Left fan" : "Right fan" }
        if total == 1 { return "Fan" }
        return "Fan \(index + 1)"
    }

    private func discoverFans() {
        let count = Int(smc.number("FNum") ?? 0)
        fanCount = count
        fanDescriptors = (0..<count).compactMap { index in
            guard let minRPM = smc.number("F\(index)Mn"),
                  let maxRPM = smc.number("F\(index)Mx"),
                  maxRPM > minRPM else { return nil }
            return (index, Self.fanName(index: index, total: count), minRPM, maxRPM)
        }
    }

    private func discoverSensors() {
        guard let keys = try? smc.allKeys() else { return }
        var found: [(String, String, SensorGroup)] = []
        for key in keys where key.hasPrefix("T") {
            guard let info = try? smc.info(for: key), info.type == "flt " || info.type == "sp78" else { continue }
            guard let description = SensorCatalog.describe(key: key) else { continue }
            // Probe once — unpopulated sensors read as a constant 0 on this Mac.
            guard let value = smc.number(key), SensorCatalog.isPlausible(value) else { continue }
            found.append((key, description.name, description.group))
        }
        sensorKeys = found.sorted { $0.0 < $1.0 }
    }

    // MARK: Polling

    public func snapshot() -> HardwareSnapshot {
        var fans: [Fan] = []
        for descriptor in fanDescriptors {
            let current = smc.number("F\(descriptor.index)Ac") ?? 0
            let target = smc.number("F\(descriptor.index)Tg") ?? current
            let mode = smc.number("F\(descriptor.index)Md") ?? 0
            fans.append(Fan(index: descriptor.index,
                            name: descriptor.name,
                            minRPM: descriptor.min,
                            maxRPM: descriptor.max,
                            currentRPM: current,
                            targetRPM: target,
                            isManual: mode != 0))
        }

        var sensors: [SensorReading] = []
        sensors.reserveCapacity(sensorKeys.count)
        for entry in sensorKeys {
            guard let value = smc.number(entry.key), SensorCatalog.isPlausible(value) else { continue }
            sensors.append(SensorReading(key: entry.key, name: entry.name, group: entry.group, celsius: value))
        }

        return HardwareSnapshot(fans: fans, sensors: sensors, timestamp: Date())
    }

    /// Every discovered sensor key, for the "all sensors" browser.
    public var knownSensorKeys: [(key: String, name: String, group: SensorGroup)] { sensorKeys }
}
