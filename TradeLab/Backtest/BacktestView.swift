import SwiftUI
import Charts
import Observation
import MarketData
import Backtest

enum StrategyKind: String, CaseIterable, Identifiable {
    case sma = "SMA"
    case macd = "MACD"
    case rsi = "RSI"
    case hold = "B&H"

    var id: String { rawValue }
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
    var allowShort = false
    var costBps = 5.0
    var compareSPY = true

    var result: BacktestResult? = nil
    var benchmark: [CurvePoint] = []
    var isRunning = false
    var errorMessage: String? = nil

    var strategy: BacktestStrategy {
        switch kind {
        case .sma: return .smaCross(fast: smaFast, slow: smaSlow)
        case .macd: return .macdCross(fast: macdFast, slow: macdSlow, signal: macdSignal)
        case .rsi: return .rsiReversion(period: rsiPeriod, lower: rsiLower, upper: rsiUpper)
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
            let data = try await client.dailyHistory(symbol: ticker, range: range)
            let bars = Self.backtestBars(data.bars)
            guard bars.count > 30 else {
                errorMessage = "Málo dat pro backtest (\(bars.count) dní)."
                return
            }
            let config = BacktestConfig(strategy: strategy, allowShort: allowShort, costBps: costBps,
                                        riskFreeRate: riskFreeRate)
            result = BacktestEngine.run(bars: bars, config: config)

            benchmark = []
            if compareSPY, ticker != "SPY",
               let spy = try? await client.dailyHistory(symbol: "SPY", range: range) {
                let start = bars[0].date
                benchmark = BacktestEngine.normalized(Self.backtestBars(spy.bars), from: start)
                    .map { CurvePoint(date: $0.date, value: $0.value, series: "SPY") }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ceny upravené o dividendy (poměr adjClose / close), ať výnos odpovídá skutečnosti.
    static func backtestBars(_ bars: [PriceBar]) -> [BacktestBar] {
        bars.compactMap { bar in
            guard bar.close > 0, bar.open > 0 else { return nil }
            let factor = (bar.adjustedClose ?? bar.close) / bar.close
            return BacktestBar(date: bar.date, open: bar.open * factor, high: bar.high * factor,
                               low: bar.low * factor, close: bar.close * factor)
        }
    }
}

struct BacktestView: View {
    @Environment(AppModel.self) private var model
    @State private var bt = BacktestModel()

    var body: some View {
        @Bindable var bt = bt
        NavigationStack {
            List {
                settingsSection
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
            .pickerStyle(.segmented)

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
            Text("Signál se počítá ze zavírací ceny a obchod proběhne za otevírací cenu dalšího dne. Ceny jsou upravené o dividendy.")
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
