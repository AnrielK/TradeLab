import Foundation
import OptionsMath

/// Opční strategie, kterou simulace umí otevřít.
public enum OptionPlay: String, CaseIterable, Codable, Hashable, Sendable {
    case bullPutSpread
    case bullCallSpread
    case bearCallSpread
    case bearPutSpread
    case ironCondor
    case longCall
    case longPut

    public var name: String {
        switch self {
        case .bullPutSpread: return "Bull put spread"
        case .bullCallSpread: return "Bull call spread"
        case .bearCallSpread: return "Bear call spread"
        case .bearPutSpread: return "Bear put spread"
        case .ironCondor: return "Iron condor"
        case .longCall: return "Long call"
        case .longPut: return "Long put"
        }
    }

    /// Kreditní strategie (prémii přijímá).
    public var isCredit: Bool { self == .bullPutSpread || self == .bearCallSpread || self == .ironCondor }

    /// Směr: 1 býčí, −1 medvědí, 0 neutrální.
    public var direction: Int {
        switch self {
        case .bullPutSpread, .bullCallSpread, .longCall: return 1
        case .bearCallSpread, .bearPutSpread, .longPut: return -1
        case .ironCondor: return 0
        }
    }
}

/// Jak se vybírá opční strategie.
public enum OptionSelection: Hashable, Codable, Sendable {
    /// Podle situace: směr ze signálu, kredit při vysoké volatilitě, debet při nízké;
    /// bez signálu a při vysoké volatilitě volitelně iron condor.
    case auto(neutralCondor: Bool)
    /// Pevně dané strategie pro býčí a medvědí signál.
    case fixed(bullish: OptionPlay, bearish: OptionPlay?)
}

public struct OptionsBacktestConfig: Hashable, Sendable {
    /// Strategie, ze které se bere směrový signál.
    public var signal: BacktestStrategy
    public var selection: OptionSelection
    /// Povolit medvědí strategie při short signálu.
    public var allowBearish: Bool
    /// Dny do expirace při otevření (kalendářní).
    public var daysToExpiry: Int
    /// Delta prodávané nohy kreditních spreadů (0.30 = 30Δ).
    public var shortDelta: Double
    /// Šířka spreadu jako zlomek ceny podkladu (zaokrouhlí se na mřížku striků).
    public var widthPct: Double
    /// Odhad IV = realizovaná volatilita 20 svíček × násobek (prémie za volatilitu).
    public var ivMultiplier: Double
    /// Hranice „vysoké“ volatility jako percentil HV za poslední rok (0–100).
    public var highVolRank: Double
    /// Maximální ztráta jednoho obchodu jako zlomek kapitálu.
    public var riskPerTrade: Double
    /// Výběr zisku: zlomek max. zisku u kreditu (0.5), zlomek zaplaceného debetu u debetu (1.0 = +100 %).
    public var creditTakeProfit: Double
    public var debitTakeProfit: Double
    /// Stop: ztráta jako násobek kreditu (2.0), u debetu zlomek zaplaceného (0.5).
    public var creditStop: Double
    public var debitStop: Double
    /// Zavřít, když zbývá méně dní do expirace.
    public var exitDaysToExpiry: Int
    /// Výstup podle strategie: opce se drží přesně jako akciový obchod (stop a cíl strategie),
    /// bez vlastního cíle a stopu na prémii; před expirací se pozice přeroluje.
    public var followStrategy: Bool
    /// Před expirací přerolovat do nové expirace, dokud obchod strategie trvá. Vypnuto = každý signál
    /// se obchoduje jen jednou: po zavření se do trvajícího signálu znovu nevstupuje.
    public var rollBeforeExpiry: Bool
    /// Poplatek za kontrakt a nohu (USD) a skluz jako zlomek ceny nohy.
    public var commission: Double
    public var slippage: Double
    public var riskFreeRate: Double
    public var initialCapital: Double

