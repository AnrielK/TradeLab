import XCTest
@testable import Backtest

final class FibonacciTests: XCTestCase {
    private func bars(_ closes: [Double]) -> [BacktestBar] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return closes.enumerated().map { i, c in
            BacktestBar(date: start.addingTimeInterval(Double(i) * 86_400), open: c, high: c + 0.5, low: c - 0.5, close: c)
        }
    }

    private let entryAt10 = (0..<20).map { $0 < 10 ? 0 : 1 }

    func testTargetHit() {
        // Swing 99,5–110,5 → cíl 1,272 = 113,492; zavření 114 na baru 14.
        let b = bars((0..<20).map { 100 + Double($0) })
        let t = Fibonacci.applyExit(b, targets: entryAt10, lookback: 10, target: 1.272, stop: 0.786)
        XCTAssertEqual(Array(t[9...15]), [0, 1, 1, 1, 1, 0, 0])
        // Signál strategie trvá dál → žádný nový vstup.
        XCTAssertEqual(t.last, 0)
    }

    func testStopHit() {
        // Stop 0,786 = 101,854; zavření 100 na baru 15.
        var closes = (0...12).map { 100 + Double($0) }
        closes += [108, 104, 100, 99, 98, 97, 96]
        let t = Fibonacci.applyExit(bars(closes), targets: entryAt10, lookback: 10, target: 1.618, stop: 0.786)
        XCTAssertEqual(Array(t[10...16]), [1, 1, 1, 1, 1, 0, 0])
    }

    func testStrategyExitStillApplies() {
        var base = entryAt10
        base[12] = 0
        base[13] = 0
        let b = bars((0..<20).map { 100 + Double($0) * 0.1 })
        let t = Fibonacci.applyExit(b, targets: base, lookback: 10, target: 1.618, stop: 1)
        XCTAssertEqual(t[11], 1)
        XCTAssertEqual(t[12], 0)
        XCTAssertEqual(t[14], 1)   // nový signál po resetu
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

    func testEngineWithFibExit() {
        let b = bars((0..<30).map { 100 + Double($0) })
        let config = BacktestConfig(strategy: .buyAndHold, costBps: 0,
                                    exit: .fibonacci(lookback: 10, target: 1.272, stop: 0.786))
        let result = BacktestEngine.run(bars: b, config: config)
        XCTAssertEqual(result.trades.count, 1)
        XCTAssertNotNil(result.trades.first?.exitDate)
        XCTAssertTrue(config.title.contains("Fib výstup"))
    }
}
