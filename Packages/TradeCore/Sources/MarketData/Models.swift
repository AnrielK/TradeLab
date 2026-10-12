import Foundation
import OptionsMath

public struct PriceBar: Hashable, Sendable {
    public var date: Date
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double
    public var adjustedClose: Double?
    public var volume: Double

    public init(date: Date, open: Double, high: Double, low: Double, close: Double, adjustedClose: Double? = nil, volume: Double) {
        self.date = date
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.adjustedClose = adjustedClose
        self.volume = volume
    }
}

public struct QuoteSnapshot: Hashable, Sendable {
    public var symbol: String
    public var name: String?
    public var currency: String
    public var exchange: String?
    public var price: Double
    public var previousClose: Double?

    public init(symbol: String, name: String?, currency: String, exchange: String?, price: Double, previousClose: Double?) {
        self.symbol = symbol
        self.name = name
        self.currency = currency
        self.exchange = exchange
        self.price = price
        self.previousClose = previousClose
    }

    public var change: Double? {
        guard let previousClose else { return nil }
        return price - previousClose
    }

    public var changePercent: Double? {
        guard let previousClose, previousClose != 0 else { return nil }
        return (price - previousClose) / previousClose
    }
}

public struct ChartData: Sendable {
    public var quote: QuoteSnapshot
    public var bars: [PriceBar]

    public init(quote: QuoteSnapshot, bars: [PriceBar]) {
        self.quote = quote
        self.bars = bars
    }
}

public enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case fiveDays = "5d"
    case oneMonth = "1mo"
    case threeMonths = "3mo"
    case sixMonths = "6mo"
    case oneYear = "1y"
    case twoYears = "2y"
    case fiveYears = "5y"

    public var id: String { rawValue }

    public var interval: String {
        switch self {
        case .fiveYears: return "1wk"
        default: return "1d"
        }
    }

    public var label: String {
        switch self {
        case .fiveDays: return "5D"
        case .oneMonth: return "1M"
        case .threeMonths: return "3M"
        case .sixMonths: return "6M"
        case .oneYear: return "1R"
        case .twoYears: return "2R"
        case .fiveYears: return "5R"
        }
    }

    /// Rozsahy vhodné pro graf v detailu.
    public static var chartable: [ChartRange] { [.oneMonth, .threeMonths, .sixMonths, .oneYear, .twoYears, .fiveYears] }
}

public struct SymbolMatch: Identifiable, Hashable, Sendable {
    public var symbol: String
    public var name: String?
    public var exchange: String?
    public var type: String?

    public var id: String { symbol }

    public init(symbol: String, name: String?, exchange: String?, type: String?) {
        self.symbol = symbol
        self.name = name
        self.exchange = exchange
        self.type = type
    }
}

public struct OptionContract: Identifiable, Hashable, Sendable {
    public var contractSymbol: String
    public var type: OptionType
    public var strike: Double
    public var lastPrice: Double?
    public var bid: Double?
    public var ask: Double?
    public var change: Double?
    public var volume: Int?
    public var openInterest: Int?
    /// IV tak, jak ji vrací Yahoo (mimo obchodní hodiny bývá nespolehlivá).
    public var yahooImpliedVolatility: Double?
    public var inTheMoney: Bool
    public var expiration: Date

    public var id: String { contractSymbol }

    public init(contractSymbol: String, type: OptionType, strike: Double, lastPrice: Double?, bid: Double?, ask: Double?,
                change: Double?, volume: Int?, openInterest: Int?, yahooImpliedVolatility: Double?,
                inTheMoney: Bool, expiration: Date) {
        self.contractSymbol = contractSymbol
        self.type = type
        self.strike = strike
        self.lastPrice = lastPrice
        self.bid = bid
        self.ask = ask
        self.change = change
        self.volume = volume
        self.openInterest = openInterest
        self.yahooImpliedVolatility = yahooImpliedVolatility
        self.inTheMoney = inTheMoney
        self.expiration = expiration
    }

    /// Střed bid/ask, případně poslední cena.
    public var mid: Double? {
        if let bid, let ask, ask > 0, bid >= 0, ask >= bid {
            return (bid + ask) / 2
        }
        if let lastPrice, lastPrice > 0 { return lastPrice }
        return nil
    }

    /// Dny do expirace. Yahoo udává půlnoc UTC dne expirace, obchodování končí v 16:00 ET (~20:00 UTC).
    public func daysToExpiry(from now: Date = Date()) -> Double {
        OptionChain.daysToExpiry(expiration, from: now)
    }

    /// IV dopočtená z mid ceny; když to nejde, IV od Yahoo.
    public func estimatedVolatility(spot: Double, rate: Double, now: Date = Date()) -> Double? {
        let days = daysToExpiry(from: now)
        if let mid, days > 0,
           let iv = ImpliedVolatility.solve(type, price: mid, spot: spot, strike: strike,
                                            years: days / BlackScholes.daysPerYear, rate: rate) {
            return iv
        }
        if let yahoo = yahooImpliedVolatility, yahoo > 0.01 { return yahoo }
        return nil
    }

    public func greeks(spot: Double, rate: Double, now: Date = Date()) -> Greeks? {
        guard let vol = estimatedVolatility(spot: spot, rate: rate, now: now) else { return nil }
        let params = OptionParameters(spot: spot, strike: strike, days: daysToExpiry(from: now), rate: rate, volatility: vol)
        return BlackScholes.greeks(type, params)
    }
}

public struct OptionChain: Sendable {
    public var symbol: String
    public var underlyingPrice: Double
    public var expirationDates: [Date]
    public var expiration: Date
    public var calls: [OptionContract]
    public var puts: [OptionContract]

    public init(symbol: String, underlyingPrice: Double, expirationDates: [Date], expiration: Date,
                calls: [OptionContract], puts: [OptionContract]) {
        self.symbol = symbol
        self.underlyingPrice = underlyingPrice
        self.expirationDates = expirationDates
        self.expiration = expiration
        self.calls = calls
        self.puts = puts
    }

    public func contracts(_ type: OptionType) -> [OptionContract] {
        type == .call ? calls : puts
    }

    static let closeOffset: TimeInterval = 20 * 3600

    public static func daysToExpiry(_ expiration: Date, from now: Date = Date()) -> Double {
        max((expiration.timeIntervalSince(now) + closeOffset) / 86_400, 0)
    }
}
