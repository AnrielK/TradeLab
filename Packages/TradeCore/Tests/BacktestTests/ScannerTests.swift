import XCTest
@testable import Backtest

/// Očekávané signály ověřené Python portem strategií.
final class ScannerTests: XCTestCase {
    private func bars(_ closes: [Double]) -> [BacktestBar] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return closes.enumerated().map { i, c in
            let o = i > 0 ? closes[i - 1] : c
            return BacktestBar(date: start.addingTimeInterval(Double(i) * 86_400), open: o,
                               high: max(o, c) + 0.3, low: min(o, c) - 0.3, close: c)
        }
    }

    private var breakout: [Double] {
        let range: [Double] = [100, 101, 102, 101, 100, 99, 98, 99]
        return (0..<8).flatMap { _ in range } + [104, 105, 106]
    }

    func testFreshBreakoutIsFound() throws {
        let hit = try XCTUnwrap(SetupScanner.scan(symbol: "TEST", bars: bars(breakout)))
        XCTAssertEqual(hit.direction, 1)
        XCTAssertEqual(hit.barsAgo, 2)
        XCTAssertEqual(Set(hit.patterns), [.levelBreakout, .trendlineBreakout])
        XCTAssertEqual(hit.suggestedPlay.direction, 1)
        XCTAssertEqual(hit.close, 106)
    }

    func testOldSignalIsIgnored() {
        XCTAssertNil(SetupScanner.scan(symbol: "TEST", bars: bars(breakout), maxAge: 1))
    }

    func testNoSetupOnFlatSeries() {
        XCTAssertNil(SetupScanner.scan(symbol: "TEST", bars: bars(Array(repeating: 100, count: 80))))
    }

    func testTooShortSeries() {
        XCTAssertNil(SetupScanner.scan(symbol: "TEST", bars: bars(Array(breakout.suffix(40)))))
    }
}
