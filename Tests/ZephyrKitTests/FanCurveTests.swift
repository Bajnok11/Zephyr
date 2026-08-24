import XCTest
@testable import ZephyrKit

/// The curve decides how fast the fans run, so its edges matter more than its
/// middle: a wrong answer below the first point or above the last one is the
/// difference between a silent Mac and a throttling one.
final class FanCurveTests: XCTestCase {

    private func curve(_ points: [(Double, Double)]) -> FanCurve {
        FanCurve(source: .hottest, points: points.map { CurvePoint(temperature: $0.0, percent: $0.1) })
    }

    func testHoldsFirstPercentBelowTheFirstPoint() {
        let subject = curve([(50, 10), (80, 100)])
        XCTAssertEqual(subject.percent(at: 20), 10)
        XCTAssertEqual(subject.percent(at: 49.9), 10)
    }

    func testHoldsLastPercentAboveTheLastPoint() {
        let subject = curve([(50, 10), (80, 90)])
        XCTAssertEqual(subject.percent(at: 80), 90)
        XCTAssertEqual(subject.percent(at: 200), 90)
    }

    func testInterpolatesLinearlyBetweenPoints() {
        let subject = curve([(50, 0), (100, 100)])
        XCTAssertEqual(subject.percent(at: 75), 50, accuracy: 0.0001)
        XCTAssertEqual(subject.percent(at: 60), 20, accuracy: 0.0001)
    }

    func testReturnsExactValuesAtThePointsThemselves() {
        let subject = curve([(40, 5), (60, 25), (90, 80)])
        XCTAssertEqual(subject.percent(at: 40), 5, accuracy: 0.0001)
        XCTAssertEqual(subject.percent(at: 60), 25, accuracy: 0.0001)
        XCTAssertEqual(subject.percent(at: 90), 80, accuracy: 0.0001)
    }

    func testAcceptsPointsGivenOutOfOrder() {
        let subject = curve([(90, 80), (40, 5), (60, 25)])
        XCTAssertEqual(subject.percent(at: 50), 15, accuracy: 0.0001)
    }

    func testHandlesDuplicateTemperaturesWithoutDividingByZero() {
        let subject = curve([(60, 20), (60, 80), (90, 100)])
        let value = subject.percent(at: 60)
        XCTAssertTrue(value.isFinite)
        XCTAssertTrue(value >= 20 && value <= 80)
    }

    func testSinglePointBehavesAsAConstant() {
        let subject = curve([(70, 42)])
        XCTAssertEqual(subject.percent(at: 20), 42)
        XCTAssertEqual(subject.percent(at: 70), 42)
        XCTAssertEqual(subject.percent(at: 120), 42)
    }

    func testEmptyCurveIsSilentRatherThanCrashing() {
        let subject = curve([])
        XCTAssertEqual(subject.percent(at: 80), 0)
    }

    func testNormalizeSortsAndClampsIntoTheEditableRange() {
        var subject = curve([(500, 250), (5, -80), (70, 50)])
        subject.normalize()

        XCTAssertEqual(subject.points.map(\.temperature), [20, 70, 110])
        XCTAssertEqual(subject.points.map(\.percent), [0, 50, 100])
    }

    /// The built-in presets ship as code, so a bad edit to one of them is a
    /// silent behaviour change for every user who never customised anything.
    func testBuiltInCurvesAreMonotonicAndInRange() {
        for preset in Preset.builtIns {
            guard case .curve(let curve) = preset.mode else { continue }
            let points = curve.points.sorted { $0.temperature < $1.temperature }

            XCTAssertGreaterThan(points.count, 1, "\(preset.name) needs at least two points")
            for point in points {
                XCTAssertTrue((0...100).contains(point.percent), "\(preset.name) has a percent out of range")
                XCTAssertTrue((20...110).contains(point.temperature), "\(preset.name) has a temperature out of range")
            }
            for (a, b) in zip(points, points.dropFirst()) {
                XCTAssertLessThanOrEqual(a.percent, b.percent,
                                         "\(preset.name) asks for less airflow as it gets hotter")
            }
            XCTAssertEqual(points.last?.percent, 100, "\(preset.name) never reaches full speed")
        }
    }
}
