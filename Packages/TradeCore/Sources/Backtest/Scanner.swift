import Foundation

/// Vzory, které skener hledá (stejná pravidla jako strategie v backtestu).
public enum SetupPattern: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case breakRetest
    case levelBounce
    case levelBreakout
    case trendlineBounce
    case trendlineBreakout
    case maBounce
    case swingPullback
    case reversal

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .breakRetest: return "Break & retest"
        case .levelBounce: return "Odraz od S/R"
        case .levelBreakout: return "Průraz S/R"
        case .trendlineBounce: return "Odraz od trendline"
        case .trendlineBreakout: return "Průraz trendline"
        case .maBounce: return "Odraz od EMA 20"
        case .swingPullback: return "Swing pullback"
        case .reversal: return "Reversal RSI"
        }
    }

    /// Výchozí parametry pro denní svíčky.
    public var strategy: BacktestStrategy {
        switch self {
        case .breakRetest: return .breakRetest(lookback: 20, retestBars: 5, tolerance: 0.01)
        case .levelBounce: return .levelBounce(lookback: 120, tolerance: 0.005, rewardRisk: 2)
        case .levelBreakout: return .levelBreakout(lookback: 120, tolerance: 0.005, rewardRisk: 2)
        case .trendlineBounce: return .trendlineBounce(lookback: 120, tolerance: 0.005, rewardRisk: 2)
        case .trendlineBreakout: return .trendlineBreakout(lookback: 120, tolerance: 0.005, rewardRisk: 2)
        case .maBounce: return .maBounce(period: 20, trendPeriod: 100, tolerance: 0.01, exponential: true)
        case .swingPullback: return .swingPullback(trendPeriod: 100, swingLookback: 10)
        case .reversal: return .reversal(period: 14, lower: 30, upper: 70)
        }
    }
}

/// Jeden nalezený setup pro ticker (všechny vzory, které se shodnou na směru).
public struct SetupHit: Identifiable, Codable, Hashable, Sendable {
    public var symbol: String
    /// 1 býčí, −1 medvědí.
    public var direction: Int
    public var patterns: [SetupPattern]
    /// Před kolika svíčkami vznikl nejčerstvější signál (0 = poslední zavřená svíčka).
    public var barsAgo: Int
    public var close: Double
    public var changePercent: Double?
    /// Realizovaná volatilita 20 svíček (roční) a její percentil za poslední rok.
    public var historicalVolatility: Double?
    public var volatilityRank: Double?
    /// Cena je nad / pod SMA 200 ve směru setupu.
    public var withTrend: Bool
    public var suggestedPlay: OptionPlay
    public var score: Double
    public var date: Date

    public var id: String { symbol }

    public init(symbol: String, direction: Int, patterns: [SetupPattern], barsAgo: Int, close: Double,
                changePercent: Double?, historicalVolatility: Double?, volatilityRank: Double?, withTrend: Bool,
                suggestedPlay: OptionPlay, score: Double, date: Date) {
        self.symbol = symbol
        self.direction = direction
        self.patterns = patterns
        self.barsAgo = barsAgo
        self.close = close
        self.changePercent = changePercent
        self.historicalVolatility = historicalVolatility
        self.volatilityRank = volatilityRank
        self.withTrend = withTrend
        self.suggestedPlay = suggestedPlay
        self.score = score
        self.date = date
    }
}

/// Hledání čerstvých setupů na denních svíčkách vhodných pro směrové opční spready.
public enum SetupScanner {
    /// - Parameters:
    ///   - maxAge: signál musí vzniknout nejvýš před tolika svíčkami a pořád trvat.
    ///   - highVolRank: od jakého percentilu HV se volí kreditní spread místo debetního.
    public static func scan(symbol: String, bars: [BacktestBar], patterns: [SetupPattern] = SetupPattern.allCases,
                            maxAge: Int = 3, allowBearish: Bool = true, highVolRank: Double = 50) -> SetupHit? {
        let n = bars.count
        guard n >= 60, let last = bars.last else { return nil }

        var found: [(pattern: SetupPattern, direction: Int, age: Int)] = []
        for pattern in patterns {
            let targets = pattern.strategy.targets(bars: bars, allowShort: allowBearish)
            guard let direction = targets.last, direction != 0 else { continue }
            // Kdy signál v tomto směru začal.
            var start = n - 1
            while start > 0 && targets[start - 1] == direction { start -= 1 }
            let age = n - 1 - start
            guard age <= maxAge, start > 0 else { continue }
            found.append((pattern, direction, age))
        }
        guard !found.isEmpty else { return nil }

        // Směr podle většiny vzorů; při shodě rozhoduje čerstvější signál.
        let bull = found.filter { $0.direction == 1 }
        let bear = found.filter { $0.direction == -1 }
        let chosen: [(pattern: SetupPattern, direction: Int, age: Int)]
        if bull.count != bear.count {
            chosen = bull.count > bear.count ? bull : bear
        } else {
            let bullAge = bull.map(\.age).min() ?? .max
            let bearAge = bear.map(\.age).min() ?? .max
            chosen = bullAge <= bearAge ? bull : bear
        }
        guard let direction = chosen.first?.direction else { return nil }
        let age = chosen.map(\.age).min() ?? 0

        let closes = bars.map(\.close)
        let hv = OptionsBacktest.rollingVolatility(closes, window: 20, periodsPerYear: 252)
        let rank = OptionsBacktest.volRank(hv, at: n - 1, window: 252)
        let sma200 = TA.sma(closes, 200)[n - 1]
        let withTrend = sma200.map { direction == 1 ? last.close > $0 : last.close < $0 } ?? false

        let config = OptionsBacktestConfig(signal: .buyAndHold, allowBearish: allowBearish, highVolRank: highVolRank)
        guard let play = OptionsBacktest.choose(signal: direction, rank: rank ?? 50, config: config) else { return nil }

        // Skóre: počet vzorů, čerstvost, souhlas s dlouhodobým trendem.
        var score = Double(chosen.count) + Double(maxAge + 1 - age) / Double(maxAge + 1)
        if withTrend { score += 0.75 }
        if found.count > chosen.count { score -= 0.5 * Double(found.count - chosen.count) }

        let previous = n >= 2 ? bars[n - 2].close : nil
        return SetupHit(symbol: symbol, direction: direction,
                        patterns: chosen.sorted { $0.age < $1.age }.map(\.pattern), barsAgo: age,
                        close: last.close, changePercent: previous.map { last.close / $0 - 1 },
                        historicalVolatility: hv[n - 1], volatilityRank: rank, withTrend: withTrend,
                        suggestedPlay: play, score: score, date: last.date)
    }
}
