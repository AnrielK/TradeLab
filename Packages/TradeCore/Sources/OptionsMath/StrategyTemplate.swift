import Foundation

/// Mřížka striků typická pro US opce.
public enum StrikeGrid {
    public static func step(for spot: Double) -> Double {
        switch spot {
        case ..<25: return 0.5
        case ..<100: return 1
        case ..<250: return 2.5
        default: return 5
        }
    }

    public static func round(_ price: Double, spot: Double) -> Double {
        let increment = Self.step(for: spot)
        return (price / increment).rounded() * increment
    }
}

/// Hotové šablony strategií. Prémie se dopočítají teoreticky z Black-Scholes,
/// po načtení řetězce je lze nahradit tržními cenami.
public enum StrategyTemplate: String, CaseIterable, Identifiable, Sendable {
    case longCall
    case longPut
    case coveredCall
    case cashSecuredPut
    case bullCallSpread
    case bearPutSpread
    case longStraddle
    case longStrangle
    case ironCondor
    case callButterfly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .longCall: return "Long call"
        case .longPut: return "Long put"
        case .coveredCall: return "Covered call"
        case .cashSecuredPut: return "Cash-secured put"
        case .bullCallSpread: return "Bull call spread"
        case .bearPutSpread: return "Bear put spread"
        case .longStraddle: return "Long straddle"
        case .longStrangle: return "Long strangle"
        case .ironCondor: return "Iron condor"
        case .callButterfly: return "Call butterfly"
        }
    }

    public var summary: String {
        switch self {
        case .longCall: return "Sázka na růst s omezenou ztrátou."
        case .longPut: return "Sázka na pokles nebo zajištění."
        case .coveredCall: return "Akcie + prodaný call, příjem z prémie."
        case .cashSecuredPut: return "Prodaný put, ochota koupit akcii levněji."
        case .bullCallSpread: return "Levnější sázka na mírný růst."
        case .bearPutSpread: return "Levnější sázka na mírný pokles."
        case .longStraddle: return "Sázka na velký pohyb libovolným směrem."
        case .longStrangle: return "Levnější sázka na velký pohyb."
        case .ironCondor: return "Kredit za to, že cena zůstane v pásmu."
        case .callButterfly: return "Sázka na cenu přesně u středního striku."
        }
    }

    public func build(
        underlying: String,
        spot: Double,
        daysToExpiry: Double = 30,
        volatility: Double = 0.3,
        market: MarketContext
    ) -> OptionStrategy {
        let step = StrikeGrid.step(for: spot)
        let atm = StrikeGrid.round(spot, spot: spot)
        func k(_ factor: Double) -> Double { StrikeGrid.round(spot * factor, spot: spot) }
        let up1 = max(k(1.05), atm + step)
        let up2 = max(k(1.10), up1 + step)
        let down1 = min(k(0.95), atm - step)
        let down2 = min(k(0.90), down1 - step)

        func option(_ instrument: LegInstrument, _ side: PositionSide, _ strike: Double, quantity: Int = 1) -> StrategyLeg {
            let params = OptionParameters(spot: spot, strike: strike, days: daysToExpiry,
                                          rate: market.rate, volatility: volatility,
                                          dividendYield: market.dividendYield)
            let premium = instrument.optionType.map { BlackScholes.price($0, params) } ?? 0
            return StrategyLeg(instrument: instrument, side: side, quantity: quantity, strike: strike,
                               premium: (premium * 100).rounded() / 100,
                               daysToExpiry: daysToExpiry, impliedVolatility: volatility)
        }

        let legs: [StrategyLeg]
        switch self {
        case .longCall:
            legs = [option(.call, .long, atm)]
        case .longPut:
            legs = [option(.put, .long, atm)]
        case .coveredCall:
            legs = [StrategyLeg(instrument: .stock, side: .long, strike: spot, daysToExpiry: daysToExpiry, impliedVolatility: volatility),
                    option(.call, .short, up1)]
        case .cashSecuredPut:
            legs = [option(.put, .short, down1)]
        case .bullCallSpread:
            legs = [option(.call, .long, atm), option(.call, .short, up1)]
        case .bearPutSpread:
            legs = [option(.put, .long, atm), option(.put, .short, down1)]
        case .longStraddle:
            legs = [option(.call, .long, atm), option(.put, .long, atm)]
        case .longStrangle:
            legs = [option(.put, .long, down1), option(.call, .long, up1)]
        case .ironCondor:
            legs = [option(.put, .long, down2), option(.put, .short, down1),
                    option(.call, .short, up1), option(.call, .long, up2)]
        case .callButterfly:
            let wing = up1 - atm
            legs = [option(.call, .long, atm - wing), option(.call, .short, atm, quantity: 2), option(.call, .long, up1)]
        }
        return OptionStrategy(name: displayName, underlying: underlying, legs: legs)
    }
}
