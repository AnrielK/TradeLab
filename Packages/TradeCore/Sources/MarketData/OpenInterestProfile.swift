import Foundation
import OptionsMath

/// Jak vážit open interest při sčítání přes expirace.
public enum OpenInterestWeighting: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Prostý součet kontraktů.
    case raw
    /// OI × 1/√(dny do expirace) – bližší expirace mají větší vliv na dnešní cenu.
    case time
    /// Gamma exposure (GEX) v USD na 1% pohyb: OI × gamma × 100 × spot² × 1 %, cally +, puty −.
    /// Předpokládá, že dealeři jsou long cally a short puty (běžná konvence, ne jistota).
    case gamma

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .raw: return "OI"
        case .time: return "OI vážené časem"
        case .gamma: return "GEX"
        }
    }
}

/// Agregace jednoho striku přes všechny zahrnuté expirace.
public struct StrikeOpenInterest: Identifiable, Hashable, Sendable {
    public var strike: Double
    public var callOpenInterest: Int
    public var putOpenInterest: Int
    /// OI vážené 1/√DTE.
    public var callTimeWeighted: Double
    public var putTimeWeighted: Double
    /// GEX v USD na 1% pohyb podkladu (call kladný, put záporný).
    public var callGamma: Double
    public var putGamma: Double

    public var id: Double { strike }

    public var totalOpenInterest: Int { callOpenInterest + putOpenInterest }
    public var netGamma: Double { callGamma + putGamma }

    public init(strike: Double, callOpenInterest: Int = 0, putOpenInterest: Int = 0,
                callTimeWeighted: Double = 0, putTimeWeighted: Double = 0,
                callGamma: Double = 0, putGamma: Double = 0) {
        self.strike = strike
        self.callOpenInterest = callOpenInterest
        self.putOpenInterest = putOpenInterest
        self.callTimeWeighted = callTimeWeighted
        self.putTimeWeighted = putTimeWeighted
        self.callGamma = callGamma
        self.putGamma = putGamma
    }

    /// Hodnota callů a putů podle vážení (puty u GEX záporné).
    public func value(_ type: OptionType, _ weighting: OpenInterestWeighting) -> Double {
        switch (type, weighting) {
        case (.call, .raw): return Double(callOpenInterest)
        case (.put, .raw): return Double(putOpenInterest)
        case (.call, .time): return callTimeWeighted
        case (.put, .time): return putTimeWeighted
        case (.call, .gamma): return callGamma
        case (.put, .gamma): return putGamma
        }
    }

    /// Velikost úrovně bez ohledu na znaménko (pro řazení).
    public func magnitude(_ weighting: OpenInterestWeighting) -> Double {
        abs(value(.call, weighting)) + abs(value(.put, weighting))
    }
}

/// Významná úroveň z profilu open interest.
public struct OpenInterestLevel: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case callWall, putWall, gammaFlip, maxPain, top
    }

    public var kind: Kind
    public var price: Double
    /// Hodnota podle vážení (OI, vážené OI nebo GEX).
    public var value: Double

    public init(kind: Kind, price: Double, value: Double) {
        self.kind = kind
        self.price = price
        self.value = value
    }
}

/// Max pain jedné expirace.
public struct MaxPain: Hashable, Sendable {
    public var expiration: Date
    public var strike: Double
    /// Hodnota všech opcí (vnitřní hodnota × OI × 100) při vypořádání na `strike`.
    public var payout: Double
}

/// Kontrakt připravený pro výpočet gammy při libovolné ceně podkladu.
struct GammaContract: Sendable {
    var type: OptionType
    var strike: Double
    var years: Double
    var volatility: Double
    var openInterest: Double
}

/// Open interest sečtené přes všechny expirace do `maxDays` dní.
public struct OpenInterestProfile: Sendable {
    public var symbol: String
    public var spot: Double
    public var maxDays: Double
    public var expirations: [Date]
    /// Striky vzestupně.
    public var strikes: [StrikeOpenInterest]
    public var rate: Double
    public var computedAt: Date
    var contracts: [GammaContract]

    public var totalCallOpenInterest: Int { strikes.reduce(0) { $0 + $1.callOpenInterest } }
    public var totalPutOpenInterest: Int { strikes.reduce(0) { $0 + $1.putOpenInterest } }
    public var totalGamma: Double { strikes.reduce(0) { $0 + $1.netGamma } }

    /// Put/call poměr podle OI.
    public var putCallRatio: Double? {
        let calls = totalCallOpenInterest
        return calls > 0 ? Double(totalPutOpenInterest) / Double(calls) : nil
    }

