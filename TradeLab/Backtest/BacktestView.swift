import SwiftUI
import Charts
import Observation
import MarketData
import Backtest

enum StrategyKind: String, CaseIterable, Identifiable {
    case sma = "SMA cross"
    case macd = "MACD cross"
    case rsi = "RSI reversion"
    case breakRetest = "Break & retest"
    case reversal = "Reversal"
    case maBounce = "Odraz od průměru"
    case hold = "Buy & hold"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .sma: return "Long, když je rychlý SMA nad pomalým."
        case .macd: return "Long, když je MACD nad signální linkou."
        case .rsi: return "Nákup při přeprodanosti, prodej při překoupenosti."
        case .breakRetest: return "Průraz rezistence (max. high za N svíček), návrat k prolomené hladině a zavření nad ní. Stop pod hladinou, trailing výstup pod low posledních N/2 svíček."
        case .reversal: return "Po přeprodanosti (RSI) býčí obratová svíčka – zelená a zavření nad high předchozí. Stop pod swing low, výstup při překoupenosti nebo medvědí obratové svíčce."
        case .maBounce: return "V trendu (cena nad pomalým SMA, průměr roste) se cena dotkne průměru a zavře nad ním zelenou svíčkou. Výstup při zavření pod průměrem."
        case .hold: return "Koupit a držet."
        }
    }
}

struct CurvePoint: Identifiable {
    let date: Date
    let value: Double
    let series: String
    var id: String { series + "\(date.timeIntervalSince1970)" }
}

@MainActor
@Observable
final class BacktestModel {
    var symbol = ""
    var range: HistoryRange = .fiveYears
    var kind: StrategyKind = .sma
    var smaFast = 50
    var smaSlow = 200
    var macdFast = 12
    var macdSlow = 26
    var macdSignal = 9
    var rsiPeriod = 14
    var rsiLower = 30.0
    var rsiUpper = 70.0
    var breakLookback = 20
    var retestBars = 5
    var breakTolerancePct = 1.0
    var reversalPeriod = 14
    var reversalLower = 30.0
    var reversalUpper = 70.0
    var bouncePeriod = 20
    var bounceTrend = 200
    var bounceTolerancePct = 1.0
    var bounceEMA = true
    var allowShort = false
    var costBps = 5.0
    var compareSPY = true

    var result: BacktestResult? = nil
    var benchmark: [CurvePoint] = []
    var dataLabel: String = ""
    var isRunning = false
    var errorMessage: String? = nil

    var strategy: BacktestStrategy {
        switch kind {
        case .sma: return .smaCross(fast: smaFast, slow: smaSlow)
        case .macd: return .macdCross(fast: macdFast, slow: macdSlow, signal: macdSignal)
        case .rsi: return .rsiReversion(period: rsiPeriod, lower: rsiLower, upper: rsiUpper)
        case .breakRetest:
            return .breakRetest(lookback: breakLookback, retestBars: retestBars, tolerance: breakTolerancePct / 100)
        case .reversal: return .reversal(period: reversalPeriod, lower: reversalLower, upper: reversalUpper)
        case .maBounce:
            return .maBounce(period: bouncePeriod, trendPeriod: bounceTrend, tolerance: bounceTolerancePct / 100,
                             exponential: bounceEMA)
        case .hold: return .buyAndHold
        }
    }

