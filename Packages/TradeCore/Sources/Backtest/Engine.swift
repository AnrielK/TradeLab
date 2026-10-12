import Foundation

public struct BacktestBar: Hashable, Sendable {
    public var date: Date
    public var open: Double
    public var high: Double
    public var low: Double
    public var close: Double

    public init(date: Date, open: Double, high: Double, low: Double, close: Double) {
        self.date = date
        self.open = open
        self.high = high
        self.low = low
        self.close = close
    }
}

public struct BacktestConfig: Hashable, Sendable {
    public var strategy: BacktestStrategy
    public var allowShort: Bool
    /// Poplatky a skluz v bazických bodech z objemu obchodu (5 = 0,05 %).
    public var costBps: Double
    public var riskFreeRate: Double
    public var initialCapital: Double

    public init(strategy: BacktestStrategy, allowShort: Bool = false, costBps: Double = 5,
                riskFreeRate: Double = 0.04, initialCapital: Double = 10_000) {
        self.strategy = strategy
        self.allowShort = allowShort
        self.costBps = costBps
        self.riskFreeRate = riskFreeRate
        self.initialCapital = initialCapital
    }
}

public struct EquityPoint: Hashable, Sendable {
    public var date: Date
    public var equity: Double
    /// Pokles od posledního maxima (0 nebo záporné číslo).
    public var drawdown: Double
    public var position: Int
}

public struct BacktestTrade: Hashable, Sendable, Identifiable {
    public var id: Int
    public var side: Int
    public var entryDate: Date
    public var entryPrice: Double
    public var exitDate: Date?
    public var exitPrice: Double
    /// Výnos obchodu po nákladech (0.05 = +5 %).
    public var returnPct: Double
    public var isOpen: Bool { exitDate == nil }
}

public struct BacktestMetrics: Hashable, Sendable {
    public var totalReturn: Double
    public var cagr: Double
    public var volatility: Double
    public var sharpe: Double
    public var sortino: Double
    public var maxDrawdown: Double
    public var calmar: Double
    public var tradeCount: Int
    public var winRate: Double?
    public var averageTrade: Double?
    public var exposure: Double
}

public struct BacktestResult: Sendable {
    public var config: BacktestConfig
    public var equity: [EquityPoint]
    public var trades: [BacktestTrade]
    public var metrics: BacktestMetrics
    /// Buy & hold stejného titulu za stejné období (bez nákladů), pro srovnání.
    public var buyAndHold: [EquityPoint]
    public var buyAndHoldMetrics: BacktestMetrics
}

public enum BacktestEngine {
    /// Spustí backtest.
    ///
    /// Signál se vyhodnotí na zavírací ceně baru `i` a obchod proběhne
    /// za otevírací cenu baru `i + 1` – žádný pohled do budoucnosti.
    public static func run(bars: [BacktestBar], config: BacktestConfig) -> BacktestResult {
        let closes = bars.map(\.close)
        let targets = config.strategy.targets(closes: closes, allowShort: config.allowShort)
        let simulation = simulate(bars: bars, targets: targets, costBps: config.costBps,
                                  initialCapital: config.initialCapital)
        let metrics = Self.metrics(equity: simulation.equity, trades: simulation.trades,
                                   riskFreeRate: config.riskFreeRate)

        let hold = simulate(bars: bars, targets: bars.map { _ in 1 }, costBps: 0,
                            initialCapital: config.initialCapital)
        let holdMetrics = Self.metrics(equity: hold.equity, trades: hold.trades,
                                       riskFreeRate: config.riskFreeRate)

        return BacktestResult(config: config, equity: simulation.equity, trades: simulation.trades,
                              metrics: metrics, buyAndHold: hold.equity, buyAndHoldMetrics: holdMetrics)
    }

    static func simulate(bars: [BacktestBar], targets: [Int], costBps: Double, initialCapital: Double)
        -> (equity: [EquityPoint], trades: [BacktestTrade]) {
        guard let first = bars.first else { return ([], []) }
        let cost = costBps / 10_000
        var equity = initialCapital
        var peak = equity
        var position = 0
        var points = [EquityPoint(date: first.date, equity: equity, drawdown: 0, position: 0)]
        var trades: [BacktestTrade] = []
        var open: (side: Int, date: Date, price: Double)?

        for i in 1..<max(bars.count, 1) {
            let previous = bars[i - 1]
            let bar = bars[i]
            let target = targets[i - 1]

            // 1) přes noc drží starou pozici: zavření (i−1) → otevření i
            var growth = 1 + Double(position) * (bar.open / previous.close - 1)

            // 2) na otevření i se pozice změní na cíl z baru i−1
            if target != position {
                growth *= 1 - cost * Double(abs(target - position))
                if let current = open {
                    trades.append(closeTrade(current, at: bar.open, date: bar.date, id: trades.count, cost: cost))
                    open = nil
                }
                if target != 0 { open = (target, bar.date, bar.open) }
                position = target
            }

            // 3) přes den drží novou pozici: otevření i → zavření i
            growth *= 1 + Double(position) * (bar.close / bar.open - 1)

            equity *= growth
            peak = max(peak, equity)
            points.append(EquityPoint(date: bar.date, equity: equity, drawdown: equity / peak - 1, position: position))
        }

        // Otevřený obchod se ocení poslední zavírací cenou.
        if let current = open, let last = bars.last {
            var trade = closeTrade(current, at: last.close, date: last.date, id: trades.count, cost: cost)
            trade.exitDate = nil
            trade.returnPct += cost   // výstupní poplatek ještě nevznikl
            trades.append(trade)
        }
        return (points, trades)
    }

