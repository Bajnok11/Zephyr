import Foundation

// MARK: - Curve

public struct CurvePoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var temperature: Double
    public var percent: Double

    public init(id: UUID = UUID(), temperature: Double, percent: Double) {
        self.id = id
        self.temperature = temperature
        self.percent = percent
    }
}

public struct FanCurve: Codable, Hashable, Sendable {
    public var source: CurveSource
    public var points: [CurvePoint]

    public init(source: CurveSource, points: [CurvePoint]) {
        self.source = source
        self.points = points.sorted { $0.temperature < $1.temperature }
    }

    /// Fan output for a temperature, as 0–100 % of the fan's usable range.
    public func percent(at temperature: Double) -> Double {
        let sorted = points.sorted { $0.temperature < $1.temperature }
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if temperature <= first.temperature { return first.percent }
        if temperature >= last.temperature { return last.percent }

        for index in 0..<(sorted.count - 1) {
            let a = sorted[index], b = sorted[index + 1]
            guard temperature >= a.temperature, temperature <= b.temperature else { continue }
            let span = b.temperature - a.temperature
            guard span > 0 else { return b.percent }
            let t = (temperature - a.temperature) / span
            return a.percent + t * (b.percent - a.percent)
        }
        return last.percent
    }

    public mutating func normalize() {
        points.sort { $0.temperature < $1.temperature }
        for index in points.indices {
            points[index].temperature = min(max(points[index].temperature, 20), 110)
            points[index].percent = min(max(points[index].percent, 0), 100)
        }
    }
}

// MARK: - Preset

public struct Preset: Codable, Hashable, Identifiable, Sendable {
    public enum Mode: Codable, Hashable, Sendable {
        /// Hand control back to the firmware.
        case system
        /// Pin every fan to a fixed percentage of its usable range.
        case fixed(percent: Double)
        /// Follow a temperature curve.
        case curve(FanCurve)
    }

    public var id: UUID
    public var name: String
    public var symbol: String
    public var tint: String
    public var mode: Mode
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, symbol: String, tint: String, mode: Mode, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.mode = mode
        self.isBuiltIn = isBuiltIn
    }

    public var subtitle: String {
        switch mode {
        case .system:
            return "A macOS vezérel"
        case .fixed(let percent):
            return "Fix \(Int(percent.rounded())) %"
        case .curve(let curve):
            return curve.source.title
        }
    }

    public var requiresControl: Bool {
        if case .system = mode { return false }
        return true
    }
}

// MARK: - Built-in presets

public extension Preset {

    /// Stable IDs so a user's selected preset survives an app update.
    enum BuiltIn {
        public static let system = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        public static let silent = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        public static let balanced = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        public static let cool = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        public static let turbo = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        public static let manual = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    }

    static let systemPreset = Preset(
        id: BuiltIn.system,
        name: "Automatikus",
        symbol: "apple.logo",
        tint: "gray",
        mode: .system,
        isBuiltIn: true
    )

    static let silent = Preset(
        id: BuiltIn.silent,
        name: "Csendes",
        symbol: "moon.zzz.fill",
        tint: "indigo",
        mode: .curve(FanCurve(source: .hottest, points: [
            CurvePoint(temperature: 45, percent: 0),
            CurvePoint(temperature: 70, percent: 0),
            CurvePoint(temperature: 82, percent: 22),
            CurvePoint(temperature: 92, percent: 55),
            CurvePoint(temperature: 100, percent: 100),
        ])),
        isBuiltIn: true
    )

    static let balanced = Preset(
        id: BuiltIn.balanced,
        name: "Kiegyensúlyozott",
        symbol: "dial.medium.fill",
        tint: "blue",
        mode: .curve(FanCurve(source: .hottest, points: [
            CurvePoint(temperature: 45, percent: 0),
            CurvePoint(temperature: 62, percent: 12),
            CurvePoint(temperature: 75, percent: 35),
            CurvePoint(temperature: 85, percent: 65),
            CurvePoint(temperature: 95, percent: 100),
        ])),
        isBuiltIn: true
    )

    static let cool = Preset(
        id: BuiltIn.cool,
        name: "Hűvös",
        symbol: "snowflake",
        tint: "teal",
        mode: .curve(FanCurve(source: .hottest, points: [
            CurvePoint(temperature: 38, percent: 12),
            CurvePoint(temperature: 52, percent: 32),
            CurvePoint(temperature: 65, percent: 58),
            CurvePoint(temperature: 76, percent: 82),
            CurvePoint(temperature: 86, percent: 100),
        ])),
        isBuiltIn: true
    )

    static let turbo = Preset(
        id: BuiltIn.turbo,
        name: "Turbó",
        symbol: "bolt.fill",
        tint: "orange",
        mode: .fixed(percent: 100),
        isBuiltIn: true
    )

