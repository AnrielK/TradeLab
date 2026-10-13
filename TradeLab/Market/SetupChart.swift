import Foundation
import Backtest
import MarketData

/// Kterou strategii zakreslit do grafu tickeru.
enum SetupChartMode: String, CaseIterable, Identifiable {
    case auto
    case breakout
    case maBounce
    case trendline
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automaticky"
        case .breakout: return "Breakout / Breakdown"
        case .maBounce: return "Odraz od KP"
        case .trendline: return "Trendlinie a trojúhelník"
        case .off: return "Nezakreslovat"
        }
    }

    static let defaultsKey = "setupChartMode"
}

/// Zakreslí aktuální stav strategie (hladiny, trojúhelník, trendlinie, průměr, vstup, stop, cíl) do kreseb grafu.
/// Kresby mají popisek „AI · … · Setup“, takže je graf vykreslí tlumeně jako ostatní kresby agenta
/// a při další změně se nahradí.
enum SetupChart {
    static let tag = "Setup"

    static func isSetup(_ d: Drawing) -> Bool { d.text?.hasSuffix("· \(tag)") == true }

    /// Strategie pro režim: Automaticky = strategie z výsledku skeneru, jinak Trendlinie.
    @MainActor
    static func strategy(for mode: SetupChartMode, symbol: String, scanner: SetupScannerModel) -> BacktestStrategy? {
        let settings = scanner.settings
        switch mode {
        case .off: return nil
        case .breakout: return .breakout(settings.breakout)
        case .maBounce: return .maBounce(settings.maBounce)
        case .trendline: return .trendline(settings.trendline)
        case .auto:
            switch scanner.results.first(where: { $0.id == symbol.uppercased() })?.hit.strategy {
            case .breakout?: return .breakout(settings.breakout)
            case .maBounce?: return .maBounce(settings.maBounce)
            default: return .trendline(settings.trendline)
            }
        }
    }

    /// Spočítá kresbu z denních svíček (stejná data jako graf) a uloží ji. Vrací popis pro UI.
    static func draw(symbol: String, strategy: BacktestStrategy?, allowShort: Bool,
                     client: YahooFinanceClient) async throws -> SetupPicture? {
        let series = try await ChartAnnotations.bars(symbol: symbol, timeframe: .day, client: client)
        let picture = strategy.flatMap {
            SetupGeometry.picture(for: $0, bars: series.bars, allowShort: allowShort)
        }
        let drawings = picture?.shapes.map(drawing) ?? []
        ChartAnnotations.write(series.tvSymbol, adding: drawings) { isSetup($0) }
        return picture
    }

    static func clear(symbol: String) async {
        let tv = await SymbolResolver.shared.resolve(symbol) ?? symbol.uppercased()
        ChartAnnotations.write(tv, adding: []) { isSetup($0) }
    }

    static func drawing(_ shape: SetupShape) -> Drawing {
        let text = "\(ChartAnnotations.prefix)\(shape.label) · \(tag)"
        let color: String
        switch shape.role {
        case .support: color = AgentDrawingStyle.supportHex
        case .resistance: color = AgentDrawingStyle.resistanceHex
        case .supportLine: color = AgentDrawingStyle.supportLineHex
        case .resistanceLine: color = AgentDrawingStyle.resistanceLineHex
        case .movingAverage: color = "#E0B85C"
        case .entry: color = "#6FA8DC"
        case .stop: color = "#E06C75"
        case .target: color = "#7CC48F"
        }
        if shape.isHorizontal {
            return Drawing(tool: "hline", points: [DrawPoint(time: shape.startDate.timeIntervalSince1970,
                                                             price: shape.startPrice)],
                           colorHex: color, width: 1.4, dash: shape.role == .entry ? 2 : 0, text: text, locked: true)
        }
        return Drawing(tool: "trend",
                       points: [DrawPoint(time: shape.startDate.timeIntervalSince1970, price: shape.startPrice),
                                DrawPoint(time: shape.endDate.timeIntervalSince1970, price: shape.endPrice)],
                       colorHex: color, width: 1.6, dash: 0, text: text, locked: true)
    }
}
