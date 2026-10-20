import XCTest
import OptionsMath
@testable import MarketData

final class OpenInterestProfileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func contract(_ type: OptionType, _ strike: Double, oi: Int?, expiration: Date, iv: Double = 0.3) -> OptionContract {
        OptionContract(contractSymbol: "X\(type.rawValue)\(strike)\(expiration.timeIntervalSince1970)", type: type, strike: strike,
                       lastPrice: nil, bid: nil, ask: nil, change: nil, volume: nil, openInterest: oi,
                       yahooImpliedVolatility: iv, inTheMoney: false, expiration: expiration)
    }

    private func chain(days: Double, spot: Double = 100,
                       calls: [(Double, Int)], puts: [(Double, Int)]) -> OptionChain {
        let expiration = now.addingTimeInterval(days * 86_400)
        return OptionChain(symbol: "TEST", underlyingPrice: spot, expirationDates: [expiration], expiration: expiration,
                           calls: calls.map { contract(.call, $0.0, oi: $0.1, expiration: expiration) },
                           puts: puts.map { contract(.put, $0.0, oi: $0.1, expiration: expiration) })
    }

    func testAggregatesAcrossExpirationsWithinHorizon() {
        let near = chain(days: 10, calls: [(105, 1_000), (110, 500)], puts: [(95, 2_000), (90, 300)])
        let far = chain(days: 60, calls: [(105, 400), (120, 5_000)], puts: [(95, 100)])
        let tooFar = chain(days: 150, calls: [(105, 99_999)], puts: [(80, 99_999)])
        let profile = OpenInterestProfile(chains: [far, tooFar, near], maxDays: 100, rate: 0.04, now: now)

        XCTAssertEqual(profile.expirations.count, 2)
        XCTAssertEqual(profile.strikes.map(\.strike), [90, 95, 105, 110, 120])
        let s105 = profile.strikes.first { $0.strike == 105 }!
        XCTAssertEqual(s105.callOpenInterest, 1_400)
        XCTAssertEqual(profile.totalCallOpenInterest, 6_900)
        XCTAssertEqual(profile.totalPutOpenInterest, 2_400)
        XCTAssertEqual(profile.putCallRatio!, 2_400.0 / 6_900.0, accuracy: 1e-9)

        // Prosté OI: největší call nad cenou je vzdálený 120, put pod cenou 95.
        XCTAssertEqual(profile.callWall(.raw)?.price, 120)
        XCTAssertEqual(profile.putWall(.raw)?.price, 95)
        XCTAssertEqual(profile.topLevels(1, weighting: .raw).first?.price, 120)

        // Váha 1/√DTE (DTE včetně posunu na zavření burzy).
        let d10 = OptionChain.daysToExpiry(near.expiration, from: now).squareRoot()
        let d60 = OptionChain.daysToExpiry(far.expiration, from: now).squareRoot()
        XCTAssertEqual(s105.callTimeWeighted, 1_000 / d10 + 400 / d60, accuracy: 1e-6)
        let s120 = profile.strikes.first { $0.strike == 120 }!
        XCTAssertEqual(s120.callTimeWeighted, 5_000 / d60, accuracy: 1e-6)
    }

    func testGammaSignsAndWalls() {
        let c = chain(days: 20, calls: [(105, 3_000), (130, 3_000)], puts: [(95, 2_000)])
        let profile = OpenInterestProfile(chains: [c], rate: 0.04, now: now)
        let s105 = profile.strikes.first { $0.strike == 105 }!
        let s130 = profile.strikes.first { $0.strike == 130 }!
        let s95 = profile.strikes.first { $0.strike == 95 }!
        XCTAssertGreaterThan(s105.callGamma, 0)
        XCTAssertLessThan(s95.putGamma, 0)
        // Daleko OTM call má malou gammu – v GEX vyhrává blízký 105, v prostém OI je to remíza.
        XCTAssertGreaterThan(s105.callGamma, s130.callGamma * 10)
        XCTAssertEqual(profile.callWall(.gamma)?.price, 105)
        XCTAssertEqual(profile.putWall(.gamma)?.price, 95)

        // Ručně spočtené GEX pro 105 call.
        let params = OptionParameters(spot: 100, strike: 105, days: OptionChain.daysToExpiry(c.expiration, from: now),
                                      rate: 0.04, volatility: 0.3)
        let expected = BlackScholes.greeks(.call, params).gamma * 3_000 * 100 * 100 * 100 * 0.01
        XCTAssertEqual(s105.callGamma, expected, accuracy: expected * 1e-9)
    }

    func testGammaFlipBetweenPutAndCallWalls() throws {
        // Silné puty pod cenou, silné cally nad: GEX je dole záporné, nahoře kladné → flip mezi nimi.
        let c = chain(days: 30, calls: [(110, 10_000)], puts: [(90, 10_000)])
        let profile = OpenInterestProfile(chains: [c], rate: 0, now: now)
        let flip = try XCTUnwrap(profile.gammaFlip())
        XCTAssertGreaterThan(flip, 90)
        XCTAssertLessThan(flip, 110)
        XCTAssertLessThan(profile.totalGamma(at: flip - 2), 0)
        XCTAssertGreaterThan(profile.totalGamma(at: flip + 2), 0)
    }

    func testSkipsMissingOpenInterestAndUsesFallbackVolatility() {
        let expiration = now.addingTimeInterval(15 * 86_400)
        let c = OptionChain(symbol: "TEST", underlyingPrice: 100, expirationDates: [expiration], expiration: expiration,
                            calls: [contract(.call, 100, oi: nil, expiration: expiration),
                                    contract(.call, 105, oi: 0, expiration: expiration),
                                    contract(.call, 110, oi: 50, expiration: expiration, iv: 0)],
                            puts: [contract(.put, 95, oi: 70, expiration: expiration, iv: 0.4)])
        let profile = OpenInterestProfile(chains: [c], rate: 0.04, now: now)
        XCTAssertEqual(profile.strikes.map(\.strike), [95, 110])
        XCTAssertGreaterThan(profile.strikes.last!.callGamma, 0, "chybějící IV nahradí medián")
    }

    func testMaxPain() throws {
        let c = chain(days: 5, calls: [(100, 100), (105, 1_000), (110, 100)], puts: [(95, 1_000), (100, 100), (105, 50)])
        let pain = try XCTUnwrap(c.maxPain)
        // Na 100: cally 105/110 bezcenné, call 100 = 0; puty: 105 → 5 × 50 × 100 = 25 000.
        // Na 105: call 100 → 5 × 100 × 100 = 50 000. Na 95: puty 100/105 → 5×100×100 + 10×50×100 = 100 000.
        XCTAssertEqual(pain.strike, 100)
        XCTAssertEqual(pain.payout, 25_000, accuracy: 1e-6)
    }
}
