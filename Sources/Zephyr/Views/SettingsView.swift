import SwiftUI
import ZephyrKit

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var section: Section = .presets

    enum Section: String, CaseIterable, Identifiable {
        case presets, sensors, automation, general
        var id: String { rawValue }

        var title: String {
            switch self {
            case .presets: return "Presets"
            case .sensors: return "Sensors"
            case .automation: return "Automation"
            case .general: return "General"
            }
        }

        var symbol: String {
            switch self {
            case .presets: return "dial.medium"
            case .sensors: return "thermometer.medium"
            case .automation: return "wand.and.stars"
            case .general: return "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch section {
                case .presets: PresetSettings()
                case .sensors: SensorSettings()
                case .automation: AutomationSettings()
                case .general: GeneralSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Thermal.accent)
                    Image(nsImage: FanIcon.image(size: 15, angle: 0.4))
                        .renderingMode(.template)
                        .foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Zephyr").font(.system(size: 13, weight: .semibold))
                    Text(state.effectivePreset.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .padding(.top, 22)

            ForEach(Section.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .frame(width: 17)
                            .foregroundStyle(section == item ? Color.white : Color.accentColor)
                        Text(item.title)
                            .font(.system(size: 12.5))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundStyle(section == item ? Color.white : Color.primary)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(section == item ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let temperature = state.snapshot.hottest?.celsius {
                HStack(spacing: 6) {
                    Circle().fill(Thermal.color(temperature)).frame(width: 7, height: 7)
                    Text(String(format: "%.0f °C", temperature))
                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    Spacer()
                    Text("\(Int(state.maxFanRPM.rounded())) RPM")
                        .font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 196)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Presets

private struct PresetSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedID: UUID?

    private var selected: Preset? {
        state.presets.first { $0.id == (selectedID ?? state.settings.activePresetID) }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 190, maxWidth: 230)
            detail
                .frame(minWidth: 420)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(state.presets) { preset in
                    HStack(spacing: 8) {
                        Image(systemName: preset.symbol)
                            .foregroundStyle(preset.color)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name).font(.system(size: 12))
                            Text(state.subtitle(for: preset))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if preset.id == state.settings.activePresetID {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tint)
                        }
                    }
                    .tag(preset.id)
                    .contextMenu {
                        Button("Activate") { state.select(preset: preset) }
                        Button("Duplicate") { selectedID = state.duplicate(preset: preset).id }
                        if !preset.isBuiltIn {
                            Divider()
                            Button("Delete", role: .destructive) { state.delete(preset: preset) }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    let new = state.duplicate(preset: selected ?? .balanced)
                    selectedID = new.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("New preset as a copy of the selected one")

                Button {
                    if let selected, !selected.isBuiltIn {
                        state.delete(preset: selected)
                        selectedID = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selected?.isBuiltIn ?? true)
                .help("Delete preset")

                Spacer()

                Button("Activate") {
                    if let selected { state.select(preset: selected) }
                }
                .controlSize(.small)
                .disabled(selected == nil || selected?.id == state.settings.activePresetID)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let preset = selected {
            PresetEditor(preset: preset)
                .id(preset.id)
        } else {
            ContentUnavailableView("Select a preset", systemImage: "dial.medium")
        }
    }
}

private struct PresetEditor: View {
    @EnvironmentObject private var state: AppState
    let preset: Preset

    @State private var draft: Preset
    @State private var isCurveMode = true

    init(preset: Preset) {
        self.preset = preset
        _draft = State(initialValue: preset)
        if case .fixed = preset.mode {
            _isCurveMode = State(initialValue: false)
        }
    }

    private var isEditable: Bool { !draft.isBuiltIn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if draft.isBuiltIn, draft.id != Preset.BuiltIn.manual, draft.id != Preset.BuiltIn.system {
                    Label("Built-in presets cannot be edited. Duplicate one to make changes.",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }

                if draft.id == Preset.BuiltIn.system {
                    Text("This preset hands control back to the macOS firmware. Zephyr only observes.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if draft.id == Preset.BuiltIn.manual {
                    manualEditor
                } else {
                    modeEditor
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: draft) { _, newValue in
            guard isEditable else { return }
            state.upsert(preset: newValue)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [draft.color, draft.color.opacity(0.65)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: draft.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                if isEditable {
                    TextField("Preset name", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .semibold))
                } else {
                    Text(draft.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                }
                Text(state.subtitle(for: draft))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isEditable {
                Picker("", selection: $draft.tint) {
                    ForEach(Preset.tintOptions, id: \.self) { tint in
                        Text(tint.capitalized).tag(tint)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
            }

            Button(draft.id == state.settings.activePresetID ? "Active" : "Activate") {
                state.select(preset: draft)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(draft.id == state.settings.activePresetID)
        }
    }

    private var manualEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual fan speed")
                .font(.system(size: 12, weight: .medium))
            HStack {
                Slider(value: Binding(get: { state.settings.manualPercent },
                                      set: { state.settings.manualPercent = $0 }), in: 0...100, step: 1)
                Text("\(Int(state.settings.manualPercent.rounded())) %")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            if let fan = state.snapshot.fans.first {
                Text("\(fan.name): ≈ \(Int(fan.rpm(forPercent: state.settings.manualPercent).rounded())) RPM (range \(Int(fan.minRPM))–\(Int(fan.maxRPM)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modeEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isEditable {
                Picker("", selection: $isCurveMode) {
                    Text("Temperature curve").tag(true)
                    Text("Fixed speed").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .onChange(of: isCurveMode) { _, newValue in
                    switch (newValue, draft.mode) {
                    case (true, .fixed):
                        draft.mode = .curve(FanCurve(source: .hottest, points: [
                            CurvePoint(temperature: 45, percent: 0),
                            CurvePoint(temperature: 70, percent: 30),
                            CurvePoint(temperature: 88, percent: 80),
                            CurvePoint(temperature: 97, percent: 100),
                        ]))
                    case (false, .curve):
                        draft.mode = .fixed(percent: 50)
                    default:
                        break
                    }
                }
            }

            switch draft.mode {
            case .curve(let curve):
                curveSection(curve)
            case .fixed(let percent):
                fixedSection(percent)
            case .system:
                EmptyView()
            }
        }
    }

    private func curveSection(_ curve: FanCurve) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Driving sensor")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if isEditable {
                    CurveSourcePicker(source: Binding(
                        get: { curve.source },
                        set: { newSource in
                            var updated = curve
                            updated.source = newSource
                            draft.mode = .curve(updated)
                        }), availableKeys: state.allSensorKeys)
                } else {
                    Text(curve.source.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            CurveEditorView(
                curve: Binding(
                    get: { curve },
                    set: { draft.mode = .curve($0) }
                ),
                currentTemperature: state.snapshot.temperature(for: curve.source),
                fan: state.snapshot.fans.first
            )
            .disabled(!isEditable)
            .opacity(isEditable ? 1 : 0.75)
        }
    }

    private func fixedSection(_ percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fixed fan speed")
                .font(.system(size: 12, weight: .medium))
            HStack {
                if isEditable {
                    Slider(value: Binding(get: { percent },
                                          set: { draft.mode = .fixed(percent: $0) }), in: 0...100, step: 1)
                } else {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(Thermal.accent)
                                .frame(width: geometry.size.width * percent / 100)
                        }
                    }
                    .frame(height: 6)
                }
                Text("\(Int(percent.rounded())) %")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            if let fan = state.snapshot.fans.first {
                Text("≈ \(Int(fan.rpm(forPercent: percent).rounded())) RPM")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sensors

private struct SensorSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var search = ""

    private var filtered: [SensorReading] {
        let readings = state.snapshot.sensors
        guard !search.isEmpty else { return readings }
        let needle = search.lowercased()
        return readings.filter {
            $0.name.lowercased().contains(needle) || $0.key.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by name or SMC key", text: $search)
                    .textFieldStyle(.plain)
                Spacer()
                Text("\(filtered.count) / \(state.snapshot.sensors.count) sensors")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            List {
                ForEach(SensorGroup.allCases, id: \.self) { group in
                    let readings = filtered.filter { $0.group == group }.sorted { $0.celsius > $1.celsius }
                    if !readings.isEmpty {
                        SwiftUI.Section {
                            ForEach(readings) { reading in
                                HStack(spacing: 10) {
                                    Text(reading.key)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 46, alignment: .leading)
                                    Text(reading.name)
                                        .font(.system(size: 11.5))
                                    Spacer()
                                    Text(String(format: "%.1f °C", reading.celsius))
                                        .font(.system(size: 11.5, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(Thermal.color(reading.celsius))
                                }
                            }
                        } header: {
                            Label(group.title, systemImage: group.symbol)
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Automation

private struct AutomationSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Switch preset by power source", isOn: Binding(
                    get: { state.settings.automation.enabled },
                    set: { state.settings.automation.enabled = $0 }
                ))

                Picker("On battery", selection: Binding(
                    get: { state.settings.automation.onBattery ?? Preset.BuiltIn.system },
                    set: { state.settings.automation.onBattery = $0 }
                )) {
                    ForEach(state.presets) { Text($0.name).tag($0.id) }
                }
                .disabled(!state.settings.automation.enabled)

                Picker("On mains", selection: Binding(
                    get: { state.settings.automation.onPower ?? Preset.BuiltIn.system },
                    set: { state.settings.automation.onPower = $0 }
                )) {
                    ForEach(state.presets) { Text($0.name).tag($0.id) }
                }
                .disabled(!state.settings.automation.enabled)
            } header: {
                Text("Power source")
            } footer: {
                Text(state.isOnBattery ? "Currently running on battery." : "Currently running on mains.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Toggle("Emergency cooling above a threshold", isOn: Binding(
                    get: { state.settings.automation.emergencyEnabled },
                    set: { state.settings.automation.emergencyEnabled = $0 }
                ))

                HStack {
                    Text("Threshold")
                    Slider(value: Binding(
                        get: { state.settings.automation.emergencyTemperature },
                        set: { state.settings.automation.emergencyTemperature = $0 }
                    ), in: 85...110, step: 1)
                    .disabled(!state.settings.automation.emergencyEnabled)
                    Text("\(Int(state.settings.automation.emergencyTemperature)) °C")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("Above the threshold the fans go to 100 % whatever the preset says, and only step back down 4 °C below it.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            SwiftUI.Section("Menu bar") {
                Picker("Display", selection: Binding(
                    get: { state.settings.menuBarStyle },
                    set: { state.settings.menuBarStyle = $0 }
                )) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }

                HStack {
                    Text("Temperature source")
                    Spacer()
                    CurveSourcePicker(source: Binding(
                        get: { state.settings.menuBarSource },
                        set: { state.settings.menuBarSource = $0 }
                    ), availableKeys: state.allSensorKeys)
                }

                Toggle("Spin the icon with fan load", isOn: Binding(
                    get: { state.settings.animateIcon },
                    set: { state.settings.animateIcon = $0 }
                ))

                Toggle("Show E-cores separately", isOn: Binding(
                    get: { state.settings.showEfficiencyCores },
                    set: { state.settings.showEfficiencyCores = $0 }
                ))
            }

            SwiftUI.Section {
                HStack {
                    Text("Ramp step")
                    Slider(value: Binding(
                        get: { state.settings.rampStep },
                        set: { state.settings.rampStep = $0 }
                    ), in: 50...1200, step: 10)
                    Text("\(Int(state.settings.rampStep)) RPM/mp")
                        .monospacedDigit()
                        .frame(width: 92, alignment: .trailing)
                }

                Toggle("Launch at login", isOn: Binding(
                    get: { state.settings.launchAtLogin },
                    set: { state.settings.launchAtLogin = $0 }
                ))
            } header: {
                Text("Behaviour")
            } footer: {
                Text("A smaller step is quieter but follows temperature more slowly.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                HStack(spacing: 10) {
                    Image(systemName: helperSymbol)
                        .foregroundStyle(helperColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.helperState.title)
                            .font(.system(size: 12, weight: .medium))
                        Text("Writing to the fans needs a root helper service. macOS asks for your password in its own dialog.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                if state.helperIsStale {
                    Label("The installed service is older than the one this app ships with — run Reinstall.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(HelperClient.isInstalled ? "Reinstall" : "Install") {
                        state.installHelper()
                    }
                    .disabled(state.isInstallingHelper)

                    Button("Remove") {
                        state.uninstallHelper()
                    }
                    .disabled(!HelperClient.isInstalled || state.isInstallingHelper)

                    if state.isInstallingHelper {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            } header: {
                Text("Control service")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = state.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                    Text("If the service stops or Zephyr quits, the fans go straight back under macOS control.")
                }
                .font(.system(size: 10.5))
            }

            SwiftUI.Section("Zephyr") {
                LabeledContent("Version", value: "1.0")
                LabeledContent("Mac", value: hardwareModel)
                LabeledContent("Fans", value: "\(state.snapshot.fans.count)")
                LabeledContent("Sensors", value: "\(state.snapshot.sensors.count)")
            }
        }
        .formStyle(.grouped)
    }

    private var helperSymbol: String {
        switch state.helperState {
        case .connected: return "checkmark.seal.fill"
        case .installed: return "seal"
        case .notInstalled: return "lock.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var helperColor: Color {
        switch state.helperState {
        case .connected: return .green
        case .installed: return .secondary
        case .notInstalled: return .orange
        case .failed: return .red
        }
    }

    private var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