    public init(signal: BacktestStrategy, selection: OptionSelection = .auto(neutralCondor: false),
                allowBearish: Bool = true, daysToExpiry: Int = 35, shortDelta: Double = 0.30,
                widthPct: Double = 0.05, ivMultiplier: Double = 1.1, highVolRank: Double = 50,
                riskPerTrade: Double = 0.05, creditTakeProfit: Double = 0.5, debitTakeProfit: Double = 1.0,
                creditStop: Double = 2.0, debitStop: Double = 0.5, exitDaysToExpiry: Int = 7,
                followStrategy: Bool = true, rollBeforeExpiry: Bool = false, commission: Double = 0.65, slippage: Double = 0.03, riskFreeRate: Double = 0.04,
                initialCapital: Double = 10_000) {
        self.signal = signal
        self.selection = selection
        self.allowBearish = allowBearish
        self.daysToExpiry = daysToExpiry
        self.shortDelta = shortDelta
        self.widthPct = widthPct
        self.ivMultiplier = ivMultiplier
        self.highVolRank = highVolRank
        self.riskPerTrade = riskPerTrade
        self.creditTakeProfit = creditTakeProfit
        self.debitTakeProfit = debitTakeProfit
        self.creditStop = creditStop
        self.debitStop = debitStop
        self.exitDaysToExpiry = exitDaysToExpiry
        self.followStrategy = followStrategy
        self.rollBeforeExpiry = rollBeforeExpiry
        self.commission = commission
        self.slippage = slippage
        self.riskFreeRate = riskFreeRate
        self.initialCapital = initialCapital
    }
}

public struct OptionLegSpec: Hashable, Sendable {
    public var type: OptionType
    /// +1 koupená, −1 prodaná.
    public var side: Int
    public var strike: Double

    public var label: String {
        "\(side > 0 ? "+" : "−")\(type == .call ? "C" : "P") \(StrikeFormat.text(strike))"
    }
}

enum StrikeFormat {
    static func text(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
    }
}

public struct OptionTrade: Identifiable, Hashable, Sendable {
    public var id: Int
    public var play: OptionPlay
    public var legs: [OptionLegSpec]
    public var entryDate: Date
    public var exitDate: Date?
    public var expiration: Date
    public var entrySpot: Double
    public var exitSpot: Double
    /// Čistá prémie na akcii: kladná = zaplacený debet, záporná = přijatý kredit.
    public var entryPremium: Double
    public var exitValue: Double
    public var contracts: Double
    /// Max. ztráta celé pozice v USD.
    public var maxLoss: Double
    public var pnl: Double
    public var exitReason: String
    public var impliedVol: Double
    public var volRank: Double
    /// Přerolování pozice před expirací v rámci stejného obchodu strategie.
    public var isRoll: Bool = false

    public var returnOnRisk: Double { maxLoss > 0 ? pnl / maxLoss : 0 }
    public var legsText: String { legs.map(\.label).joined(separator: " / ") }
}

public struct OptionsBacktestResult: Sendable {
    public var config: OptionsBacktestConfig
    public var equity: [EquityPoint]
    public var trades: [OptionTrade]
    public var metrics: BacktestMetrics
    public var buyAndHold: [EquityPoint]
    public var buyAndHoldMetrics: BacktestMetrics
    /// Odkud jsou ceny opcí.
    public var pricing: String = "Simulace: Black-Scholes, IV z historické volatility"
    /// Kolikrát se nepodařilo otevřít pozici (chybějící kotace).
    public var skippedEntries: Int = 0

    /// Obchody strategie (bez přerolování stejné pozice před expirací) – odpovídá počtu akciových obchodů.
    public var strategyTradeCount: Int { trades.filter { !$0.isRoll }.count }
    public var rollCount: Int { trades.filter(\.isRoll).count }

    public struct PlaySummary: Identifiable, Hashable, Sendable {
        public var play: OptionPlay
        public var count: Int
        public var pnl: Double
        public var id: OptionPlay { play }
    }

    /// Kolik obchodů připadlo na kterou strategii.
    public var playCounts: [PlaySummary] {
        OptionPlay.allCases.compactMap { play in
            let selected = trades.filter { $0.play == play }
            return selected.isEmpty ? nil : PlaySummary(play: play, count: selected.count,
                                                        pnl: selected.map(\.pnl).reduce(0, +))
        }
    }
}

