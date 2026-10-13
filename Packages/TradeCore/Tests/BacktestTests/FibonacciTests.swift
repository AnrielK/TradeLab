import XCTest
@testable import Backtest

final class FibonacciTests: XCTestCase {
    private func bars(_ closes: [Double]) -> [BacktestBar] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return closes.enumerated().map { i, c in
            BacktestBar(date: start.addingTimeInterval(Double(i) * 86_400), open: c, high: c + 0.5, low: c - 0.5, close: c)
        }
    }

    func testSwingAndLevels() {
        let b = bars([100, 105, 120, 115, 110, 112])
        guard let swing = Fibonacci.lastSwing(b, lookback: 10) else { return XCTFail("swing") }
        XCTAssertEqual(swing.direction, .up)
        XCTAssertEqual(swing.startPrice, 99.5)
        XCTAssertEqual(swing.endPrice, 120.5)
        XCTAssertEqual(swing.retracement(0.5), 110, accuracy: 1e-9)
        XCTAssertEqual(swing.extensionLevel(1.618), 99.5 + 21 * 1.618, accuracy: 1e-9)
    }
}
