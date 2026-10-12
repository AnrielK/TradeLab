import XCTest
@testable import Backtest

/// Scénáře ověřené referenční implementací v Pythonu.
final class StructureTests: XCTestCase {
    private func bars(_ closes: [Double]) -> [BacktestBar] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return closes.enumerated().map { i, c in
            let o = i > 0 ? closes[i - 1] : c
            return BacktestBar(date: start.addingTimeInterval(Double(i) * 86_400), open: o,
                               high: max(o, c) + 0.3, low: min(o, c) - 0.3, close: c)
        }
    }

    private var range: [Double] {
        [100.0, 101, 102, 101, 100, 99, 98, 99].repeated(5)
    }

    func testLevelBreakout() {
        let t = Structure.levelBreakout(bars(range + [104, 105, 106]), lookback: 120, tolerance: 0.005,
                                        rewardRisk: 2, allowShort: false)
        XCTAssertEqual(Array(t[38...]), [0, 0, 1, 1, 1])
    }

    func testLevelBounce() {
        let t = Structure.levelBounce(bars(range), lookback: 120, tolerance: 0.005, rewardRisk: 2, allowShort: false)
        XCTAssertEqual(t.firstIndex(of: 1), 23)
        XCTAssertFalse(t.contains(-1))
    }

    func testTrendlineBounce() {
        let closes: [Double] = (0..<100).map { i in
            let x = Double(i)
            let wave: Double = 5 * sin(2 * Double.pi * x / 20)
            return 100 + 0.5 * x + wave
        }
        let t = Structure.trendlineBounce(bars(closes), lookback: 120, tolerance: 0.005, rewardRisk: 2, allowShort: false)
        XCTAssertEqual(t.firstIndex(of: 1), 37)
    }

    func testTrendlineBreakout() {
        var closes: [Double] = (0..<80).map { i in
            let x = Double(i)
            let wave: Double = 5 * sin(2 * Double.pi * x / 20)
            return 150 - 0.5 * x + wave
        }
        let last = closes[closes.count - 1]
        for k in 1...6 { closes.append(last + 4 * Double(k)) }
        let t = Structure.trendlineBreakout(bars(closes), lookback: 120, tolerance: 0.005, rewardRisk: 2, allowShort: false)
        XCTAssertEqual(t.firstIndex(of: 1), 81)
    }

    func testSwingPullbackRuns() {
        var seed: UInt64 = 42
        var price = 100.0
        let closes: [Double] = (0..<600).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(seed >> 33) / Double(UInt64(1) << 31) - 0.5
            price *= 1 + 0.0006 + noise * 0.03 + (i % 60 < 8 ? -0.006 : 0)
            return price
        }
        let b = bars(closes)
        let t = Structure.swingPullback(b, trendPeriod: 200, swingLookback: 20, allowShort: false)
        XCTAssertEqual(t.count, b.count)
        XCTAssertTrue(t.allSatisfy { $0 == 0 || $0 == 1 })
        XCTAssertTrue(t.prefix(199).allSatisfy { $0 == 0 })   // před SMA 200 bez obchodů
        let result = BacktestEngine.run(bars: b, config: BacktestConfig(strategy: .swingPullback(trendPeriod: 200, swingLookback: 20)))
        XCTAssertEqual(result.equity.count, b.count)
    }
}

private extension Array {
    func repeated(_ count: Int) -> [Element] { (0..<count).flatMap { _ in self } }
}
