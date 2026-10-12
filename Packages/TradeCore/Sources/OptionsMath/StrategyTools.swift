import Foundation

// MARK: - Cena celé strategie

/// Cena strategie za jednu jednotku (např. 1 vertical). Kladné = debet, záporné = kredit.
public struct NetQuote: Hashable, Sendable {
    /// Okamžitá cena otevření (long za ask, short za bid).
    public var natural: Double
    /// Opačná strana (long za bid, short za ask).
    public var opposite: Double

    public init(natural: Double, opposite: Double) {
        self.natural = natural
        self.opposite = opposite
    }

    public var mid: Double { (natural + opposite) / 2 }
    public var isDebit: Bool { mid >= 0 }
    /// Nižší a vyšší hodnota v absolutní velikosti (pro zobrazení „bid / ask“).
    public var low: Double { min(abs(natural), abs(opposite)) }
    public var high: Double { max(abs(natural), abs(opposite)) }
}

extension OptionStrategy {
    /// Počet „jednotek“ strategie = NSD množství opčních nohou (2 + 2 → 2 vertikály).
    public var spreadCount: Int {
        let quantities = optionLegs.map(\.quantity).filter { $0 > 0 }
        guard var result = quantities.first else { return legs.first?.quantity ?? 0 }
        for q in quantities.dropFirst() { result = Self.gcd(result, q) }
        return result
    }

    /// Změní počet jednotek a zachová poměr nohou.
    public func withSpreadCount(_ count: Int) -> OptionStrategy {
        let current = spreadCount
        guard current > 0, count > 0 else { return self }
        var copy = self
        for i in copy.legs.indices {
            let unit = copy.legs[i].quantity / current
            copy.legs[i].quantity = max(unit, 1) * count
        }
        return copy
    }

    /// Net bid/ask/mid z kotací nohou. `nil`, když některá opční noha nemá bid i ask.
    public var netQuote: NetQuote? {
        let options = optionLegs
        let count = Double(max(spreadCount, 1))
        guard !options.isEmpty else { return nil }
        var natural = 0.0
        var opposite = 0.0
        for leg in options {
            guard let bid = leg.bid, let ask = leg.ask else { return nil }
            let q = Double(leg.quantity) / count
            switch leg.side {
            case .long:
                natural += ask * q
                opposite += bid * q
            case .short:
                natural -= bid * q
                opposite -= ask * q
            }
        }
        return NetQuote(natural: natural, opposite: opposite)
    }

    /// Časová (extrinsic) hodnota pozice v dolarech při daném spotu.
    public func extrinsicValue(spot: Double) -> Double {
        optionLegs.reduce(0) { total, leg in
            guard let type = leg.instrument.optionType else { return total }
            let intrinsic = BlackScholes.intrinsic(type, spot: spot, strike: leg.strike)
            return total + leg.side.sign * Double(leg.quantity) * multiplier * (leg.premium - intrinsic)
        }
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}

// MARK: - Posun striků a šířky

public enum StrikeLadder {
    public static func nearestIndex(to value: Double, in strikes: [Double]) -> Int? {
        strikes.indices.min { abs(strikes[$0] - value) < abs(strikes[$1] - value) }
    }

    /// Strike o `steps` pozic vedle v seznamu dostupných striků (seřazeném vzestupně).
    public static func shift(_ strike: Double, by steps: Int, in strikes: [Double]) -> Double? {
        guard let index = nearestIndex(to: strike, in: strikes) else { return nil }
        let target = index + steps
        guard strikes.indices.contains(target) else { return nil }
        return strikes[target]
    }

    /// Nejbližší dostupný strike.
    public static func nearest(to value: Double, in strikes: [Double]) -> Double? {
        nearestIndex(to: value, in: strikes).map { strikes[$0] }
    }
}

extension OptionStrategy {
    /// Posune všechny opční nohy o `steps` striků. `nil`, když se dojede na kraj řetězce.
    public func shiftingStrikes(by steps: Int, strikes: (StrategyLeg) -> [Double]) -> OptionStrategy? {
        var copy = self
        for i in copy.legs.indices where copy.legs[i].instrument != .stock {
            guard let strike = StrikeLadder.shift(copy.legs[i].strike, by: steps, in: strikes(copy.legs[i])) else {
                return nil
            }
            copy.legs[i].strike = strike
        }
        return copy
    }

