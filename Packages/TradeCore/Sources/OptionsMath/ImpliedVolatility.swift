import Foundation

public enum ImpliedVolatility {
    public static let lowerBound = 0.0001
    public static let upperBound = 5.0

    /// Najde volatilitu, při které Black-Scholes vrátí `price`.
    /// Kombinace Newtonovy metody a bisekce, takže vždy konverguje,
    /// pokud cena leží v arbitrážních mezích. Jinak vrací `nil`.
    public static func solve(
        _ type: OptionType,
        price target: Double,
        spot: Double,
        strike: Double,
        years: Double,
        rate: Double,
        dividendYield: Double = 0,
        tolerance: Double = 1e-7
    ) -> Double? {
        guard target > 0, spot > 0, strike > 0, years > 0 else { return nil }

        var params = OptionParameters(spot: spot, strike: strike, years: years,
                                      rate: rate, volatility: lowerBound, dividendYield: dividendYield)
        let minPrice = BlackScholes.price(type, params)
        params.volatility = upperBound
        let maxPrice = BlackScholes.price(type, params)
        guard target >= minPrice - tolerance, target <= maxPrice + tolerance else { return nil }

        var lo = lowerBound
        var hi = upperBound
        var sigma = 0.3

        for _ in 0..<100 {
            params.volatility = sigma
            let diff = BlackScholes.price(type, params) - target
            if abs(diff) < tolerance { return sigma }
            if diff > 0 { hi = sigma } else { lo = sigma }

            let vega = BlackScholes.rawVega(params)
            let newton = vega > 1e-10 ? sigma - diff / vega : .nan
            if newton.isFinite, newton > lo, newton < hi {
                sigma = newton
            } else {
                sigma = 0.5 * (lo + hi)
            }
            if hi - lo < 1e-9 { return sigma }
        }
        return sigma
    }
}

public enum Volatility {
    public static func logReturns(_ closes: [Double]) -> [Double] {
        guard closes.count > 1 else { return [] }
        var result: [Double] = []
        result.reserveCapacity(closes.count - 1)
        for i in 1..<closes.count where closes[i - 1] > 0 && closes[i] > 0 {
            result.append(log(closes[i] / closes[i - 1]))
        }
        return result
    }

    /// Anualizovaná realizovaná (historická) volatilita z posledních `window` výnosů.
    public static func realized(closes: [Double], window: Int? = nil, periodsPerYear: Double = 252) -> Double? {
        var returns = logReturns(closes)
        if let window, returns.count > window {
            returns = Array(returns.suffix(window))
        }
        guard returns.count >= 2 else { return nil }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count - 1)
        return (variance * periodsPerYear).squareRoot()
    }
}
