import Foundation

/// Strategie nad strukturou trhu: supporty, rezistence a trendové linie.
///
/// Žádný pohled do budoucnosti: swing (pivot) na svíčce `p` je potvrzený až na svíčce `p + k`,
/// takže v baru `i` se hladiny a linie skládají jen z pivotů s indexem ≤ `i − k`.
/// Výstupy se vyhodnocují na zavírací ceně, obchod proběhne na otevření další svíčky.
enum Structure {
    static let pivotWindow = 3

    /// Potvrzené pivoty v okně `[i − lookback, i − k]`.
    static func confirmed(_ pivots: [LevelFinder.Pivot], at i: Int, lookback: Int) -> [LevelFinder.Pivot] {
        let lo = i - lookback, hi = i - pivotWindow
        return pivots.filter { $0.index >= lo && $0.index <= hi }
    }

    /// Horizontální hladiny (shluky aspoň dvou pivotů).
    static func levels(_ pivots: [LevelFinder.Pivot], tolerance: Double) -> [Double] {
        var clusters: [[Double]] = []
        for price in pivots.map(\.price).sorted() {
            if let last = clusters.last {
                let mean = last.reduce(0, +) / Double(last.count)
                if abs(price - mean) <= tolerance {
                    clusters[clusters.count - 1].append(price)
                    continue
                }
            }
            clusters.append([price])
        }
        return clusters.filter { $0.count >= 2 }.map { $0.reduce(0, +) / Double($0.count) }
    }

    /// Nejlepší platná trendová linie daného druhu (platná do baru `i − 1`).
    static func trendLine(_ bars: [BacktestBar], pivots: [LevelFinder.Pivot], kind: PriceLevel.Kind,
                          at i: Int, tolerance: Double) -> TrendLine? {
        let side = Array(pivots.filter { $0.isHigh == (kind == .resistance) }.suffix(12))
        return LevelFinder.bestLines(bars, pivots: side, kind: kind, tolerance: tolerance, max: 1,
                                     lastIndex: i - 1).first
    }

    // MARK: - Supporty a rezistence

    /// Odraz: svíčka se dotkne nejbližšího supportu (low v toleranci) a zavře nad ním zeleně → long.
    /// Cíl = nejbližší rezistence (jinak `rewardRisk` × riziko), stop = zavření pod supportem.
    static func levelBounce(_ bars: [BacktestBar], lookback: Int, tolerance: Double, rewardRisk: Double,
                            allowShort: Bool) -> [Int] {
        let n = bars.count
        var targets = [Int](repeating: 0, count: n)
        let pivots = LevelFinder.pivots(bars, window: pivotWindow)
        var position = 0, level = 0.0, target = 0.0

        for i in 0..<n {
            let bar = bars[i]
            if position == 1, bar.close < level * (1 - tolerance) || bar.close >= target { position = 0 }
            if position == -1, bar.close > level * (1 + tolerance) || bar.close <= target { position = 0 }

            if position == 0, i > 2 * pivotWindow {
                let tol = bar.close * tolerance
                let levels = Self.levels(confirmed(pivots, at: i, lookback: lookback), tolerance: tol)
                let support = levels.filter { $0 < bar.close }.max()
                let resistance = levels.filter { $0 > bar.close }.min()

                if let s = support, bar.low <= s + tol, bar.close > bar.open {
                    let risk = bar.close - s * (1 - tolerance)
                    position = 1
                    level = s
                    target = resistance ?? (bar.close + rewardRisk * risk)
                } else if allowShort, let r = resistance, bar.high >= r - tol, bar.close < bar.open {
                    let risk = r * (1 + tolerance) - bar.close
                    position = -1
                    level = r
                    target = support ?? (bar.close - rewardRisk * risk)
                }
            }
            targets[i] = position
        }
        return targets
    }

