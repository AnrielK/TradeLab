import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Klient pro neoficiální Yahoo Finance API.
/// - Graf a vyhledávání fungují bez autentizace.
/// - Opční řetězce vyžadují cookie + „crumb“, který se získá a uloží automaticky.
public actor YahooFinanceClient {
    public static let shared = YahooFinanceClient()

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession
    private var crumb: String?
    private var chartCache: [String: (stamp: Date, value: ChartData)] = [:]
    private let cacheTTL: TimeInterval = 60

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: config)
    }

    // MARK: - Veřejné API

    public func chart(symbol: String, range: ChartRange) async throws -> ChartData {
        let key = "\(symbol.uppercased())|\(range.rawValue)"
        if let cached = chartCache[key], Date().timeIntervalSince(cached.stamp) < cacheTTL {
            return cached.value
        }
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(Self.encodePath(symbol))")!
        components.queryItems = [
            URLQueryItem(name: "range", value: range.rawValue),
            URLQueryItem(name: "interval", value: range.interval),
            URLQueryItem(name: "includeAdjustedClose", value: "true"),
        ]
        let data = try await get(components.url!)
        let result = try YahooParser.parseChart(data)
        chartCache[key] = (Date(), result)
        return result
    }

    public func quote(symbol: String) async throws -> QuoteSnapshot {
        try await chart(symbol: symbol, range: .fiveDays).quote
    }

    public func search(_ query: String) async throws -> [SymbolMatch] {
        var components = URLComponents(string: "https://query2.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "10"),
            URLQueryItem(name: "newsCount", value: "0"),
        ]
        return try YahooParser.parseSearch(try await get(components.url!))
    }

    /// Řetězec pro danou expiraci (nil = nejbližší).
    public func optionChain(symbol: String, expiration: Date? = nil) async throws -> OptionChain {
        do {
            return try await fetchOptionChain(symbol: symbol, expiration: expiration, refreshCrumb: false)
        } catch MarketDataError.unauthorized {
            return try await fetchOptionChain(symbol: symbol, expiration: expiration, refreshCrumb: true)
        }
    }

    /// Bezriziková sazba z 13týdenních T-bills (^IRX), např. 0.042.
    public func riskFreeRate() async -> Double? {
        guard let chart = try? await chart(symbol: "^IRX", range: .fiveDays) else { return nil }
        let value = chart.bars.last?.close ?? chart.quote.price
        guard value > 0, value < 25 else { return nil }
        return value / 100
    }

    public func clearCache() {
        chartCache.removeAll()
    }

    // MARK: - Interní

    private func fetchOptionChain(symbol: String, expiration: Date?, refreshCrumb: Bool) async throws -> OptionChain {
        let crumb = try await obtainCrumb(forceRefresh: refreshCrumb)
        var components = URLComponents(string: "https://query2.finance.yahoo.com/v7/finance/options/\(Self.encodePath(symbol))")!
        var items = [URLQueryItem(name: "crumb", value: crumb)]
        if let expiration {
            items.append(URLQueryItem(name: "date", value: String(Int(expiration.timeIntervalSince1970))))
        }
        components.queryItems = items
        let data = try await get(components.url!)
        return try YahooParser.parseOptionChain(data)
    }

    private func obtainCrumb(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let crumb { return crumb }
        crumb = nil

        // 1) fc.yahoo.com vrací 404, ale nastaví cookie A3, se kterou getcrumb funguje.
        _ = try? await session.data(from: URL(string: "https://fc.yahoo.com")!)
        if let value = try? await requestCrumb() {
            crumb = value
            return value
        }

        // 2) Záložně načíst běžnou stránku, která cookies nastaví také.
        _ = try? await session.data(from: URL(string: "https://finance.yahoo.com/quote/AAPL/options")!)
        if let value = try? await requestCrumb() {
            crumb = value
            return value
        }
        throw MarketDataError.crumbUnavailable
    }

    private func requestCrumb() async throws -> String {
        let (data, response) = try await session.data(from: URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("<"), text.count < 64 else {
            throw MarketDataError.crumbUnavailable
        }
        return text
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw MarketDataError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw MarketDataError.unauthorized
        case 404: throw MarketDataError.notFound
        case 429: throw MarketDataError.rateLimited
        default: throw MarketDataError.http(http.statusCode)
        }
    }

    static func encodePath(_ symbol: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return symbol.uppercased().addingPercentEncoding(withAllowedCharacters: allowed) ?? symbol
    }
}
