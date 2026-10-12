import Foundation

public enum LegInstrument: String, Codable, CaseIterable, Hashable, Sendable {
    case call
    case put
    case stock

    public var optionType: OptionType? {
        switch self {
        case .call: return .call
        case .put: return .put
        case .stock: return nil
        }
    }
}

public enum PositionSide: String, Codable, CaseIterable, Hashable, Sendable {
    case long
    case short

    public var sign: Double { self == .long ? 1 : -1 }
}

/// Tržní prostředí pro ocenění strategie.
public struct MarketContext: Hashable, Codable, Sendable {
    public var rate: Double
    public var dividendYield: Double

    public init(rate: Double, dividendYield: Double = 0) {
        self.rate = rate
        self.dividendYield = dividendYield
    }
}

/// Jedna noha strategie. Množství je v kontraktech (u akcie v lotech po `multiplier` kusech).
public struct StrategyLeg: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var instrument: LegInstrument
    public var side: PositionSide
    public var quantity: Int
    /// Strike opce, u akcie vstupní cena.
    public var strike: Double
    /// Zaplacená / přijatá prémie za 1 akcii. U akcie se ignoruje.
    public var premium: Double
    public var daysToExpiry: Double
    public var impliedVolatility: Double
    public var contractSymbol: String?
    /// Datum expirace (u nohou z řetězce), slouží k posunu expirace a přecenění.
    public var expiration: Date?
    /// Poslední známý bid/ask kontraktu (za 1 akcii).
    public var bid: Double?
    public var ask: Double?

    public init(
        id: UUID = UUID(),
        instrument: LegInstrument,
        side: PositionSide,
        quantity: Int = 1,
        strike: Double,
        premium: Double = 0,
        daysToExpiry: Double = 30,
        impliedVolatility: Double = 0.3,
        contractSymbol: String? = nil,
        expiration: Date? = nil,
        bid: Double? = nil,
        ask: Double? = nil
    ) {
        self.id = id
        self.instrument = instrument
        self.side = side
        self.quantity = quantity
        self.strike = strike
        self.premium = premium
        self.daysToExpiry = daysToExpiry
        self.impliedVolatility = impliedVolatility
        self.contractSymbol = contractSymbol
        self.expiration = expiration
        self.bid = bid
        self.ask = ask
    }

    /// Stejný kontrakt (typ, strike, expirace) bez ohledu na směr a množství.
    public func isSameContract(as other: StrategyLeg) -> Bool {
        instrument == other.instrument && strike == other.strike && expiration == other.expiration
    }

    /// Vstupní cena za 1 akcii (prémie u opce, nákupní cena u akcie).
    public var entryPrice: Double { instrument == .stock ? strike : premium }
}

public struct PayoffPoint: Hashable, Sendable {
    public var spot: Double
    public var pnl: Double

    public init(spot: Double, pnl: Double) {
        self.spot = spot
        self.pnl = pnl
    }
}

public struct StrategyAnalysis: Sendable {
    /// P/L při nejbližší expiraci.
    public var expiryCurve: [PayoffPoint]
    /// `nil` = neomezený zisk.
    public var maxProfit: Double?
    /// Nejhorší P/L (záporné číslo). `nil` = neomezená ztráta.
    public var maxLoss: Double?
    public var breakevens: [Double]
    /// Pravděpodobnost zisku při expiraci (log-normální model, průměrná IV nohou).
    public var probabilityOfProfit: Double?
}

public struct OptionStrategy: Codable, Hashable, Sendable {
    public var name: String
    public var underlying: String
    public var legs: [StrategyLeg]
    public var multiplier: Double

    public init(name: String = "Vlastní strategie", underlying: String = "", legs: [StrategyLeg] = [], multiplier: Double = 100) {
        self.name = name
        self.underlying = underlying
        self.legs = legs
        self.multiplier = multiplier
    }

    public var optionLegs: [StrategyLeg] { legs.filter { $0.instrument != .stock } }

