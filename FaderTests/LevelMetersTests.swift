import XCTest
@testable import Fader

final class LevelMetersTests: XCTestCase {
    func testNormalizesOnDecibelScale() {
        XCTAssertEqual(LevelMeters.normalized(0), 0)
        XCTAssertEqual(LevelMeters.normalized(1), 1, accuracy: 1e-6)
        XCTAssertEqual(LevelMeters.normalized(0.001), 0, accuracy: 1e-6, "-60 dB is the floor")
        XCTAssertEqual(LevelMeters.normalized(0.5), 1 - 6.0206 / 60, accuracy: 1e-3, "-6 dB")
        XCTAssertEqual(LevelMeters.normalized(2), 1, "clamped")
    }

    func testRisesInstantlyAndFallsGradually() {
        XCTAssertEqual(LevelMeters.smooth(0.9, previous: 0.1), 0.9)
        XCTAssertEqual(LevelMeters.smooth(0, previous: 0.9), 0.9 - LevelMeters.fallPerUpdate, accuracy: 1e-6)
        XCTAssertEqual(LevelMeters.smooth(0, previous: 0.01), 0)
    }

    @MainActor
    func testOutputIsLoudestApp() {
        let meters = LevelMeters()
        meters.update(apps: ["a": 0.1, "b": 1], mic: 0)
        XCTAssertEqual(meters.output, 1, accuracy: 1e-6)
        meters.reset()
        XCTAssertEqual(meters.output, 0)
    }
}
