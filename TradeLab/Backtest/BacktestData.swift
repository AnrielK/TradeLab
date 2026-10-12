import Foundation
import MarketData
import Backtest

/// Odkud backtest bere svíčky.
enum BacktestSource: String, CaseIterable, Identifiable {
    case yahoo
    case tradingView

    var id: String { rawValue }
    var label: String { self == .yahoo ? "Yahoo" : "TradingView" }

    static let defaultsKey = "backtest.source"
    static var current: BacktestSource {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(BacktestSource.init(rawValue:)) ?? .yahoo
    }
}

/// Interval svíček z TradingView (Yahoo dává pro backtest jen denní).
enum BacktestInterval: String, CaseIterable, Identifiable {
    case day = "1D"
    case week = "1W"
    case fourHours = "240"
    case hour = "60"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "1D"
        case .week: return "1W"
        case .fourHours: return "4H"
        case .hour: return "1H"
        }
    }

    /// Přibližný počet svíček za rok (US akcie, běžná seance).
    var barsPerYear: Double {
        switch self {
        case .day: return 252
        case .week: return 52
        case .fourHours: return 504
        case .hour: return 1_764
        }
    }

    static let defaultsKey = "backtest.tvInterval"
    static var current: BacktestInterval {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(BacktestInterval.init(rawValue:)) ?? .day
    }
}

struct BacktestSeries {
    var bars: [BacktestBar]
    /// Popis dat pro výsledky, např. „TradingView · NASDAQ:AAPL · 1D · upraveno o dividendy“.
    var label: String
}

enum BacktestData {
    static func years(_ range: HistoryRange) -> Double {
        switch range {
        case .oneYear: return 1
        case .twoYears: return 2
        case .fiveYears: return 5
        case .tenYears: return 10
        case .max: return 40
        }
    }

    static func load(symbol: String, range: HistoryRange, source: BacktestSource = .current,
                     interval: BacktestInterval = .current, client: YahooFinanceClient) async throws -> BacktestSeries {
        switch source {
        case .yahoo:
            let data = try await client.dailyHistory(symbol: symbol, range: range)
            return BacktestSeries(bars: yahooBars(data.bars), label: "Yahoo · \(symbol) · 1D · upraveno o dividendy")

        case .tradingView:
            let count = Int(min(years(range) * interval.barsPerYear * 1.05, 10_000))
            let result = try await TVHistory.fetch(symbol: symbol, resolution: interval.rawValue, count: max(count, 60))
            let bars = result.bars.compactMap { bar -> BacktestBar? in
                guard bar.open > 0, bar.close > 0 else { return nil }
                return BacktestBar(date: Date(timeIntervalSince1970: bar.time), open: bar.open, high: bar.high,
                                   low: bar.low, close: bar.close)
            }
            // U „max“ a delších období vzít jen požadovaný úsek.
            let cutoff = Date().addingTimeInterval(-years(range) * 365.25 * 86_400)
            let trimmed = range == .max ? bars : bars.filter { $0.date >= cutoff }
            let adjusted = result.adjustment == "dividends" ? "upraveno o dividendy" : "jen splity"
            return BacktestSeries(bars: trimmed,
                                  label: "TradingView · \(result.symbol) · \(interval.label) · \(adjusted)")
        }
    }

    /// Ceny upravené o dividendy (poměr adjClose / close), ať výnos odpovídá skutečnosti.
    static func yahooBars(_ bars: [PriceBar]) -> [BacktestBar] {
        bars.compactMap { bar in
            guard bar.close > 0, bar.open > 0 else { return nil }
            let factor = (bar.adjustedClose ?? bar.close) / bar.close
            return BacktestBar(date: bar.date, open: bar.open * factor, high: bar.high * factor,
                               low: bar.low * factor, close: bar.close * factor)
        }
    }
}

/// Jednorázové stažení historie z websocketu TradingView (stejný protokol jako `TVRealtimeClient`).
enum TVHistory {
    struct Result {
        var symbol: String
        var adjustment: String
        var bars: [Bar]
    }

