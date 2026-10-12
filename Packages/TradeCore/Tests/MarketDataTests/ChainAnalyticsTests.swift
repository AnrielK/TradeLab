import XCTest
import OptionsMath
@testable import MarketData

final class ChainAnalyticsTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testMonthlyExpirations() {
        func d(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
        XCTAssertTrue(ExpirationCalendar.isMonthly(d(1_792_108_800)))   // pá 16. 10. 2026
        XCTAssertFalse(ExpirationCalendar.isMonthly(d(1_793_318_400)))  // pá 30. 10. 2026 (weekly)
        XCTAssertTrue(ExpirationCalendar.isMonthly(d(1_795_132_800)))   // pá 20. 11. 2026
        XCTAssertTrue(ExpirationCalendar.isMonthly(d(1_799_971_200)))   // pá 15. 1. 2027
        XCTAssertFalse(ExpirationCalendar.isMonthly(d(1_775_088_000)))  // čt 2. 4. 2026
    }

    func testSummaryAndLegs() throws {
        let chain = try YahooParser.parseOptionChain(try fixture("options"))
        XCTAssertEqual(chain.strikes, [220, 230, 240])
        XCTAssertEqual(chain.atmStrike, 230)
        let now = chain.expiration.addingTimeInterval(-10 * 86_400)
        let summary = chain.summary(rate: 0.04, now: now)
        XCTAssertTrue(summary.isMonthly, "17. 10. 2025 je třetí pátek")
        XCTAssertNotNil(summary.atmVolatility)
        XCTAssertNil(summary.straddleMove, "fixture nemá ATM call")
        let sigma = try XCTUnwrap(summary.oneSigmaMove)
        XCTAssertEqual(sigma, 231.5 * summary.atmVolatility! * (summary.daysToExpiry / 365).squareRoot(), accuracy: 1e-9)

        let contract = try XCTUnwrap(chain.contract(.call, strike: 240))
        let leg = chain.leg(for: contract, side: .short, quantity: 2, rate: 0.04, now: now)
        XCTAssertEqual(leg.instrument, .call)
        XCTAssertEqual(leg.side, .short)
        XCTAssertEqual(leg.quantity, 2)
        XCTAssertEqual(leg.premium, 1.20, accuracy: 1e-9)
        XCTAssertEqual(leg.bid, 1.15)
        XCTAssertEqual(leg.ask, 1.25)
        XCTAssertEqual(leg.expiration, chain.expiration)

        var stale = leg
        stale.premium = 9
        let repriced = chain.repriced(stale, rate: 0.04, now: now)
        XCTAssertEqual(repriced.id, leg.id)
        XCTAssertEqual(repriced.premium, 1.20, accuracy: 1e-9)
        XCTAssertEqual(repriced.quantity, 2)
    }
}
