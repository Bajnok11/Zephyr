import SwiftUI
import ZephyrKit

struct ControlPanelView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if state.menuBarUnavailable { menuBarWarning }
                    presetSection
                    if state.effectivePreset.id == Preset.BuiltIn.manual { manualSlider }
                    fanSection
                    trendSection
                    sensorSection
                }
                .padding(14)
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 380)
        .frame(minHeight: 480, maxHeight: 620)
        .background(.ultraThinMaterial)
    }

    // MARK: Header

    private var header: some View {
        let hottest = state.snapshot.hottest
        let temperature = hottest?.celsius ?? 0

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(hottest == nil ? "--" : String(format: "%.0f", temperature))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Thermal.color(temperature))
                    Text("°C")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(hottest?.name ?? "Nincs szenzoradat")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                StatusPill(symbol: controlSymbol, text: state.helperState.title, color: controlColor)
                if state.isOverriddenByAutomation {
                    StatusPill(symbol: "wand.and.stars",
                               text: state.isOnBattery ? "Akkun" : "Hálózaton",
                               color: .orange)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private var controlSymbol: String {
        switch state.helperState {
        case .connected: return "checkmark.circle.fill"
        case .installed: return "pause.circle.fill"
        case .notInstalled: return "lock.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var controlColor: Color {
        switch state.helperState {
        case .connected: return .green
        case .installed: return .secondary
        case .notInstalled: return .orange
        case .failed: return .red
        }
    }

    private var menuBarWarning: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Nincs hely a menüsorban", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            Text("A macOS nem tudta kitenni a Zephyr ikonját, mert a menüsor betelt. Zárj be pár menüsor-ikont, vagy állítsd a kijelzést „Csak ikon”-ra a Beállításokban. Addig ez az ablak a Zephyr indításával bármikor előhívható.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: Presets

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionLabel(text: "Profil")
                Spacer()
                if state.isOverriddenByAutomation {
                    Text("automatizálás felülírja")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(state.presets) { preset in
                    PresetChip(preset: preset,
                               isActive: preset.id == state.settings.activePresetID,
                               isForced: preset.id == state.effectivePresetID && state.isOverriddenByAutomation) {
                        state.select(preset: preset)
                    }
                }
            }
        }
    }

    private var manualSlider: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Kézi fordulatszám")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(Int(state.settings.manualPercent.rounded())) %")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                }
                Slider(value: Binding(
                    get: { state.settings.manualPercent },
                    set: { state.settings.manualPercent = $0 }
                ), in: 0...100, step: 1)
                if let fan = state.snapshot.fans.first {
                    Text("≈ \(Int(fan.rpm(forPercent: state.settings.manualPercent).rounded())) RPM")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Fans

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "Ventilátorok")

            if state.snapshot.fans.isEmpty {
                Card {
                    Text("Nem található vezérelhető ventilátor ezen a gépen.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(state.snapshot.fans) { fan in
                        Card(padding: 10) {
                            VStack(spacing: 7) {
                                RingGauge(progress: fan.load,
                                          gradient: Thermal.accent,
                                          label: "\(Int(fan.currentRPM.rounded()))",
                                          caption: "RPM")
                                    .frame(width: 76, height: 76)

                                Text(fan.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)

                                HStack(spacing: 4) {
                                    Text("\(Int((fan.load * 100).rounded())) %")
                                    Text("·")
                                    Text(fan.isManual ? "vezérelt" : "auto")
                                        .foregroundStyle(fan.isManual ? Color.accentColor : .secondary)
                                }
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: Trend

    private var trendSection: some View {
        let samples = state.history.suffix(90)
        let temperatures = samples.map(\.temperature).filter { $0 > 0 }
        let low = (temperatures.min() ?? 30) - 3
        let high = (temperatures.max() ?? 90) + 3

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionLabel(text: "Alakulás")
                Spacer()
                if let last = temperatures.last {
                    Text("\(Int(low))° – \(Int(high))°")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel("Tartomány, aktuális \(Int(last)) fok")
                }
            }
            Card(padding: 9) {
                VStack(spacing: 5) {
                    Sparkline(values: samples.map(\.temperature),
                              range: low...high,
                              gradient: Thermal.gradient(temperatures.last ?? 50))
                        .frame(height: 42)
                    Sparkline(values: samples.map(\.fanPercent),
                              range: 0...100,
                              gradient: Thermal.accent,
                              filled: false)
                        .frame(height: 18)
                }
            }
        }
    }

    // MARK: Sensors

    private var sensorSection: some View {
        let summary = state.snapshot.groupSummary.filter {
            state.settings.showEfficiencyCores || $0.group != .efficiency
        }

        return VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "Szenzorok")
            Card {
                VStack(spacing: 7) {
                    ForEach(summary, id: \.group) { entry in
                        SensorRow(name: entry.group.title,
                                  symbol: entry.group.symbol,
                                  celsius: entry.reading.celsius)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .notInstalled = state.helperState {
                Button {
                    state.installHelper()
                } label: {
                    Label("Vezérlés bekapcsolása", systemImage: "lock.open")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.isInstallingHelper)
            } else if let error = state.lastError {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(state.subtitle(for: state.effectivePreset))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NotificationCenter.default.post(name: .openZephyrSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Beállítások")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Kilépés")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
