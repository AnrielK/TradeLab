import Foundation

/// Obchodní pravidla backtestu. Každé vrací cílovou pozici po zavření baru:
/// 1 = long, 0 = bez pozice, −1 = short.
public enum BacktestStrategy: Hashable, Codable, Sendable {
    case buyAndHold
    case smaCross(fast: Int, slow: Int)
    case macdCross(fast: Int, slow: Int, signal: Int)
    case rsiReversion(period: Int, lower: Double, upper: Double)

    public var name: String {
        switch self {
        case .buyAndHold: return "Buy & hold"
        case .smaCross(let f, let s): return "SMA \(f)/\(s)"
        case .macdCross(let f, let s, let g): return "MACD \(f)/\(s)/\(g)"
        case .rsiReversion(let p, let lo, let hi): return "RSI \(p) (\(Int(lo))/\(Int(hi)))"
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
        }
    }
}