    /// Průraz: zavření nad rezistencí (o toleranci), předchozí zavření pod ní → long.
    /// Stop = návrat pod hladinu, cíl = další rezistence (jinak `rewardRisk` × riziko).
    static func levelBreakout(_ bars: [BacktestBar], lookback: Int, tolerance: Double, rewardRisk: Double,
                              allowShort: Bool) -> [Int] {
        let n = bars.count
        var targets = [Int](repeating: 0, count: n)
        let pivots = LevelFinder.pivots(bars, window: pivotWindow)
        var position = 0, level = 0.0, target = 0.0

        for i in 1..<max(n, 1) {
            let bar = bars[i]
            let previous = bars[i - 1].close
            if position == 1, bar.close < level * (1 - tolerance) || bar.close >= target { position = 0 }
            if position == -1, bar.close > level * (1 + tolerance) || bar.close <= target { position = 0 }

            if position == 0, i > 2 * pivotWindow {
                let tol = bar.close * tolerance
                let levels = Self.levels(confirmed(pivots, at: i, lookback: lookback), tolerance: tol)
                let brokenUp = levels.filter { previous <= $0 && bar.close > $0 + tol }.max()
                let brokenDown = levels.filter { previous >= $0 && bar.close < $0 - tol }.min()

                if let r = brokenUp {
                    let risk = bar.close - r * (1 - tolerance)
                    position = 1
                    level = r
                    target = levels.filter { $0 > bar.close + tol }.min() ?? (bar.close + rewardRisk * risk)
                } else if allowShort, let s = brokenDown {
                    let risk = s * (1 + tolerance) - bar.close
                    position = -1
                    level = s
                    target = levels.filter { $0 < bar.close - tol }.max() ?? (bar.close - rewardRisk * risk)
                }
            }
            targets[i] = position
        }
        return targets
    }

    // MARK: - Trendové linie

    /// Odraz od trendline: dotyk support linie a zelené zavření nad ní → long (short od rezistenční linie).
    /// Stop = zavření pod linií (posouvá se s ní), cíl = `rewardRisk` × riziko.
    static func trendlineBounce(_ bars: [BacktestBar], lookback: Int, tolerance: Double, rewardRisk: Double,
                                allowShort: Bool) -> [Int] {
        let n = bars.count
        var targets = [Int](repeating: 0, count: n)
        let pivots = LevelFinder.pivots(bars, window: pivotWindow)
        var position = 0, target = 0.0
        var line: TrendLine?

        for i in 0..<n {
            let bar = bars[i]
            if position != 0, let active = line {
                let v = active.value(at: i)
                if position == 1, bar.close < v * (1 - tolerance) || bar.close >= target { position = 0 }
                if position == -1, bar.close > v * (1 + tolerance) || bar.close <= target { position = 0 }
            }

            if position == 0, i > 2 * pivotWindow + 3 {
                let tol = bar.close * tolerance
                let window = confirmed(pivots, at: i, lookback: lookback)
                if let support = trendLine(bars, pivots: window, kind: .support, at: i, tolerance: tol) {
                    let v = support.value(at: i)
                    if v > 0, bar.low <= v + tol, bar.close > v, bar.close > bar.open {
                        position = 1
                        line = support
                        target = bar.close + rewardRisk * (bar.close - v * (1 - tolerance))
                    }
                }
                if position == 0, allowShort,
                   let resistance = trendLine(bars, pivots: window, kind: .resistance, at: i, tolerance: tol) {
                    let v = resistance.value(at: i)
                    if v > 0, bar.high >= v - tol, bar.close < v, bar.close < bar.open {
                        position = -1
                        line = resistance
                        target = bar.close - rewardRisk * (v * (1 + tolerance) - bar.close)
                    }
                }
            }
            targets[i] = position
        }
        return targets
    }

    /// Průraz trendline: zavření nad rezistenční linií (o toleranci) → long; pod support linií → short.
    /// Stop = návrat za linii, cíl = `rewardRisk` × riziko.
    static func trendlineBreakout(_ bars: [BacktestBar], lookback: Int, tolerance: Double, rewardRisk: Double,
                                  allowShort: Bool) -> [Int] {
        let n = bars.count
        var targets = [Int](repeating: 0, count: n)
        let pivots = LevelFinder.pivots(bars, window: pivotWindow)
        var position = 0, target = 0.0
        var line: TrendLine?

        for i in 0..<n {
            let bar = bars[i]
            if position != 0, let active = line {
                let v = active.value(at: i)
                if position == 1, bar.close < v * (1 - tolerance) || bar.close >= target { position = 0 }
                if position == -1, bar.close > v * (1 + tolerance) || bar.close <= target { position = 0 }
            }

            if position == 0, i > 2 * pivotWindow + 3 {
                let tol = bar.close * tolerance
                let window = confirmed(pivots, at: i, lookback: lookback)
                // Linie platná do předchozí svíčky → zavření za ní je čerstvý průraz.
                if let resistance = trendLine(bars, pivots: window, kind: .resistance, at: i, tolerance: tol) {
                    let v = resistance.value(at: i)
                    if v > 0, bar.close > v + tol {
                        position = 1
                        line = resistance
                        target = bar.close + rewardRisk * (bar.close - v * (1 - tolerance))
                    }
                }
                if position == 0, allowShort,
                   let support = trendLine(bars, pivots: window, kind: .support, at: i, tolerance: tol) {
                    let v = support.value(at: i)
                    if v > 0, bar.close < v - tol {
                        position = -1
                        line = support
                        target = bar.close - rewardRisk * (v * (1 + tolerance) - bar.close)
                    }
                }
            }
            targets[i] = position
        }
        return targets
    }

