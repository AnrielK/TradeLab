import Foundation
import Backtest
import MarketData

/// Zakreslení obchodů z backtestu do grafu TVChart: zóna zisku (vstup → cíl) a ztráty (vstup → stop),
/// spojnice vstup → výstup, popisky otevření a zavření a linie strategie (hladina, trendline, průměr).
/// Kresby se ukládají ke kreslím symbolu a při dalším běhu backtestu se nahradí.
enum BacktestTradeChart {
    struct Item {
        var side: Int
        var entryDate: Date
        var entryPrice: Double
        var exitDate: Date?
        var exitPrice: Double
        var result: String
        var won: Bool
        var label: String?
    }

    static let enabledKey = "backtest.drawTrades"

    private static func idsKey(_ tvSymbol: String) -> String { "backtestDrawings::\(tvSymbol)" }

    /// Zakreslí obchody; vrací počet zakreslených obchodů.
    @discardableResult
    static func draw(symbol: String, bars: [BacktestBar], strategy: BacktestStrategy, allowShort: Bool,
                     items: [Item], client: YahooFinanceClient) async throws -> Int {
        let chart = try await ChartAnnotations.bars(symbol: symbol, timeframe: .day, client: client)
        let scale = priceScale(backtest: bars, chart: chart.bars)
        let plans = SetupGeometry.tradePlans(for: strategy, bars: bars, allowShort: allowShort)
        var planByEntry: [Date: TradePlan] = [:]
        for plan in plans where plan.signalIndex + 1 < bars.count {
            planByEntry[bars[plan.signalIndex + 1].date] = plan
        }
        let lastDate = bars.last?.date ?? Date()

        var drawings: [Drawing] = []
        for item in items.suffix(80) {
            let exitDate = item.exitDate ?? lastDate
            let t0 = item.entryDate.timeIntervalSince1970
            let t1 = exitDate.timeIntervalSince1970
            let entry = scale(item.entryDate, item.entryPrice)
            let exit = scale(exitDate, item.exitPrice)
            let plan = planByEntry[item.entryDate]

            if let plan {
                let target = scale(item.entryDate, plan.target)
                let stop = scale(item.entryDate, plan.stop)
                drawings.append(Drawing(tool: "rect", points: [DrawPoint(time: t0, price: entry), DrawPoint(time: t1, price: target)],
                                        colorHex: "#2EA98C", width: 0.5, dash: 0, text: nil, locked: true))
                drawings.append(Drawing(tool: "rect", points: [DrawPoint(time: t0, price: entry), DrawPoint(time: t1, price: stop)],
                                        colorHex: "#E0566B", width: 0.5, dash: 0, text: nil, locked: true))
                for shape in plan.shapes {
                    // Hladiny a trendlinie se protáhnou až do výstupu obchodu (průměr ne).
                    let ts = shape.startDate.timeIntervalSince1970
                    let te = shape.endDate.timeIntervalSince1970
                    var endTime = te
                    var endPrice = shape.endPrice
                    if shape.role != .movingAverage, t1 > te, te > ts {
                        endPrice = shape.startPrice + (shape.endPrice - shape.startPrice) * (t1 - ts) / (te - ts)
                        endTime = t1
                    }
                    let endDate = Date(timeIntervalSince1970: endTime)
                    drawings.append(Drawing(
                        tool: "trend",
                        points: [DrawPoint(time: ts, price: scale(shape.startDate, shape.startPrice)),
                                 DrawPoint(time: endTime, price: scale(endDate, endPrice))],
                        colorHex: color(shape.role), width: 1.4, dash: 0, text: nil, locked: true))
                }
            }
            drawings.append(Drawing(tool: "trend", points: [DrawPoint(time: t0, price: entry), DrawPoint(time: t1, price: exit)],
                                    colorHex: item.won ? "#7CC48F" : "#E06C75", width: 1.4, dash: 2, text: nil, locked: true))
            let arrow = item.side > 0 ? "▲" : "▼"
            let name = item.label ?? plan?.title ?? (item.side > 0 ? "Long" : "Short")
            drawings.append(Drawing(tool: "text", points: [DrawPoint(time: t0, price: entry)],
                                    colorHex: "#6FA8DC", width: 1, dash: 0, text: "\(arrow) \(name)", locked: true))
            drawings.append(Drawing(tool: "text", points: [DrawPoint(time: t1, price: exit)],
                                    colorHex: item.won ? "#7CC48F" : "#E06C75", width: 1, dash: 0,
                                    text: item.exitDate == nil ? "● \(item.result) otevřený" : "✕ \(item.result)",
                                    locked: true))
        }
        replace(chart.tvSymbol, with: drawings)
        return min(items.count, 80)
    }

    static func clear(symbol: String) async {
        let tv = await SymbolResolver.shared.resolve(symbol) ?? symbol.uppercased()
        replace(tv, with: [])
    }

    /// Kresby backtestu mají vlastní úložiště – v detailu tickeru ani v běžném grafu nejsou vidět.
    static let namespace = "backtestChart"

    private static func replace(_ tvSymbol: String, with drawings: [Drawing]) {
        let defaults = UserDefaults.standard
        // Úklid po starších verzích, které kreslily do běžného grafu.
        let old = Set((defaults.stringArray(forKey: idsKey(tvSymbol)) ?? []).compactMap(UUID.init(uuidString:)))
        if !old.isEmpty {
            let kept = ChartAnnotations.load(tvSymbol).filter { !old.contains($0.id) }
            if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: ChartAnnotations.key(tvSymbol)) }
            defaults.removeObject(forKey: idsKey(tvSymbol))
        }
        if let data = try? JSONEncoder().encode(drawings) {
            defaults.set(data, forKey: "\(namespace)::\(tvSymbol)")
        }
        NotificationCenter.default.post(name: .chartDrawingsChanged, object: tvSymbol)
    }

    /// Backtest může mít ceny upravené o dividendy, graf jen o splity – ceny se přepočtou poměrem
    /// zavíracích cen ve stejný den.
    private static func priceScale(backtest: [BacktestBar], chart: [BacktestBar]) -> (Date, Double) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func day(_ d: Date) -> Int {
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
        }
        var chartClose: [Int: Double] = [:]
        for bar in chart { chartClose[day(bar.date)] = bar.close }
        var ratios: [(Int, Double)] = []
        for bar in backtest where bar.close > 0 {
            if let c = chartClose[day(bar.date)] { ratios.append((day(bar.date), c / bar.close)) }
        }
        ratios.sort { $0.0 < $1.0 }
        guard !ratios.isEmpty else { return { _, price in price } }
        return { date, price in
            let key = day(date)
            // Poslední známý poměr do daného dne (binární hledání).
            var lo = 0, hi = ratios.count - 1, best = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if ratios[mid].0 <= key { best = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return price * ratios[best].1
        }
    }

    private static func color(_ role: SetupShape.Role) -> String {
        switch role {
        case .support: return AgentDrawingStyle.supportHex
        case .resistance: return AgentDrawingStyle.resistanceHex
        case .supportLine: return AgentDrawingStyle.supportLineHex
        case .resistanceLine: return AgentDrawingStyle.resistanceLineHex
        case .movingAverage: return "#E0B85C"
        case .entry: return "#6FA8DC"
        case .stop: return "#E06C75"
        case .target: return "#7CC48F"
        }
    }
}
