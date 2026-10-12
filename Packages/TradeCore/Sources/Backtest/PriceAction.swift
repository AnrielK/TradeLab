import Foundation

/// Cenové (price action) strategie nad OHLC svíčkami.
/// Každá vrací cílovou pozici po zavření baru (1 long, 0 bez pozice, −1 short);
/// obchod pak engine provede za otevírací cenu dalšího baru.
enum PriceAction {

    // MARK: - Break & retest

    /// Průraz rezistence (nejvyšší high posledních `lookback` barů), návrat k prolomené hladině
    /// do `retestBars` barů a zavření nad ní → long. Stop: zavření pod hladinou o víc než toleranci,
    /// trailing výstup pod nejnižší low posledních `lookback / 2` barů. Short zrcadlově od supportu.
    static func breakRetest(_ bars: [BacktestBar], lookback: Int, retestBars: Int, tolerance: Double,
                            allowShort: Bool) -> [Int] {
        let n = bars.count
        var targets = [Int](repeating: 0, count: n)
        guard lookback >= 2, n > lookback else { return targets }
        let exitWindow = max(lookback / 2, 3)

        var position = 0
        var stop = 0.0
        // Čekající průraz: směr, hladina, index průrazu.
        var armed: (side: Int, level: Double, index: Int)? = nil

        for i in lookback..<n {
            let bar = bars[i]
            let window = bars[(i - lookback)..<i]
            let resistance = window.map(\.high).max()!
            let support = window.map(\.low).min()!
            let exitFrom = max(i - exitWindow, 0)
            let trailLow = bars[exitFrom..<i].map(\.low).min() ?? bar.low
            let trailHigh = bars[exitFrom..<i].map(\.high).max() ?? bar.high

            // 1) výstupy
            if position == 1, bar.close < stop || bar.close < trailLow {
                position = 0
            } else if position == -1, bar.close > stop || bar.close > trailHigh {
                position = 0
            }

            // 2) retest čekajícího průrazu
            if position == 0, let setup = armed {
                let tol = setup.level * tolerance
                if i - setup.index > retestBars {
                    armed = nil
                } else if setup.side == 1 {
                    if bar.close < setup.level - tol {
                        armed = nil                                   // průraz selhal
                    } else if i > setup.index, bar.low <= setup.level + tol, bar.close > setup.level {
                        position = 1
                        stop = setup.level - tol
                        armed = nil
                    }
                } else {
                    if bar.close > setup.level + tol {
                        armed = nil
                    } else if i > setup.index, bar.high >= setup.level - tol, bar.close < setup.level {
                        position = -1
                        stop = setup.level + tol
                        armed = nil
                    }
                }
            }

            // 3) nový průraz
            if position == 0, armed == nil {
                if bar.close > resistance {
                    armed = (1, resistance, i)
                } else if allowShort, bar.close < support {
                    armed = (-1, support, i)
                }
            }
            targets[i] = position
        }
        return targets
    }

    // MARK: - Reversal

    /// Obrat z extrému: RSI bylo v posledních 3 barech pod `lower` a přijde býčí obratová svíčka
    /// (zelená, zavření nad high předchozího baru) → long. Stop pod swing low posledních 3 barů,
    /// výstup při RSI nad `upper` nebo medvědí obratové svíčce. Short zrcadlově.
    static func reversal(_ bars: [BacktestBar], period: Int, lower: Double, upper: Double,
                         allowShort: Bool) -> [Int] {
        let n = bars.count
        var targets = [Int](repeating: 0, count: n)
        guard n > period + 1 else { return targets }
        let rsi = TA.rsi(bars.map(\.close), period)

        var position = 0
        var stop = 0.0

        for i in 1..<n {
            guard let r = rsi[i] else { continue }
            let bar = bars[i]
            let previous = bars[i - 1]
            let recent = rsi[max(i - 3, 0)...i].compactMap { $0 }
            let wasOversold = recent.contains { $0 < lower }
            let wasOverbought = recent.contains { $0 > upper }
            let bullish = bar.close > bar.open && bar.close > previous.high
            let bearish = bar.close < bar.open && bar.close < previous.low
            let swingLow = bars[max(i - 3, 0)...i].map(\.low).min()!
            let swingHigh = bars[max(i - 3, 0)...i].map(\.high).max()!

            switch position {
            case 1:
                if bar.close < stop || r > upper || bearish { position = 0 }
            case -1:
                if bar.close > stop || r < lower || bullish { position = 0 }
            default:
                break
            }

            if position == 0 {
                if wasOversold, bullish {
                    position = 1
                    stop = swingLow
                } else if allowShort, wasOverbought, bearish {
                    position = -1
                    stop = swingHigh
                }
            }
            targets[i] = position
        }
        return targets
    }

    // MARK: - Odraz od klouzavého průměru

    /// V trendu (cena nad pomalým SMA a rostoucí průměr) se cena vrátí k průměru (low v toleranci),
    /// zavře nad ním zelenou svíčkou → long. Výstup při zavření pod průměrem o víc než toleranci.
    /// Short zrcadlově v klesajícím trendu.
    static func maBounce(_ bars: [BacktestBar], period: Int, trendPeriod: Int, tolerance: Double,
                         exponential: Bool, allowShort: Bool) -> [Int] {
        let n = bars.count
        var targets = [Int](repeating: 0, count: n)
        let closes = bars.map(\.close)
        let ma = exponential ? TA.ema(closes, period) : TA.sma(closes, period)
        let trend = TA.sma(closes, trendPeriod)
        let slopeLag = 5

        var position = 0
        for i in slopeLag..<max(n, slopeLag) {
            guard let m = ma[i], let mPast = ma[i - slopeLag], let t = trend[i] else { continue }
            let bar = bars[i]
            let tol = m * tolerance

            if position == 1, bar.close < m - tol { position = 0 }
            if position == -1, bar.close > m + tol { position = 0 }

            if position == 0 {
                let upTrend = bar.close > t && m > mPast
                let downTrend = bar.close < t && m < mPast
                if upTrend, bar.low <= m + tol, bar.close > m, bar.close > bar.open {
                    position = 1
                } else if allowShort, downTrend, bar.high >= m - tol, bar.close < m, bar.close < bar.open {
                    position = -1
                }
            }
            targets[i] = position
        }
        return targets
    }
}
