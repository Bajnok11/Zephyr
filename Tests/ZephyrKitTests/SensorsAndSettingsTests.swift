import XCTest
@testable import ZephyrKit

final class SensorCatalogTests: XCTestCase {

    func testRecognisesAppleSiliconNamingScheme() {
        XCTAssertEqual(SensorCatalog.describe(key: "Tp0M")?.group, .cpu)
        XCTAssertEqual(SensorCatalog.describe(key: "Te02")?.group, .efficiency)
        XCTAssertEqual(SensorCatalog.describe(key: "Tg0D")?.group, .gpu)
        XCTAssertEqual(SensorCatalog.describe(key: "Tm05")?.group, .memory)
        XCTAssertEqual(SensorCatalog.describe(key: "TH0a")?.group, .storage)
    }

    func testExplicitlyNamedKeysWinOverThePrefixRules() {
        // "Ts" would otherwise fall through to the generic enclosure rule.
        XCTAssertEqual(SensorCatalog.describe(key: "Ts0P")?.name, "Enclosure – left palm rest")
        XCTAssertEqual(SensorCatalog.describe(key: "TB0T")?.name, "Battery 1")
    }

    func testRejectsKeysThatAreNotTemperatures() {
        XCTAssertNil(SensorCatalog.describe(key: "F0Ac"))
        XCTAssertNil(SensorCatalog.describe(key: "#KEY"))
        XCTAssertNil(SensorCatalog.describe(key: "Tp"))
        XCTAssertNil(SensorCatalog.describe(key: "TZZZZ"))
    }

    /// Unpopulated sensors read as a constant 0 or an absurd value; showing them
    /// would put a fake "0 °C" or "200 °C" in front of the user.
    func testFiltersImplausibleReadings() {
        XCTAssertFalse(SensorCatalog.isPlausible(0))
        XCTAssertFalse(SensorCatalog.isPlausible(200))
        XCTAssertTrue(SensorCatalog.isPlausible(45))
        XCTAssertTrue(SensorCatalog.isPlausible(99.5))
    }

    func testHottestIgnoresSlowMovingSensors() {
        let readings = [
            SensorReading(key: "Tp01", name: "CPU", group: .cpu, celsius: 70),
            SensorReading(key: "TB0T", name: "Battery", group: .battery, celsius: 95),
            SensorReading(key: "TaLP", name: "Airflow", group: .ambient, celsius: 90),
        ]
        // The battery and airflow readings are hotter but must not drive a curve.
        XCTAssertEqual(CurveSource.hottest.temperature(in: readings), 70)
    }

    func testGroupSourcePicksTheHottestWithinThatGroup() {
        let readings = [
            SensorReading(key: "Tp01", name: "P1", group: .cpu, celsius: 70),
            SensorReading(key: "Tp02", name: "P2", group: .cpu, celsius: 84),
            SensorReading(key: "Tg01", name: "GPU", group: .gpu, celsius: 60),
        ]
        XCTAssertEqual(CurveSource.group(.cpu).temperature(in: readings), 84)
        XCTAssertEqual(CurveSource.group(.gpu).temperature(in: readings), 60)
        XCTAssertNil(CurveSource.group(.storage).temperature(in: readings))
    }

    func testSpecificKeySourceResolvesExactly() {
        let readings = [SensorReading(key: "Tp01", name: "P1", group: .cpu, celsius: 70)]
        XCTAssertEqual(CurveSource.key("Tp01").temperature(in: readings), 70)
        XCTAssertNil(CurveSource.key("Tp99").temperature(in: readings))
    }

    func testCurveSourceSurvivesAJSONRoundTrip() throws {
        for source in [CurveSource.hottest, .group(.gpu), .key("Tp0M")] {
            let data = try JSONEncoder().encode(source)
            XCTAssertEqual(try JSONDecoder().decode(CurveSource.self, from: data), source)
        }
    }
}

final class FanTests: XCTestCase {

    private let fan = Fan(index: 0, name: "Left fan", minRPM: 1200, maxRPM: 5779,
                          currentRPM: 3000, targetRPM: 3000, isManual: false)

    func testPercentAndRPMAreInverses() {
        for percent in stride(from: 0.0, through: 100.0, by: 12.5) {
            let rpm = fan.rpm(forPercent: percent)
            XCTAssertEqual(fan.percent(forRPM: rpm), percent, accuracy: 0.0001)
        }
    }

