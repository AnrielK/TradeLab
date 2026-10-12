import Foundation

/// Obchodní pravidla backtestu. Každé vrací cílovou pozici po zavření baru:
/// 1 = long, 0 = bez pozice, −1 = short.
public enum BacktestStrategy: Hashable, Codable, Sendable {
    case buyAndHold
    case smaCross(fast: Int, slow: Int)
    case macdCross(fast: Int, slow: Int, signal: Int)
    case rsiReversion(period: Int, lower: Double, upper: Double)
    /// Průraz hladiny a její retest (tolerance jako zlomek, 0.01 = 1 %).
    case breakRetest(lookback: Int, retestBars: Int, tolerance: Double)
    /// Obrat z přeprodanosti/překoupenosti potvrzený obratovou svíčkou.
    case reversal(period: Int, lower: Double, upper: Double)
    /// Odraz od klouzavého průměru ve směru trendu.
    case maBounce(period: Int, trendPeriod: Int, tolerance: Double, exponential: Bool)
    /// Odraz od supportu / rezistence (hladiny ze swingů posledních `lookback` svíček).
    case levelBounce(lookback: Int, tolerance: Double, rewardRisk: Double)
    /// Průraz supportu / rezistence.
    case levelBreakout(lookback: Int, tolerance: Double, rewardRisk: Double)
    /// Odraz od trendové linie.
    case trendlineBounce(lookback: Int, tolerance: Double, rewardRisk: Double)
    /// Průraz trendové linie.
    case trendlineBreakout(lookback: Int, tolerance: Double, rewardRisk: Double)
    /// Vlastní swingová strategie: pullback ve směru trendu s potvrzením.
    case swingPullback(trendPeriod: Int, swingLookback: Int)

    public var name: String {
        switch self {
        case .buyAndHold: return "Buy & hold"
        case .smaCross(let f, let s): return "SMA \(f)/\(s)"
        case .macdCross(let f, let s, let g): return "MACD \(f)/\(s)/\(g)"
        case .rsiReversion(let p, let lo, let hi): return "RSI \(p) (\(Int(lo))/\(Int(hi)))"
        case .breakRetest(let n, let r, let tol):
            return "Break & retest \(n) (retest \(r), \(Self.percent(tol)))"
        case .reversal(let p, let lo, let hi): return "Reversal RSI \(p) (\(Int(lo))/\(Int(hi)))"
        case .maBounce(let p, let t, let tol, let ema):
            return "Odraz od \(ema ? "EMA" : "SMA") \(p) (trend \(t), \(Self.percent(tol)))"
        case .levelBounce(let n, let tol, let rr): return "Odraz od S/R (\(n), \(Self.percent(tol)), R:R \(Self.ratio(rr)))"
        case .levelBreakout(let n, let tol, let rr): return "Průraz S/R (\(n), \(Self.percent(tol)), R:R \(Self.ratio(rr)))"
        case .trendlineBounce(let n, let tol, let rr): return "Odraz od trendline (\(n), \(Self.percent(tol)), R:R \(Self.ratio(rr)))"
        case .trendlineBreakout(let n, let tol, let rr): return "Průraz trendline (\(n), \(Self.percent(tol)), R:R \(Self.ratio(rr)))"
        case .swingPullback(let t, let s): return "Swing pullback (trend \(t), swing \(s))"
        }
    }

    static func ratio(_ x: Double) -> String {
        x == x.rounded() ? "\(Int(x))" : String(format: "%.1f", x)
    }

    static func percent(_ x: Double) -> String {
        let value = x * 100
        return value == value.rounded() ? "\(Int(value)) %" : String(format: "%.1f %%", value)
    }

    /// Strategie, které potřebují celé svíčky (open/high/low), ne jen zavírací ceny.
    public var usesOHLC: Bool {
        switch self {
        case .buyAndHold, .smaCross, .macdCross, .rsiReversion: return false
        default: return true
        }
    }

    /// Cílová pozice po zavření každého baru ze svíček.
    public func targets(bars: [BacktestBar], allowShort: Bool) -> [Int] {
        switch self {
        case .breakRetest(let lookback, let retestBars, let tolerance):
            return PriceAction.breakRetest(bars, lookback: lookback, retestBars: retestBars,
                                           tolerance: tolerance, allowShort: allowShort)
        case .reversal(let period, let lower, let upper):
            return PriceAction.reversal(bars, period: period, lower: lower, upper: upper, allowShort: allowShort)
        case .maBounce(let period, let trendPeriod, let tolerance, let exponential):
            return PriceAction.maBounce(bars, period: period, trendPeriod: trendPeriod, tolerance: tolerance,
                                        exponential: exponential, allowShort: allowShort)
        case .levelBounce(let n, let tol, let rr):
            return Structure.levelBounce(bars, lookback: n, tolerance: tol, rewardRisk: rr, allowShort: allowShort)
        case .levelBreakout(let n, let tol, let rr):
            return Structure.levelBreakout(bars, lookback: n, tolerance: tol, rewardRisk: rr, allowShort: allowShort)
        case .trendlineBounce(let n, let tol, let rr):
            return Structure.trendlineBounce(bars, lookback: n, tolerance: tol, rewardRisk: rr, allowShort: allowShort)
        case .trendlineBreakout(let n, let tol, let rr):
            return Structure.trendlineBreakout(bars, lookback: n, tolerance: tol, rewardRisk: rr, allowShort: allowShort)
        case .swingPullback(let t, let s):
            return Structure.swingPullback(bars, trendPeriod: t, swingLookback: s, allowShort: allowShort)
        default:
            return targets(closes: bars.map(\.close), allowShort: allowShort)
        }
    }

    /// Cílová pozice po zavření každého baru. Nedostatek dat = bez pozice.
    public func targets(closes: [Double], allowShort: Bool) -> [Int] {
        let flat = allowShort ? -1 : 0
        switch self {
        case .buyAndHold:
            return closes.map { _ in 1 }

        case .smaCross(let fast, let slow):
            let f = TA.sma(closes, fast)
            let s = TA.sma(closes, slow)
            return closes.indices.map { i in
                guard let a = f[i], let b = s[i] else { return 0 }
                return a > b ? 1 : flat
            }

        case .macdCross(let fast, let slow, let signal):
            let m = TA.macd(closes, fast: fast, slow: slow, signal: signal)
            return closes.indices.map { i in
                guard let line = m.macd[i], let sig = m.signal[i] else { return 0 }
                return line > sig ? 1 : flat
            }

        case .rsiReversion(let period, let lower, let upper):
            // Nákup při přeprodanosti, výstup (případně short) při překoupenosti.
            let r = TA.rsi(closes, period)
            var position = 0
            return closes.indices.map { i in
                guard let value = r[i] else { return 0 }
                if value < lower {
                    position = 1
                } else if value > upper {
                    position = allowShort ? -1 : 0
                }
                return position
            }

        case .breakRetest, .reversal, .maBounce, .levelBounce, .levelBreakout, .trendlineBounce,
             .trendlineBreakout, .swingPullback:
            // Potřebují OHLC – ze zavíracích cen se postaví „svíčky“ bez knotů.
            let bars = closes.enumerated().map { i, c in
                BacktestBar(date: Date(timeIntervalSince1970: Double(i) * 86_400),
                            open: i > 0 ? closes[i - 1] : c, high: max(c, i > 0 ? closes[i - 1] : c),
                            low: min(c, i > 0 ? closes[i - 1] : c), close: c)
            }
            return targets(bars: bars, allowShort: allowShort)
        }
    }
}