    /// Dny do nejbližší expirace (0, pokud strategie nemá opce).
    public var nearestExpiryDays: Double { optionLegs.map(\.daysToExpiry).min() ?? 0 }

    /// Kladné = zaplacený debet, záporné = přijatý kredit (jen opční nohy).
    public var netPremium: Double {
        optionLegs.reduce(0) { $0 + $1.side.sign * Double($1.quantity) * $1.premium * multiplier }
    }

    /// Kapitál vázaný v akciích.
    public var stockCost: Double {
        legs.filter { $0.instrument == .stock }
            .reduce(0) { $0 + $1.side.sign * Double($1.quantity) * $1.strike * multiplier }
    }

    func parameters(for leg: StrategyLeg, spot: Double, daysElapsed: Double, ivShift: Double, market: MarketContext) -> OptionParameters {
        OptionParameters(
            spot: spot,
            strike: leg.strike,
            days: max(leg.daysToExpiry - daysElapsed, 0),
            rate: market.rate,
            volatility: max(leg.impliedVolatility + ivShift, ImpliedVolatility.lowerBound),
            dividendYield: market.dividendYield
        )
    }

    /// Teoretická hodnota nohy za 1 akcii.
    public func legValue(_ leg: StrategyLeg, spot: Double, daysElapsed: Double, ivShift: Double = 0, market: MarketContext) -> Double {
        guard let type = leg.instrument.optionType else { return spot }
        return BlackScholes.price(type, parameters(for: leg, spot: spot, daysElapsed: daysElapsed, ivShift: ivShift, market: market))
    }

    /// P/L celé strategie v dolarech.
    /// - Parameters:
    ///   - daysElapsed: kolik dní uplynulo od dneška
    ///   - ivShift: absolutní posun IV (0.05 = +5 procentních bodů)
    public func profitLoss(atSpot spot: Double, daysElapsed: Double, ivShift: Double = 0, market: MarketContext) -> Double {
        legs.reduce(0) { total, leg in
            let value = legValue(leg, spot: spot, daysElapsed: daysElapsed, ivShift: ivShift, market: market)
            return total + leg.side.sign * Double(leg.quantity) * multiplier * (value - leg.entryPrice)
        }
    }

    public func expiryProfitLoss(atSpot spot: Double, market: MarketContext) -> Double {
        profitLoss(atSpot: spot, daysElapsed: nearestExpiryDays, market: market)
    }

    /// Greeks celé pozice (delta v akciích, theta/vega/rho v dolarech).
    public func greeks(atSpot spot: Double, daysElapsed: Double = 0, ivShift: Double = 0, market: MarketContext) -> Greeks {
        legs.reduce(Greeks.zero) { total, leg in
            let scale = leg.side.sign * Double(leg.quantity) * multiplier
            guard let type = leg.instrument.optionType else {
                return total + Greeks(delta: scale, gamma: 0, vega: 0, theta: 0, rho: 0)
            }
            let g = BlackScholes.greeks(type, parameters(for: leg, spot: spot, daysElapsed: daysElapsed, ivShift: ivShift, market: market))
            return total + g * scale
        }
    }

    /// Sklon P/L pro spot → ∞ (počet „dlouhých akcií“ v callech a akciích).
    var slopeAtInfinity: Double {
        legs.reduce(0) { total, leg in
            switch leg.instrument {
            case .call, .stock: return total + leg.side.sign * Double(leg.quantity) * multiplier
            case .put: return total
            }
        }
    }

    /// Body grafu: rovnoměrná mřížka + všechny striky v rozsahu.
    public func grid(lower: Double, upper: Double, samples: Int = 200) -> [Double] {
        let lo = max(lower, 0.01)
        let hi = max(upper, lo + 0.01)
        let n = max(samples, 2)
        var points = (0..<n).map { lo + (hi - lo) * Double($0) / Double(n - 1) }
        points += legs.map(\.strike).filter { $0 > lo && $0 < hi }
        return Array(Set(points)).sorted()
    }

