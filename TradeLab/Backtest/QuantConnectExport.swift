import Foundation
import Backtest
import MarketData

extension QuantConnectExport {
    enum Instrument { case stock, options }

    /// Sestaví celý skript `main.py` pro QuantConnect.
    static func script(instrument: Instrument, ticker: String, range: HistoryRange,
                       strategy: BacktestStrategy, allowShort: Bool, costBps: Double,
                       options: OptionsBacktestConfig?, now: Date = Date()) -> String {
        let symbol = ticker.trimmingCharacters(in: .whitespaces).uppercased()
        let (start, end) = dates(range: range, options: instrument == .options, now: now)
        let isOptions = instrument == .options && options != nil

        let signal = constructor(strategy, allowShort: isOptions ? true : allowShort)

        var values: [String: String] = [
            "START": start, "END": end, "CASH": "10000", "TICKER": symbol, "SIGNAL": signal,
            "SLIPPAGE": py(costBps / 10_000),
            "WARMUP_DAYS": "\(warmupDays(strategy))",
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
        let header = """
        # TradeLab → QuantConnect (LEAN, Python) – \(title)
        # \(symbol) · \(strategy.name)
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
        switch s {
        case .buyAndHold:
            return "BuyHold()"
        case .breakout(let b):
            return """
            Breakout(lookback=\(b.lookback), min_touches=\(b.minTouches), tolerance=\(py(b.tolerance)), \
            pre=\(py(b.preBreakout)), breakout=\(py(b.breakout)), pullback=\(py(b.pullback)), \
            weekly=\(py(b.weeklyFilter)), daily=\(py(b.dailyFilter)), ma_cross=\(py(b.requireMACross)), \
            headroom=\(py(b.headroomATR)), stop_atr=\(py(b.stopATR)), target_fib=\(py(b.targetFib)), \
            pullback_bars=\(b.pullbackBars), allow_short=\(py(allowShort)))
            """
        case .maBounce(let m):
            return """
            MaBounce(ma20=\(py(m.ma20)), ma50=\(py(m.ma50)), ma100=\(py(m.ma100)), ma200=\(py(m.ma200)), \
            two_candle=\(py(m.twoCandle)), one_candle=\(py(m.oneCandle)), prior_test=\(py(m.priorTest)), \
            prior_bars=\(m.priorBars), weekly=\(py(m.weeklyFilter)), stochastic=\(py(m.stochasticFilter)), \
            headroom=\(py(m.headroom)), stop_atr=\(py(m.stopATR)), target_fib=\(py(m.targetFib)), \
            min_rr=\(py(m.minRR)), max_rr=\(py(m.maxRR)), swing_bars=\(m.swingBars), allow_short=\(py(allowShort)))
            """
        case .trendline(let t):
            return """
            Trendline(triangle=\(py(t.triangle)), bounce=\(py(t.bounce)), breakout=\(py(t.breakout)), \
            lookback=\(t.lookback), min_touches=\(t.minTouches), tolerance=\(py(t.tolerance)), flat=\(py(t.flat)), \
            weekly=\(py(t.weeklyFilter)), daily=\(py(t.dailyFilter)), headroom=\(py(t.headroom)), \
            stop_atr=\(py(t.stopATR)), target_fib=\(py(t.targetFib)), min_rr=\(py(t.minRR)), max_rr=\(py(t.maxRR)), \
            swing_bars=\(t.swingBars), two_candle=\(py(t.twoCandle)), one_candle=\(py(t.oneCandle)), \
            allow_short=\(py(allowShort)))
            """
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

    /// Kalendářní dny zahřátí: týdenní SMA 40 + konsolidace (svíčky × 1,5) + rezerva.
    static func warmupDays(_ s: BacktestStrategy) -> Int {
        switch s {
        case .buyAndHold: return 0
        case .breakout(let b): return max(42 * 7, Int(Double(max(b.lookback, 100)) * 1.5)) + 30
        case .maBounce: return 42 * 7 + 30
        case .trendline(let t): return max(42 * 7, Int(Double(max(t.lookback, 200)) * 1.5)) + 30
        }
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
