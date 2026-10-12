import SwiftUI
import MarketData
import OptionsMath

/// „Curve“ – interaktivní payoff s ovládáním striků, šířky, počtu a expirace.
struct PayoffWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var daysForward: Double = 0
    @State private var ivShiftPoints: Double = 0
    @State private var isBusy = false

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
            .font(.headline)

        statsRow(analysis: analysis, extrinsic: strategy.extrinsicValue(spot: spot))

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
            onDragMarkerEnded: { _ in model.finishLegDrag() }
        )
        .frame(height: 330)

        legend

        if let quote = strategy.netQuote {
            NetQuoteBar(quote: quote)
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }

        controls
        sliders(maxDays: strategy.nearestExpiryDays)

        VStack(alignment: .leading, spacing: 6) {
            Text("Nohy").font(.subheadline.weight(.semibold))
            ForEach(strategy.legs) { leg in
                LegRow(leg: leg)
            }
        }
        if !model.canAdjustFromChain {
            Text("Posun striků, šířky a expirace funguje pro nohy přidané z opčního řetězce.")
                .font(.caption)
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

    private func stat(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.blue, "Expirace")
            legendItem(.orange, currentLabel + (ivShiftPoints == 0 ? "" : ", IV \(ivShiftPoints > 0 ? "+" : "")\(Int(ivShiftPoints)) b."))
            legendItem(.purple, "Break-even")
        }
        .font(.caption)
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
                    .font(.caption)
                Slider(value: $daysForward, in: 0...(maxDays - 1), step: 1)
            }
            Text("Posun IV: \(ivShiftPoints > 0 ? "+" : "")\(Int(ivShiftPoints)) p. b.")
                .font(.caption)
            Slider(value: $ivShiftPoints, in: -30...30, step: 1)
            HStack {
                Spacer()
                Button("Obnovit ceny") { run { await model.repriceStrategy() } }
                    .font(.caption)
                    .disabled(!model.canAdjustFromChain || isBusy)
            }
        }
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
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(action: left.action) {
                    Image(systemName: left.icon).frame(width: 36, height: 30)
                }
                Spacer(minLength: 0)
                Text(value ?? "")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: right.action) {
                    Image(systemName: right.icon).frame(width: 36, height: 30)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
