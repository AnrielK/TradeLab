import Foundation

/// Strategie, ze které setup pochází.
public enum SetupStrategy: String, Codable, Hashable, Sendable {
    case breakout
    case maBounce
}

/// Nalezený setup pro ticker: čerstvý vstup strategie, nebo kandidát těsně u hladiny / průměru.
public struct SetupHit: Identifiable, Codable, Hashable, Sendable {
    public var symbol: String
    public var strategy: SetupStrategy
    /// 1 long, −1 short.
    public var direction: Int
    /// Čerstvý vstup (jinak jen kandidát, který čeká na signál).
    public var isEntry: Bool
    /// Typ vstupu u breakoutu.
    public var entry: BreakoutEntry?
    /// Průměr u odrazu od KP (20, 50, 100, 200).
    public var maPeriod: Int?
    /// Před kolika svíčkami vznikl vstup (0 = poslední zavřená svíčka).
    public var barsAgo: Int
    /// Rezistence / support nebo hodnota průměru.
    public var level: Double
    public var stop: Double?
    public var target: Double?
    /// Vzdálenost kandidáta od hladiny / průměru v ATR.
    public var distanceATR: Double?
    public var close: Double
    public var changePercent: Double?
    public var atr: Double?
    /// Realizovaná volatilita 20 svíček (roční) a její percentil za poslední rok.
    public var historicalVolatility: Double?
    public var volatilityRank: Double?
    public var suggestedPlay: OptionPlay
    public var score: Double
    public var date: Date

    public var id: String { symbol }

    public var title: String {
        switch strategy {
        case .breakout:
            return entry?.name(direction: direction) ?? (direction > 0 ? "Pod rezistencí" : "Nad supportem")
        case .maBounce:
            let p = maPeriod.map(String.init) ?? ""
            return isEntry ? "Odraz od KP \(p)" : "Test KP \(p)"
        }
    }

    /// Popis hladiny pro řádek („R 512“, „KP 50 498,2“).
    public var levelName: String {
        switch strategy {
        case .breakout: return direction > 0 ? "R" : "S"
        case .maBounce: return "KP \(maPeriod.map(String.init) ?? "")"
        }
    }
}

/// Hledání setupů na denních svíčkách (Breakout/Breakdown a Odraz od KP).
public enum SetupScanner {
    /// - Parameters:
    ///   - breakout / maBounce: nastavení strategií; `nil` = strategie se nehledá.
    ///   - maxAge: vstup nejvýš před tolika svíčkami a pozice pořád trvá.
    ///   - includeWatch: vracet i kandidáty těsně u hladiny / průměru (bez vstupu).
    ///   - highVolRank: od jakého percentilu HV se volí kreditní spread místo debetního.
    public static func scan(symbol: String, bars: [BacktestBar], breakout: BreakoutSettings? = BreakoutSettings(),
                            maBounce: MABounceSettings? = nil, maxAge: Int = 3, allowBearish: Bool = true,
                            includeWatch: Bool = true, highVolRank: Double = 50) -> SetupHit? {
        let n = bars.count
        guard n >= 60, let last = bars.last else { return nil }

        let closes = bars.map(\.close)
        let hv = OptionsBacktest.rollingVolatility(closes, window: 20, periodsPerYear: 252)
        let rank = OptionsBacktest.volRank(hv, at: n - 1, window: 252)
        let config = OptionsBacktestConfig(signal: .buyAndHold, allowBearish: allowBearish, highVolRank: highVolRank)
        let change = n >= 2 ? last.close / bars[n - 2].close - 1 : nil

        var hits: [SetupHit] = []
        func add(_ strategy: SetupStrategy, direction: Int, isEntry: Bool, entry: BreakoutEntry? = nil,
                 period: Int? = nil, age: Int, level: Double, stop: Double?, target: Double?, distance: Double?,
                 atr: Double?, score: Double) {
            guard let play = OptionsBacktest.choose(signal: direction, rank: rank ?? 50, config: config) else { return }
            hits.append(SetupHit(symbol: symbol, strategy: strategy, direction: direction, isEntry: isEntry,
                                 entry: entry, maPeriod: period, barsAgo: age, level: level, stop: stop,
                                 target: target, distanceATR: distance, close: last.close, changePercent: change,
                                 atr: atr, historicalVolatility: hv[n - 1], volatilityRank: rank,
                                 suggestedPlay: play, score: score, date: last.date))
        }

        if let settings = breakout {
            let e = BreakoutStrategy.evaluate(bars, settings: settings, allowShort: allowBearish)
            if let signal = e.signals.last, e.targets.last == signal.direction, n - 1 - signal.index <= maxAge {
                let age = n - 1 - signal.index
                let bonus: Double = signal.entry == .breakout ? 0.5 : (signal.entry == .pullback ? 0.3 : 0)
                add(.breakout, direction: signal.direction, isEntry: true, entry: signal.entry, age: age,
                    level: signal.level, stop: signal.stop, target: signal.target, distance: nil, atr: e.atr,
                    score: 3 + bonus - 0.3 * Double(age))
            } else if includeWatch, let w = e.watch {
                add(.breakout, direction: w.direction, isEntry: false, age: 0, level: w.level, stop: nil,
                    target: nil, distance: w.distanceATR, atr: e.atr, score: 1.5 - w.distanceATR)
            }
        }

        if let settings = maBounce {
            let e = MABounceStrategy.evaluate(bars, settings: settings, allowShort: allowBearish)
            if let signal = e.signals.last, e.targets.last == signal.direction, n - 1 - signal.index <= maxAge {
                let age = n - 1 - signal.index
                add(.maBounce, direction: signal.direction, isEntry: true, period: signal.period, age: age,
                    level: signal.level, stop: signal.stop, target: signal.target, distance: nil, atr: e.atr,
                    score: 3.2 - 0.3 * Double(age))
            } else if includeWatch, let w = e.watch {
                add(.maBounce, direction: w.direction, isEntry: false, period: w.period, age: 0, level: w.level,
                    stop: nil, target: nil, distance: w.distanceATR, atr: e.atr, score: 1.4 - w.distanceATR)
            }
        }

        return hits.max { $0.score < $1.score }
    }
}
