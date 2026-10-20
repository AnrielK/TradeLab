import SwiftUI
import Backtest
import Charts
import MarketData
import OptionsMath

struct SymbolDetailView: View {
    let symbol: String
    @Environment(AppModel.self) private var model
    @State private var range: ChartRange = .sixMonths
    @State private var data: ChartData?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @AppStorage(SetupChartMode.defaultsKey) private var setupMode: SetupChartMode = .auto
    @State private var setupPicture: SetupPicture?
    @State private var setupStatus: String?

    var body: some View {
        List {
            Section {
                if let quote = data?.quote {
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = quote.name {
                            Text(name).font(.subheadline).foregroundStyle(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(quote.price.usd)
                                .font(.largeTitle.weight(.semibold))
                                .monospacedDigit()
                            if let change = quote.change, let pct = quote.changePercent {
                                Text("\(change.signedUSD) (\(pct.signedPercent))")
                                    .font(.subheadline.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.pnl(change))
                            }
                        }
                    }
                }

                // Graf z TVChart (bez indikátorů) se striky a break-even aktuální pozice a OI úrovněmi (načtenými v Opce → OI).
                EmbeddedTVChart(symbol: symbol, priceLines: positionLines + model.chainStore.openInterestLines(for: symbol))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            setupSection

            Section("Statistiky období") {
                Picker("Období", selection: $range) {
                    ForEach(ChartRange.chartable) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                if let bars = data?.bars, bars.count > 2 {
                    statistics(bars)
                } else if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(symbol)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { AgentToolbarButton() }
        }
        .task(id: range) { await load() }
        .task(id: setupMode) { await drawSetup() }
        .onAppear { model.selectOptionsSymbol(symbol) }
        .refreshable {
            await model.client.clearCache()
            await load()
        }
    }

    // MARK: - Strategie v grafu

    private var setupSection: some View {
        Section {
            Picker("Zakreslit", selection: $setupMode) {
                ForEach(SetupChartMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            if let p = setupPicture {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if p.direction != 0 {
                            Image(systemName: p.direction > 0 ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(p.direction > 0 ? .green : .red)
                        }
                        Text(p.title).font(.subheadline.weight(.semibold))
                    }
                    if let entry = p.entry, let stop = p.stop, let target = p.target {
                        let risk = abs(entry - stop)
                        let reward = abs(target - entry)
                        Text("Vstup \(entry.fixed(2)) · stop \(stop.fixed(2)) · cíl \(target.fixed(2))"
                             + (risk > 0 ? " · R:R \((reward / risk).fixed(1))" : ""))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let setupStatus {
                Text(setupStatus).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Strategie v grafu")
        } footer: {
            Text("Hladiny, trojúhelník, trendlinie nebo průměr podle strategie z denních svíček; u otevřeného vstupu i vstup, stop a cíl. Automaticky = strategie z watchlistu setupů, jinak trendlinie.")
        }
    }

    private func drawSetup() async {
        if setupMode == .off {
            setupPicture = nil
            setupStatus = nil
            await SetupChart.clear(symbol: symbol)
            return
        }
        setupStatus = "Počítám…"
        let strategy = SetupChart.strategy(for: setupMode, symbol: symbol, scanner: model.scanner)
        do {
            setupPicture = try await SetupChart.draw(symbol: symbol, strategy: strategy,
                                                     allowShort: model.scanner.settings.allowBearish,
                                                     client: model.client)
            setupStatus = setupPicture == nil ? "Strategie teď na grafu nic nevidí." : nil
        } catch {
            setupPicture = nil
            setupStatus = "Nepodařilo se načíst svíčky: \(error.localizedDescription)"
        }
    }

    /// Striky a break-even opční pozice na tomto tickeru jako čáry do grafu.
    private var positionLines: [ChartPriceLine] {
        let strategy = model.strategy
        guard strategy.underlying.uppercased() == symbol.uppercased(), !strategy.optionLegs.isEmpty else { return [] }
        var lines = strategy.optionLegs.map { leg in
            let sign = leg.side == .long ? "+" : "−"
            let type = leg.instrument == .call ? "C" : "P"
            return ChartPriceLine(price: leg.strike,
                                  label: sign + String(leg.quantity) + type + " " + leg.strike.strikeLabel,
                                  color: leg.side == .long ? ChainTheme.long : ChainTheme.short)
        }
        let spot = model.strategySpot > 0 ? model.strategySpot : (data?.quote.price ?? 0)
        if spot > 0 {
            for be in strategy.analyze(spot: spot, market: model.market).breakevens {
                lines.append(ChartPriceLine(price: be, label: "BE " + be.fixed(2), color: Color.purple, dashed: false))
            }
        }
        return lines
    }

    @ViewBuilder
    private func statistics(_ bars: [PriceBar]) -> some View {
        let closes = bars.map(\.close)
        if let first = closes.first, let last = closes.last, first > 0 {
            StatRow(title: "Výnos za období", value: ((last - first) / first).signedPercent,
                    color: Color.pnl(last - first))
        }
        if let high = bars.map(\.high).max(), let low = bars.map(\.low).min() {
            StatRow(title: "Maximum / minimum", value: "\(high.usd) / \(low.usd)")
        }
        if let peak = maxDrawdown(closes) {
            StatRow(title: "Max. propad", value: peak.percent, color: .red)
        }
        if range.interval == "1d" {
            if let hv20 = Volatility.realized(closes: closes, window: 20) {
                StatRow(title: "Hist. volatilita 20D", value: hv20.percent)
            }
            if let hv60 = Volatility.realized(closes: closes, window: 60), closes.count > 60 {
                StatRow(title: "Hist. volatilita 60D", value: hv60.percent)
            }
        }
    }

    private func maxDrawdown(_ closes: [Double]) -> Double? {
        guard closes.count > 1 else { return nil }
        var peak = closes[0]
        var worst = 0.0
        for c in closes {
            peak = max(peak, c)
            if peak > 0 { worst = min(worst, (c - peak) / peak) }
        }
        return worst
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            data = try await model.client.chart(symbol: symbol, range: range)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PriceChart: View {
    let bars: [PriceBar]

    var body: some View {
        if bars.isEmpty {
            Color.clear
        } else {
            let rising = (bars.last?.close ?? 0) >= (bars.first?.close ?? 0)
            Chart(bars, id: \.date) { bar in
                LineMark(
                    x: .value("Datum", bar.date),
                    y: .value("Cena", bar.close)
                )
                .foregroundStyle(rising ? Color.green : Color.red)
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }
}
