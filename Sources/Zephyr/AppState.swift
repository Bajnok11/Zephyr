import Foundation
import Combine
import IOKit.ps
import ServiceManagement
import ZephyrKit

// MARK: - Helper state

enum HelperState: Equatable {
    case notInstalled
    case installed
    case connected
    case failed(String)

    var canControl: Bool { self == .connected }

    var title: String {
        switch self {
        case .notInstalled: return "Control not installed"
        case .installed: return "Service available"
        case .connected: return "Control active"
        case .failed(let reason): return reason
        }
    }
}

struct HistorySample: Identifiable {
    let id = UUID()
    let date: Date
    let temperature: Double
    let fanPercent: Double
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {

    @Published private(set) var snapshot = HardwareSnapshot()
    @Published private(set) var helperState: HelperState = .notInstalled
    @Published private(set) var history: [HistorySample] = []
    @Published private(set) var isOnBattery = false
    @Published private(set) var lastError: String?
    @Published var isInstallingHelper = false
    /// Set when macOS could not fit our icon into the menu bar.
    @Published private(set) var menuBarUnavailable = false
    /// Set when the installed root helper is an older build than this app ships.
    @Published private(set) var helperIsStale = false

    func reportMenuBarUnavailable() {
        menuBarUnavailable = true
    }

    @Published var settings: Settings {
        didSet {
            SettingsStore.save(settings)
            syncLaunchAtLogin(oldValue: oldValue)
        }
    }

    /// The preset actually in force — automation can override the user's pick.
    @Published private(set) var effectivePresetID: UUID

    private let queue = DispatchQueue(label: "com.bence.zephyr.monitor", qos: .utility)
    private let helper = HelperClient()
    private var monitor: HardwareMonitor?
    private var timer: Timer?
    private var commandedRPM: [Int: Double] = [:]
    private var hasControl = false
    private var emergencyActive = false

    private let maxHistory = 180

    init() {
        var loaded = SettingsStore.load()
        loaded.mergeBuiltIns()
        settings = loaded
        effectivePresetID = loaded.activePresetID

        refreshHelperState()
        start()

        // Sensor discovery walks every SMC key — a couple of thousand of them,
        // two round trips each. Doing that on the main thread stalls launch for
        // seconds, and a status item created after that stall gets mis-placed
        // by the window server. Discover in the background instead; `tick()`
        // no-ops until the monitor is ready.
        queue.async { [weak self] in
            let created: HardwareMonitor?
            var failure: String?
            do {
                created = try HardwareMonitor()
            } catch {
                created = nil
                failure = error.localizedDescription
            }
            Task { @MainActor in
                guard let self else { return }
                self.monitor = created
                self.lastError = failure
                self.tick()
            }
        }
    }

    // MARK: Presets

    var presets: [Preset] { settings.presets }

    var activePreset: Preset {
        settings.presets.first { $0.id == settings.activePresetID } ?? .systemPreset
    }

    var effectivePreset: Preset {
        settings.presets.first { $0.id == effectivePresetID } ?? .systemPreset
    }

    /// The manual preset's percentage lives outside the preset, so its subtitle
    /// has to be assembled here rather than by `Preset` itself.
    func subtitle(for preset: Preset) -> String {
        preset.id == Preset.BuiltIn.manual
            ? "Fixed \(Int(settings.manualPercent.rounded())) %"
            : preset.subtitle
    }

    var isOverriddenByAutomation: Bool {
        settings.automation.enabled && effectivePresetID != settings.activePresetID
    }

    func select(preset: Preset) {
        settings.activePresetID = preset.id
        tick()
    }

    func upsert(preset: Preset) {
        if let index = settings.presets.firstIndex(where: { $0.id == preset.id }) {
            settings.presets[index] = preset
        } else {
            settings.presets.append(preset)
        }
        tick()
    }

    func delete(preset: Preset) {
        guard !preset.isBuiltIn else { return }
        settings.presets.removeAll { $0.id == preset.id }
        if settings.activePresetID == preset.id {
            settings.activePresetID = Preset.BuiltIn.system
        }
        tick()
    }

    func duplicate(preset: Preset) -> Preset {
        var copy = preset
        copy.id = UUID()
        copy.name = preset.name + " copy"
        copy.isBuiltIn = false
        if case .system = copy.mode {
            copy.mode = .curve(FanCurve(source: .hottest, points: [
                CurvePoint(temperature: 45, percent: 0),
                CurvePoint(temperature: 65, percent: 20),
                CurvePoint(temperature: 80, percent: 55),
                CurvePoint(temperature: 92, percent: 100),
            ]))
        }
        upsert(preset: copy)
        return copy
    }

    // MARK: Lifecycle

    private func start() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func shutdown() {
        timer?.invalidate()
        releaseControl()
        helper.disconnect()
    }

    // MARK: Poll + control

    func tick() {
        guard let monitor else { return }
        isOnBattery = Self.runningOnBattery()

        queue.async { [weak self] in
            let snapshot = monitor.snapshot()
            Task { @MainActor in
                self?.apply(snapshot: snapshot)
            }
        }
    }

    private func apply(snapshot: HardwareSnapshot) {
        self.snapshot = snapshot
        resolveEffectivePreset()
        drive(with: snapshot)
        record(snapshot: snapshot)
    }

    private func resolveEffectivePreset() {
        guard settings.automation.enabled else {
            effectivePresetID = settings.activePresetID
            return
        }
        let ruleID = isOnBattery ? settings.automation.onBattery : settings.automation.onPower
        effectivePresetID = ruleID ?? settings.activePresetID
    }

    private func record(snapshot: HardwareSnapshot) {
        let temperature = snapshot.temperature(for: settings.menuBarSource) ?? 0
        let percent = snapshot.fans.map { $0.load * 100 }.max() ?? 0
        history.append(HistorySample(date: snapshot.timestamp, temperature: temperature, fanPercent: percent))
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
    }

    /// Fan speed the active preset asks for, as a percentage — nil means "let macOS decide".
    func desiredPercent(for snapshot: HardwareSnapshot) -> Double? {
        let preset = effectivePreset

        if settings.automation.emergencyEnabled,
           let hottest = snapshot.hottest,
           hottest.celsius >= settings.automation.emergencyTemperature {
            emergencyActive = true
            return 100
        }
        // Re-arm with 4 °C of hysteresis so we do not oscillate at the threshold.
        if emergencyActive {
            let hottest = snapshot.hottest?.celsius ?? 0
            if hottest > settings.automation.emergencyTemperature - 4 { return 100 }
            emergencyActive = false
        }

        // The manual preset's percentage lives in Settings so the slider survives
        // the built-in presets being re-seeded on every launch.
        if preset.id == Preset.BuiltIn.manual { return settings.manualPercent }

        switch preset.mode {
        case .system:
            return nil
        case .fixed(let percent):
            return percent
        case .curve(let curve):
            guard let temperature = snapshot.temperature(for: curve.source) else { return nil }
            return curve.percent(at: temperature)
        }
    }

    private func drive(with snapshot: HardwareSnapshot) {
        guard let percent = desiredPercent(for: snapshot) else {
            releaseControl()
            return
        }
        guard !snapshot.fans.isEmpty else { return }

        do {
            if !hasControl {
                _ = try helper.send(.hello)
                hasControl = true
            }
            for fan in snapshot.fans {
                let target = fan.rpm(forPercent: percent)
                let previous = commandedRPM[fan.index] ?? fan.currentRPM
                let step = max(settings.rampStep, 20)
                let ramped = min(max(target, previous - step), previous + step)
                _ = try helper.send(.set(fan: fan.index, rpm: ramped))
                commandedRPM[fan.index] = ramped
            }
            if helperState != .connected { helperState = .connected }
            lastError = nil
        } catch {
            hasControl = false
            commandedRPM.removeAll()
            helper.disconnect()
            if case HelperClient.ClientError.notInstalled = error {
                helperState = .notInstalled
            } else {
                helperState = .failed(error.localizedDescription)
            }
        }
    }

    private func releaseControl() {
        guard hasControl else {
            if helperState == .connected { helperState = HelperClient.isInstalled ? .installed : .notInstalled }
            return
        }
        _ = try? helper.send(.autoAll)
        helper.disconnect()
        hasControl = false
        commandedRPM.removeAll()
        helperState = HelperClient.isInstalled ? .installed : .notInstalled
    }

    // MARK: Helper installation

    func refreshHelperState() {
        if !HelperClient.isInstalled {
            helperState = .notInstalled
        } else if helperState == .notInstalled {
            helperState = .installed
        }
        // Comparing two 500 KB binaries, so do it on state changes only —
        // never from a SwiftUI body.
        helperIsStale = HelperClient.installedHelperIsStale
    }

    func installHelper() {
        guard !isInstallingHelper else { return }
        isInstallingHelper = true
        lastError = nil

        let script = Bundle.main.path(forResource: "install-helper", ofType: "sh")
        let binary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/zephyr-helper").path
        let uid = getuid()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runPrivileged(script: script, arguments: [binary, "\(uid)"])
            Task { @MainActor in
                self.isInstallingHelper = false
                switch result {
                case .success:
                    self.helperState = .installed
                    self.refreshHelperState()
                    self.tick()
                case .failure(let message):
                    self.lastError = message
                    self.helperState = .failed(message)
                }
            }
        }
    }

