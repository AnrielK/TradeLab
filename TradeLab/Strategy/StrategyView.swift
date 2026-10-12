import SwiftUI
import Charts
import OptionsMath

struct StrategyView: View {
    @Environment(AppModel.self) private var model
    @State private var daysForward: Double = 0
    @State private var ivShiftPoints: Double = 0
    @State private var editingLeg: StrategyLeg?
    @State private var isApplyingTemplate = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("Podkladové aktivum") {
                    LabeledContent("Ticker") {
                        TextField("AAPL", text: $model.strategy.underlying)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .onSubmit { Task { await model.refreshStrategySpot() } }
                    }
                    LabeledContent("Spot") {
                        HStack {
                            DecimalField(title: "Cena", value: $model.strategySpot)
                            Button {
                                Task { await model.refreshStrategySpot() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    StatRow(title: model.riskFreeRateIsLive ? "Sazba (13W T-bill)" : "Sazba (výchozí)",
                            value: model.riskFreeRate.percent)
                }

                if model.strategy.legs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Prázdná strategie",
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                            description: Text("Vyber šablonu vpravo nahoře, přidej nohu ručně nebo klepni na kontrakt v opčním řetězci.")
                        )
                    }
                } else if model.strategySpot > 0 {
                    analysisSections
                }

                Section {
                    ForEach(model.strategy.legs) { leg in
                        Button {
                            editingLeg = leg
                        } label: {
                            LegRow(leg: leg)
                        }
                        .tint(.primary)
                    }
                    .onDelete { model.deleteLegs(at: $0) }
                    Button {
                        editingLeg = model.makeDefaultLeg()
                    } label: {
                        Label("Přidat nohu", systemImage: "plus")
                    }
                } header: {
                    Text("Nohy")
                } footer: {
                    if let error = model.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(model.strategy.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Vymazat", role: .destructive) { model.clearStrategy() }
                        .disabled(model.strategy.legs.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(StrategyTemplate.allCases) { template in
                            Button {
                                apply(template)
                            } label: {
                                Text(template.displayName)
                                Text(template.summary)
                            }
                        }
                    } label: {
                        if isApplyingTemplate {
                            ProgressView()
                        } else {
                            Label("Šablony", systemImage: "square.grid.2x2")
                        }
                    }
                }
            }
            .sheet(item: $editingLeg) { leg in
                LegEditorView(leg: leg)
            }
            .onChange(of: model.strategy.nearestExpiryDays) { _, newValue in
                daysForward = min(daysForward, newValue)
            }
            .onChange(of: model.strategy) { _, _ in model.saveStrategy() }
            .onChange(of: model.strategySpot) { _, _ in model.saveStrategy() }
        }
    }

    // MARK: - Analýza

    private var currentLabel: String {
        daysForward == 0 ? "Dnes" : "Za \(Int(daysForward)) d"
    }

    private var ivShiftLabel: String {
        let sign = ivShiftPoints > 0 ? "+" : ""
        return "\(sign)\(Int(ivShiftPoints)) p. b."
    }

    @ViewBuilder
    private var analysisSections: some View {
        let strategy = model.strategy
        let spot = model.strategySpot
        let market = model.market
        let ivShift = ivShiftPoints / 100
        let analysis = strategy.analyze(spot: spot, market: market)
        let currentCurve = analysis.expiryCurve.map { point in
            PayoffPoint(spot: point.spot,
                        pnl: strategy.profitLoss(atSpot: point.spot, daysElapsed: daysForward, ivShift: ivShift, market: market))
        }
        let greeks = strategy.greeks(atSpot: spot, daysElapsed: daysForward, ivShift: ivShift, market: market)
        let pnlNow = strategy.profitLoss(atSpot: spot, daysElapsed: daysForward, ivShift: ivShift, market: market)

        payoffSection(analysis: analysis, current: currentCurve, spot: spot, maxDays: strategy.nearestExpiryDays)
        summarySection(strategy: strategy, analysis: analysis, pnlNow: pnlNow)
        greeksSection(greeks)
    }

    private func payoffSection(analysis: StrategyAnalysis, current: [PayoffPoint], spot: Double, maxDays: Double) -> some View {
        let legendText = ivShiftPoints == 0 ? currentLabel : "\(currentLabel), IV \(ivShiftLabel)"
        return Section("Payoff") {
            InteractivePayoffChart(
                expiry: analysis.expiryCurve,
                current: current,
                spot: spot,
                breakevens: analysis.breakevens,
                currentLabel: currentLabel,
                valueAt: valueAt(spot: spot)
            )
                .frame(height: 260)
            HStack(spacing: 16) {
                LegendDot(color: .blue, text: "Expirace")
                LegendDot(color: .orange, text: legendText)
            }
            .font(.caption)

            if maxDays >= 1 {
                VStack(alignment: .leading) {
                    Text("Posun v čase: \(Int(daysForward)) z \(Int(maxDays)) dní")
                        .font(.caption)
                    Slider(value: $daysForward, in: 0...maxDays, step: 1)
                }
            }
            VStack(alignment: .leading) {
                Text("Posun IV: \(ivShiftLabel)")
                    .font(.caption)
                Slider(value: $ivShiftPoints, in: -30...30, step: 1)
            }
        }
    }

    private func valueAt(spot: Double) -> (Double) -> (expiry: Double, current: Double) {
        let strategy = model.strategy
        let market = model.market
        let days = daysForward
        let ivShift = ivShiftPoints / 100
        return { price in
            (strategy.expiryProfitLoss(atSpot: price, market: market),
             strategy.profitLoss(atSpot: price, daysElapsed: days, ivShift: ivShift, market: market))
        }
    }

    private func summarySection(strategy: OptionStrategy, analysis: StrategyAnalysis, pnlNow: Double) -> some View {
        let net = strategy.netPremium
        let premiumTitle = net >= 0 ? "Zaplacený debet" : "Přijatý kredit"
        let maxProfit = analysis.maxProfit.map { $0.signedUSDWhole } ?? "Neomezený"
        let maxLoss = analysis.maxLoss.map { $0.signedUSDWhole } ?? "Neomezená"
        let breakevens = analysis.breakevens.isEmpty
            ? "–"
            : analysis.breakevens.map { $0.fixed(2) }.joined(separator: " · ")
        let pnlTitle = "P/L při spotu (\(currentLabel.lowercased()))"

        return Section("Souhrn") {
            StatRow(title: premiumTitle, value: abs(net).usd)
            if strategy.stockCost != 0 {
                StatRow(title: "Kapitál v akciích", value: strategy.stockCost.usdWhole)
            }
            StatRow(title: "Max. zisk", value: maxProfit, color: .green)
            StatRow(title: "Max. ztráta", value: maxLoss, color: .red)
            StatRow(title: "Break-even", value: breakevens)
            if let pop = analysis.probabilityOfProfit {
                StatRow(title: "Pravděpodobnost zisku", value: pop.percent)
            }
            StatRow(title: pnlTitle, value: pnlNow.signedUSDWhole, color: Color.pnl(pnlNow))
        }
    }

    private func greeksSection(_ g: Greeks) -> some View {
        Section {
            StatRow(title: "Delta (akcie)", value: g.delta.fixed(1))
            StatRow(title: "Gamma", value: g.gamma.fixed(2))
            StatRow(title: "Theta ($/den)", value: g.theta.signedUSD, color: Color.pnl(g.theta))
            StatRow(title: "Vega ($/1 b. IV)", value: g.vega.signedUSD)
            StatRow(title: "Rho ($/1 b. sazby)", value: g.rho.signedUSD)
        } header: {
            Text("Greeks pozice")
        } footer: {
            Text("Model Black-Scholes (evropské opce), log-normální rozdělení pro pravděpodobnost zisku. Slouží k výzkumu, ne jako investiční doporučení.")
        }
    }

    private func apply(_ template: StrategyTemplate) {
        isApplyingTemplate = true
        Task {
            await model.applyTemplate(template)
            daysForward = 0
            ivShiftPoints = 0
            isApplyingTemplate = false
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct LegRow: View {
    let leg: StrategyLeg

    var body: some View {
        HStack {
            Text(leg.side == .long ? "+\(leg.quantity)" : "−\(leg.quantity)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(leg.side == .long ? Color.green : Color.red)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if leg.instrument != .stock {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(leg.instrument == .stock ? leg.strike.usd : leg.premium.usd)
                .monospacedDigit()
        }
    }

    private var detail: String {
        let expiry = leg.expiration.map { $0.shortExpiryLabel + " · " } ?? ""
        return expiry + "\(Int(leg.daysToExpiry.rounded())) d · IV " + leg.impliedVolatility.percent
    }

    private var title: String {
        switch leg.instrument {
        case .call: return "Call \(leg.strike.fixed(leg.strike.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))"
        case .put: return "Put \(leg.strike.fixed(leg.strike.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))"
        case .stock: return "Akcie ×100"
        }
    }
}
