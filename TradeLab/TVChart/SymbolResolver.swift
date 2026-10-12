import Foundation

/// Doplní burzu k symbolu, když ji uživatel nenapsal.
///
/// „AAPL“ → „NASDAQ:AAPL“, „F“ → „NYSE:F“, „BTCUSDT“ → „BINANCE:BTCUSDT“.
/// Symbol už obsahující dvojtečku se propustí beze změny.
///
/// Postup:
///  1. vyhledávací endpoint `symbol-search.tradingview.com` — vrátí burzu rovnou
///  2. když selže, zkouší se známé burzy proti `scanner.tradingview.com/symbol`
///     (endpoint, který používá `validate_symbols()` v tradingview-scraper)
actor SymbolResolver {

    static let shared = SymbolResolver()

    /// Záložní pořadí burz. Akcie první, ať „AAPL“ nespadne na exotický CFD.
    private let candidates = [
        "NASDAQ", "NYSE", "AMEX", "BATS",
        "BINANCE", "COINBASE", "BITSTAMP",
        "FX", "OANDA",
        "LSE", "XETR", "TSX"
    ]

    /// Ruční zkratky pro věci, kde chci konkrétní trh.
    private let aliases: [String: String] = [
        "BTC": "BINANCE:BTCUSDT",
        "ETH": "BINANCE:ETHUSDT",
        "SPX": "SP:SPX",
        "NDX": "NASDAQ:NDX",
        "DJI": "DJ:DJI",
        "GOLD": "COMEX:GC1!",
        "OIL": "NYMEX:CL1!"
    ]

    private var cache: [String: String] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config)

        if let saved = UserDefaults.standard.dictionary(forKey: "symbolCache") as? [String: String] {
            cache = saved
        }
    }

    /// Vrátí symbol ve tvaru BURZA:SYMBOL, nebo nil když se nic nenašlo.
    func resolve(_ input: String) async -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !raw.isEmpty else { return nil }
        if raw.contains(":") { return raw }          // burzu napsal uživatel

        if let alias = aliases[raw] { return alias }
        if let hit = cache[raw] { return hit }

        if let found = await searchSymbol(raw) { return remember(raw, found) }
        if let found = await probeExchanges(raw) { return remember(raw, found) }
        return nil
    }

    @discardableResult
    func remember(_ key: String, _ full: String) -> String {
        cache[key] = full
        UserDefaults.standard.set(cache, forKey: "symbolCache")
        return full
    }

    // MARK: - 1) Vyhledávání

    private func searchSymbol(_ symbol: String) async -> String? {
        var comps = URLComponents(string: "https://symbol-search.tradingview.com/symbol_search/")!
        comps.queryItems = [
            .init(name: "text", value: symbol),
            .init(name: "hl", value: "0"),
            .init(name: "lang", value: "en"),
            .init(name: "domain", value: "production")
        ]
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("https://www.tradingview.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.tradingview.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        // odpověď je pole objektů, občas zabalené do {"symbols": [...]}
        let root = try? JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            items = arr
        } else if let dict = root as? [String: Any],
                  let arr = dict["symbols"] as? [[String: Any]] {
            items = arr
        } else {
            return nil
        }

        // výsledky mají ticker obalený v <em>…</em> kvůli zvýraznění
        let cleaned = items.compactMap { item -> (symbol: String, exchange: String)? in
            guard var s = item["symbol"] as? String else { return nil }
            s = s.replacingOccurrences(of: "<em>", with: "")
                 .replacingOccurrences(of: "</em>", with: "")
                 .uppercased()
            // "prefix"/"source_id" je to, co chce websocket; "exchange" je zobrazovaný název
            let ex = (item["prefix"] as? String)
                ?? (item["source_id"] as? String)
                ?? (item["exchange"] as? String)
            guard let ex, !ex.isEmpty else { return nil }
            return (s, ex.uppercased())
        }

        if let exact = cleaned.first(where: { $0.symbol == symbol }) {
            return "\(exact.exchange):\(exact.symbol)"
        }
        return cleaned.first.map { "\($0.exchange):\($0.symbol)" }
    }

    // MARK: - 2) Zkoušení burz

    private func probeExchanges(_ symbol: String) async -> String? {
        for exchange in candidates where await exists(exchange: exchange, symbol: symbol) {
            return "\(exchange):\(symbol)"
        }
        return nil
    }

    private func exists(exchange: String, symbol: String) async -> Bool {
        let path = "https://scanner.tradingview.com/symbol"
            + "?symbol=\(exchange)%3A\(symbol)&fields=market&no_404=false"
        guard let url = URL(string: path) else { return false }

        var request = URLRequest(url: url)
        request.setValue("https://www.tradingview.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.tradingview.com/", forHTTPHeaderField: "Referer")

        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