    func run(client: YahooFinanceClient, riskFreeRate: Double) async {
        let ticker = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ticker.isEmpty else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            let source = BacktestSource.current
            let interval = BacktestInterval.current
            let series = try await BacktestData.load(symbol: ticker, range: range, source: source,
                                                     interval: interval, client: client)
            let bars = series.bars
            guard bars.count > 30 else {
                errorMessage = "Málo dat pro backtest (\(bars.count) svíček)."
                return
            }
            let config = BacktestConfig(strategy: strategy, allowShort: allowShort, costBps: costBps,
                                        riskFreeRate: riskFreeRate)
            result = BacktestEngine.run(bars: bars, config: config)
            dataLabel = series.label

            benchmark = []
            if compareSPY, ticker != "SPY",
               let spy = try? await BacktestData.load(symbol: "SPY", range: range, source: source,
                                                      interval: interval, client: client) {
                let start = bars[0].date
                benchmark = BacktestEngine.normalized(spy.bars, from: start)
                    .map { CurvePoint(date: $0.date, value: $0.value, series: "SPY") }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ceny upravené o dividendy (poměr adjClose / close), ať výnos odpovídá skutečnosti.
    static func backtestBars(_ bars: [PriceBar]) -> [BacktestBar] {
        BacktestData.yahooBars(bars)
    }
}

struct BacktestView: View {
    @Environment(AppModel.self) private var model
    @State private var bt = BacktestModel()
    @AppStorage(BacktestSource.defaultsKey) private var source: BacktestSource = .yahoo
    @AppStorage(BacktestInterval.defaultsKey) private var interval: BacktestInterval = .day

    var body: some View {
        @Bindable var bt = bt
        NavigationStack {
            List {
                settingsSection
                dataSection
                if let error = bt.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let result = bt.result {
                    metricsSection(result)
                    equitySection(result)
                    drawdownSection(result)
                    tradesSection(result)
                }
            }
            .navigationTitle("Backtest")
            .onAppear {
                if bt.symbol.isEmpty { bt.symbol = model.optionsSymbol }
            }
        }
    }

    // MARK: - Nastavení

    private var settingsSection: some View {
        @Bindable var bt = bt
        return Section {
            LabeledContent("Ticker") {
                TextField("SPY", text: $bt.symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            Picker("Období", selection: $bt.range) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Strategie", selection: $bt.kind) {
                ForEach(StrategyKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            Text(bt.kind.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch bt.kind {
            case .sma:
                Stepper("Rychlý SMA: \(bt.smaFast)", value: $bt.smaFast, in: 2...200, step: 5)
                Stepper("Pomalý SMA: \(bt.smaSlow)", value: $bt.smaSlow, in: 10...400, step: 10)
            case .macd:
                Stepper("Rychlá EMA: \(bt.macdFast)", value: $bt.macdFast, in: 2...50)
                Stepper("Pomalá EMA: \(bt.macdSlow)", value: $bt.macdSlow, in: 5...100)
                Stepper("Signál: \(bt.macdSignal)", value: $bt.macdSignal, in: 2...30)
            case .rsi:
                Stepper("Perioda RSI: \(bt.rsiPeriod)", value: $bt.rsiPeriod, in: 2...50)
                Stepper("Nákup pod: \(Int(bt.rsiLower))", value: $bt.rsiLower, in: 5...50, step: 5)
                Stepper("Prodej nad: \(Int(bt.rsiUpper))", value: $bt.rsiUpper, in: 50...95, step: 5)
            case .breakRetest:
                Stepper("Hladina z \(bt.breakLookback) svíček", value: $bt.breakLookback, in: 5...200, step: 5)
                Stepper("Retest do \(bt.retestBars) svíček", value: $bt.retestBars, in: 1...30)
                Stepper("Tolerance: \(bt.breakTolerancePct.fixed(2)) %", value: $bt.breakTolerancePct, in: 0...5, step: 0.25)
            case .reversal:
                Stepper("Perioda RSI: \(bt.reversalPeriod)", value: $bt.reversalPeriod, in: 2...50)
                Stepper("Přeprodanost pod: \(Int(bt.reversalLower))", value: $bt.reversalLower, in: 5...50, step: 5)
                Stepper("Překoupenost nad: \(Int(bt.reversalUpper))", value: $bt.reversalUpper, in: 50...95, step: 5)
            case .maBounce:
                Picker("Průměr", selection: $bt.bounceEMA) {
                    Text("EMA").tag(true)
                    Text("SMA").tag(false)
                }
                .pickerStyle(.segmented)
                Stepper("Perioda průměru: \(bt.bouncePeriod)", value: $bt.bouncePeriod, in: 5...200, step: 5)
                Stepper("Trend SMA: \(bt.bounceTrend)", value: $bt.bounceTrend, in: 20...400, step: 10)
                Stepper("Tolerance: \(bt.bounceTolerancePct.fixed(2)) %", value: $bt.bounceTolerancePct, in: 0...5, step: 0.25)
            case .hold:
                EmptyView()
            }

            if bt.kind != .hold {
                Toggle("Povolit short", isOn: $bt.allowShort)
            }
            Stepper("Náklady: \(bt.costBps.fixed(0)) bp / obchod", value: $bt.costBps, in: 0...50, step: 1)
            Toggle("Srovnat se SPY", isOn: $bt.compareSPY)

            Button {
                Task { await bt.run(client: model.client, riskFreeRate: model.riskFreeRate) }
            } label: {
                HStack {
                    if bt.isRunning { ProgressView().controlSize(.small) }
                    Text(bt.isRunning ? "Počítám…" : "Spustit backtest")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(bt.isRunning || bt.symbol.isEmpty)
            .listRowBackground(Color.clear)
        } header: {
            Text("Nastavení")
        } footer: {
            Text("Signál se počítá ze zavírací ceny svíčky a obchod proběhne za otevírací cenu další svíčky.")
        }
    }

    private var dataSection: some View {
        Section {
            Picker("Zdroj dat", selection: $source) {
                ForEach(BacktestSource.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if source == .tradingView {
                Picker("Interval", selection: $interval) {
                    ForEach(BacktestInterval.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if !bt.dataLabel.isEmpty, bt.result != nil {
                Text("Poslední běh: \(bt.dataLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Data")
        } footer: {
            Text(source == .yahoo
                 ? "Yahoo Finance: denní svíčky upravené o dividendy."
                 : "TradingView (nepřihlášený přístup): svíčky 1D, 1W, 4H nebo 1H, upravené o dividendy, když to server dovolí, jinak jen o splity. U hodinových dat je historie kratší (limit počtu svíček). Platí i pro backtesty agenta.")
        }
    }

    // MARK: - Výsledky

    private func metricsSection(_ result: BacktestResult) -> some View {
        let m = result.metrics
        let h = result.buyAndHoldMetrics
        return Section {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text(result.config.strategy.name).font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                    Text("Buy & hold").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                metricRow("Celkový výnos", m.totalReturn.signedPercent, h.totalReturn.signedPercent, m.totalReturn - h.totalReturn)
                metricRow("CAGR", m.cagr.signedPercent, h.cagr.signedPercent, m.cagr - h.cagr)
                metricRow("Max. drawdown", m.maxDrawdown.percent, h.maxDrawdown.percent, m.maxDrawdown - h.maxDrawdown)
                metricRow("Sharpe", m.sharpe.fixed(2), h.sharpe.fixed(2), m.sharpe - h.sharpe)
                metricRow("Sortino", m.sortino.fixed(2), h.sortino.fixed(2), m.sortino - h.sortino)
                metricRow("Volatilita", m.volatility.percent, h.volatility.percent, h.volatility - m.volatility)
                metricRow("Calmar", m.calmar.fixed(2), h.calmar.fixed(2), m.calmar - h.calmar)
                metricRow("Expozice", m.exposure.percent, h.exposure.percent, nil)
                metricRow("Obchody", "\(m.tradeCount)", "\(h.tradeCount)", nil)
                metricRow("Win rate", m.winRate.map { $0.percent } ?? "–", "–", nil)
                metricRow("Ø obchod", m.averageTrade.map { $0.signedPercent } ?? "–", "–", nil)
            }
            .font(.footnote)
            .monospacedDigit()
        } header: {
            Text("Metriky")
        }
    }

    private func metricRow(_ title: String, _ strategy: String, _ hold: String, _ edge: Double?) -> GridRow<some View> {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(strategy)
                .fontWeight(.semibold)
                .foregroundStyle(edge.map { $0 > 0 ? Color.green : ($0 < 0 ? Color.red : Color.primary) } ?? Color.primary)
            Text(hold).foregroundStyle(.secondary)
        }
    }

    private func equitySection(_ result: BacktestResult) -> some View {
        let start = result.equity.first?.equity ?? 1
        let holdStart = result.buyAndHold.first?.equity ?? 1
        let strategyCurve = result.equity.map { CurvePoint(date: $0.date, value: $0.equity / start * 100, series: "Strategie") }
        let holdCurve = result.buyAndHold.map { CurvePoint(date: $0.date, value: $0.equity / holdStart * 100, series: "Buy & hold") }
        let all = strategyCurve + holdCurve + bt.benchmark
        return Section {
            Chart(all) { point in
                LineMark(
                    x: .value("Datum", point.date),
                    y: .value("Hodnota", point.value),
                    series: .value("Řada", point.series)
                )
                .foregroundStyle(by: .value("Řada", point.series))
                .lineStyle(StrokeStyle(lineWidth: point.series == "Strategie" ? 2 : 1.2))
            }
            .chartForegroundStyleScale([
                "Strategie": Color.orange,
                "Buy & hold": Color.blue,
                "SPY": Color.gray,
            ])
            .chartYScale(type: .log)
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 240)
        } header: {
            Text("Kapitál (start = 100, log. osa)")
        }
    }

    private func drawdownSection(_ result: BacktestResult) -> some View {
        Section {
            Chart(result.equity, id: \.date) { point in
                AreaMark(
                    x: .value("Datum", point.date),
                    yStart: .value("Nula", 0.0),
                    yEnd: .value("Drawdown", point.drawdown * 100)
                )
                .foregroundStyle(Color.red.opacity(0.35))
            }
            .chartYAxisLabel("%")
            .frame(height: 140)
        } header: {
            Text("Drawdown strategie")
        }
    }

    private func tradesSection(_ result: BacktestResult) -> some View {
        Section {
            if result.trades.isEmpty {
                Text("Žádné obchody").foregroundStyle(.secondary)
            }
            ForEach(result.trades.suffix(40).reversed()) { trade in
                HStack {
                    Text(trade.side > 0 ? "LONG" : "SHORT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(trade.side > 0 ? ChainTheme.long : ChainTheme.short, in: Capsule())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(trade.entryDate.formatted(date: .numeric, time: .omitted)) → \(trade.exitDate?.formatted(date: .numeric, time: .omitted) ?? "otevřený")")
                            .font(.caption)
                        Text("\(trade.entryPrice.fixed(2)) → \(trade.exitPrice.fixed(2))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(trade.returnPct.signedPercent)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.pnl(trade.returnPct))
                }
                .monospacedDigit()
            }
        } header: {
            Text("Obchody (posledních \(min(result.trades.count, 40)) z \(result.trades.count))")
        }
    }
}