    // MARK: - Swing pullback (vlastní strategie TradeLab)

    /// Pullback ve směru trendu:
    /// 1. trend – cena i EMA 50 nad SMA `trendPeriod` a EMA 50 roste;
    /// 2. pullback – za posledních 5 svíček se cena vrátila do zóny 0,382–0,786 swingu (`swingLookback` svíček)
    ///    nebo k EMA 20;
    /// 3. momentum – RSI 14 kleslo pod 45 a teď roste;
    /// 4. spoušť – zelená svíčka se zavřením nad high předchozí.
    /// Stop pod minimem pullbacku, cíl na extenzi 1,272 swingu, předčasný výstup při zavření pod EMA 50.
    /// Short zrcadlově.
    static func swingPullback(_ bars: [BacktestBar], trendPeriod: Int, swingLookback: Int, allowShort: Bool) -> [Int] {
        let n = bars.count
        var targets = [Int](repeating: 0, count: n)
        let closes = bars.map(\.close)
        let ema20 = TA.ema(closes, 20)
        let ema50 = TA.ema(closes, 50)
        let trend = TA.sma(closes, trendPeriod)
        let rsi = TA.rsi(closes, 14)
        var position = 0, stop = 0.0, target = 0.0

        for i in max(swingLookback, 5)..<max(n, max(swingLookback, 5)) {
            guard let fast = ema20[i], let mid = ema50[i], let midPast = ema50[i - 5], let t = trend[i],
                  let r = rsi[i], let rPrev = rsi[i - 1] else { continue }
            let bar = bars[i]

            if position == 1, bar.close <= stop || bar.close >= target || bar.close < mid { position = 0 }
            if position == -1, bar.close >= stop || bar.close <= target || bar.close > mid { position = 0 }

            if position == 0 {
                let recent = bars[(i - 4)...i]
                let recentLow = recent.map(\.low).min()!
                let recentHigh = recent.map(\.high).max()!
                let swing = bars[(i - swingLookback)...i]
                let high = swing.map(\.high).max()!
                let low = swing.map(\.low).min()!
                let range = high - low
                let recentRSI = rsi[(i - 4)...i].compactMap { $0 }
                guard range > 0 else { targets[i] = position; continue }

                let upTrend = bar.close > t && mid > t && mid > midPast
                let longZone = (recentLow <= high - 0.382 * range && recentLow >= high - 0.786 * range)
                    || recentLow <= fast * 1.005
                let longMomentum = (recentRSI.min() ?? 50) < 45 && r > rPrev
                let longTrigger = bar.close > bar.open && bar.close > bars[i - 1].high

                let downTrend = bar.close < t && mid < t && mid < midPast
                let shortZone = (recentHigh >= low + 0.382 * range && recentHigh <= low + 0.786 * range)
                    || recentHigh >= fast * 0.995
                let shortMomentum = (recentRSI.max() ?? 50) > 55 && r < rPrev
                let shortTrigger = bar.close < bar.open && bar.close < bars[i - 1].low

                if upTrend, longZone, longMomentum, longTrigger, recentLow < bar.close {
                    position = 1
                    stop = recentLow
                    target = low + 1.272 * range
                    if target <= bar.close { target = bar.close + 2 * (bar.close - stop) }
                } else if allowShort, downTrend, shortZone, shortMomentum, shortTrigger, recentHigh > bar.close {
                    position = -1
                    stop = recentHigh
                    target = high - 1.272 * range
                    if target >= bar.close { target = bar.close - 2 * (stop - bar.close) }
                }
            }
            targets[i] = position
        }
        return targets
    }
}
