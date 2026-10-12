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

    /// Fibonacciho výstup nad signály libovolné strategie.
    ///
    /// Při vstupu (signál strategie změní pozici z 0) se vezme swing posledních `lookback` svíček:
    /// cíl = extenze `target` (1 = předchozí extrém), stop = retracement `stop` (1 = počátek swingu).
    /// Pozice se zavře, když zavírací cena dosáhne cíle nebo stopu, nebo když strategie sama vystoupí.
    /// Nový vstup až poté, co strategie signál zruší nebo otočí.
    public static func applyExit(_ bars: [BacktestBar], targets base: [Int], lookback: Int,
                                 target: Double, stop: Double) -> [Int] {
        var result = [Int](repeating: 0, count: base.count)
        var position = 0
        var takeProfit = 0.0
        var stopLoss = 0.0
        var blockedSide = 0          // strana, na kterou se nesmí znovu vstoupit, dokud signál nezmizí

        for i in base.indices where i < bars.count {
            let signal = base[i]
            let close = bars[i].close
            if blockedSide != 0, signal != blockedSide { blockedSide = 0 }

            if position != 0 {
                let hitTarget = position == 1 ? close >= takeProfit : close <= takeProfit
                let hitStop = position == 1 ? close <= stopLoss : close >= stopLoss
                if hitTarget || hitStop {
                    blockedSide = signal == position ? position : 0
                    position = 0
                } else if signal != position {
                    position = 0              // strategie vystoupila nebo otočila
                }
            }

            if position == 0, signal != 0, signal != blockedSide {
                let from = max(0, i - lookback)
                let window = bars[from...i]
                let high = window.map(\.high).max()!
                let low = window.map(\.low).min()!
                let range = high - low
                if range > 0 {
                    if signal == 1 {
                        takeProfit = low + range * target
                        stopLoss = high - range * stop
                        if stopLoss >= close { stopLoss = low }
                        if takeProfit <= close { takeProfit = close + range * (target - 1 > 0 ? target - 1 : 0.272) }
                    } else {
                        takeProfit = high - range * target
                        stopLoss = low + range * stop
                        if stopLoss <= close { stopLoss = high }
                        if takeProfit >= close { takeProfit = close - range * (target - 1 > 0 ? target - 1 : 0.272) }
                    }
                    position = signal
                }
            }
            result[i] = position
        }
        return result
    }
}

/// Jak se vystupuje z obchodu.
public enum ExitRule: Hashable, Codable, Sendable {
    /// Podle pravidel strategie.
    case strategy
    /// Cíl na Fibonacciho extenzi, stop na retracementu swingu posledních `lookback` svíček.
    case fibonacci(lookback: Int, target: Double, stop: Double)

    public var name: String {
        switch self {
        case .strategy: return ""
        case .fibonacci(let n, let target, let stop):
            return "Fib výstup (swing \(n), cíl \(Self.ratio(target)), stop \(Self.ratio(stop)))"
        }
    }

    static func ratio(_ x: Double) -> String {
        String(format: x == x.rounded() ? "%.0f" : (x * 100 == (x * 100).rounded() ? "%.2f" : "%.3f"), x)
    }
}
