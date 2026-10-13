import Foundation

/// Nalezený setup pro ticker: čerstvý vstup strategie Breakout/Breakdown, nebo konsolidace těsně u hladiny.
public struct SetupHit: Identifiable, Codable, Hashable, Sendable {
    public var symbol: String
    /// 1 breakout (long), −1 breakdown (short).
    public var direction: Int
    /// Typ vstupu; `nil` = zatím jen kandidát (konsolidace těsně pod rezistencí / nad supportem).
    public var entry: BreakoutEntry?
    /// Před kolika svíčkami vznikl vstup (0 = poslední zavřená svíčka).
    public var barsAgo: Int
    /// Rezistence (support), o kterou jde.
    public var level: Double
    public var stop: Double?
    public var target: Double?
    /// Vzdálenost kandidáta od hladiny v ATR.
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
        entry?.name(direction: direction) ?? (direction > 0 ? "Pod rezistencí" : "Nad supportem")
    }
}

/// Hledání setupů Breakout/Breakdown na denních svíčkách.
public enum SetupScanner {
    /// - Parameters:
    ///   - maxAge: vstup nejvýš před tolika svíčkami a pozice pořád trvá.
    ///   - includeWatch: vracet i kandidáty těsně u hladiny (bez vstupu).
    ///   - highVolRank: od jakého percentilu HV se volí kreditní spread místo debetního.
    public static func scan(symbol: String, bars: [BacktestBar], settings: BreakoutSettings = BreakoutSettings(),
                            maxAge: Int = 3, allowBearish: Bool = true, includeWatch: Bool = true,
                            highVolRank: Double = 50) -> SetupHit? {
        let n = bars.count
        guard n >= 60, let last = bars.last else { return nil }
        let evaluation = BreakoutStrategy.evaluate(bars, settings: settings, allowShort: allowBearish)

        let closes = bars.map(\.close)
        let hv = OptionsBacktest.rollingVolatility(closes, window: 20, periodsPerYear: 252)
        let rank = OptionsBacktest.volRank(hv, at: n - 1, window: 252)
        let config = OptionsBacktestConfig(signal: .buyAndHold, allowBearish: allowBearish, highVolRank: highVolRank)
        let change = n >= 2 ? last.close / bars[n - 2].close - 1 : nil

        func hit(direction: Int, entry: BreakoutEntry?, age: Int, level: Double, stop: Double?, target: Double?,
                 distance: Double?, score: Double) -> SetupHit? {
            guard let play = OptionsBacktest.choose(signal: direction, rank: rank ?? 50, config: config) else { return nil }
            return SetupHit(symbol: symbol, direction: direction, entry: entry, barsAgo: age, level: level, stop: stop,
                            target: target, distanceATR: distance, close: last.close, changePercent: change,
                            atr: evaluation.atr, historicalVolatility: hv[n - 1], volatilityRank: rank,
                            suggestedPlay: play, score: score, date: last.date)
        }

        if let signal = evaluation.signals.last, evaluation.targets.last == signal.direction {
            let age = n - 1 - signal.index
            if age <= maxAge {
                let bonus: Double = signal.entry == .breakout ? 0.5 : (signal.entry == .pullback ? 0.3 : 0)
                return hit(direction: signal.direction, entry: signal.entry, age: age, level: signal.level,
                           stop: signal.stop, target: signal.target, distance: nil,
                           score: 3 + bonus - 0.3 * Double(age))
            }
        }
        if includeWatch, let watch = evaluation.watch {
            return hit(direction: watch.direction, entry: nil, age: 0, level: watch.level, stop: nil, target: nil,
                       distance: watch.distanceATR, score: 1.5 - watch.distanceATR)
        }
        return nil
    }
}
