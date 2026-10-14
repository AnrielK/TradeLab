import XCTest
import OptionsMath
@testable import Backtest

final class OptionsBacktestTests: XCTestCase {
    private func bars(_ closes: [Double]) -> [BacktestBar] {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        return closes.enumerated().map { i, c in
            let o = i > 0 ? closes[i - 1] : c
            return BacktestBar(date: start.addingTimeInterval(Double(i) * 86_400), open: o,
                               high: max(o, c) * 1.003, low: min(o, c) * 0.997, close: c)
        }
    }

    /// Deterministický šum (LCG).
    private func walk(count: Int, drift: Double, vol: Double, seed start: UInt64) -> [Double] {
        var seed = start
        var price = 100.0
        var closes: [Double] = []
        for _ in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(seed >> 33) / Double(UInt64(1) << 31) - 0.5
            price *= 1 + drift + noise * vol
            closes.append(price)
        }
        return closes
    }

    func testSelectionByRegime() {
        let config = OptionsBacktestConfig(signal: .buyAndHold, selection: .auto(neutralCondor: true))
        XCTAssertEqual(OptionsBacktest.choose(signal: 1, rank: 80, config: config), .bullPutSpread)
        XCTAssertEqual(OptionsBacktest.choose(signal: 1, rank: 20, config: config), .bullCallSpread)
        XCTAssertEqual(OptionsBacktest.choose(signal: -1, rank: 80, config: config), .bearCallSpread)
        XCTAssertEqual(OptionsBacktest.choose(signal: -1, rank: 20, config: config), .bearPutSpread)
        XCTAssertEqual(OptionsBacktest.choose(signal: 0, rank: 80, config: config), .ironCondor)
        XCTAssertNil(OptionsBacktest.choose(signal: 0, rank: 20, config: config))

        let fixed = OptionsBacktestConfig(signal: .buyAndHold, selection: .fixed(bullish: .longCall, bearish: nil))
        XCTAssertEqual(OptionsBacktest.choose(signal: 1, rank: 90, config: fixed), .longCall)
        XCTAssertNil(OptionsBacktest.choose(signal: -1, rank: 90, config: fixed))
    }

    func testStrikeByDelta() {
        let k = OptionsBacktest.strike(.put, delta: 0.3, spot: 100, days: 35, iv: 0.3, rate: 0.04)
        XCTAssertLessThan(k, 100)
        let delta = abs(BlackScholes.greeks(.put, OptionParameters(spot: 100, strike: k, days: 35, rate: 0.04,
                                                                   volatility: 0.3)).delta)
        XCTAssertEqual(delta, 0.3, accuracy: 0.06)
    }

    func testCreditSpreadConstruction() throws {
        let config = OptionsBacktestConfig(signal: .buyAndHold)
        let position = try XCTUnwrap(OptionsBacktest.open(.bullPutSpread, spot: 100, date: Date(), iv: 0.3,
                                                           equity: 10_000, signal: 1, rank: 70, config: config))
        XCTAssertLessThan(position.entryPremium, 0)             // kredit
        XCTAssertEqual(position.legs.count, 2)
        XCTAssertEqual(position.legs[0].strike - position.legs[1].strike, 5)
        // Max. ztráta = 5 % kapitálu.
        XCTAssertEqual(position.maxLossPerShare * 100 * position.contracts, 500, accuracy: 1e-6)
    }

    func testRunProducesTrades() {
        let b = bars(walk(count: 500, drift: 0.0008, vol: 0.03, seed: 7))
        let config = OptionsBacktestConfig(signal: .buyAndHold, selection: .auto(neutralCondor: true))
        let result = OptionsBacktest.run(bars: b, config: config)
        XCTAssertEqual(result.equity.count, b.count)
        XCTAssertFalse(result.trades.isEmpty)
        XCTAssertTrue(result.trades.allSatisfy { $0.contracts > 0 && $0.maxLoss > 0 })
        // Ztráta jednoho obchodu nepřekročí plánované riziko + náklady.
        for trade in result.trades {
            XCTAssertGreaterThan(trade.pnl, -trade.maxLoss * 1.2 - 50)
        }
        XCTAssertGreaterThan(result.equity.last!.equity, 0)
        XCTAssertFalse(result.playCounts.isEmpty)
    }
}

final class OptionsMatchStockTests: XCTestCase {
    /// Opce s výstupem podle strategie mají stejné obchody jako akcie (navíc jen přerolování před expirací).
    func testOptionTradesFollowStockTrades() {
        let loose = BreakoutSettings(weeklyFilter: false, dailyFilter: false, requireMACross: false)
        for seed: UInt64 in [1, 9, 14] {
            for allowShort in [false, true] {
                let bars = BreakoutTests.series(seed: seed)
                let strategy = BacktestStrategy.breakout(loose)
                let stock = BacktestEngine.run(bars: bars, config: BacktestConfig(strategy: strategy, allowShort: allowShort))
                let options = OptionsBacktest.run(bars: bars, config: OptionsBacktestConfig(signal: strategy,
                                                                                         allowBearish: allowShort))
                XCTAssertEqual(options.strategyTradeCount, stock.trades.count, "seed \(seed) short \(allowShort)")
                let stockEntries = stock.trades.map(\.entryDate)
                let optionEntries = options.trades.filter { !$0.isRoll }.map(\.entryDate)
                XCTAssertEqual(optionEntries, stockEntries, "seed \(seed) short \(allowShort)")
            }
        }
    }
}