    /// Doporučený rozsah grafu kolem spotu a striků.
    public func suggestedRange(spot: Double) -> ClosedRange<Double> {
        let strikes = legs.map(\.strike)
        let low = min(strikes.min() ?? spot, spot)
        let high = max(strikes.max() ?? spot, spot)
        let lower = max(low * 0.75, 0.01)
        let upper = max(high * 1.25, lower + 1)
        return lower...upper
    }

    public func analyze(spot: Double, market: MarketContext, range: ClosedRange<Double>? = nil, samples: Int = 240) -> StrategyAnalysis {
        let chartRange = range ?? suggestedRange(spot: spot)
        let curve = grid(lower: chartRange.lowerBound, upper: chartRange.upperBound, samples: samples)
            .map { PayoffPoint(spot: $0, pnl: expiryProfitLoss(atSpot: $0, market: market)) }

        // Extrémy po částech lineárního payoffu leží v nule, ve stricích nebo v nekonečnu.
        // Hustá mřížka navíc pokryje kalendářní spready (nohy s pozdější expirací).
        let maxStrike = legs.map(\.strike).max() ?? spot
        let wideUpper = max(maxStrike, spot) * 3
        var candidates = grid(lower: 0.01, upper: wideUpper, samples: 1200)
        candidates += legs.map(\.strike)
        let values = candidates.map { expiryProfitLoss(atSpot: $0, market: market) }

        let slope = slopeAtInfinity
        let maxProfit: Double? = slope > 1e-9 ? nil : values.max()
        let maxLoss: Double? = slope < -1e-9 ? nil : values.min()

        // Break-even body z husté mřížky (lineární interpolace změn znaménka).
        let dense = grid(lower: 0.01, upper: wideUpper, samples: 2400)
        let densePnL = dense.map { expiryProfitLoss(atSpot: $0, market: market) }
        var breakevens: [Double] = []
        for i in 1..<dense.count {
            let a = densePnL[i - 1], b = densePnL[i]
            if (a < 0 && b >= 0) || (a >= 0 && b < 0) {
                let t = a / (a - b)
                let be = dense[i - 1] + t * (dense[i] - dense[i - 1])
                if let last = breakevens.last, abs(last - be) < 1e-6 { continue }
                breakevens.append(be)
            }
        }

        let pop = probabilityOfProfit(spot: spot, market: market, grid: dense, pnl: densePnL)
        return StrategyAnalysis(expiryCurve: curve, maxProfit: maxProfit, maxLoss: maxLoss,
                                breakevens: breakevens, probabilityOfProfit: pop)
    }

    /// P(S_T ≤ x) v log-normálním modelu.
    static func lognormalCDF(_ x: Double, spot: Double, years: Double, volatility: Double, market: MarketContext) -> Double {
        guard x > 0 else { return 0 }
        let sd = volatility * years.squareRoot()
        let mu = (market.rate - market.dividendYield - 0.5 * volatility * volatility) * years
        return Normal.cdf((log(x / spot) - mu) / sd)
    }

    func probabilityOfProfit(spot: Double, market: MarketContext, grid: [Double], pnl: [Double]) -> Double? {
        let options = optionLegs
        let days = nearestExpiryDays
        guard !options.isEmpty, days > 0, spot > 0, grid.count > 1 else { return nil }
        let vol = options.map(\.impliedVolatility).reduce(0, +) / Double(options.count)
        guard vol > 0 else { return nil }
        let years = days / BlackScholes.daysPerYear
        var probability = 0.0
        var previousCDF = Self.lognormalCDF(grid[0], spot: spot, years: years, volatility: vol, market: market)
        if pnl[0] > 0 { probability += previousCDF }
        for i in 1..<grid.count {
            let cdf = Self.lognormalCDF(grid[i], spot: spot, years: years, volatility: vol, market: market)
            if 0.5 * (pnl[i - 1] + pnl[i]) > 0 { probability += cdf - previousCDF }
            previousCDF = cdf
        }
        if pnl[pnl.count - 1] > 0 { probability += 1 - previousCDF }
        return min(max(probability, 0), 1)
    }
}
