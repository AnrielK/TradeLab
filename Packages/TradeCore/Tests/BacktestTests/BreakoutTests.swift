import XCTest
@testable import Backtest

/// Očekávané vstupy spočítané referenční implementací v Pythonu (stejná řada z LCG generátoru).
final class BreakoutTests: XCTestCase {
    /// Stejný generátor jako `bt_test.py`: 5 obchodních dní v týdnu, první den pondělí.
    static func series(seed: UInt64, count: Int = 700, drift: Double = 0.0006, vol: Double = 0.015) -> [BacktestBar] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        let monday = Date(timeIntervalSince1970: 1_704_067_200 + 14 * 3600)   // pondělí 2024-01-01 14:00 UTC
        var c = 100.0
        var bars: [BacktestBar] = []
        for i in 0..<count {
            let o = c
            c = o * (1 + drift + vol * (next() - 0.5) * 2)
            let h = max(o, c) * (1 + 0.006 * next())
            let l = min(o, c) * (1 - 0.006 * next())
            let day = Double((i / 5) * 7 + i % 5)
            bars.append(BacktestBar(date: monday.addingTimeInterval(day * 86_400), open: o, high: h, low: l, close: c))
        }
        return bars
    }

    private func signals(_ seed: UInt64, _ settings: BreakoutSettings = BreakoutSettings(),
                         allowShort: Bool = true) -> [String] {
        BreakoutStrategy.evaluate(Self.series(seed: seed), settings: settings, allowShort: allowShort)
            .signals.map { "\($0.index) \($0.entry.rawValue) \($0.direction)" }
    }

    func testSeriesMatchesPython() {
        let b = Self.series(seed: 3)
        XCTAssertEqual(b[0].close, 98.899631, accuracy: 1e-6)
        XCTAssertEqual(b[699].close, 104.960195, accuracy: 1e-6)
    }

    func testWeekKeys() {
        let b = Self.series(seed: 1, count: 12)
        let keys = b.map { BreakoutStrategy.weekKey($0.date) }
        XCTAssertEqual(Set(keys[0..<5]).count, 1)
        XCTAssertNotEqual(keys[4], keys[5])
        XCTAssertEqual(keys[5], keys[9])
    }

    func testDefaultEntries() {
        XCTAssertEqual(signals(3), ["283 breakout -1", "359 breakout 1"])
        XCTAssertEqual(signals(9), ["254 preBreakout 1", "312 breakout 1", "672 breakout 1"])
        XCTAssertEqual(signals(14), ["371 pullback 1", "493 preBreakout 1", "526 breakout 1"])
        XCTAssertEqual(signals(20), ["202 pullback 1", "266 breakout 1", "407 breakout 1", "541 preBreakout 1"])
    }

    func testStopsAndTargets() {
        let s = BreakoutStrategy.evaluate(Self.series(seed: 9), settings: BreakoutSettings(), allowShort: true).signals
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0].stop, 119.6924, accuracy: 1e-3)
        XCTAssertEqual(s[0].target, 127.3814, accuracy: 1e-3)
        XCTAssertEqual(s[2].level, 158.322373, accuracy: 1e-5)
        XCTAssertEqual(s[2].stop, 157.1522, accuracy: 1e-3)
        XCTAssertEqual(s[2].target, 167.0272, accuracy: 1e-3)
        let short = BreakoutStrategy.evaluate(Self.series(seed: 3), settings: BreakoutSettings(), allowShort: true).signals[0]
        XCTAssertEqual(short.stop, 92.4248, accuracy: 1e-3)
        XCTAssertEqual(short.target, 88.9189, accuracy: 1e-3)
    }

    func testPositionChanges() {
        for (seed, changes) in [(3, 4), (9, 6), (14, 6), (20, 8)] as [(UInt64, Int)] {
            let t = BreakoutStrategy.evaluate(Self.series(seed: seed), settings: BreakoutSettings(), allowShort: true).targets
            XCTAssertEqual((1..<t.count).filter { t[$0] != t[$0 - 1] }.count, changes, "seed \(seed)")
        }
    }

    func testLooseFilters() {
        let loose = BreakoutSettings(weeklyFilter: false, dailyFilter: false, requireMACross: false)
        XCTAssertEqual(signals(1, loose), ["123 pullback 1", "152 breakout 1", "307 breakout 1", "352 pullback 1",
                                           "501 breakout -1"])
    }

    func testOnlyBreakoutLong() {
        let s = BreakoutSettings(preBreakout: false, pullback: false)
        XCTAssertEqual(signals(9, s, allowShort: false), ["258 breakout 1", "312 breakout 1", "672 breakout 1"])
    }

    func testWatch() throws {
        let w = try XCTUnwrap(BreakoutStrategy.evaluate(Self.series(seed: 1), settings: BreakoutSettings(),
                                                        allowShort: true).watch)
        XCTAssertEqual(w.direction, 1)
        XCTAssertEqual(w.level, 164.660933, accuracy: 1e-5)
        XCTAssertEqual(w.distanceATR, 0.255364, accuracy: 1e-5)
    }

    func testScannerFreshEntry() throws {
        let b = Array(Self.series(seed: 9).prefix(675))
        let hit = try XCTUnwrap(SetupScanner.scan(symbol: "TEST", bars: b))
        XCTAssertEqual(hit.entry, .breakout)
        XCTAssertEqual(hit.direction, 1)
        XCTAssertEqual(hit.barsAgo, 2)
        XCTAssertEqual(hit.suggestedPlay.direction, 1)
        XCTAssertNil(SetupScanner.scan(symbol: "TEST", bars: b, maxAge: 1, includeWatch: false))
    }

    func testScannerWatch() throws {
        let hit = try XCTUnwrap(SetupScanner.scan(symbol: "TEST", bars: Self.series(seed: 1)))
        XCTAssertNil(hit.entry)
        XCTAssertEqual(hit.direction, 1)
        XCTAssertEqual(hit.distanceATR ?? -1, 0.255364, accuracy: 1e-5)
    }
}