    func uninstallHelper() {
        releaseControl()
        let script = Bundle.main.path(forResource: "uninstall-helper", ofType: "sh")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runPrivileged(script: script, arguments: [])
            Task { @MainActor in
                if case .failure(let message) = result { self.lastError = message }
                self.helperState = HelperClient.isInstalled ? .installed : .notInstalled
            }
        }
    }

    private enum PrivilegedResult {
        case success(String)
        case failure(String)
    }

    /// Runs a shell script through the standard macOS authorisation prompt.
    /// The password is typed into the system dialog — it never passes through Zephyr.
    private static func runPrivileged(script: String?, arguments: [String]) -> PrivilegedResult {
        guard let script else { return .failure("The installer script is missing from the app bundle.") }
        let quoted = ([script] + arguments)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let command = "/bin/sh " + quoted
        let source = """
        do shell script "\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))" with administrator privileges
        """

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else {
            return .failure("Could not prepare the installation.")
        }
        let output = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
            if number == -128 { return .failure("Installation cancelled.") }
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "unknown error"
            return .failure(message)
        }
        return .success(output.stringValue ?? "")
    }

    // MARK: Login item

    private func syncLaunchAtLogin(oldValue: Settings) {
        guard settings.launchAtLogin != oldValue.launchAtLogin else { return }
        do {
            if settings.launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
    }

    // MARK: Power

    private static func runningOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    // MARK: Convenience for views

    var headlineTemperature: Double? {
        snapshot.temperature(for: settings.menuBarSource)
    }

    var averageFanPercent: Double {
        guard !snapshot.fans.isEmpty else { return 0 }
        return snapshot.fans.map { $0.load * 100 }.reduce(0, +) / Double(snapshot.fans.count)
    }

    var maxFanRPM: Double {
        snapshot.fans.map(\.currentRPM).max() ?? 0
    }

    var allSensorKeys: [(key: String, name: String, group: SensorGroup)] {
        monitor?.knownSensorKeys ?? []
    }
}
