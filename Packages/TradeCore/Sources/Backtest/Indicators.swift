import Foundation

/// Technické indikátory nad řadou zavíracích cen.
/// Výstup má stejnou délku jako vstup; `nil` = na výpočet ještě není dost dat.
public enum TA {
    /// Prostý klouzavý průměr.
    public static func sma(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0 else { return values.map { _ in nil } }
        var result = [Double?](repeating: nil, count: values.count)
        var sum = 0.0
        for i in values.indices {
            sum += values[i]
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { result[i] = sum / Double(period) }
        }
        return result
    }

    /// Exponenciální průměr, první hodnota = SMA prvních `period` prvků.
    public static func ema(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return values.map { _ in nil } }
        var result = [Double?](repeating: nil, count: values.count)
        let alpha = 2.0 / Double(period + 1)
        var current = values[0..<period].reduce(0, +) / Double(period)
        result[period - 1] = current
        for i in period..<values.count {
            current = alpha * values[i] + (1 - alpha) * current
            result[i] = current
        }
        return result
    }

    /// RSI s Wilderovým vyhlazením.
    public static func rsi(_ values: [Double], _ period: Int = 14) -> [Double?] {
        guard period > 0, values.count > period else { return values.map { _ in nil } }
        var result = [Double?](repeating: nil, count: values.count)
        var gain = 0.0, loss = 0.0
        for i in 1...period {
            let change = values[i] - values[i - 1]
            gain += max(change, 0)
            loss += max(-change, 0)
        }
        var avgGain = gain / Double(period)
        var avgLoss = loss / Double(period)
        result[period] = rsiValue(avgGain, avgLoss)
        if values.count > period + 1 {
            for i in (period + 1)..<values.count {
                let change = values[i] - values[i - 1]
                avgGain = (avgGain * Double(period - 1) + max(change, 0)) / Double(period)
                avgLoss = (avgLoss * Double(period - 1) + max(-change, 0)) / Double(period)
                result[i] = rsiValue(avgGain, avgLoss)
            }
        }
        return result
    }

    private static func rsiValue(_ gain: Double, _ loss: Double) -> Double {
        if loss == 0 { return gain == 0 ? 50 : 100 }
        return 100 - 100 / (1 + gain / loss)
    }

    /// MACD = EMA(fast) − EMA(slow), signál = EMA(signal) z MACD.
    public static func macd(_ values: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9)
        -> (macd: [Double?], signal: [Double?], histogram: [Double?]) {
        let fastEMA = ema(values, fast)
        let slowEMA = ema(values, slow)
        var line = [Double?](repeating: nil, count: values.count)
        for i in values.indices {
            if let f = fastEMA[i], let s = slowEMA[i] { line[i] = f - s }
        }
        // Signál se počítá jen z definovaných hodnot MACD a vrátí se na původní indexy.
        let definedIndices = line.indices.filter { line[$0] != nil }
        let signalValues = ema(definedIndices.map { line[$0]! }, signal)
        var signalLine = [Double?](repeating: nil, count: values.count)
        for (k, index) in definedIndices.enumerated() { signalLine[index] = signalValues[k] }
        var histogram = [Double?](repeating: nil, count: values.count)
        for i in values.indices {
            if let m = line[i], let s = signalLine[i] { histogram[i] = m - s }
        }
        return (line, signalLine, histogram)
    }
}