/// Simulace opčních strategií nad historií podkladu.
///
/// Historické ceny opcí nejsou volně dostupné, proto se oceňují Black-Scholesem:
/// IV = realizovaná volatilita 20 svíček × `ivMultiplier`, striky na mřížce podle ceny,
/// skluz a poplatky za každou nohu. Signál strategie se vyhodnotí na zavření svíčky,
/// pozice se otevře na otevírací ceně další svíčky a přeceňuje se na zavíracích cenách.
public enum OptionsBacktest {
    struct Position {
        var play: OptionPlay
        var legs: [OptionLegSpec]
        var expiration: Date
        var entryDate: Date
        var entrySpot: Double
        var entryPremium: Double
        var contracts: Double
        var maxLossPerShare: Double
        var maxProfitPerShare: Double
        var equityAtEntry: Double
        var entryCosts: Double
        var signal: Int
        var iv: Double
        var rank: Double
        var isRoll = false
    }

    public static func run(bars: [BacktestBar], config: OptionsBacktestConfig) -> OptionsBacktestResult {
        let n = bars.count
        let hold = BacktestEngine.run(bars: bars, config: BacktestConfig(strategy: .buyAndHold, costBps: 0,
                                                                       riskFreeRate: config.riskFreeRate,
                                                                       initialCapital: config.initialCapital))
        guard n > 30, let first = bars.first, let last = bars.last else {
            return OptionsBacktestResult(config: config, equity: [], trades: [], metrics: hold.metrics,
                                         buyAndHold: hold.buyAndHold, buyAndHoldMetrics: hold.buyAndHoldMetrics)
        }

        let signals = config.signal.targets(bars: bars, allowShort: config.allowBearish)
        let years = max(last.date.timeIntervalSince(first.date) / (365.25 * 86_400), 1 / 365)
        let barsPerYear = Double(n) / years
        let hv = rollingVolatility(bars.map(\.close), window: 20, periodsPerYear: barsPerYear)
        let rankWindow = max(Int(barsPerYear.rounded()), 20)

        var equity = config.initialCapital
        var peak = equity
        var points = [EquityPoint(date: first.date, equity: equity, drawdown: 0, position: 0)]
        var trades: [OptionTrade] = []
        var position: Position? = nil
        var rollSignal: Int? = nil       // pozice zavřená kvůli expiraci, obchod strategie pořád trvá
        var waitingEntry: Int? = nil     // vstup strategie, na který ještě chybí volatilita
        var pending: (play: OptionPlay, signal: Int, rank: Double, roll: Bool)? = nil

        for i in 1..<n {
            let bar = bars[i]
            let iv = max((hv[i] ?? hv[i - 1] ?? 0.25) * config.ivMultiplier, 0.05)

            // 1) Otevření naplánované pozice na otevírací ceně.
            if position == nil, let plan = pending {
                let openIV = max((hv[i - 1] ?? 0.25) * config.ivMultiplier, 0.05)
                position = open(plan.play, spot: bar.open, date: bar.date, iv: openIV, equity: equity,
                                signal: plan.signal, rank: plan.rank, config: config)
                position?.isRoll = plan.roll
            }
            pending = nil

            // 2) Přecenění a výstupy na zavírací ceně.
            var marked = equity
            if let current = position {
                let daysLeft = current.expiration.timeIntervalSince(bar.date) / 86_400
                let value = Self.value(current.legs, spot: bar.close, days: daysLeft, iv: iv, rate: config.riskFreeRate)
                let pnlPerShare = value - current.entryPremium
                marked = current.equityAtEntry - current.entryCosts + pnlPerShare * 100 * current.contracts

                var reason: String? = nil
                if signals[i] != current.signal {
                    reason = config.followStrategy ? "výstup strategie" : "změna signálu"
                } else if daysLeft <= 0 {
                    reason = "expirace"
                } else if config.followStrategy {
                    if daysLeft <= Double(config.exitDaysToExpiry) { reason = config.rollBeforeExpiry ? "rolování" : "čas" }
                } else if current.play.isCredit {
                    let credit = -current.entryPremium
                    if pnlPerShare >= credit * config.creditTakeProfit { reason = "cíl zisku" }
                    else if -pnlPerShare >= credit * config.creditStop { reason = "stop" }
                } else {
                    let debit = current.entryPremium
                    if pnlPerShare >= debit * config.debitTakeProfit { reason = "cíl zisku" }
                    else if -pnlPerShare >= debit * config.debitStop { reason = "stop" }
                }
                if reason == nil, daysLeft <= Double(config.exitDaysToExpiry) { reason = "čas" }

                if let reason {
                    // Výstup se skluzem proti nám a poplatky.
                    let exitValue = Self.value(current.legs, spot: bar.close, days: max(daysLeft, 0), iv: iv,
                                               rate: config.riskFreeRate, slippage: daysLeft > 0 ? config.slippage : 0,
                                               closing: true)
                    let exitCosts = daysLeft > 0 ? config.commission * Double(current.legs.count) * current.contracts : 0
                    let pnl = (exitValue - current.entryPremium) * 100 * current.contracts - current.entryCosts - exitCosts
                    equity = current.equityAtEntry + pnl
                    marked = equity
                    trades.append(OptionTrade(
                        id: trades.count, play: current.play, legs: current.legs, entryDate: current.entryDate,
                        exitDate: bar.date, expiration: current.expiration, entrySpot: current.entrySpot,
                        exitSpot: bar.close, entryPremium: current.entryPremium, exitValue: exitValue,
                        contracts: current.contracts, maxLoss: current.maxLossPerShare * 100 * current.contracts,
                        pnl: pnl, exitReason: reason, impliedVol: current.iv, volRank: current.rank,
                        isRoll: current.isRoll))
                    // Před expirací se pozice přeroluje, pokud obchod strategie pořád trvá.
                    rollSignal = config.followStrategy && config.rollBeforeExpiry && (reason == "rolování" || reason == "expirace")
                        && signals[i] == current.signal ? current.signal : nil
                    position = nil
                }
            }

            // 3) Plán na další svíčku.
            // Nová pozice jen při novém vstupu strategie (změna signálu), nebo při přerolování.
            if position == nil, i < n - 1 {
                if signals[i] != (i > 1 ? signals[i - 1] : 0) { waitingEntry = signals[i] }
                if waitingEntry != signals[i] { waitingEntry = nil }
                let isRoll = rollSignal != nil && rollSignal == signals[i]
                if waitingEntry != nil || isRoll, let rank = volRank(hv, at: i, window: rankWindow),
                   let play = choose(signal: signals[i], rank: rank, config: config) {
                    pending = (play, signals[i], rank, isRoll && waitingEntry == nil)
                    waitingEntry = nil
                }
            }
            if position == nil { rollSignal = nil }

            peak = max(peak, marked)
            let exposure = position.map { $0.play.direction == 0 ? 1 : $0.play.direction } ?? 0
            points.append(EquityPoint(date: bar.date, equity: marked, drawdown: marked / peak - 1, position: exposure))
        }

        // Otevřená pozice na konci se ocení poslední cenou (bez výstupních nákladů).
        if let current = position {
            let daysLeft = current.expiration.timeIntervalSince(last.date) / 86_400
            let iv = max((hv[n - 1] ?? 0.25) * config.ivMultiplier, 0.05)
            let value = Self.value(current.legs, spot: last.close, days: daysLeft, iv: iv, rate: config.riskFreeRate)
            let pnl = (value - current.entryPremium) * 100 * current.contracts - current.entryCosts
            trades.append(OptionTrade(
                id: trades.count, play: current.play, legs: current.legs, entryDate: current.entryDate,
                exitDate: nil, expiration: current.expiration, entrySpot: current.entrySpot, exitSpot: last.close,
                entryPremium: current.entryPremium, exitValue: value, contracts: current.contracts,
                maxLoss: current.maxLossPerShare * 100 * current.contracts, pnl: pnl, exitReason: "otevřený",
                impliedVol: current.iv, volRank: current.rank, isRoll: current.isRoll))
        }

        let summary = trades.map { t in
            BacktestTrade(id: t.id, side: t.play.direction == 0 ? 1 : t.play.direction, entryDate: t.entryDate,
                          entryPrice: t.entrySpot, exitDate: t.exitDate, exitPrice: t.exitSpot,
                          returnPct: t.returnOnRisk)
        }
        let metrics = BacktestEngine.metrics(equity: points, trades: summary, riskFreeRate: config.riskFreeRate)
        return OptionsBacktestResult(config: config, equity: points, trades: trades, metrics: metrics,
                                     buyAndHold: hold.buyAndHold, buyAndHoldMetrics: hold.buyAndHoldMetrics)
    }