    /// Rozšíří (kladné `steps`) nebo zúží strategii.
    /// - Dva různé striky (vertical, strangle…): strike první nohy zůstává, druhý se posouvá od něj.
    /// - Tři a více striků (condor, butterfly…): posouvají se jen krajní křídla.
    /// Vrací `nil`, pokud by se striky překřížily nebo slily.
    public func changingWidth(by steps: Int, strikes: (StrategyLeg) -> [Double]) -> OptionStrategy? {
        let options = optionLegs
        let distinct = Array(Set(options.map(\.strike))).sorted()
        guard distinct.count >= 2, let anchorLeg = options.first else { return nil }

        var copy = self
        for i in copy.legs.indices where copy.legs[i].instrument != .stock {
            let strike = copy.legs[i].strike
            var direction = 0
            if distinct.count == 2 {
                if strike != anchorLeg.strike { direction = strike > anchorLeg.strike ? 1 : -1 }
            } else {
                if strike == distinct.first { direction = -1 }
                if strike == distinct.last { direction = 1 }
            }
            guard direction != 0 else { continue }
            guard let newStrike = StrikeLadder.shift(strike, by: direction * steps, in: strikes(copy.legs[i])) else {
                return nil
            }
            copy.legs[i].strike = newStrike
        }

        // Pořadí striků musí zůstat zachované a žádné dva se nesmí slít.
        let oldLegs = legs.filter { $0.instrument != .stock }
        let newLegs = copy.legs.filter { $0.instrument != .stock }
        for i in oldLegs.indices {
            for j in oldLegs.indices where j > i {
                let before = oldLegs[i].strike - oldLegs[j].strike
                let after = newLegs[i].strike - newLegs[j].strike
                if (before > 0) != (after > 0) || (before < 0) != (after < 0) { return nil }
            }
        }
        return copy
    }
}

// MARK: - Pojmenování strategie

public enum StrategyClassifier {
    public static func name(for strategy: OptionStrategy) -> String {
        let options = strategy.optionLegs
        let stocks = strategy.legs.filter { $0.instrument == .stock }

        if options.isEmpty { return stocks.isEmpty ? "Prázdná" : "Akcie" }

        if !stocks.isEmpty {
            if options.count == 1, stocks.count == 1, stocks[0].side == .long {
                let o = options[0]
                if o.instrument == .call && o.side == .short { return "Covered call" }
                if o.instrument == .put && o.side == .long { return "Protective put" }
            }
            return "Vlastní"
        }

        func expiryKey(_ leg: StrategyLeg) -> Double {
            leg.expiration?.timeIntervalSince1970 ?? -leg.daysToExpiry.rounded()
        }
        let sameExpiry = Set(options.map(expiryKey)).count == 1
        let sameQuantity = Set(options.map(\.quantity)).count == 1

        switch options.count {
        case 1:
            let o = options[0]
            let side = o.side == .long ? "Long" : "Short"
            return "\(side) \(o.instrument == .call ? "call" : "put")"

        case 2:
            let a = options[0], b = options[1]
            let sameType = a.instrument == b.instrument
            if !sameExpiry {
                guard sameType, a.side != b.side else { return "Vlastní" }
                return a.strike == b.strike ? "Calendar" : "Diagonal"
            }
            if sameType {
                if a.side != b.side { return sameQuantity ? "Vertical" : "Ratio spread" }
                return "Vlastní"
            }
            if a.side == b.side, sameQuantity {
                let side = a.side == .long ? "Long" : "Short"
                return a.strike == b.strike ? "\(side) straddle" : "\(side) strangle"
            }
            return "Risk reversal"

        case 3:
            guard sameExpiry, Set(options.map(\.instrument)).count == 1 else { return "Vlastní" }
            let sorted = options.sorted { $0.strike < $1.strike }
            let signed = sorted.map { $0.side.sign * Double($0.quantity) }
            if signed[0] == signed[2], signed[1] == -2 * signed[0], Set(sorted.map(\.strike)).count == 3 {
                return "Butterfly"
            }
            return "Vlastní"

        case 4:
            guard sameExpiry, sameQuantity else { return "Vlastní" }
            let puts = options.filter { $0.instrument == .put }.sorted { $0.strike < $1.strike }
            let calls = options.filter { $0.instrument == .call }.sorted { $0.strike < $1.strike }
            if puts.count == 2, calls.count == 2 {
                if puts[0].side == .long, puts[1].side == .short, calls[0].side == .short, calls[1].side == .long {
                    return puts[1].strike == calls[0].strike ? "Iron butterfly" : "Iron condor"
                }
                if puts[0].side == .short, puts[1].side == .long, calls[0].side == .long, calls[1].side == .short {
                    return "Reverse iron condor"
                }
            }
            if calls.count == 4 || puts.count == 4 {
                let sorted = (calls.count == 4 ? calls : puts)
                let sides = sorted.map(\.side)
                if sides == [.long, .short, .short, .long] { return "Condor" }
            }
            return "Vlastní"

        default:
            return "Vlastní"
        }
    }
}