    func testPercentMapsOntoTheHardwareRangeNotZeroToMax() {
        XCTAssertEqual(fan.rpm(forPercent: 0), 1200)
        XCTAssertEqual(fan.rpm(forPercent: 100), 5779)
    }

    func testOutOfRangeRequestsAreClamped() {
        XCTAssertEqual(fan.rpm(forPercent: -20), 1200)
        XCTAssertEqual(fan.rpm(forPercent: 400), 5779)
        XCTAssertEqual(fan.percent(forRPM: 0), 0)
        XCTAssertEqual(fan.percent(forRPM: 99_999), 100)
    }

    func testDegenerateFanRangeDoesNotDivideByZero() {
        let stuck = Fan(index: 0, name: "Fan", minRPM: 2000, maxRPM: 2000,
                        currentRPM: 2000, targetRPM: 2000, isManual: false)
        XCTAssertEqual(stuck.load, 0)
        XCTAssertEqual(stuck.percent(forRPM: 2000), 0)
    }
}

final class SettingsTests: XCTestCase {

    /// Losing every preference because a newer build added one field would be a
    /// poor trade, so decoding is deliberately tolerant.
    func testDecodingToleratesAFileMissingNewerKeys() throws {
        let json = """
        { "activePresetID": "00000000-0000-0000-0000-000000000003" }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(Settings.self, from: json)
        XCTAssertEqual(settings.activePresetID, Preset.BuiltIn.balanced)
        XCTAssertEqual(settings.manualPercent, Settings().manualPercent)
        XCTAssertEqual(settings.menuBarStyle, Settings().menuBarStyle)
    }

    func testSettingsSurviveARoundTrip() throws {
        var original = Settings()
        original.manualPercent = 73
        original.menuBarStyle = .both
        original.rampStep = 500

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(decoded.manualPercent, 73)
        XCTAssertEqual(decoded.menuBarStyle, .both)
        XCTAssertEqual(decoded.rampStep, 500)
    }

    func testBuiltInsAreReseededAndCustomPresetsKept() {
        var settings = Settings(presets: [], activePresetID: UUID())
        let custom = Preset(name: "Mine", symbol: "star", tint: "pink",
                            mode: .fixed(percent: 30), isBuiltIn: false)
        settings.presets = [custom]
        settings.mergeBuiltIns()

        XCTAssertEqual(settings.presets.filter(\.isBuiltIn).count, Preset.builtIns.count)
        XCTAssertTrue(settings.presets.contains { $0.id == custom.id })
        // The stored active preset no longer exists, so it falls back to Automatic.
        XCTAssertEqual(settings.activePresetID, Preset.BuiltIn.system)
    }

    func testMergeKeepsAValidActivePreset() {
        var settings = Settings(presets: [], activePresetID: Preset.BuiltIn.turbo)
        settings.mergeBuiltIns()
        XCTAssertEqual(settings.activePresetID, Preset.BuiltIn.turbo)
    }

    func testBuiltInPresetIDsAreUnique() {
        let ids = Preset.builtIns.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testOnlyAutomaticHandsControlBack() {
        for preset in Preset.builtIns {
            XCTAssertEqual(preset.requiresControl, preset.id != Preset.BuiltIn.system,
                           "\(preset.name) has the wrong control requirement")
        }
    }
}

final class SnapshotTests: XCTestCase {

    func testGroupSummaryReportsTheHottestReadingPerGroup() {
        let snapshot = HardwareSnapshot(fans: [], sensors: [
            SensorReading(key: "Tp01", name: "P1", group: .cpu, celsius: 70),
            SensorReading(key: "Tp02", name: "P2", group: .cpu, celsius: 88),
            SensorReading(key: "Tg01", name: "GPU", group: .gpu, celsius: 61),
        ])

        let summary = Dictionary(uniqueKeysWithValues: snapshot.groupSummary.map { ($0.group, $0.reading.celsius) })
        XCTAssertEqual(summary[.cpu], 88)
        XCTAssertEqual(summary[.gpu], 61)
        XCTAssertNil(summary[.battery])
    }

    func testEmptySnapshotHasNoHottestReading() {
        XCTAssertNil(HardwareSnapshot().hottest)
        XCTAssertNil(HardwareSnapshot().temperature(for: .hottest))
    }
}
