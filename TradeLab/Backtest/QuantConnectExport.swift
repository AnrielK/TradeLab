import Foundation
import Backtest
import MarketData

extension QuantConnectExport {
    enum Instrument { case stock, options }

    /// Sestaví celý skript `main.py` pro QuantConnect.
    static func script(instrument: Instrument, ticker: String, range: HistoryRange,
                       strategy: BacktestStrategy, exit: ExitRule, allowShort: Bool, costBps: Double,
                       options: OptionsBacktestConfig?, now: Date = Date()) -> String {
        let symbol = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        let (start, end) = dates(range: range, options: instrument == .options, now: now)
        let isOptions = instrument == .options && options != nil

        var signal = constructor(strategy, allowShort: isOptions ? true : allowShort)
        if !isOptions, case .fibonacci(let n, let target, let stop) = exit {
            signal = "FibExit(\(signal), \(n), \(py(target)), \(py(stop)))"
        }

        var values: [String: String] = [
            "START": start, "END": end, "CASH": "10000", "TICKER": symbol, "SIGNAL": signal,
            "SLIPPAGE": py(costBps / 10_000),
        ]
        var template = stockTemplate
        if isOptions, let o = options {
            template = optionsTemplate
            let auto: Bool, condor: Bool, bullish: OptionPlay, bearish: OptionPlay?
            switch o.selection {
            case .auto(let c): (auto, condor, bullish, bearish) = (true, c, .bullPutSpread, .bearCallSpread)
            case .fixed(let b, let s): (auto, condor, bullish, bearish) = (false, false, b, s)
            }
            values.merge([
                "MIN_DTE": "\(max(o.daysToExpiry - 10, o.exitDaysToExpiry + 1))",
                "MAX_DTE": "\(o.daysToExpiry + 15)",
                "WARMUP_DAYS": "\(warmupDays(strategy))",
                "AUTO": py(auto), "CONDOR": py(condor),
                "BULLISH": playKey(bullish),
                "BEARISH": bearish.map { "\"\(playKey($0))\"" } ?? "None",
                "ALLOW_BEARISH": py(o.allowBearish),
                "DTE": "\(o.daysToExpiry)",
                "SHORT_DELTA": py(o.shortDelta), "WIDTH_PCT": py(o.widthPct),
                "HIGH_VOL_RANK": py(o.highVolRank), "RISK": py(o.riskPerTrade),
                "CREDIT_TP": py(o.creditTakeProfit), "CREDIT_STOP": py(o.creditStop),
                "DEBIT_TP": py(o.debitTakeProfit), "DEBIT_STOP": py(o.debitStop),
                "EXIT_DTE": "\(o.exitDaysToExpiry)",
            ]) { $1 }
        }
        for (key, value) in values {
            template = template.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        let title = isOptions ? "opce" : "akcie"
        let exitName = (!isOptions && exit != .strategy) ? " · \(exit.name)" : ""
        let header = """
        # TradeLab → QuantConnect (LEAN, Python) – \(title)
        # \(symbol) · \(strategy.name)\(exitName)
        # Období \(start.replacingOccurrences(of: ", ", with: "-")) až \(end.replacingOccurrences(of: ", ", with: "-")), kapitál 10 000 USD.
        # Vlož celé do main.py nového Python projektu na quantconnect.com a spusť Backtest.

        from AlgorithmImports import *
        import math
        from datetime import timedelta

        """
        return header + signalsLibrary + "\n\n" + template + "\n"
    }

    static func fileName(ticker: String, instrument: Instrument) -> String {
        let t = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        return "tradelab_\(t.isEmpty ? "export" : t)_\(instrument == .options ? "opce" : "akcie").py"
    }

    // MARK: - Pomocné

    static func constructor(_ s: BacktestStrategy, allowShort: Bool) -> String {
        let a = py(allowShort)
        switch s {
        case .buyAndHold: return "BuyHold()"
        case .smaCross(let f, let sl): return "SmaCross(\(f), \(sl), \(a))"
        case .macdCross(let f, let sl, let g): return "MacdCross(\(f), \(sl), \(g), \(a))"
        case .rsiReversion(let p, let lo, let hi): return "RsiReversion(\(p), \(py(lo)), \(py(hi)), \(a))"
        case .breakRetest(let n, let r, let tol): return "BreakRetest(\(n), \(r), \(py(tol)), \(a))"
        case .reversal(let p, let lo, let hi): return "Reversal(\(p), \(py(lo)), \(py(hi)), \(a))"
        case .maBounce(let p, let t, let tol, let ema):
            return "MaBounce(\(p), \(t), \(py(tol)), \(py(ema)), \(a))"
        case .levelBounce(let n, let tol, let rr): return "LevelBounce(\(n), \(py(tol)), \(py(rr)), \(a))"
        case .levelBreakout(let n, let tol, let rr): return "LevelBreakout(\(n), \(py(tol)), \(py(rr)), \(a))"
        case .trendlineBounce(let n, let tol, let rr): return "TrendlineBounce(\(n), \(py(tol)), \(py(rr)), \(a))"
        case .trendlineBreakout(let n, let tol, let rr): return "TrendlineBreakout(\(n), \(py(tol)), \(py(rr)), \(a))"
        case .swingPullback(let t, let sw): return "SwingPullback(\(t), \(sw), \(a))"
        }
    }

    static func playKey(_ p: OptionPlay) -> String {
        switch p {
        case .bullPutSpread: return "bull_put"
        case .bullCallSpread: return "bull_call"
        case .bearCallSpread: return "bear_call"
        case .bearPutSpread: return "bear_put"
        case .ironCondor: return "iron_condor"
        case .longCall: return "long_call"
        case .longPut: return "long_put"
        }
    }

    /// Kalendářní dny zahřátí: nejdelší perioda strategie v obchodních dnech × 1,5 + rok na HV rank.
    static func warmupDays(_ s: BacktestStrategy) -> Int {
        let bars: Int
        switch s {
        case .buyAndHold: bars = 0
        case .smaCross(_, let sl): bars = sl
        case .macdCross(_, let sl, let g): bars = sl + g
        case .rsiReversion(let p, _, _), .reversal(let p, _, _): bars = p * 3
        case .breakRetest(let n, let r, _): bars = n + r
        case .maBounce(let p, let t, _, _): bars = max(p, t)
        case .levelBounce(let n, _, _), .levelBreakout(let n, _, _),
             .trendlineBounce(let n, _, _), .trendlineBreakout(let n, _, _): bars = n
        case .swingPullback(let t, let sw): bars = max(t, sw)
        }
        return Int((Double(max(bars, 252)) * 1.5).rounded(.up)) + 10
    }

    static func dates(range: HistoryRange, options: Bool, now: Date) -> (String, String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let end = cal.date(byAdding: .day, value: -1, to: now) ?? now
        let years: Int
        switch range {
        case .oneYear: years = 1
        case .twoYears: years = 2
        case .fiveYears: years = 5
        case .tenYears: years = 10
        case .max: years = 30
        }
        var start = cal.date(byAdding: .year, value: -years, to: end) ?? end
        let floor = cal.date(from: DateComponents(year: options ? 2012 : 1998, month: 1, day: 3)) ?? start
        if start < floor { start = floor }
        func fmt(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return "\(c.year ?? 2020), \(c.month ?? 1), \(c.day ?? 1)"
        }
        return (fmt(start), fmt(end))
    }

    static func py(_ b: Bool) -> String { b ? "True" : "False" }

    static func py(_ x: Double) -> String {
        if x == x.rounded(), abs(x) < 1e12 { return String(format: "%.1f", x) }
        var s = String(format: "%.6f", x)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}