    /// Sečte řetězce, které expirují do `maxDays` dní. Kontrakty bez OI se přeskočí.
    /// Volatilita se dopočte z mid ceny (nebo IV od Yahoo); když chybí, použije se medián ostatních.
    public init(chains: [OptionChain], maxDays: Double = 100, rate: Double, now: Date = Date()) {
        let included = chains
            .filter { let d = OptionChain.daysToExpiry($0.expiration, from: now); return d > 0 && d <= maxDays }
            .sorted { $0.expiration < $1.expiration }
        let spot = included.first?.underlyingPrice ?? chains.first?.underlyingPrice ?? 0

        self.symbol = included.first?.symbol ?? chains.first?.symbol ?? ""
        self.spot = spot
        self.maxDays = maxDays
        self.rate = rate
        self.computedAt = now

        var seen = Set<Date>()
        self.expirations = included.map(\.expiration).filter { seen.insert($0).inserted }

        var pending: [(type: OptionType, strike: Double, years: Double, vol: Double?, oi: Double, expiration: Date)] = []
        for chain in included {
            guard seen.remove(chain.expiration) != nil else { continue }   // duplicitní expirace jen jednou
            let days = OptionChain.daysToExpiry(chain.expiration, from: now)
            for contract in chain.calls + chain.puts {
                guard let oi = contract.openInterest, oi > 0, contract.strike > 0 else { continue }
                let vol = spot > 0 ? contract.estimatedVolatility(spot: spot, rate: rate, now: now) : nil
                pending.append((contract.type, contract.strike, days / BlackScholes.daysPerYear,
                                vol.flatMap { $0 > 0.01 && $0 < 5 ? $0 : nil }, Double(oi), chain.expiration))
            }
        }

        let vols = pending.compactMap(\.vol).sorted()
        let fallbackVol = vols.isEmpty ? 0.3 : vols[vols.count / 2]
        self.contracts = pending.map {
            GammaContract(type: $0.type, strike: $0.strike, years: $0.years,
                          volatility: $0.vol ?? fallbackVol, openInterest: $0.oi)
        }

        var byStrike: [Double: StrikeOpenInterest] = [:]
        for c in contracts {
            let key = (c.strike * 1000).rounded() / 1000
            var row = byStrike[key] ?? StrikeOpenInterest(strike: key)
            let days = max(c.years * BlackScholes.daysPerYear, 1)
            let timeWeighted = c.openInterest / days.squareRoot()
            let gex = Self.gammaExposure(c, spot: spot, rate: rate)
            switch c.type {
            case .call:
                row.callOpenInterest += Int(c.openInterest)
                row.callTimeWeighted += timeWeighted
                row.callGamma += gex
            case .put:
                row.putOpenInterest += Int(c.openInterest)
                row.putTimeWeighted += timeWeighted
                row.putGamma -= gex
            }
            byStrike[key] = row
        }
        self.strikes = byStrike.values.sorted { $0.strike < $1.strike }
    }

    /// GEX jednoho kontraktu (kladný) v USD na 1% pohyb při ceně `spot`.
    static func gammaExposure(_ c: GammaContract, spot: Double, rate: Double) -> Double {
        guard spot > 0 else { return 0 }
        let params = OptionParameters(spot: spot, strike: c.strike, years: c.years, rate: rate, volatility: c.volatility)
        let gamma = BlackScholes.greeks(c.type, params).gamma
        return gamma * c.openInterest * 100 * spot * spot * 0.01
    }

    /// Celkové GEX všech kontraktů, kdyby podklad stál na `price` (IV a čas beze změny).
    public func totalGamma(at price: Double) -> Double {
        contracts.reduce(0) { sum, c in
            let gex = Self.gammaExposure(c, spot: price, rate: rate)
            return sum + (c.type == .call ? gex : -gex)
        }
    }

    // MARK: - Úrovně

    /// Strike s největší hodnotou callů nad cenou (rezistence / „strop“).
    public func callWall(_ weighting: OpenInterestWeighting) -> OpenInterestLevel? {
        strikes.filter { $0.strike >= spot }
            .max { $0.value(.call, weighting) < $1.value(.call, weighting) }
            .flatMap { row in
                let v = row.value(.call, weighting)
                return v > 0 ? OpenInterestLevel(kind: .callWall, price: row.strike, value: v) : nil
            }
    }