    /// - Parameter preferDividends: ceny upravené o dividendy (backtest); `false` = jen splity jako v grafu.
    static func fetch(symbol rawSymbol: String, resolution: String, count: Int,
                      preferDividends: Bool = true) async throws -> Result {
        guard let symbol = await SymbolResolver.shared.resolve(rawSymbol) else {
            throw TVError.symbolNotFound(rawSymbol)
        }
        guard preferDividends else {
            let bars = try await load(symbol: symbol, resolution: resolution, count: count, adjustment: "splits")
            return Result(symbol: symbol, adjustment: "splits", bars: bars)
        }
        do {
            let bars = try await load(symbol: symbol, resolution: resolution, count: count, adjustment: "dividends")
            return Result(symbol: symbol, adjustment: "dividends", bars: bars)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Úprava o dividendy nemusí být bez přihlášení dostupná – zkusit jen splity.
            let bars = try await load(symbol: symbol, resolution: resolution, count: count, adjustment: "splits")
            return Result(symbol: symbol, adjustment: "splits", bars: bars)
        }
    }

    private static func load(symbol: String, resolution: String, count: Int, adjustment: String) async throws -> [Bar] {
        var request = URLRequest(url: URL(string: "wss://data.tradingview.com/socket.io/websocket?from=chart%2F")!)
        request.setValue("https://www.tradingview.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                         + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 64 * 1024 * 1024
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let chart = "cs_" + String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
        let resolve = "=" + ((try? String(data: JSONSerialization.data(withJSONObject: ["adjustment": adjustment, "symbol": symbol]),
                                           encoding: .utf8)) ?? "")
        let messages: [(String, [Any])] = [
            ("set_auth_token", ["unauthorized_user_token"]),
            ("chart_create_session", [chart, ""]),
            ("resolve_symbol", [chart, "sds_sym_1", resolve]),
            ("create_series", [chart, "sds_1", "s1", "sds_sym_1", resolution, count, ""]),
        ]
        for (method, params) in messages {
            try await socket.send(.string(frame(method, params)))
        }

        return try await withThrowingTaskGroup(of: [Bar].self) { group in
            group.addTask {
                var bars: [Bar] = []
                while true {
                    try Task.checkCancellation()
                    let message = try await socket.receive()
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: continue
                    }
                    for payload in TVRealtimeClient.splitFrames(text) {
                        if payload.hasPrefix("~h~") {
                            try await socket.send(.string("~m~\(payload.utf8.count)~m~\(payload)"))
                            continue
                        }
                        guard let data = payload.data(using: .utf8),
                              let packet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let method = packet["m"] as? String else { continue }
                        switch method {
                        case "symbol_error", "critical_error":
                            throw TVError.symbolNotFound(symbol)
                        case "series_error":
                            let detail = (packet["p"] as? [Any])?.compactMap { $0 as? String }.joined(separator: " ") ?? ""
                            throw TVError.seriesError(detail)
                        case "timescale_update":
                            bars.append(contentsOf: TVRealtimeClient.extractBars(from: packet))
                        case "series_completed":
                            // Seřadit a odstranit duplicity podle času.
                            var seen = Set<Double>()
                            return bars.sorted { $0.time < $1.time }.filter { seen.insert($0.time).inserted }
                        default:
                            continue
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw TVError.transport("TradingView neodpověděl včas.")
            }
            let bars = try await group.next() ?? []
            group.cancelAll()
            guard !bars.isEmpty else { throw TVError.seriesError("žádná data") }
            return bars
        }
    }

    private static func frame(_ method: String, _ params: [Any]) -> String {
        let body = (try? JSONSerialization.data(withJSONObject: ["m": method, "p": params],
                                                options: [.withoutEscapingSlashes])) ?? Data()
        let json = String(decoding: body, as: UTF8.self)
        return "~m~\(json.utf8.count)~m~\(json)"
    }
}