    private static func closeTrade(_ open: (side: Int, date: Date, price: Double), at price: Double,
                                   date: Date, id: Int, cost: Double) -> BacktestTrade {
        let gross = Double(open.side) * (price / open.price - 1)
        return BacktestTrade(id: id, side: open.side, entryDate: open.date, entryPrice: open.price,
                             exitDate: date, exitPrice: price, returnPct: gross - 2 * cost)
    }

    /// Metriky z křivky kapitálu. Počet období za rok se odhadne z rozestupu dat.
    public static func metrics(equity points: [EquityPoint], trades: [BacktestTrade], riskFreeRate: Double) -> BacktestMetrics {
        guard let first = points.first, let last = points.last, points.count > 1 else {
            return BacktestMetrics(totalReturn: 0, cagr: 0, volatility: 0, sharpe: 0, sortino: 0, maxDrawdown: 0,
                                   calmar: 0, tradeCount: 0, winRate: nil, averageTrade: nil, exposure: 0)
        }
        let returns = (1..<points.count).map { points[$0].equity / points[$0 - 1].equity - 1 }
        let periodsPerYear = Self.periodsPerYear(points.map(\.date))
        let totalReturn = last.equity / first.equity - 1
        let years = max(last.date.timeIntervalSince(first.date) / (365.25 * 86_400), 1e-9)
        let cagr = pow(max(1 + totalReturn, 0), 1 / years) - 1

        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1
            ? returns.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(returns.count - 1)
            : 0
        let std = variance.squareRoot()
        let rfPeriod = riskFreeRate / periodsPerYear
        let excess = mean - rfPeriod
        let sharpe = std > 0 ? excess / std * periodsPerYear.squareRoot() : 0
        let downside = (returns.reduce(0) { $0 + pow(min($1 - rfPeriod, 0), 2) } / Double(returns.count)).squareRoot()
        let sortino = downside > 0 ? excess / downside * periodsPerYear.squareRoot() : 0

        let maxDrawdown = points.map(\.drawdown).min() ?? 0
        let calmar = maxDrawdown < 0 ? cagr / abs(maxDrawdown) : 0
        let closed = trades.filter { !$0.isOpen }
        let winRate = closed.isEmpty ? nil : Double(closed.filter { $0.returnPct > 0 }.count) / Double(closed.count)
        let averageTrade = trades.isEmpty ? nil : trades.map(\.returnPct).reduce(0, +) / Double(trades.count)
        let exposure = Double(points.dropFirst().filter { $0.position != 0 }.count) / Double(points.count - 1)

        return BacktestMetrics(totalReturn: totalReturn, cagr: cagr, volatility: std * periodsPerYear.squareRoot(),
                               sharpe: sharpe, sortino: sortino, maxDrawdown: maxDrawdown, calmar: calmar,
                               tradeCount: trades.count, winRate: winRate, averageTrade: averageTrade,
                               exposure: exposure)
    }

    /// 252 pro denní data, 52 pro týdenní, 12 pro měsíční.
    static func periodsPerYear(_ dates: [Date]) -> Double {
        guard dates.count > 2 else { return 252 }
        let gaps = (1..<dates.count).map { dates[$0].timeIntervalSince(dates[$0 - 1]) / 86_400 }.sorted()
        let median = gaps[gaps.count / 2]
        if median >= 25 { return 12 }
        if median >= 5 { return 52 }
        return 252
    }

    /// Řada normalizovaná na 100 v prvním společném datu (pro srovnání se SPY).
    public static func normalized(_ bars: [BacktestBar], from start: Date) -> [(date: Date, value: Double)] {
        let slice = bars.filter { $0.date >= start }
        guard let base = slice.first?.close, base > 0 else { return [] }
        return slice.map { ($0.date, $0.close / base * 100) }
    }
}