    /// Driven by the slider in the popover; its percentage lives in `Settings.manualPercent`.
    static let manual = Preset(
        id: BuiltIn.manual,
        name: "Kézi",
        symbol: "slider.horizontal.3",
        tint: "purple",
        mode: .fixed(percent: 45),
        isBuiltIn: true
    )

    static let builtIns: [Preset] = [.systemPreset, .silent, .balanced, .cool, .turbo, .manual]
}

// MARK: - Automation

public struct AutomationRules: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var onBattery: UUID?
    public var onPower: UUID?
    /// Force full speed above this temperature no matter what the curve says.
    public var emergencyEnabled: Bool
    public var emergencyTemperature: Double

    public init(enabled: Bool = false,
                onBattery: UUID? = Preset.BuiltIn.silent,
                onPower: UUID? = Preset.BuiltIn.balanced,
                emergencyEnabled: Bool = true,
                emergencyTemperature: Double = 100) {
        self.enabled = enabled
        self.onBattery = onBattery
        self.onPower = onPower
        self.emergencyEnabled = emergencyEnabled
        self.emergencyTemperature = emergencyTemperature
    }
}

// MARK: - Menu bar display

public enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case iconOnly
    case temperature
    case rpm
    case both

    public var title: String {
        switch self {
        case .iconOnly: return "Csak ikon"
        case .temperature: return "Hőmérséklet"
        case .rpm: return "Fordulatszám"
        case .both: return "Hőmérséklet + RPM"
        }
    }
}

// MARK: - Settings

public struct Settings: Codable, Sendable {
    public var presets: [Preset]
    public var activePresetID: UUID
    public var automation: AutomationRules
    public var menuBarStyle: MenuBarStyle
    public var animateIcon: Bool
    public var menuBarSource: CurveSource
    public var showEfficiencyCores: Bool
    /// Max RPM change per update tick — keeps the fans from stepping audibly.
    public var rampStep: Double
    public var launchAtLogin: Bool
    /// Percentage the "Kézi" preset holds, edited by the popover slider.
    public var manualPercent: Double

    public init(presets: [Preset] = Preset.builtIns,
                activePresetID: UUID = Preset.BuiltIn.system,
                automation: AutomationRules = AutomationRules(),
                menuBarStyle: MenuBarStyle = .temperature,
                animateIcon: Bool = true,
                menuBarSource: CurveSource = .hottest,
                showEfficiencyCores: Bool = false,
                rampStep: Double = 220,
                launchAtLogin: Bool = false,
                manualPercent: Double = 45) {
        self.presets = presets
        self.activePresetID = activePresetID
        self.automation = automation
        self.menuBarStyle = menuBarStyle
        self.animateIcon = animateIcon
        self.menuBarSource = menuBarSource
        self.showEfficiencyCores = showEfficiencyCores
        self.rampStep = rampStep
        self.launchAtLogin = launchAtLogin
        self.manualPercent = manualPercent
    }

    /// Tolerant decoding: a settings file written by an older build is missing
    /// keys we added since, and losing every preference over one new field
    /// would be a poor trade.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        presets = (try? container.decode([Preset].self, forKey: .presets)) ?? defaults.presets
        activePresetID = (try? container.decode(UUID.self, forKey: .activePresetID)) ?? defaults.activePresetID
        automation = (try? container.decode(AutomationRules.self, forKey: .automation)) ?? defaults.automation
        menuBarStyle = (try? container.decode(MenuBarStyle.self, forKey: .menuBarStyle)) ?? defaults.menuBarStyle
        animateIcon = (try? container.decode(Bool.self, forKey: .animateIcon)) ?? defaults.animateIcon
        menuBarSource = (try? container.decode(CurveSource.self, forKey: .menuBarSource)) ?? defaults.menuBarSource
        showEfficiencyCores = (try? container.decode(Bool.self, forKey: .showEfficiencyCores)) ?? defaults.showEfficiencyCores
        rampStep = (try? container.decode(Double.self, forKey: .rampStep)) ?? defaults.rampStep
        launchAtLogin = (try? container.decode(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        manualPercent = (try? container.decode(Double.self, forKey: .manualPercent)) ?? defaults.manualPercent
    }

    /// Built-in presets are code, not data: re-seed them on every load so fixes
    /// to a default curve reach users who never touched that preset.
    public mutating func mergeBuiltIns() {
        var merged = Preset.builtIns
        merged.append(contentsOf: presets.filter { !$0.isBuiltIn })
        presets = merged
        if !presets.contains(where: { $0.id == activePresetID }) {
            activePresetID = Preset.BuiltIn.system
        }
    }
}

// MARK: - Persistence

public enum SettingsStore {
    public static var url: URL {
        // Lets a throwaway instance (screenshots, tests) run without touching
        // the real configuration.
        if let override = ProcessInfo.processInfo.environment["ZEPHYR_SETTINGS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zephyr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    public static func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        settings.mergeBuiltIns()
        return settings
    }

    public static func save(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
