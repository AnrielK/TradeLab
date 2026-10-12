import XCTest
@testable import Backtest

/// Scénáře ověřené referenční implementací v Pythonu.
final class PriceActionTests: XCTestCase {
    private func bars(_ ohlc: [(Double, Double, Double, Double)]) -> [BacktestBar] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return ohlc.enumerated().map { i, b in
            BacktestBar(date: start.addingTimeInterval(Double(i) * 86_400), open: b.0, high: b.1, low: b.2, close: b.3)
        }
    }

    func testBreakAndRetest() {
        var b = [(Double, Double, Double, Double)](repeating: (100, 101, 99, 100), count: 25)
        b.append((100, 106, 100, 105))        // 25 průraz nad 101
        b.append((104, 104.5, 101.5, 103))    // 26 retest a zavření nad hladinou → long
        b += [(103, 107, 103, 106), (106, 109, 105, 108), (108, 110, 107, 109)]
        b.append((109, 109, 95, 96))          // 30 zavření pod stopem → ven
        let t = PriceAction.breakRetest(bars(b), lookback: 20, retestBars: 5, tolerance: 0.01, allowShort: false)
        XCTAssertEqual(Array(t[24...]), [0, 0, 1, 1, 1, 1, 0])

        // Průraz, který se vrátí pod hladinu, se neobchoduje.
        var f = [(Double, Double, Double, Double)](repeating: (100, 101, 99, 100), count: 25)
        f += [(100, 106, 100, 105), (104, 104, 99, 99.5), (99, 100, 98, 99)]
        XCTAssertEqual(PriceAction.breakRetest(bars(f), lookback: 20, retestBars: 5, tolerance: 0.01, allowShort: false)
            .filter { $0 != 0 }.count, 0)
    }

    func testReversal() {
        var b: [(Double, Double, Double, Double)] = []
        var c = 100.0
        for _ in 0..<20 {
            let o = c
            c -= 1.5
            b.append((o, o + 0.2, c - 0.3, c))
        }
        b.append((c - 0.5, c + 2.5, c - 0.8, c + 2))   // 20 býčí obratová svíčka
        c += 2
        for _ in 0..<5 {
            let o = c
            c += 0.8
            b.append((o, c + 0.2, o - 0.2, c))
        }
        let t = PriceAction.reversal(bars(b), period: 14, lower: 30, upper: 70, allowShort: false)
        XCTAssertEqual(Array(t[17...]), [0, 0, 0, 1, 1, 1, 1, 1, 1])
    }

    func testMovingAverageBounce() {
        var b: [(Double, Double, Double, Double)] = []
        var c = 50.0
        for _ in 0..<40 {
            let o = c
            c += 1
            b.append((o, c + 0.3, o - 0.3, c))
        }
        b += [(90, 90.2, 88.3, 88.5), (88.5, 88.7, 86.8, 87)]          // 40–41 pullback
        b.append((86.8, 88.8, 87.5, 88.5))                              // 42 odraz od SMA 10
        b += [(88.5, 89.8, 88.2, 89.5), (89.5, 90.8, 89.2, 90.5), (90.5, 91.8, 90.2, 91.5)]
        b.append((91.5, 91.5, 80, 80.5))                                // 46 průraz pod průměr → ven
        let t = PriceAction.maBounce(bars(b), period: 10, trendPeriod: 30, tolerance: 0.01,
                                     exponential: false, allowShort: false)
        XCTAssertEqual(Array(t[38...]), [0, 0, 0, 0, 1, 1, 1, 1, 0])
    }

    func testEngineUsesOHLCStrategies() {
        var b = [(Double, Double, Double, Double)](repeating: (100, 101, 99, 100), count: 25)
        b += [(100, 106, 100, 105), (104, 104.5, 101.5, 103), (103, 107, 103, 106), (106, 109, 105, 108)]
        let config = BacktestConfig(strategy: .breakRetest(lookback: 20, retestBars: 5, tolerance: 0.01), costBps: 0)
        let result = BacktestEngine.run(bars: bars(b), config: config)
        // Signál na baru 26 → vstup za open baru 27 (103).
        XCTAssertEqual(result.trades.first?.entryPrice, 103)
        XCTAssertTrue(BacktestStrategy.maBounce(period: 20, trendPeriod: 200, tolerance: 0.01, exponential: true).usesOHLC)
        XCTAssertEqual(BacktestStrategy.breakRetest(lookback: 20, retestBars: 5, tolerance: 0.01).name,
                       "Break & retest 20 (retest 5, 1 %)")
    }
}
