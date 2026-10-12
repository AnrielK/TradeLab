import SwiftUI
import Charts
import OptionsMath

struct StrikeMarker: Identifiable, Hashable {
    let id: UUID
    let strike: Double
    let label: String
    let isLong: Bool
}

/// Payoff graf: zelená/červená zóna při expiraci, křivka „dnes / za N dní“,
/// 1σ pásmo, striky nohou a výběr ceny tažením prstu.
struct InteractivePayoffChart: View {
    let expiry: [PayoffPoint]
    let current: [PayoffPoint]
    let spot: Double
    let breakevens: [Double]
    var sigmaBand: ClosedRange<Double>? = nil
    var markers: [StrikeMarker] = []
    var currentLabel: String = "Dnes"
    /// P/L (expirace, aktuální křivka) pro vybranou cenu.
    var valueAt: ((Double) -> (expiry: Double, current: Double))? = nil

    @State private var selectedPrice: Double?

    private var domain: ClosedRange<Double> {
        let lower = expiry.first?.spot ?? 0
        let upper = max(expiry.last?.spot ?? 1, lower + 1)
        return lower...upper
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            readout
            chart
        }
    }

    @ViewBuilder
    private var readout: some View {
        if let price = selectedPrice, let values = valueAt?(price) {
            HStack(spacing: 12) {
                Text(price.usd).font(.caption.weight(.semibold))
                Text("Exp. \(values.expiry.signedUSDWhole)")
                    .foregroundStyle(Color.pnl(values.expiry))
                Text("\(currentLabel) \(values.current.signedUSDWhole)")
                    .foregroundStyle(Color.pnl(values.current))
                Text("(\(((price - spot) / spot).signedPercent))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .monospacedDigit()
        } else {
            Text("Tažením po grafu zobrazíš P/L pro konkrétní cenu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(expiry, id: \.spot) { point in
                AreaMark(
                    x: .value("Cena", point.spot),
                    yStart: .value("Nula", 0.0),
                    yEnd: .value("P/L", max(point.pnl, 0))
                )
                .foregroundStyle(by: .value("Zóna", "Zisk"))
            }
            ForEach(expiry, id: \.spot) { point in
                AreaMark(
                    x: .value("Cena", point.spot),
                    yStart: .value("Nula", 0.0),
                    yEnd: .value("P/L", min(point.pnl, 0))
                )
                .foregroundStyle(by: .value("Zóna", "Ztráta"))
            }

            RuleMark(y: .value("Nula", 0.0))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1))

            ForEach(expiry, id: \.spot) { point in
                LineMark(
                    x: .value("Cena", point.spot),
                    y: .value("P/L", point.pnl),
                    series: .value("Křivka", "Expirace")
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            ForEach(current, id: \.spot) { point in
                LineMark(
                    x: .value("Cena", point.spot),
                    y: .value("P/L", point.pnl),
                    series: .value("Křivka", "Aktuální")
                )
                .foregroundStyle(Color.orange)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            if let band = sigmaBand {
                RuleMark(x: .value("−1σ", band.lowerBound))
                    .foregroundStyle(Color.indigo.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("1 SD").font(.caption2).foregroundStyle(.indigo)
                    }
                RuleMark(x: .value("+1σ", band.upperBound))
                    .foregroundStyle(Color.indigo.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("1 SD").font(.caption2).foregroundStyle(.indigo)
                    }
            }

            ForEach(markers) { marker in
                RuleMark(x: .value("Strike", marker.strike))
                    .foregroundStyle((marker.isLong ? Color.green : Color.red).opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .bottom, spacing: 2) {
                        Text(marker.label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(marker.isLong ? Color.green : Color.red, in: RoundedRectangle(cornerRadius: 4))
                    }
            }

            RuleMark(x: .value("Spot", spot))
                .foregroundStyle(Color.gray)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

            ForEach(breakevens, id: \.self) { be in
                PointMark(x: .value("Break-even", be), y: .value("P/L", 0.0))
                    .foregroundStyle(Color.purple)
                    .symbolSize(30)
            }

            if let price = selectedPrice, let values = valueAt?(price) {
                RuleMark(x: .value("Výběr", price))
                    .foregroundStyle(Color.primary.opacity(0.35))
                PointMark(x: .value("Výběr", price), y: .value("P/L", values.expiry))
                    .foregroundStyle(Color.blue)
                PointMark(x: .value("Výběr", price), y: .value("P/L", values.current))
                    .foregroundStyle(Color.orange)
            }
        }
        .chartForegroundStyleScale([
            "Zisk": Color.green.opacity(0.22),
            "Ztráta": Color.red.opacity(0.22),
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartXSelection(value: $selectedPrice)
    }
}
