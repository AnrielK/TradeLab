import XCTest
@testable import Backtest

final class IndicatorTests: XCTestCase {
    // Klasická řada z Wilderova příkladu RSI.
    let x: [Double] = [44.34, 44.09, 44.15, 43.61, 44.33, 44.83, 45.10, 45.42, 45.84, 46.08, 45.89, 46.03, 45.61,
                       46.28, 46.28, 46.00, 46.03, 46.41, 46.22, 45.64, 46.21, 46.25, 45.71, 46.45, 45.78, 45.35,
                       44.03, 44.18, 44.22, 44.57, 43.42, 42.66, 43.13]

    func testSMA() {
        let s = TA.sma([1, 2, 3, 4, 5], 3)
        XCTAssertNil(s[1])
        XCTAssertEqual(s[2]!, 2, accuracy: 1e-12)
        XCTAssertEqual(s[4]!, 4, accuracy: 1e-12)
    }

    func testEMA() {
        let e = TA.ema(x, 10)
        XCTAssertNil(e[8])
        XCTAssertEqual(e[9]!, 44.779, accuracy: 1e-9)
        XCTAssertEqual(e.last!!, 44.11929901522181, accuracy: 1e-9)
    }

    func testRSI() {
        let r = TA.rsi(x, 14)
        XCTAssertNil(r[13])
        XCTAssertEqual(r[14]!, 70.46413502109705, accuracy: 1e-9)
        XCTAssertEqual(r[15]!, 66.24961855355505, accuracy: 1e-9)
        XCTAssertEqual(r.last!!, 37.788771982057824, accuracy: 1e-9)
    }

    func testMACD() {
        let m = TA.macd(x, fast: 5, slow: 10, signal: 3)
        XCTAssertEqual(m.macd.last!!, -0.6082205441401882, accuracy: 1e-9)
        XCTAssertEqual(m.signal.last!!, -0.5712842523620352, accuracy: 1e-9)
        XCTAssertEqual(m.histogram.last!!, -0.6082205441401882 + 0.5712842523620352, accuracy: 1e-9)
    }
}

final class EngineTests: XCTestCase {
    private func bars(_ closes: [Double], opens: [Double]? = nil, stepDays: Double = 1) -> [BacktestBar] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return closes.indices.map { i in
            let open = opens?[i] ?? closes[i]
            return BacktestBar(date: start.addingTimeInterval(Double(i) * stepDays * 86_400),
                               open: open, high: max(open, closes[i]), low: min(open, closes[i]), close: closes[i])
        }
    }

    func testBuyAndHoldEntersOnNextOpen() {
        let b = bars([100, 110, 121, 133.1], opens: [100, 105, 115, 125])
        let r = BacktestEngine.run(bars: b, config: BacktestConfig(strategy: .buyAndHold, costBps: 0))
        // vstup za open baru 1 (105), konec na close posledního (133.1)
        XCTAssertEqual(r.metrics.totalReturn, 133.1 / 105 - 1, accuracy: 1e-9)
        XCTAssertEqual(r.trades.count, 1)
        XCTAssertTrue(r.trades[0].isOpen)
        XCTAssertEqual(r.trades[0].entryPrice, 105)
    }

    func testNoLookAhead() {
        // Signál z baru 1 se smí projevit až od open baru 2.
        let targets = [0, 1, 0, 0]
        let b = bars([100, 100, 120, 120], opens: [100, 100, 110, 130])
        let sim = BacktestEngine.simulate(bars: b, targets: targets, costBps: 0, initialCapital: 100)
        XCTAssertEqual(sim.equity[1].equity, 100, accuracy: 1e-9, "bar 1 bez pozice")
        XCTAssertEqual(sim.equity[2].equity, 100 * 120 / 110, accuracy: 1e-9, "vstup za open 110")
        // bar 3: přes noc 120 → 130 ještě long, pak výstup na open 130
        XCTAssertEqual(sim.equity[3].equity, 100 * 130 / 110, accuracy: 1e-9)
        XCTAssertEqual(sim.trades.count, 1)
        XCTAssertEqual(sim.trades[0].returnPct, 130.0 / 110 - 1, accuracy: 1e-9)
        XCTAssertFalse(sim.trades[0].isOpen)
    }

    func testCostsReduceReturn() {
        let targets = [1, 0, 0]
        let b = bars([100, 100, 100])
        let sim = BacktestEngine.simulate(bars: b, targets: targets, costBps: 10, initialCapital: 100)
        // vstup i výstup po 10 bp
        XCTAssertEqual(sim.equity.last!.equity, 100 * 0.999 * 0.999, accuracy: 1e-9)
        XCTAssertEqual(sim.trades[0].returnPct, -0.002, accuracy: 1e-12)
    }

    func testShortPosition() {
        let targets = [-1, -1, -1]
        let b = bars([100, 90, 80])
        let sim = BacktestEngine.simulate(bars: b, targets: targets, costBps: 0, initialCapital: 100)
        XCTAssertGreaterThan(sim.equity.last!.equity, 100)
        XCTAssertEqual(sim.trades[0].side, -1)
    }

    func testDrawdownAndMetrics() {
        let b = bars([100, 100, 120, 90, 108])
        let r = BacktestEngine.run(bars: b, config: BacktestConfig(strategy: .buyAndHold, costBps: 0, riskFreeRate: 0))
        XCTAssertEqual(r.metrics.maxDrawdown, 90.0 / 120 - 1, accuracy: 1e-9)
        XCTAssertEqual(r.metrics.exposure, 1, accuracy: 1e-9)
        XCTAssertEqual(r.metrics.totalReturn, 0.08, accuracy: 1e-9)
    }

    func testPeriodsPerYear() {
        let daily = bars([1, 2, 3, 4], stepDays: 1).map(\.date)
        let weekly = bars([1, 2, 3, 4], stepDays: 7).map(\.date)
        XCTAssertEqual(BacktestEngine.periodsPerYear(daily), 252)
        XCTAssertEqual(BacktestEngine.periodsPerYear(weekly), 52)
    }

    func testStrategiesProduceTargets() {
        let b = bars((0..<300).map { 100 + 10 * sin(Double($0) / 8) + Double($0) * 0.05 }, stepDays: 1)
        for strategy in [BacktestStrategy.buyAndHold, .breakout(BreakoutSettings())] {
            let t = strategy.targets(bars: b, allowShort: true)
            XCTAssertEqual(t.count, b.count)
            XCTAssertTrue(t.allSatisfy { [-1, 0, 1].contains($0) }, strategy.name)
        }
    }
}
