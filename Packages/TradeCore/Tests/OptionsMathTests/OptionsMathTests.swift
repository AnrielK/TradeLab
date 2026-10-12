import XCTest
@testable import OptionsMath

final class BlackScholesTests: XCTestCase {
    let atm = OptionParameters(spot: 100, strike: 100, years: 1, rate: 0.05, volatility: 0.2)

    func testTextbookPrices() {
        XCTAssertEqual(BlackScholes.price(.call, atm), 10.450584, accuracy: 1e-5)
        XCTAssertEqual(BlackScholes.price(.put, atm), 5.573526, accuracy: 1e-5)
    }

    func testGreeks() {
        let call = BlackScholes.greeks(.call, atm)
        XCTAssertEqual(call.delta, 0.636831, accuracy: 1e-5)
        XCTAssertEqual(call.gamma, 0.018762, accuracy: 1e-5)
        XCTAssertEqual(call.vega, 0.375240, accuracy: 1e-5)
        XCTAssertEqual(call.theta, -0.017573, accuracy: 1e-5)
        XCTAssertEqual(call.rho, 0.532325, accuracy: 1e-5)

        let put = BlackScholes.greeks(.put, atm)
        XCTAssertEqual(put.delta, -0.363169, accuracy: 1e-5)
        XCTAssertEqual(put.theta, -0.004542, accuracy: 1e-5)
        XCTAssertEqual(put.rho, -0.418905, accuracy: 1e-5)
    }

    func testDividendYield() {
        let p = OptionParameters(spot: 100, strike: 110, years: 0.5, rate: 0.03, volatility: 0.25, dividendYield: 0.01)
        XCTAssertEqual(BlackScholes.price(.call, p), 3.723010, accuracy: 1e-5)
        XCTAssertEqual(BlackScholes.greeks(.call, p).delta, 0.344988, accuracy: 1e-5)
    }

    func testPutCallParity() {
        for strike in stride(from: 60.0, through: 140, by: 10) {
            var p = atm
            p.strike = strike
            let lhs = BlackScholes.price(.call, p) - BlackScholes.price(.put, p)
            let rhs = p.spot - strike * exp(-p.rate * p.years)
            XCTAssertEqual(lhs, rhs, accuracy: 1e-9)
        }
    }

    func testExpiredOptionIsIntrinsic() {
        let p = OptionParameters(spot: 105, strike: 100, years: 0, rate: 0.05, volatility: 0.2)
        XCTAssertEqual(BlackScholes.price(.call, p), 5)
        XCTAssertEqual(BlackScholes.price(.put, p), 0)
        XCTAssertEqual(BlackScholes.greeks(.call, p).delta, 1)
    }

    func testImpliedVolatilityRoundTrip() throws {
        for vol in [0.08, 0.2, 0.45, 1.2] {
            for strike in [80.0, 100, 125] {
                for type in OptionType.allCases {
                    let p = OptionParameters(spot: 100, strike: strike, years: 0.25, rate: 0.04, volatility: vol)
                    let price = BlackScholes.price(type, p)
                    guard price > 1e-4 else { continue }
                    let iv = try XCTUnwrap(ImpliedVolatility.solve(type, price: price, spot: 100, strike: strike, years: 0.25, rate: 0.04))
                    XCTAssertEqual(iv, vol, accuracy: 1e-4, "\(type) K=\(strike) σ=\(vol)")
                }
            }
        }
    }

    func testImpliedVolatilityRejectsArbitrage() {
        // Call nemůže stát méně než diskontovaná vnitřní hodnota.
        XCTAssertNil(ImpliedVolatility.solve(.call, price: 1, spot: 120, strike: 100, years: 0.5, rate: 0.04))
        XCTAssertNil(ImpliedVolatility.solve(.call, price: 150, spot: 100, strike: 100, years: 0.5, rate: 0.04))
    }

    func testRealizedVolatility() throws {
        // Střídavě +1 % / -1 % → σ denně ≈ 1 %, ročně ≈ 15,9 %.
        var closes = [100.0]
        for i in 0..<200 { closes.append(closes.last! * (i.isMultiple(of: 2) ? 1.01 : 0.99)) }
        let vol = try XCTUnwrap(Volatility.realized(closes: closes))
        XCTAssertEqual(vol, 0.01 * sqrt(252), accuracy: 0.002)
    }
}

final class StrategyTests: XCTestCase {
    let market = MarketContext(rate: 0.04)

    func bullCallSpread() -> OptionStrategy {
        OptionStrategy(name: "Bull call", underlying: "TEST", legs: [
            StrategyLeg(instrument: .call, side: .long, strike: 95, premium: 8, daysToExpiry: 30),
            StrategyLeg(instrument: .call, side: .short, strike: 105, premium: 3, daysToExpiry: 30),
        ])
    }

