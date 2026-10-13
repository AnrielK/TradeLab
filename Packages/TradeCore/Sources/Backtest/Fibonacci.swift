import Foundation

/// Fibonacciho swing: pohyb od počátku (start) k extrému (end) a jeho hladiny.
public struct FibonacciSwing: Hashable, Sendable {
    public enum Direction: String, Sendable { case up, down }

    public var direction: Direction
    public var startDate: Date
    public var startPrice: Double
    public var endDate: Date
    public var endPrice: Double

    public init(direction: Direction, startDate: Date, startPrice: Double, endDate: Date, endPrice: Double) {
        self.direction = direction
        self.startDate = startDate
        self.startPrice = startPrice
        self.endDate = endDate
        self.endPrice = endPrice
    }

    public static let retracementRatios = [0.236, 0.382, 0.5, 0.618, 0.786]
    public static let extensionRatios = [1.272, 1.618]

    /// Retracement: návrat z extrému zpět k počátku (0 = extrém, 1 = počátek).
    public func retracement(_ ratio: Double) -> Double {
        endPrice - (endPrice - startPrice) * ratio
    }

    /// Extenze: projekce pohybu za extrém (1 = extrém, 1.618 = 61,8 % za ním).
    public func extensionLevel(_ ratio: Double) -> Double {
        startPrice + (endPrice - startPrice) * ratio
    }
}

public enum Fibonacci {
    /// Poslední výrazný swing: nejvyšší high a nejnižší low posledních `lookback` svíček.
    /// Směr podle toho, co přišlo dřív (low → high = růst, retracement se měří dolů).
    public static func lastSwing(_ bars: [BacktestBar], lookback: Int) -> FibonacciSwing? {
        guard bars.count >= 3 else { return nil }
        let window = bars.suffix(max(lookback, 3))
        guard let hi = window.indices.max(by: { window[$0].high < window[$1].high }),
              let lo = window.indices.min(by: { window[$0].low < window[$1].low }),
              hi != lo else { return nil }
        let high = window[hi], low = window[lo]
        if lo < hi {
            return FibonacciSwing(direction: .up, startDate: low.date, startPrice: low.low,
                                  endDate: high.date, endPrice: high.high)
        }
        return FibonacciSwing(direction: .down, startDate: high.date, startPrice: high.high,
                              endDate: low.date, endPrice: low.low)
    }
}