    // MARK: - Výběr strategie

    static func choose(signal: Int, rank: Double, config: OptionsBacktestConfig) -> OptionPlay? {
        let highVol = rank >= config.highVolRank
        switch config.selection {
        case .auto(let neutralCondor):
            switch signal {
            case 1: return highVol ? .bullPutSpread : .bullCallSpread
            case -1: return config.allowBearish ? (highVol ? .bearCallSpread : .bearPutSpread) : nil
            default: return neutralCondor && highVol ? .ironCondor : nil
            }
        case .fixed(let bullish, let bearish):
            switch signal {
            case 1: return bullish
            case -1: return config.allowBearish ? bearish : nil
            default: return nil
            }
        }
    }

    /// Percentil aktuální HV v okně posledních `window` svíček (0–100).
    static func volRank(_ hv: [Double?], at i: Int, window: Int) -> Double? {
        guard let current = hv[i] else { return nil }
        let past = hv[max(0, i - window)...i].compactMap { $0 }
        guard past.count >= 10 else { return nil }
        return Double(past.filter { $0 <= current }.count) / Double(past.count) * 100
    }

    static func rollingVolatility(_ closes: [Double], window: Int, periodsPerYear: Double) -> [Double?] {
        var result = [Double?](repeating: nil, count: closes.count)
        guard closes.count > window else { return result }
        var returns = [Double](repeating: 0, count: closes.count)
        for i in 1..<closes.count where closes[i - 1] > 0 && closes[i] > 0 {
            returns[i] = log(closes[i] / closes[i - 1])
        }
        for i in window..<closes.count {
            let slice = returns[(i - window + 1)...i]
            let mean = slice.reduce(0, +) / Double(window)
            let variance = slice.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window - 1)
            result[i] = (variance * periodsPerYear).squareRoot()
        }
        return result
    }

    // MARK: - Konstrukce pozice

    static func open(_ play: OptionPlay, spot: Double, date: Date, iv: Double, equity: Double, signal: Int,
                     rank: Double, config: OptionsBacktestConfig) -> Position? {
        let days = Double(config.daysToExpiry)
        let rate = config.riskFreeRate
        let step = StrikeGrid.step(for: spot)
        let width = max(step, StrikeGrid.round(spot * config.widthPct, spot: spot))
        func strike(_ type: OptionType, delta target: Double) -> Double {
            Self.strike(type, delta: target, spot: spot, days: days, iv: iv, rate: rate)
        }
        let atm = StrikeGrid.round(spot, spot: spot)

        var legs: [OptionLegSpec]
        switch play {
        case .bullPutSpread:
            let short = strike(.put, delta: config.shortDelta)
            legs = [OptionLegSpec(type: .put, side: -1, strike: short), OptionLegSpec(type: .put, side: 1, strike: short - width)]
        case .bearCallSpread:
            let short = strike(.call, delta: config.shortDelta)
            legs = [OptionLegSpec(type: .call, side: -1, strike: short), OptionLegSpec(type: .call, side: 1, strike: short + width)]
        case .bullCallSpread:
            legs = [OptionLegSpec(type: .call, side: 1, strike: atm), OptionLegSpec(type: .call, side: -1, strike: atm + width)]
        case .bearPutSpread:
            legs = [OptionLegSpec(type: .put, side: 1, strike: atm), OptionLegSpec(type: .put, side: -1, strike: atm - width)]
        case .ironCondor:
            let delta = min(config.shortDelta, 0.2)
            let shortPut = strike(.put, delta: delta)
            let shortCall = strike(.call, delta: delta)
            legs = [OptionLegSpec(type: .put, side: 1, strike: shortPut - width),
                    OptionLegSpec(type: .put, side: -1, strike: shortPut),
                    OptionLegSpec(type: .call, side: -1, strike: shortCall),
                    OptionLegSpec(type: .call, side: 1, strike: shortCall + width)]
        case .longCall:
            legs = [OptionLegSpec(type: .call, side: 1, strike: atm)]
        case .longPut:
            legs = [OptionLegSpec(type: .put, side: 1, strike: atm)]
        }
        legs = legs.filter { $0.strike > 0 }
        guard !legs.isEmpty else { return nil }

        // Vstup se skluzem proti nám.
        let premium = value(legs, spot: spot, days: days, iv: iv, rate: rate, slippage: config.slippage, closing: false)
        let maxLoss: Double
        let maxProfit: Double
        if play.isCredit {
            let credit = -premium
            guard credit > 0.01 else { return nil }
            maxLoss = width - credit
            maxProfit = credit
        } else {
            guard premium > 0.01 else { return nil }
            maxLoss = premium
            maxProfit = legs.count > 1 ? width - premium : .infinity
        }
        guard maxLoss > 0 else { return nil }

        let contracts = equity * config.riskPerTrade / (maxLoss * 100)
        guard contracts > 0 else { return nil }
        let costs = config.commission * Double(legs.count) * contracts
        let expiration = date.addingTimeInterval(days * 86_400)
        return Position(play: play, legs: legs, expiration: expiration, entryDate: date, entrySpot: spot,
                        entryPremium: premium, contracts: contracts, maxLossPerShare: maxLoss,
                        maxProfitPerShare: maxProfit, equityAtEntry: equity, entryCosts: costs,
                        signal: play.direction == 0 ? 0 : signal, iv: iv, rank: rank)
    }

    /// Strike na mřížce s deltou nejbližší cíli (v absolutní hodnotě), mimo peníze.
    static func strike(_ type: OptionType, delta target: Double, spot: Double, days: Double, iv: Double,
                       rate: Double) -> Double {
        let step = StrikeGrid.step(for: spot)
        var best = StrikeGrid.round(spot, spot: spot)
        var bestGap = Double.infinity
        for k in 0...200 {
            let strike = StrikeGrid.round(spot, spot: spot) + (type == .call ? 1 : -1) * Double(k) * step
            guard strike > 0 else { break }
            let delta = abs(BlackScholes.greeks(type, OptionParameters(spot: spot, strike: strike, days: days,
                                                                       rate: rate, volatility: iv)).delta)
            let gap = abs(delta - target)
            if gap < bestGap { best = strike; bestGap = gap }
            if delta < target - 0.05 { break }
        }
        return best
    }

    /// Hodnota pozice na akcii (Σ strana × cena). Se skluzem: nákup dráž, prodej levněji
    /// (`closing` obrací strany – při zavírání se long prodává a short kupuje).
    static func value(_ legs: [OptionLegSpec], spot: Double, days: Double, iv: Double, rate: Double,
                      slippage: Double = 0, closing: Bool = false) -> Double {
        legs.reduce(0) { total, leg in
            let params = OptionParameters(spot: spot, strike: leg.strike, days: max(days, 0), rate: rate, volatility: iv)
            let price = BlackScholes.price(leg.type, params)
            let buying = closing ? leg.side < 0 : leg.side > 0
            let adjusted = slippage > 0 ? (buying ? price * (1 + slippage) + 0.01 : max(price * (1 - slippage) - 0.01, 0)) : price
            return total + Double(leg.side) * adjusted
        }
    }
}
