import XCTest
@testable import Backtest

final class PaperAccountTests: XCTestCase {
    func testLongLifecycle() throws {
        var a = PaperAccount(startingCash: 10_000)
        let shares = a.shares(entry: 100, stop: 95, riskFraction: 0.01, maxFraction: 0.5)
        XCTAssertEqual(shares, 20)                       // 100 USD riziko / 5 USD na akcii
        let p = try XCTUnwrap(a.open(symbol: "aapl", side: 1, shares: shares, price: 100, date: Date(),
                                     stop: 95, target: 110, source: "test"))
        XCTAssertEqual(a.cash, 8_000)
        XCTAssertEqual(a.equity, 10_000, accuracy: 1e-9)
        XCTAssertTrue(a.mark(prices: ["AAPL": 105], date: Date()).isEmpty)
        XCTAssertEqual(a.equity, 10_100, accuracy: 1e-9)
        let closed = a.mark(prices: ["AAPL": 111], date: Date())
        XCTAssertEqual(closed.first?.reason, "cíl")
        XCTAssertEqual(closed.first?.id, p.id)
        XCTAssertTrue(a.positions.isEmpty)
        XCTAssertEqual(a.cash, 10_220, accuracy: 1e-9)
        XCTAssertEqual(a.winRate, 1)
    }

    func testShortStop() throws {
        var a = PaperAccount(startingCash: 10_000)
        try XCTUnwrap(a.open(symbol: "TSLA", side: -1, shares: 10, price: 200, date: Date(), stop: 210,
                             target: 180, source: "test"))
        XCTAssertEqual(a.equity, 10_000, accuracy: 1e-9)
        let closed = a.mark(prices: ["TSLA": 212], date: Date())
        XCTAssertEqual(closed.first?.reason, "stop")
        XCTAssertEqual(a.equity, 9_880, accuracy: 1e-9)
        XCTAssertEqual(a.realizedPnL, -120, accuracy: 1e-9)
    }

    func testSizingCaps() {
        let a = PaperAccount(startingCash: 10_000)
        // Stop velmi blízko → omezí to max. 20 % účtu.
        XCTAssertEqual(a.shares(entry: 50, stop: 49.99, riskFraction: 0.01, maxFraction: 0.2), 40)
        XCTAssertEqual(a.shares(entry: 0, stop: nil, riskFraction: 0.01, maxFraction: 0.2), 0)
    }

    func testLongNeedsCash() {
        var a = PaperAccount(startingCash: 1_000)
        XCTAssertNil(a.open(symbol: "X", side: 1, shares: 20, price: 100, date: Date(), stop: nil, target: nil,
                            source: "test"))
    }
}
