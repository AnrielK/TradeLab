import XCTest
@testable import Backtest

/// Očekávané vstupy spočítané referenční implementací v Pythonu (stejná řada jako u `BreakoutTests`).
final class TrendlineTests: XCTestCase {
    private func evaluate(_ seed: UInt64, _ settings: TrendlineSettings = TrendlineSettings(),
                          allowShort: Bool = true) -> TrendlineEvaluation {
        TrendlineStrategy.evaluate(BreakoutTests.series(seed: seed), settings: settings, allowShort: allowShort)
    }

    private func signals(_ seed: UInt64, _ settings: TrendlineSettings = TrendlineSettings(),
                         allowShort: Bool = true) -> [String] {
        evaluate(seed, settings, allowShort: allowShort).signals.map { "\($0.index) \($0.entry.rawValue) \($0.direction)" }
    }

    func testDefaultEntries() {
        XCTAssertEqual(signals(1), ["208 triangle 1", "232 breakout 1", "339 breakout 1", "416 triangle 1",
                                    "437 bounce 1", "532 breakout -1", "621 bounce 1", "693 bounce 1"])
        XCTAssertEqual(signals(3), ["282 triangle -1", "353 triangle 1", "596 triangle -1"])
        XCTAssertEqual(signals(8), ["317 breakout -1", "437 bounce -1"])
        XCTAssertEqual(signals(13), ["255 triangle 1", "278 bounce 1", "299 breakout 1", "434 breakout -1",
                                     "482 bounce -1"])
    }

    func testPositionChanges() {
        for (seed, changes) in [(1, 15), (3, 6), (8, 4), (13, 10)] as [(UInt64, Int)] {
            let t = evaluate(seed).targets
            XCTAssertEqual((1..<t.count).filter { t[$0] != t[$0 - 1] }.count, changes, "seed \(seed)")
        }
    }

    func testLevelsStopsTargets() {
        let s = evaluate(1).signals
        XCTAssertEqual(s[0].level, 116.030162, accuracy: 1e-5)
        XCTAssertEqual(s[0].stop, 114.097054, accuracy: 1e-5)
        XCTAssertEqual(s[0].target, 127.850278, accuracy: 1e-5)
        XCTAssertEqual(s[1].level, 112.055321, accuracy: 1e-5)
        XCTAssertEqual(s[1].stop, 112.091722, accuracy: 1e-5)
        XCTAssertEqual(s[1].target, 121.427782, accuracy: 1e-5)
        XCTAssertEqual(s[2].target, 137.308414, accuracy: 1e-5)
    }

    func testOnlyTriangleLong() {
        XCTAssertEqual(signals(3, TrendlineSettings(bounce: false, breakout: false), allowShort: false),
                       ["353 triangle 1"])
    }

    func testTriangleWatch() throws {
        let w = try XCTUnwrap(evaluate(8).watch)
        XCTAssertEqual(w.entry, .triangle)
        XCTAssertEqual(w.direction, 1)
        XCTAssertEqual(w.level, 89.501819, accuracy: 1e-5)
        XCTAssertEqual(w.distanceATR, 1.291106, accuracy: 1e-5)
        XCTAssertNotNil(evaluate(8).triangle)
    }

    func testScannerTrendlineEntry() throws {
        let bars = Array(BreakoutTests.series(seed: 13).prefix(301))
        let hit = try XCTUnwrap(SetupScanner.scan(symbol: "TEST", bars: bars, breakout: nil,
                                                  trendline: TrendlineSettings()))
        XCTAssertEqual(hit.strategy, .trendline)
        XCTAssertEqual(hit.trendlineEntry, .breakout)
        XCTAssertTrue(hit.isEntry)
        XCTAssertEqual(hit.barsAgo, 1)
        XCTAssertEqual(hit.title, "Průraz trendline")
    }

    func testLineValue() {
        let line = SwingLine(startIndex: 10, startPrice: 100, endIndex: 20, endPrice: 110, slope: 1, touches: 2)
        XCTAssertEqual(line.value(at: 25), 115)
    }
}