    /// Strike s největší hodnotou putů pod cenou (support / „podlaha“).
    public func putWall(_ weighting: OpenInterestWeighting) -> OpenInterestLevel? {
        strikes.filter { $0.strike <= spot }
            .max { abs($0.value(.put, weighting)) < abs($1.value(.put, weighting)) }
            .flatMap { row in
                let v = row.value(.put, weighting)
                return v != 0 ? OpenInterestLevel(kind: .putWall, price: row.strike, value: v) : nil
            }
    }

    /// N striků s největší hodnotou (call + put) podle vážení, seřazené od největší.
    public func topLevels(_ count: Int, weighting: OpenInterestWeighting) -> [OpenInterestLevel] {
        strikes.sorted { $0.magnitude(weighting) > $1.magnitude(weighting) }
            .prefix(count)
            .filter { $0.magnitude(weighting) > 0 }
            .map { row in
                let value = weighting == .gamma ? row.netGamma : row.magnitude(weighting)
                return OpenInterestLevel(kind: .top, price: row.strike, value: value)
            }
    }

    /// Cena, kde celkové GEX mění znaménko (nad ní dealeři tlumí pohyby, pod ní je zesilují).
    /// Hledá se v pásmu ±`range` kolem spotu; vrací průsečík nejbližší ke spotu.
    public func gammaFlip(range: Double = 0.2, steps: Int = 80) -> Double? {
        guard spot > 0, !contracts.isEmpty, steps > 1 else { return nil }
        let low = spot * (1 - range), high = spot * (1 + range)
        let step = (high - low) / Double(steps)
        var prices: [Double] = []
        var values: [Double] = []
        for i in 0...steps {
            let price = low + Double(i) * step
            prices.append(price)
            values.append(totalGamma(at: price))
        }
        var best: Double? = nil
        for i in 1..<values.count {
            let a = values[i - 1], b = values[i]
            guard (a <= 0 && b > 0) || (a >= 0 && b < 0) else { continue }
            let t = a == b ? 0 : a / (a - b)
            let cross = prices[i - 1] + t * (prices[i] - prices[i - 1])
            if best == nil || abs(cross - spot) < abs(best! - spot) { best = cross }
        }
        return best
    }

    /// Striky v pásmu ±`range` kolem spotu (pro graf).
    public func strikes(within range: Double) -> [StrikeOpenInterest] {
        guard spot > 0 else { return strikes }
        return strikes.filter { abs($0.strike / spot - 1) <= range }
    }
}

extension OptionChain {
    /// Max pain: cena vypořádání, při které mají všechny opce této expirace nejmenší hodnotu.
    public var maxPain: MaxPain? {
        let candidates = strikes
        let withOI = (calls + puts).filter { ($0.openInterest ?? 0) > 0 }
        guard !candidates.isEmpty, !withOI.isEmpty else { return nil }
        var best: (strike: Double, payout: Double)? = nil
        for settle in candidates {
            var payout = 0.0
            for c in withOI {
                let intrinsic = BlackScholes.intrinsic(c.type, spot: settle, strike: c.strike)
                payout += intrinsic * Double(c.openInterest ?? 0) * 100
            }
            if best == nil || payout < best!.payout { best = (settle, payout) }
        }
        return best.map { MaxPain(expiration: expiration, strike: $0.strike, payout: $0.payout) }
    }
}

extension YahooFinanceClient {
    /// Řetězce všech expirací do `maxDays` dní (nejvýš `limit`), načítané po `concurrency` najednou.
    /// Expirace, které selžou, se přeskočí; selže-li i první dotaz, vyhodí chybu.
    public func optionChains(symbol: String, maxDays: Double = 100, limit: Int = 80, concurrency: Int = 4,
                             now: Date = Date()) async throws -> [OptionChain] {
        let first = try await optionChain(symbol: symbol)
        let dates = first.expirationDates
            .filter { let d = OptionChain.daysToExpiry($0, from: now); return d > 0 && d <= maxDays }
            .prefix(limit)
        var result: [Date: OptionChain] = [first.expiration: first]
        let remaining = dates.filter { $0 != first.expiration }
        var index = 0
        while index < remaining.count {
            let batch = remaining[index..<min(index + max(concurrency, 1), remaining.count)]
            index += batch.count
            await withTaskGroup(of: OptionChain?.self) { group in
                for date in batch {
                    group.addTask { try? await self.optionChain(symbol: symbol, expiration: date) }
                }
                for await chain in group {
                    if let chain { result[chain.expiration] = chain }
                }
            }
        }
        return result.values.sorted { $0.expiration < $1.expiration }
    }
}
