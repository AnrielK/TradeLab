import XCTest
@testable import Backtest

/// Očekávané vstupy spočítané referenční implementací v Pythonu (stejná řada jako u `BreakoutTests`).
final class MABounceTests: XCTestCase {
    private func signals(_ seed: UInt64, _ settings: MABounceSettings = MABounceSettings(),
                         allowShort: Bool = true) -> [String] {
        MABounceStrategy.evaluate(BreakoutTests.series(seed: seed), settings: settings, allowShort: allowShort)
            .signals.map { "\($0.index) \($0.period) \($0.direction)" }
    }

    func testDefaultEntries() {
        XCTAssertEqual(signals(1), ["235 20 1", "551 200 -1", "621 20 1"])
        XCTAssertEqual(signals(4), ["603 100 1"])
        XCTAssertEqual(signals(7), ["414 20 1", "474 20 1", "574 50 1"])
        XCTAssertEqual(signals(10), ["664 200 1"])
        XCTAssertEqual(signals(13), ["289 100 1", "482 20 -1"])
        XCTAssertEqual(signals(17), ["507 50 1"])
    }

    func testPositionChanges() {
        for (seed, changes) in [(1, 6), (4, 2), (7, 6), (10, 1), (13, 4), (17, 2)] as [(UInt64, Int)] {
            let t = MABounceStrategy.evaluate(BreakoutTests.series(seed: seed), settings: MABounceSettings(),
                                              allowShort: true).targets
            XCTAssertEqual((1..<t.count).filter { t[$0] != t[$0 - 1] }.count, changes, "seed \(seed)")
        }
    }

    func testShortStopAndTarget() {
        let s = MABounceStrategy.evaluate(BreakoutTests.series(seed: 1), settings: MABounceSettings(),
                                          allowShort: true).signals[1]
        XCTAssertEqual(s.direction, -1)
        XCTAssertEqual(s.stop, 139.935793, accuracy: 1e-5)
        XCTAssertEqual(s.target, 133.415409, accuracy: 1e-5)
        XCTAssertGreaterThan(s.stop, s.price)
        XCTAssertLessThan(s.target, s.price)
    }

    func testWithoutPriorTest() {
        XCTAssertEqual(signals(7, MABounceSettings(priorTest: false)), ["414 20 1", "474 20 1", "574 50 1", "615 100 1"])
    }

    func testOnlySlowAverages() {
        XCTAssertEqual(signals(7, MABounceSettings(ma20: false, ma50: false), allowShort: false), [])
    }

    func testWatch() throws {
        let w = try XCTUnwrap(MABounceStrategy.evaluate(BreakoutTests.series(seed: 9), settings: MABounceSettings(),
                                                        allowShort: true).watch)
        XCTAssertEqual(w.direction, 1)
        XCTAssertEqual(w.period, 50)
        XCTAssertEqual(w.level, 159.542208, accuracy: 1e-5)
        XCTAssertEqual(w.distanceATR, 0.321051, accuracy: 1e-5)
    }

    func testScannerPicksBounce() throws {
        let bars = Array(BreakoutTests.series(seed: 1).prefix(553))
        let hit = try XCTUnwrap(SetupScanner.scan(symbol: "TEST", bars: bars, breakout: nil,
                                                  maBounce: MABounceSettings()))
        XCTAssertEqual(hit.strategy, .maBounce)
        XCTAssertTrue(hit.isEntry)
        XCTAssertEqual(hit.maPeriod, 200)
        XCTAssertEqual(hit.direction, -1)
        XCTAssertEqual(hit.barsAgo, 1)
        XCTAssertEqual(hit.title, "Odraz od KP 200")
    }

    func testStrategyTargets() {
        let b = BreakoutTests.series(seed: 4)
        let t = BacktestStrategy.maBounce(MABounceSettings()).targets(bars: b, allowShort: true)
        XCTAssertEqual(t.count, b.count)
        XCTAssertEqual(t[604], 1)
    }
}
