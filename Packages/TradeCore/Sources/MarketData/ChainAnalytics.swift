import Foundation
import OptionsMath

/// Souhrn jedné expirace pro přehled řetězce.
public struct ExpirationSummary: Hashable, Sendable {
    public var expiration: Date
    public var daysToExpiry: Double
    /// IV u ATM striku (průměr callu a putu).
    public var atmVolatility: Double?
    /// Cena ATM straddle (mid) – trhem implikovaný očekávaný pohyb do expirace.
    public var straddleMove: Double?
    /// 1 směrodatná odchylka ceny do expirace: spot · σ · √(dny/365).
    public var oneSigmaMove: Double?
    public var isMonthly: Bool

    public init(expiration: Date, daysToExpiry: Double, atmVolatility: Double?, straddleMove: Double?,
                oneSigmaMove: Double?, isMonthly: Bool) {
        self.expiration = expiration
        self.daysToExpiry = daysToExpiry
        self.atmVolatility = atmVolatility
        self.straddleMove = straddleMove
        self.oneSigmaMove = oneSigmaMove
        self.isMonthly = isMonthly
    }
}

public enum ExpirationCalendar {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Standardní měsíční expirace = třetí pátek v měsíci (Yahoo udává půlnoc UTC dne expirace).
    /// Když pátek připadne na svátek, burza expiruje ve čtvrtek – i ten se počítá jako měsíční.
    public static func isMonthly(_ date: Date) -> Bool {
        let c = utc.dateComponents([.weekday, .day], from: date)
        guard let weekday = c.weekday, let day = c.day else { return false }
        if weekday == 6 { return (15...21).contains(day) }        // pátek
        if weekday == 5 { return (14...20).contains(day) }        // čtvrtek před svátkem
        return false
    }
}

extension OptionChain {
    /// Všechny striky (cally i puty), vzestupně.
    public var strikes: [Double] {
        Array(Set(calls.map(\.strike) + puts.map(\.strike))).sorted()
    }

    public func contract(_ type: OptionType, strike: Double) -> OptionContract? {
        contracts(type).first { abs($0.strike - strike) < 1e-6 }
    }

    public var atmStrike: Double? {
        StrikeLadder.nearest(to: underlyingPrice, in: strikes)
    }

    public func summary(rate: Double, now: Date = Date()) -> ExpirationSummary {
        let days = OptionChain.daysToExpiry(expiration, from: now)
        var atmVolatility: Double?
        var straddle: Double?

        if let atm = atmStrike {
            let call = contract(.call, strike: atm)
            let put = contract(.put, strike: atm)
            let vols = [call, put].compactMap { $0?.estimatedVolatility(spot: underlyingPrice, rate: rate, now: now) }
            if !vols.isEmpty { atmVolatility = vols.reduce(0, +) / Double(vols.count) }
            if let c = call?.mid, let p = put?.mid { straddle = c + p }
        }

        let sigmaMove = atmVolatility.map { underlyingPrice * $0 * (days / BlackScholes.daysPerYear).squareRoot() }
        return ExpirationSummary(expiration: expiration, daysToExpiry: days, atmVolatility: atmVolatility,
                                 straddleMove: straddle, oneSigmaMove: sigmaMove,
                                 isMonthly: ExpirationCalendar.isMonthly(expiration))
    }

    /// Noha strategie z kontraktu s aktuálními kotacemi.
    public func leg(for contract: OptionContract, side: PositionSide, quantity: Int = 1, rate: Double, now: Date = Date()) -> StrategyLeg {
        let days = contract.daysToExpiry(from: now)
        return StrategyLeg(
            instrument: contract.type == .call ? .call : .put,
            side: side,
            quantity: quantity,
            strike: contract.strike,
            premium: contract.mid ?? 0,
            daysToExpiry: (days * 100).rounded() / 100,
            impliedVolatility: contract.estimatedVolatility(spot: underlyingPrice, rate: rate, now: now) ?? 0.3,
            contractSymbol: contract.contractSymbol,
            expiration: expiration,
            bid: contract.bid,
            ask: contract.ask
        )
    }

    /// Přecení nohu podle tohoto řetězce (stejná expirace). Když strike chybí, vrací nohu beze změny.
    public func repriced(_ leg: StrategyLeg, rate: Double, now: Date = Date()) -> StrategyLeg {
        guard let type = leg.instrument.optionType, let contract = contract(type, strike: leg.strike) else { return leg }
        var updated = self.leg(for: contract, side: leg.side, quantity: leg.quantity, rate: rate, now: now)
        updated.id = leg.id
        return updated
    }
}
