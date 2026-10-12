import XCTest
@testable import Backtest

final class LevelTests: XCTestCase {
    private func series(_ f: (Int) -> Double, count: Int) -> [BacktestBar] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { i in
            let close = f(i)
            let open = i > 0 ? f(i - 1) : close
            return BacktestBar(date: start.addingTimeInterval(Double(i) * 86_400), open: open,
                               high: max(open, close) + 0.5, low: min(open, close) - 0.5, close: close)
        }
    }

    func testHorizontalLevelsInRange() {
        let bars = series({ 100 + 10 * sin(2 * .pi * Double($0) / 20) }, count: 120)
        let analysis = LevelFinder.analyze(bars)
        let resistance = analysis.levels.first { $0.kind == .resistance && abs($0.price - 110.5) < 1.5 }
        let support = analysis.levels.first { $0.kind == .support && abs($0.price - 89.5) < 1.5 }
        XCTAssertNotNil(resistance)
        XCTAssertNotNil(support)
        XCTAssertGreaterThanOrEqual(resistance?.touches ?? 0, 4)
        XCTAssertGreaterThanOrEqual(support?.touches ?? 0, 4)
        XCTAssertEqual(analysis.levels.map(\.strength).max(), 1)
    }

    func testRisingTrendLine() {
        let bars = series({ 100 + 0.5 * Double($0) + 5 * sin(2 * .pi * Double($0) / 20) }, count: 120)
        let analysis = LevelFinder.analyze(bars)
        let support = analysis.trendLines.first { $0.kind == .support }
        XCTAssertNotNil(support)
        XCTAssertTrue(support?.isRising ?? false)
        XCTAssertGreaterThanOrEqual(support?.touches ?? 0, 4)
        // Linie dnes leží pod poslední zavírací cenou.
        XCTAssertLessThan(support?.priceNow ?? .infinity, analysis.lastClose)
    }

    func testPivotsAndATR() {
        let bars = series({ [1.0, 2, 5, 2, 1, 2, 1][$0] * 10 }, count: 7)
        let pivots = LevelFinder.pivots(bars, window: 2)
        XCTAssertTrue(pivots.contains { $0.isHigh && $0.index == 2 })
        XCTAssertGreaterThan(LevelFinder.atr(bars), 0)
    }
}
