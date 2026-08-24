import Foundation

// MARK: - Grouping

public enum SensorGroup: String, Codable, CaseIterable, Hashable, Sendable {
    case cpu
    case efficiency
    case gpu
    case soc
    case memory
    case storage
    case battery
    case power
    case enclosure
    case ambient
    case other

    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .efficiency: return "E-cores"
        case .gpu: return "GPU"
        case .soc: return "SoC"
        case .memory: return "Memory"
        case .storage: return "SSD"
        case .battery: return "Battery"
        case .power: return "Power"
        case .enclosure: return "Enclosure"
        case .ambient: return "Ambient"
        case .other: return "Other"
        }
    }

    public var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .efficiency: return "leaf"
        case .gpu: return "cpu.fill"
        case .soc: return "square.stack.3d.up"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .battery: return "battery.100"
        case .power: return "bolt"
        case .enclosure: return "macbook"
        case .ambient: return "wind"
        case .other: return "thermometer.medium"
        }
    }

    /// Groups that make sense as a fan-curve driver, in the order we show them.
    public static let controllable: [SensorGroup] = [.cpu, .gpu, .soc, .memory, .storage, .battery, .enclosure]
}

// MARK: - Readings

public struct SensorReading: Identifiable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let group: SensorGroup
    public let celsius: Double

    public var id: String { key }

    public init(key: String, name: String, group: SensorGroup, celsius: Double) {
        self.key = key
        self.name = name
        self.group = group
        self.celsius = celsius
    }
}

// MARK: - Catalog

/// Maps raw SMC keys to human names and groups.
///
/// Apple Silicon exposes hundreds of thermal keys with no metadata, so this is
/// pattern matching on the naming scheme Apple has used since the M1. Anything
/// we do not recognise still shows up under "Other" with its raw key.
public enum SensorCatalog {

    /// Keys we explicitly know, with a nicer label.
    private static let named: [String: (String, SensorGroup)] = [
        "TB0T": ("Battery 1", .battery),
        "TB1T": ("Battery 2", .battery),
        "TB2T": ("Battery 3", .battery),
        "TW0P": ("Wi-Fi module", .other),
        "Ts0P": ("Enclosure – left palm rest", .enclosure),
        "Ts1P": ("Enclosure – right palm rest", .enclosure),
        "TS0P": ("Enclosure – bottom case", .enclosure),
        "TCHP": ("Charger chip", .power),
        "TCMb": ("Main board", .soc),
        "TCMz": ("Main board (hot spot)", .soc),
        "TMVR": ("Memory VRM", .memory),
        "TSVR": ("System VRM", .power),
        "TPMP": ("Power supply", .power),
        "TPSP": ("Power – mains side", .power),
        "TaLP": ("Airflow – left", .ambient),
        "TaRF": ("Airflow – right", .ambient),
        "TaTP": ("Airflow – top", .ambient),
        "TaLT": ("Air – left (intake)", .ambient),
        "TaRT": ("Air – right (intake)", .ambient),
        "TaLW": ("Air – left (exhaust)", .ambient),
        "TaRW": ("Air – right (exhaust)", .ambient),
        "TAOL": ("Ambient air", .ambient),
        "TH0x": ("SSD controller", .storage),
        "TH1x": ("SSD NAND", .storage),
    ]

    public static func describe(key: String) -> (name: String, group: SensorGroup)? {
        if let known = named[key] { return known }

        let chars = Array(key)
        guard chars.count == 4, chars[0] == "T" else { return nil }
        let suffix = String(chars[2...])

        switch String(chars[0...1]) {
        case "Tp":  return ("CPU P-core \(suffix)", .cpu)
        case "Te":  return ("CPU E-core \(suffix)", .efficiency)
        case "Tg":  return ("GPU \(suffix)", .gpu)
        case "Tm":  return ("Memory \(suffix)", .memory)
        case "Td":  return ("SoC die \(suffix)", .soc)
        case "Th":  return ("Heatsink \(suffix)", .soc)
        case "Ts":  return ("Enclosure \(suffix)", .enclosure)
        case "TH":  return ("SSD \(suffix)", .storage)
        case "TB":  return ("Battery \(suffix)", .battery)
        case "TC":  return ("CPU cluster \(suffix)", .cpu)
        case "TP":  return ("PMU \(suffix)", .power)
        case "TV":  return ("VRM \(suffix)", .power)
        case "TR":  return ("Radio / RF \(suffix)", .other)
        case "TD":  return ("Display / die \(suffix)", .other)
        case "Ta":  return ("Airflow \(suffix)", .ambient)
        case "TT":  return ("Thunderbolt \(suffix)", .other)
        default:    return nil
        }
    }

    /// A reading is trusted if it lands in a plausible range. The SMC happily
    /// reports 0 °C or 200 °C for sensors that are not populated on this model.
    public static func isPlausible(_ celsius: Double) -> Bool {
        celsius > 1 && celsius < 125
    }

    /// Sensors that drive the "hottest component" reading. Skin, ambient and
    /// battery sensors are excluded — they lag badly and would flatten a curve.
    public static let thermallyRelevant: Set<SensorGroup> = [.cpu, .efficiency, .gpu, .soc, .memory]
}

// MARK: - Curve source

/// What a fan curve watches.
public enum CurveSource: Codable, Hashable, Sendable {
    case hottest
    case group(SensorGroup)
    case key(String)

    public var title: String {
        switch self {
        case .hottest: return "Hottest component"
        case .group(let group): return group.title
        case .key(let key): return SensorCatalog.describe(key: key)?.name ?? key
        }
    }

    public var symbol: String {
        switch self {
        case .hottest: return "flame"
        case .group(let group): return group.symbol
        case .key: return "thermometer.medium"
        }
    }

    public func temperature(in readings: [SensorReading]) -> Double? {
        switch self {
        case .hottest:
            return readings
                .filter { SensorCatalog.thermallyRelevant.contains($0.group) }
                .map(\.celsius).max()
        case .group(let group):
            return readings.filter { $0.group == group }.map(\.celsius).max()
        case .key(let key):
            return readings.first { $0.key == key }?.celsius
        }
    }
}
