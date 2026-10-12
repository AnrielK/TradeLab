import Foundation
import Backtest
import MarketData

extension Notification.Name {
    /// Agent změnil kresby v grafu (object = symbol BURZA:TICKER).
    static let chartDrawingsChanged = Notification.Name("chartDrawingsChanged")
}

/// Časový rámec pro hledání hladin.
enum LevelTimeframe: String, CaseIterable {
    case week = "1W"
    case day = "1D"
    case fourHours = "4H"

    /// Rozlišení TradingView.
    var resolution: String {
        switch self {
        case .week: return "1W"
        case .day: return "1D"
        case .fourHours: return "240"
        }
    }

    var barCount: Int {
        switch self {
        case .week: return 300
        case .day: return 500
        case .fourHours: return 450
        }
    }

    var pivotWindow: Int { self == .week ? 2 : 3 }

    /// Styl čáry: týdenní nejsilnější, 4H čárkovaně.
    var lineWidth: Double {
        switch self {
        case .week: return 2.5
        case .day: return 1.8
        case .fourHours: return 1.2
        }
    }

    var dash: Int { self == .fourHours ? 2 : 0 }
}

/// Zápis hladin a trendlinií od agenta do kreseb grafu TVChart (uložené podle symbolu).
enum ChartAnnotations {
    static let prefix = "AI · "
    static let supportColor = "#2ea98c"
    static let resistanceColor = "#e0566b"
    static let trendColor = "#4aa8ff"

    static func key(_ tvSymbol: String) -> String { "drawings::\(tvSymbol)" }

    static func load(_ tvSymbol: String) -> [Drawing] {
        guard let data = UserDefaults.standard.data(forKey: key(tvSymbol)),
              let drawings = try? JSONDecoder().decode([Drawing].self, from: data) else { return [] }
        return drawings
    }

    /// Přidá kresby; nejdřív odstraní agentovy kresby, které vyhovují `removing`.
    static func write(_ tvSymbol: String, adding new: [Drawing], removing: (Drawing) -> Bool) {
        var drawings = load(tvSymbol).filter { d in !(isAgent(d) && removing(d)) }
        drawings += new
        if let data = try? JSONEncoder().encode(drawings) {
            UserDefaults.standard.set(data, forKey: key(tvSymbol))
        }
        NotificationCenter.default.post(name: .chartDrawingsChanged, object: tvSymbol)
    }

    static func isAgent(_ d: Drawing) -> Bool { d.text?.hasPrefix("AI") == true }

    static func timeframe(of d: Drawing) -> String? {
        d.text?.components(separatedBy: " ").first { tf in LevelTimeframe(rawValue: tf) != nil }
    }

    static func level(price: Double, kind: PriceLevel.Kind, timeframe: LevelTimeframe, note: String?) -> Drawing {
        let tag = kind == .support ? "S" : "R"
        var text = "\(prefix)\(tag) \(timeframe.rawValue) \(String(format: "%.2f", price))"
        if let note, !note.isEmpty { text += " · \(note)" }
        return Drawing(tool: "hline", points: [DrawPoint(time: Date().timeIntervalSince1970, price: price)],
                       colorHex: kind == .support ? supportColor : resistanceColor,
                       width: timeframe.lineWidth, dash: timeframe.dash, text: text, locked: true)
    }

    static func trendLine(kind: PriceLevel.Kind, timeframe: LevelTimeframe, start: (Date, Double),
                          end: (Date, Double), note: String?) -> Drawing {
        var text = "\(prefix)TL \(timeframe.rawValue) \(kind == .support ? "support" : "rezistence")"
        if let note, !note.isEmpty { text += " · \(note)" }
        return Drawing(tool: "ray",
                       points: [DrawPoint(time: start.0.timeIntervalSince1970, price: start.1),
                                DrawPoint(time: end.0.timeIntervalSince1970, price: end.1)],
                       colorHex: kind == .support ? supportColor : (kind == .resistance ? resistanceColor : trendColor),
                       width: timeframe.lineWidth, dash: timeframe.dash, text: text, locked: true)
    }

    // MARK: - Data

    struct Series {
        var tvSymbol: String
        var source: String
        var bars: [BacktestBar]
    }

    /// Svíčky jako v grafu (TradingView, jen splity); 1D a 1W záložně z Yahoo.
    static func bars(symbol: String, timeframe: LevelTimeframe, client: YahooFinanceClient) async throws -> Series {
        do {
            let result = try await TVHistory.fetch(symbol: symbol, resolution: timeframe.resolution,
                                                   count: timeframe.barCount, preferDividends: false)
            let bars = result.bars.map {
                BacktestBar(date: Date(timeIntervalSince1970: $0.time), open: $0.open, high: $0.high,
                            low: $0.low, close: $0.close)
            }
            return Series(tvSymbol: result.symbol, source: "TradingView", bars: bars)
        } catch {
            guard timeframe != .fourHours else { throw error }
            let chart = timeframe == .week
                ? try await client.chart(symbol: symbol, range: .fiveYears)
                : try await client.dailyHistory(symbol: symbol, range: .twoYears)
            let bars = chart.bars.filter { $0.close > 0 }.map {
                BacktestBar(date: $0.date, open: $0.open, high: $0.high, low: $0.low, close: $0.close)
            }
            let tv = await SymbolResolver.shared.resolve(symbol) ?? symbol.uppercased()
            return Series(tvSymbol: tv, source: "Yahoo", bars: bars)
        }
    }
}
