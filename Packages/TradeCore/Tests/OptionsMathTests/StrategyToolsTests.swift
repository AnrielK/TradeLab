import XCTest
@testable import OptionsMath

final class StrategyToolsTests: XCTestCase {
    let exp = Date(timeIntervalSince1970: 1_793_318_400) // 30. 10. 2026
    let strikes: [Double] = stride(from: 215.0, through: 240, by: 2.5).map { $0 }

    /// NVDA vertical ze screenshotu: +1 C227.5 (5.50/5.65), −1 C232.5 (3.45/3.55).
    func vertical() -> OptionStrategy {
        OptionStrategy(underlying: "NVDA", legs: [
            StrategyLeg(instrument: .call, side: .long, strike: 227.5, premium: 5.575, daysToExpiry: 18,
                        impliedVolatility: 0.35, expiration: exp, bid: 5.50, ask: 5.65),
            StrategyLeg(instrument: .call, side: .short, strike: 232.5, premium: 3.50, daysToExpiry: 18,
                        impliedVolatility: 0.35, expiration: exp, bid: 3.45, ask: 3.55),
        ])
    }

    func testNetQuoteMatchesBroker() throws {
        let q = try XCTUnwrap(vertical().netQuote)
        XCTAssertEqual(q.opposite, 1.95, accuracy: 1e-9)
        XCTAssertEqual(q.natural, 2.20, accuracy: 1e-9)
        XCTAssertEqual(q.mid, 2.075, accuracy: 1e-9)
        XCTAssertTrue(q.isDebit)
    }

    func testCreditQuote() throws {
        var s = vertical()
        s.legs[0].side = .short
        s.legs[1].side = .long
        let q = try XCTUnwrap(s.netQuote)
        XCTAssertFalse(q.isDebit)
        XCTAssertEqual(q.low, 1.95, accuracy: 1e-9)
        XCTAssertEqual(q.high, 2.20, accuracy: 1e-9)
    }

    func testExtrinsicAndMaxValues() throws {
        let s = vertical()
        XCTAssertEqual(s.extrinsicValue(spot: 225.88), 207.5, accuracy: 1e-9)
        let a = s.analyze(spot: 225.88, market: MarketContext(rate: 0.04))
        XCTAssertEqual(try XCTUnwrap(a.maxProfit), 292.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(a.maxLoss), -207.5, accuracy: 1e-6)
    }

    func testSpreadCount() {
        var s = vertical().withSpreadCount(3)
        XCTAssertEqual(s.legs.map(\.quantity), [3, 3])
        XCTAssertEqual(s.spreadCount, 3)
        XCTAssertEqual(s.netQuote?.mid ?? 0, 2.075, accuracy: 1e-9, "cena je za jednu jednotku")
        s = s.withSpreadCount(1)
        XCTAssertEqual(s.legs.map(\.quantity), [1, 1])
    }

    func testShiftStrikes() throws {
        let s = vertical()
        let up = try XCTUnwrap(s.shiftingStrikes(by: 1) { _ in self.strikes })
        XCTAssertEqual(up.legs.map(\.strike), [230, 235])
        let down = try XCTUnwrap(s.shiftingStrikes(by: -2) { _ in self.strikes })
        XCTAssertEqual(down.legs.map(\.strike), [222.5, 227.5])
        XCTAssertNil(s.shiftingStrikes(by: 5) { _ in self.strikes }, "mimo řetězec")
    }

    func testChangeWidthKeepsFirstLeg() throws {
        let s = vertical()
        let wider = try XCTUnwrap(s.changingWidth(by: 1) { _ in self.strikes })
        XCTAssertEqual(wider.legs.map(\.strike), [227.5, 235])
        let narrower = try XCTUnwrap(s.changingWidth(by: -1) { _ in self.strikes })
        XCTAssertEqual(narrower.legs.map(\.strike), [227.5, 230])
        XCTAssertNil(narrower.changingWidth(by: -1) { _ in self.strikes }, "striky by se slily")
    }

    func testChangeWidthMovesCondorWings() throws {
        let condor = StrategyTemplate.ironCondor.build(underlying: "X", spot: 100, market: MarketContext(rate: 0.04))
        let ladder = stride(from: 80.0, through: 120, by: 1).map { $0 }
        let wider = try XCTUnwrap(condor.changingWidth(by: 2) { _ in ladder })
        XCTAssertEqual(wider.legs.map(\.strike), [88, 95, 105, 112])
    }

    func testClassifier() {
        XCTAssertEqual(StrategyClassifier.name(for: vertical()), "Vertical")
        let m = MarketContext(rate: 0.04)
        XCTAssertEqual(StrategyClassifier.name(for: StrategyTemplate.ironCondor.build(underlying: "X", spot: 100, market: m)), "Iron condor")
        XCTAssertEqual(StrategyClassifier.name(for: StrategyTemplate.callButterfly.build(underlying: "X", spot: 100, market: m)), "Butterfly")
        XCTAssertEqual(StrategyClassifier.name(for: StrategyTemplate.longStraddle.build(underlying: "X", spot: 100, market: m)), "Long straddle")
        XCTAssertEqual(StrategyClassifier.name(for: StrategyTemplate.longStrangle.build(underlying: "X", spot: 100, market: m)), "Long strangle")
        XCTAssertEqual(StrategyClassifier.name(for: StrategyTemplate.coveredCall.build(underlying: "X", spot: 100, market: m)), "Covered call")
        XCTAssertEqual(StrategyClassifier.name(for: StrategyTemplate.longPut.build(underlying: "X", spot: 100, market: m)), "Long put")

        var calendar = vertical()
        calendar.legs[1].strike = 227.5
        calendar.legs[1].expiration = exp.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(StrategyClassifier.name(for: calendar), "Calendar")
        calendar.legs[1].strike = 232.5
        XCTAssertEqual(StrategyClassifier.name(for: calendar), "Diagonal")
    }

    func testSameContract() {
        let s = vertical()
        var other = s.legs[0]
        other.side = .short
        other.quantity = 5
        XCTAssertTrue(s.legs[0].isSameContract(as: other))
        XCTAssertFalse(s.legs[0].isSameContract(as: s.legs[1]))
    }

    func testLegacyStrategyDecodes() throws {
        // Strategie uložená verzí 0.1 (bez expirace a kotací) se musí dát načíst.
        let json = #"{"name":"X","underlying":"AAPL","multiplier":100,"legs":[{"id":"6A0C6E39-6B46-4B0E-9E44-7B1C4C3F0B11","instrument":"call","side":"long","quantity":1,"strike":100,"premium":2,"daysToExpiry":30,"impliedVolatility":0.3}]}"#
        let s = try JSONDecoder().decode(OptionStrategy.self, from: Data(json.utf8))
        XCTAssertNil(s.legs[0].expiration)
        XCTAssertNil(s.legs[0].bid)
    }
}
