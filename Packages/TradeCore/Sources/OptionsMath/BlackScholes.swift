import Foundation

public enum OptionType: String, Codable, CaseIterable, Hashable, Sendable {
    case call
    case put
}

/// Normální rozdělení N(0,1).
public enum Normal {
    public static func cdf(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }

    public static func pdf(_ x: Double) -> Double {
        exp(-0.5 * x * x) / (2.0 * Double.pi).squareRoot()
    }
}

/// Vstupy pro ocenění evropské opce.
public struct OptionParameters: Hashable, Codable, Sendable {
    public var spot: Double
    public var strike: Double
    /// Čas do expirace v letech.
    public var years: Double
    /// Bezriziková sazba (0.04 = 4 %), spojitě úročená.
    public var rate: Double
    /// Volatilita (0.25 = 25 %).
    public var volatility: Double
    /// Spojitý dividendový výnos.
    public var dividendYield: Double

    public init(spot: Double, strike: Double, years: Double, rate: Double, volatility: Double, dividendYield: Double = 0) {
        self.spot = spot
        self.strike = strike
        self.years = years
        self.rate = rate
        self.volatility = volatility
        self.dividendYield = dividendYield
    }

    public init(spot: Double, strike: Double, days: Double, rate: Double, volatility: Double, dividendYield: Double = 0) {
        self.init(spot: spot, strike: strike, years: days / BlackScholes.daysPerYear,
                  rate: rate, volatility: volatility, dividendYield: dividendYield)
    }
}

/// Citlivosti ceny opce. Jednotky odpovídají běžné praxi brokerů.
public struct Greeks: Hashable, Codable, Sendable {
    /// dCena/dSpot
    public var delta: Double
    /// dDelta/dSpot
    public var gamma: Double
    /// Změna ceny při růstu volatility o 1 procentní bod.
    public var vega: Double
    /// Změna ceny za jeden kalendářní den.
    public var theta: Double
    /// Změna ceny při růstu sazby o 1 procentní bod.
    public var rho: Double

    public init(delta: Double, gamma: Double, vega: Double, theta: Double, rho: Double) {
        self.delta = delta
        self.gamma = gamma
        self.vega = vega
        self.theta = theta
        self.rho = rho
    }

    public static let zero = Greeks(delta: 0, gamma: 0, vega: 0, theta: 0, rho: 0)

    public static func + (lhs: Greeks, rhs: Greeks) -> Greeks {
        Greeks(delta: lhs.delta + rhs.delta, gamma: lhs.gamma + rhs.gamma,
               vega: lhs.vega + rhs.vega, theta: lhs.theta + rhs.theta, rho: lhs.rho + rhs.rho)
    }

    public static func * (lhs: Greeks, rhs: Double) -> Greeks {
        Greeks(delta: lhs.delta * rhs, gamma: lhs.gamma * rhs,
               vega: lhs.vega * rhs, theta: lhs.theta * rhs, rho: lhs.rho * rhs)
    }
}

/// Black-Scholes-Merton pro evropské opce se spojitým dividendovým výnosem.
/// Americké opce na US akcie bez dividendy se u callů chovají stejně,
/// u putů je to dobrá aproximace pro kratší expirace.
public enum BlackScholes {
    public static let daysPerYear = 365.0

    public static func intrinsic(_ type: OptionType, spot: Double, strike: Double) -> Double {
        switch type {
        case .call: return max(spot - strike, 0)
        case .put: return max(strike - spot, 0)
        }
    }

    static func d1d2(_ p: OptionParameters) -> (Double, Double) {
        let sqrtT = p.years.squareRoot()
        let d1 = (log(p.spot / p.strike) + (p.rate - p.dividendYield + 0.5 * p.volatility * p.volatility) * p.years)
            / (p.volatility * sqrtT)
        return (d1, d1 - p.volatility * sqrtT)
    }

    public static func price(_ type: OptionType, _ p: OptionParameters) -> Double {
        guard p.spot > 0, p.strike > 0 else { return 0 }
        if p.years <= 0 {
            return intrinsic(type, spot: p.spot, strike: p.strike)
        }
        let dfR = exp(-p.rate * p.years)
        let dfQ = exp(-p.dividendYield * p.years)
        if p.volatility <= 0 {
            let forward = p.spot * dfQ - p.strike * dfR
            return type == .call ? max(forward, 0) : max(-forward, 0)
        }
        let (d1, d2) = d1d2(p)
        switch type {
        case .call:
            return p.spot * dfQ * Normal.cdf(d1) - p.strike * dfR * Normal.cdf(d2)
        case .put:
            return p.strike * dfR * Normal.cdf(-d2) - p.spot * dfQ * Normal.cdf(-d1)
        }
    }

    public static func greeks(_ type: OptionType, _ p: OptionParameters) -> Greeks {
        guard p.spot > 0, p.strike > 0 else { return .zero }
        if p.years <= 0 || p.volatility <= 0 {
            let inTheMoney = type == .call ? p.spot > p.strike : p.spot < p.strike
            let delta: Double = inTheMoney ? (type == .call ? 1 : -1) : 0
            return Greeks(delta: delta, gamma: 0, vega: 0, theta: 0, rho: 0)
        }
        let (d1, d2) = d1d2(p)
        let sqrtT = p.years.squareRoot()
        let dfR = exp(-p.rate * p.years)
        let dfQ = exp(-p.dividendYield * p.years)
        let pdf1 = Normal.pdf(d1)

        let gamma = dfQ * pdf1 / (p.spot * p.volatility * sqrtT)
        let vega = p.spot * dfQ * pdf1 * sqrtT / 100
        let decay = -p.spot * dfQ * pdf1 * p.volatility / (2 * sqrtT)

        switch type {
        case .call:
            let delta = dfQ * Normal.cdf(d1)
            let theta = (decay - p.rate * p.strike * dfR * Normal.cdf(d2)
                         + p.dividendYield * p.spot * dfQ * Normal.cdf(d1)) / daysPerYear
            let rho = p.strike * p.years * dfR * Normal.cdf(d2) / 100
            return Greeks(delta: delta, gamma: gamma, vega: vega, theta: theta, rho: rho)
        case .put:
            let delta = dfQ * (Normal.cdf(d1) - 1)
            let theta = (decay + p.rate * p.strike * dfR * Normal.cdf(-d2)
                         - p.dividendYield * p.spot * dfQ * Normal.cdf(-d1)) / daysPerYear
            let rho = -p.strike * p.years * dfR * Normal.cdf(-d2) / 100
            return Greeks(delta: delta, gamma: gamma, vega: vega, theta: theta, rho: rho)
        }
    }

    /// dCena/dSigma (nenormalizovaná vega) – pro Newtonovu metodu.
    static func rawVega(_ p: OptionParameters) -> Double {
        guard p.spot > 0, p.strike > 0, p.years > 0, p.volatility > 0 else { return 0 }
        let (d1, _) = d1d2(p)
        return p.spot * exp(-p.dividendYield * p.years) * Normal.pdf(d1) * p.years.squareRoot()
    }
}
