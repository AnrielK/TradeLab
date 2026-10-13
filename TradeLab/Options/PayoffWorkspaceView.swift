import SwiftUI
import MarketData
import OptionsMath

/// „Curve“ – interaktivní payoff s ovládáním striků, šířky, počtu a expirace.
struct PayoffWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var daysForward: Double = 0
    @State private var ivShiftPoints: Double = 0
    @State private var isBusy = false
    /// Cena pro panel hodnot (vybraná v grafu); nil = aktuální cena.
    @State private var probePrice: Double?

    var body: some View {
        if model.strategy.optionLegs.isEmpty {
            ContentUnavailableView(
                "Žádná pozice",
                systemImage: "chart.xyaxis.line",
                description: Text("V tabulce klepni na bid (prodej) nebo ask (nákup) u kontraktu.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding()
                .padding(.bottom, 90)
            }
            .onChange(of: model.strategy.nearestExpiryDays) { _, newValue in
                daysForward = min(daysForward, max(newValue - 1, 0))
            }
        }
    }

    private var currentLabel: String {
        daysForward == 0 ? "Dnes" : "+\(Int(daysForward)) d"
    }

    @ViewBuilder
    private var content: some View {
        let strategy = model.strategy
        let spot = model.strategySpot > 0 ? model.strategySpot : model.chainStore.underlyingPrice
        let market = model.market
        let ivShift = ivShiftPoints / 100
        let analysis = strategy.analyze(spot: spot, market: market)
        let currentCurve = analysis.expiryCurve.map { point in
            PayoffPoint(spot: point.spot,
                        pnl: strategy.profitLoss(atSpot: point.spot, daysElapsed: daysForward, ivShift: ivShift, market: market))
        }
        let markers = strategy.optionLegs.map(marker(for:))

        Text(ticketTitle(strategy, quote: strategy.netQuote))
            .font(.subheadline.weight(.semibold))

        statsRow(analysis: analysis, extrinsic: strategy.extrinsicValue(spot: spot))
        breakevenRow(analysis.breakevens, spot: spot)

        InteractivePayoffChart(
            expiry: analysis.expiryCurve,
            current: currentCurve,
            spot: spot,
            breakevens: analysis.breakevens,
            sigmaBand: sigmaBand(spot: spot),
            markers: markers,
            currentLabel: currentLabel,
            valueAt: { price in
                (strategy.expiryProfitLoss(atSpot: price, market: market),
                 strategy.profitLoss(atSpot: price, daysElapsed: daysForward, ivShift: ivShift, market: market))
            },
            onDragMarker: { id, price in model.dragLeg(id: id, toPrice: price) },
            onDragMarkerEnded: { _ in model.finishLegDrag() },
            onSelectPrice: { probePrice = $0 }
        )
        .frame(height: 330)

        legend

        if let quote = strategy.netQuote {
            NetQuoteBar(quote: quote)
                .padding(10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }

        controls
        sliders(maxDays: strategy.nearestExpiryDays)
        valuesPanel(strategy: strategy, spot: spot, market: market, ivShift: ivShift)

        VStack(alignment: .leading, spacing: 6) {
            Text("Nohy").font(.subheadline.weight(.semibold))
            ForEach(strategy.legs) { leg in
                let color = leg.side == .long ? ChainTheme.long : ChainTheme.short
                HStack {
                    LegRow(leg: leg)
                    Button {
                        model.deleteLeg(id: leg.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(color, lineWidth: 1.5)
                }
            }
        }
        if !model.canAdjustFromChain {
            Text("Posun striků, šířky a expirace funguje pro nohy přidané z opčního řetězce.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func marker(for leg: StrategyLeg) -> StrikeMarker {
        let sign = leg.side == .long ? "+" : "−"
        let type = leg.instrument == .call ? "C" : "P"
        return StrikeMarker(id: leg.id, strike: leg.strike, label: sign + String(leg.quantity) + type,
                            isLong: leg.side == .long)
    }

    private func sigmaBand(spot: Double) -> ClosedRange<Double>? {
        guard let expiration = model.strategy.optionLegs.compactMap(\.expiration).min(),
              let move = model.chainStore.summaries[expiration]?.oneSigmaMove,
              move > 0, spot > move else { return nil }
        return (spot - move)...(spot + move)
    }

    private func statsRow(analysis: StrategyAnalysis, extrinsic: Double) -> some View {
        HStack(alignment: .top) {
            stat("POP", analysis.probabilityOfProfit.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")
            Spacer()
            stat("EXT", extrinsic.fixed(1))
            Spacer()
            stat("MAX ZISK", analysis.maxProfit.map { $0.fixed(2) } ?? "∞", color: .green)
            Spacer()
            stat("MAX ZTRÁTA", analysis.maxLoss.map { abs($0).fixed(2) } ?? "∞", color: .red)
        }
    }

    /// „Break-even 229,76 (+1,5 %)“ – u více bodů všechny.
    private func breakevenRow(_ breakevens: [Double], spot: Double) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.purple).frame(width: 8, height: 8)
            Text("Break-even").foregroundStyle(.secondary)
            if breakevens.isEmpty {
                Text("–")
            } else {
                Text(breakevens.map { breakevenText($0, spot: spot) }.joined(separator: "  ·  "))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .font(.footnote)
    }

    private func breakevenText(_ value: Double, spot: Double) -> String {
        let change = spot > 0 ? " (" + ((value - spot) / spot).signedPercent + ")" : ""
        return value.fixed(2) + change
    }

    private func stat(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.blue, "Expirace")
            legendItem(.orange, currentLabel + (ivShiftPoints == 0 ? "" : ", IV \(ivShiftPoints > 0 ? "+" : "")\(Int(ivShiftPoints)) b."))
            legendItem(.purple, "Break-even")
        }
        .font(.caption2)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    // MARK: - Ovládání

    private var controls: some View {
        let enabled = model.canAdjustFromChain && !isBusy
        let expiry = model.strategy.optionLegs.compactMap(\.expiration).min()
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                ControlBox(title: "Striky", value: nil,
                           left: ("chevron.left", { run { await model.shiftStrikes(by: -1) } }),
                           right: ("chevron.right", { run { await model.shiftStrikes(by: 1) } }))
                    .disabled(!enabled)
                ControlBox(title: "Šířka", value: widthLabel,
                           left: ("arrow.right.and.line.vertical.and.arrow.left", { run { await model.changeWidth(by: -1) } }),
                           right: ("arrow.left.and.line.vertical.and.arrow.right", { run { await model.changeWidth(by: 1) } }))
                    .disabled(!enabled || Set(model.strategy.optionLegs.map(\.strike)).count < 2)
            }
            GridRow {
                ControlBox(title: "Počet", value: "\(model.strategy.spreadCount)",
                           left: ("minus", { model.changeQuantity(by: -1) }),
                           right: ("plus", { model.changeQuantity(by: 1) }))
                    .disabled(isBusy)
                ControlBox(title: "Expirace", value: expiry?.shortExpiryLabel,
                           left: ("chevron.left", { run { await model.shiftExpiration(by: -1) } }),
                           right: ("chevron.right", { run { await model.shiftExpiration(by: 1) } }))
                    .disabled(!enabled)
            }
        }
        .overlay {
            if isBusy { ProgressView() }
        }
    }

    private var widthLabel: String? {
        let strikes = Set(model.strategy.optionLegs.map(\.strike)).sorted()
        guard let low = strikes.first, let high = strikes.last, high > low else { return nil }
        return (high - low).strikeLabel
    }

    private func sliders(maxDays: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if maxDays >= 2 {
                Text("Posun v čase: \(Int(daysForward)) z \(Int(maxDays)) dní")
                    .font(.caption2)
                Slider(value: $daysForward, in: 0...(maxDays - 1), step: 1)
            }
            Text("Posun IV: \(ivShiftPoints > 0 ? "+" : "")\(Int(ivShiftPoints)) p. b.")
                .font(.caption2)
            Slider(value: $ivShiftPoints, in: -30...30, step: 1)
            HStack {
                Spacer()
                Button("Obnovit ceny", systemImage: "arrow.clockwise") { run { await model.repriceStrategy() } }
                    .buttonStyle(.glass)
                    .font(.caption2)
                    .disabled(!model.canAdjustFromChain || isBusy)
            }
        }
    }

    // MARK: - Hodnoty v bodě (dřívější kalkulačka)

    @ViewBuilder
    private func valuesPanel(strategy: OptionStrategy, spot: Double, market: MarketContext, ivShift: Double) -> some View {
        let price = probePrice ?? spot
        let greeks = strategy.greeks(atSpot: price, daysElapsed: daysForward, ivShift: ivShift, market: market)
        let pnl = strategy.profitLoss(atSpot: price, daysElapsed: daysForward, ivShift: ivShift, market: market)
        let expiryPnl = strategy.expiryProfitLoss(atSpot: price, market: market)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hodnoty v bodě").font(.subheadline.weight(.semibold))
                Spacer()
                Text(scenarioLabel).font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button { probePrice = price * 0.99 } label: { Text("−1 %") }
                    .buttonStyle(.glass)
                VStack(spacing: 1) {
                    Text(price.fixed(2)).font(.headline).monospacedDigit()
                    Text(probePrice == nil ? "aktuální cena" : "\((price / spot - 1).signedPercent) od aktuální")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Button { probePrice = price * 1.01 } label: { Text("+1 %") }
                    .buttonStyle(.glass)
                if probePrice != nil {
                    Button { probePrice = nil } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                }
            }
            .font(.caption.weight(.semibold))

            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Noha").gridColumnAlignment(.leading)
                    Text("Vstup")
                    Text("Hodnota")
                    Text("P/L")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(strategy.legs) { leg in
                    let value = strategy.legValue(leg, spot: price, daysElapsed: daysForward, ivShift: ivShift, market: market)
                    let legPnl = leg.side.sign * Double(leg.quantity) * strategy.multiplier * (value - leg.entryPrice)
                    GridRow {
                        Text(legLabel(leg))
                            .foregroundStyle(leg.side == .long ? ChainTheme.long : ChainTheme.short)
                            .gridColumnAlignment(.leading)
                        Text(leg.entryPrice.fixed(2)).foregroundStyle(.secondary)
                        Text(value.fixed(2))
                        Text(legPnl.signedUSDWhole).foregroundStyle(Color.pnl(legPnl))
                    }
                }
                Divider()
                GridRow {
                    Text(currentLabel).gridColumnAlignment(.leading)
                    Text("")
                    Text("")
                    Text(pnl.signedUSDWhole).fontWeight(.semibold).foregroundStyle(Color.pnl(pnl))
                }
                GridRow {
                    Text("Při expiraci").gridColumnAlignment(.leading).foregroundStyle(.secondary)
                    Text("")
                    Text("")
                    Text(expiryPnl.signedUSDWhole).foregroundStyle(Color.pnl(expiryPnl))
                }
            }
            .font(.caption)
            .monospacedDigit()

            HStack(spacing: 0) {
                greek("Δ", greeks.delta.fixed(1), "akcií")
                greek("Γ", greeks.gamma.fixed(2), "/ 1 $")
                greek("Θ", greeks.theta.signedUSDWhole, "/ den")
                greek("Vega", greeks.vega.signedUSDWhole, "/ 1 p. b.")
            }
        }
        .padding(12)
        .background(ChainTheme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var scenarioLabel: String {
        var parts = [currentLabel]
        if ivShiftPoints != 0 { parts.append("IV \(ivShiftPoints > 0 ? "+" : "")\(Int(ivShiftPoints)) p. b.") }
        return parts.joined(separator: " · ")
    }

    private func legLabel(_ leg: StrategyLeg) -> String {
        let sign = leg.side == .long ? "+" : "−"
        switch leg.instrument {
        case .stock: return "\(sign)\(leg.quantity * 100) akcií"
        case .call: return "\(sign)\(leg.quantity) C \(leg.strike.strikeLabel)"
        case .put: return "\(sign)\(leg.quantity) P \(leg.strike.strikeLabel)"
        }
    }

    private func greek(_ symbol: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 1) {
            Text(symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            Text(unit).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func run(_ action: @escaping () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}

struct ControlBox: View {
    let title: String
    let value: String?
    let left: (icon: String, action: () -> Void)
    let right: (icon: String, action: () -> Void)

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button(action: left.action) {
                    Image(systemName: left.icon).frame(width: 30, height: 24)
                }
                Spacer(minLength: 0)
                Text(value ?? "")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: right.action) {
                    Image(systemName: right.icon).frame(width: 30, height: 24)
                }
            }
            .buttonStyle(.glass)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