    func testBullCallSpreadAnalysis() throws {
        let s = bullCallSpread()
        XCTAssertEqual(s.netPremium, 500, accuracy: 1e-9)
        XCTAssertEqual(s.expiryProfitLoss(atSpot: 80, market: market), -500, accuracy: 1e-9)
        XCTAssertEqual(s.expiryProfitLoss(atSpot: 120, market: market), 500, accuracy: 1e-9)

        let a = s.analyze(spot: 100, market: market)
        XCTAssertEqual(try XCTUnwrap(a.maxProfit), 500, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(a.maxLoss), -500, accuracy: 1e-6)
        XCTAssertEqual(a.breakevens.count, 1)
        XCTAssertEqual(a.breakevens[0], 100, accuracy: 1e-6)
        let pop = try XCTUnwrap(a.probabilityOfProfit)
        XCTAssertTrue(pop > 0.3 && pop < 0.7)
    }

    func testUnlimitedProfitAndLoss() throws {
        let longCall = OptionStrategy(legs: [StrategyLeg(instrument: .call, side: .long, strike: 100, premium: 4)])
        let a = longCall.analyze(spot: 100, market: market)
        XCTAssertNil(a.maxProfit)
        XCTAssertEqual(try XCTUnwrap(a.maxLoss), -400, accuracy: 1e-6)
        XCTAssertEqual(a.breakevens.first ?? 0, 104, accuracy: 1e-6)

        let shortCall = OptionStrategy(legs: [StrategyLeg(instrument: .call, side: .short, strike: 100, premium: 4)])
        let b = shortCall.analyze(spot: 100, market: market)
        XCTAssertNil(b.maxLoss)
        XCTAssertEqual(try XCTUnwrap(b.maxProfit), 400, accuracy: 1e-6)
    }

    func testCoveredCall() throws {
        let s = OptionStrategy(legs: [
            StrategyLeg(instrument: .stock, side: .long, strike: 100),
            StrategyLeg(instrument: .call, side: .short, strike: 105, premium: 2),
        ])
        let a = s.analyze(spot: 100, market: market)
        XCTAssertEqual(try XCTUnwrap(a.maxProfit), 700, accuracy: 1e-6) // (105 - 100 + 2) * 100
        XCTAssertEqual(a.breakevens.first ?? 0, 98, accuracy: 1e-6)
        XCTAssertEqual(s.greeks(atSpot: 100, daysElapsed: 30, market: market).delta, 100, accuracy: 1e-9)
    }

    func testIronCondorHasTwoBreakevens() throws {
        let s = StrategyTemplate.ironCondor.build(underlying: "TEST", spot: 100, daysToExpiry: 30, volatility: 0.25, market: market)
        XCTAssertEqual(s.legs.count, 4)
        XCTAssertLessThan(s.netPremium, 0, "iron condor je kreditní strategie")
        let a = s.analyze(spot: 100, market: market)
        XCTAssertEqual(a.breakevens.count, 2)
        XCTAssertNotNil(a.maxProfit)
        XCTAssertNotNil(a.maxLoss)
    }

    func testTimeValueBeforeExpiry() {
        let s = bullCallSpread()
        // Před expirací je P/L hladší než payoff: u spotu 100 mezi -500 a +500.
        let today = s.profitLoss(atSpot: 100, daysElapsed: 0, market: market)
        XCTAssertGreaterThan(today, -500)
        XCTAssertLessThan(today, 500)
        // Posun IV o +10 b. mění hodnotu.
        let higherIV = s.profitLoss(atSpot: 100, daysElapsed: 0, ivShift: 0.10, market: market)
        XCTAssertNotEqual(today, higherIV, accuracy: 1e-6)
    }

    func testAllTemplatesBuild() {
        for template in StrategyTemplate.allCases {
            let s = template.build(underlying: "TEST", spot: 187.3, market: market)
            XCTAssertFalse(s.legs.isEmpty, template.rawValue)
            XCTAssertTrue(s.legs.allSatisfy { $0.strike > 0 }, template.rawValue)
            _ = s.analyze(spot: 187.3, market: market)
        }
    }

    func testStrikeGrid() {
        XCTAssertEqual(StrikeGrid.round(187.3, spot: 187.3), 187.5)
        XCTAssertEqual(StrikeGrid.round(431.2, spot: 431.2), 430)
        XCTAssertEqual(StrikeGrid.round(12.3, spot: 12.3), 12.5)
    }
}
