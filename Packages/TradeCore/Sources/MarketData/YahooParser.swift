import Foundation
import OptionsMath

public enum MarketDataError: Error, Equatable, LocalizedError {
    case invalidResponse
    case unauthorized
    case notFound
    case rateLimited
    case http(Int)
    case api(String)
    case crumbUnavailable
    case noData

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Neplatná odpověď serveru."
        case .unauthorized: return "Yahoo odmítl požadavek (chybí platný crumb/cookie)."
        case .notFound: return "Symbol nebyl nalezen."
        case .rateLimited: return "Příliš mnoho požadavků, zkus to za chvíli."
        case .http(let code): return "Chyba serveru (HTTP \(code))."
        case .api(let message): return message
        case .crumbUnavailable: return "Nepodařilo se získat přístup k opčním datům Yahoo (crumb). V EU může blokovat souhlas s cookies."
        case .noData: return "Žádná data."
        }
    }
}

// MARK: - Payloady

struct YahooErrorPayload: Decodable {
    let code: String?
    let description: String?
}

struct ChartEnvelope: Decodable {
    struct Chart: Decodable {
        let result: [ChartResultPayload]?
        let error: YahooErrorPayload?
    }
    let chart: Chart
}

struct ChartResultPayload: Decodable {
    struct Meta: Decodable {
        let symbol: String
        let currency: String?
        let exchangeName: String?
        let fullExchangeName: String?
        let regularMarketPrice: Double?
        let chartPreviousClose: Double?
        let previousClose: Double?
        let longName: String?
        let shortName: String?
    }

    struct Indicators: Decodable {
        struct Quote: Decodable {
            let open: [Double?]?
            let high: [Double?]?
            let low: [Double?]?
            let close: [Double?]?
            let volume: [Double?]?
        }

        struct AdjClose: Decodable {
            let adjclose: [Double?]?
        }

        let quote: [Quote]?
        let adjclose: [AdjClose]?
    }

    let meta: Meta
    let timestamp: [Double]?
    let indicators: Indicators?
}

struct OptionsEnvelope: Decodable {
    struct OptionChainPayload: Decodable {
        let result: [ResultPayload]?
        let error: YahooErrorPayload?
    }

    struct ResultPayload: Decodable {
        let underlyingSymbol: String?
        let expirationDates: [Double]?
        let quote: QuotePayload?
        let options: [OptionsPayload]?
    }

    struct QuotePayload: Decodable {
        let regularMarketPrice: Double?
    }

    struct OptionsPayload: Decodable {
        let expirationDate: Double?
        let calls: [ContractPayload]?
        let puts: [ContractPayload]?
    }

    struct ContractPayload: Decodable {
        let contractSymbol: String
        let strike: Double
        let lastPrice: Double?
        let change: Double?
        let volume: Double?
        let openInterest: Double?
        let bid: Double?
        let ask: Double?
        let impliedVolatility: Double?
        let inTheMoney: Bool?
        let expiration: Double?
    }

    let optionChain: OptionChainPayload
}

struct SearchEnvelope: Decodable {
    struct QuotePayload: Decodable {
        let symbol: String
        let shortname: String?
        let longname: String?
        let quoteType: String?
        let exchDisp: String?
    }
    let quotes: [QuotePayload]?
}

// MARK: - Parser

public enum YahooParser {
    public static func parseChart(_ data: Data) throws -> ChartData {
        let envelope = try JSONDecoder().decode(ChartEnvelope.self, from: data)
        if let error = envelope.chart.error {
            throw MarketDataError.api(error.description ?? error.code ?? "Neznámá chyba")
        }
        guard let result = envelope.chart.result?.first else { throw MarketDataError.noData }

        let timestamps = result.timestamp ?? []
        let quote = result.indicators?.quote?.first
        let adj = result.indicators?.adjclose?.first?.adjclose

        func value(_ array: [Double?]?, _ i: Int) -> Double? {
            guard let array, i < array.count else { return nil }
            return array[i]
        }

        var bars: [PriceBar] = []
        bars.reserveCapacity(timestamps.count)
        for (i, ts) in timestamps.enumerated() {
            guard let close = value(quote?.close, i) else { continue }
            bars.append(PriceBar(
                date: Date(timeIntervalSince1970: ts),
                open: value(quote?.open, i) ?? close,
                high: value(quote?.high, i) ?? close,
                low: value(quote?.low, i) ?? close,
                close: close,
                adjustedClose: value(adj, i),
                volume: value(quote?.volume, i) ?? 0
            ))
        }

        let meta = result.meta
        guard let price = meta.regularMarketPrice ?? bars.last?.close else { throw MarketDataError.noData }
        let previousClose: Double?
        if bars.count >= 2 {
            previousClose = bars[bars.count - 2].close
        } else {
            previousClose = meta.previousClose ?? meta.chartPreviousClose
        }

        let snapshot = QuoteSnapshot(
            symbol: meta.symbol,
            name: meta.longName ?? meta.shortName,
            currency: meta.currency ?? "USD",
            exchange: meta.fullExchangeName ?? meta.exchangeName,
            price: price,
            previousClose: previousClose
        )
        return ChartData(quote: snapshot, bars: bars)
    }

    public static func parseOptionChain(_ data: Data) throws -> OptionChain {
        let envelope = try JSONDecoder().decode(OptionsEnvelope.self, from: data)
        if let error = envelope.optionChain.error {
            throw MarketDataError.api(error.description ?? error.code ?? "Neznámá chyba")
        }
        guard let result = envelope.optionChain.result?.first,
              let symbol = result.underlyingSymbol,
              let price = result.quote?.regularMarketPrice else { throw MarketDataError.noData }

        let expirations = (result.expirationDates ?? []).map { Date(timeIntervalSince1970: $0) }
        let block = result.options?.first
        guard let expirationStamp = block?.expirationDate ?? result.expirationDates?.first else {
            throw MarketDataError.noData
        }
        let expiration = Date(timeIntervalSince1970: expirationStamp)

        func map(_ payloads: [OptionsEnvelope.ContractPayload]?, _ type: OptionType) -> [OptionContract] {
            (payloads ?? []).map { c in
                OptionContract(
                    contractSymbol: c.contractSymbol,
                    type: type,
                    strike: c.strike,
                    lastPrice: c.lastPrice,
                    bid: c.bid,
                    ask: c.ask,
                    change: c.change,
                    volume: c.volume.map { Int($0) },
                    openInterest: c.openInterest.map { Int($0) },
                    yahooImpliedVolatility: c.impliedVolatility,
                    inTheMoney: c.inTheMoney ?? false,
                    expiration: c.expiration.map { Date(timeIntervalSince1970: $0) } ?? expiration
                )
            }
            .sorted { $0.strike < $1.strike }
        }

        return OptionChain(
            symbol: symbol,
            underlyingPrice: price,
            expirationDates: expirations,
            expiration: expiration,
            calls: map(block?.calls, .call),
            puts: map(block?.puts, .put)
        )
    }

    public static func parseSearch(_ data: Data) throws -> [SymbolMatch] {
        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        let allowed: Set<String> = ["EQUITY", "ETF", "INDEX", "MUTUALFUND"]
        return (envelope.quotes ?? [])
            .filter { allowed.contains($0.quoteType ?? "") }
            .map { SymbolMatch(symbol: $0.symbol, name: $0.longname ?? $0.shortname, exchange: $0.exchDisp, type: $0.quoteType) }
    }
}
