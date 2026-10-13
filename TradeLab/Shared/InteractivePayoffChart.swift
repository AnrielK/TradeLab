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
/// 1σ pásmo a striky nohou.
/// - Tažení mimo strike: ukáže P/L pro konkrétní cenu.
/// - Tažení za štítek striku (nahoře) nohu posune na jiný strike.
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
    /// Tažení striku: id nohy a cena pod prstem (aplikace ji přichytí na dostupný strike).
    var onDragMarker: ((UUID, Double) -> Void)? = nil
    var onDragMarkerEnded: ((UUID) -> Void)? = nil
    /// Vybraná cena při posunu prstem po grafu (pro panel hodnot).
    var onSelectPrice: ((Double) -> Void)? = nil

    @State private var selectedPrice: Double?
    @State private var draggingMarker: UUID?
    @State private var gestureActive = false

    /// Rozsah osy X zafixovaný během tažení, aby graf „neujížděl“ pod prstem.
    @State private var frozenDomain: ClosedRange<Double>?
    @State private var frozenYDomain: ClosedRange<Double>?

    /// Rozsah osy Y s rezervou; během tažení zafixovaný, aby se graf nechvěl.
    private var yDomain: ClosedRange<Double> {
        if let frozenYDomain { return frozenYDomain }
        let values = expiry.map(\.pnl) + current.map(\.pnl) + [0]
        let low = values.min() ?? -1
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.12, 1)
        return (low - pad)...(high + pad)
    }

    private var domain: ClosedRange<Double> {
        if let frozenDomain { return frozenDomain }
        let lower = expiry.first?.spot ?? 0
        let upper = max(expiry.last?.spot ?? 1, lower + 1)
        return lower...upper
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            readout
                .frame(height: 34, alignment: .topLeading)
            chart
            hint
        }
    }

    // MARK: - Texty mimo graf (nepřekrývají se s grafem)

    @ViewBuilder
    private var readout: some View {
        if let id = draggingMarker, let marker = markers.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Strike \(marker.label): \(marker.strike.strikeLabel)")
                    .font(.caption2.weight(.semibold))
                Text("Pusť pro přecenění z řetězce")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let price = selectedPrice, let values = valueAt?(price) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(price.usd).fontWeight(.semibold)
                    Text("(\(((price - spot) / spot).signedPercent))").foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("Expirace \(values.expiry.signedUSDWhole)")
                        .foregroundStyle(Color.pnl(values.expiry))
                    Text("\(currentLabel) \(values.current.signedUSDWhole)")
                        .foregroundStyle(Color.pnl(values.current))
                }
            }
            .font(.caption2)
            .monospacedDigit()
        } else {
            Text("Tažením po grafu zobrazíš P/L pro cenu.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var hint: some View {
        if onDragMarker != nil, !markers.isEmpty {
            Text("Štítky striků nahoře můžeš tažením posunout.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Graf

    private var visibleExpiry: [PayoffPoint] { visible(expiry) }

    private var visibleCurrent: [PayoffPoint] { visible(current) }

    /// Body v rozsahu os (hodnoty mimo osu Y se ořežou, aby nekreslily mimo graf).
    private func visible(_ points: [PayoffPoint]) -> [PayoffPoint] {
        let d = domain
        let y = yDomain
        return points
            .filter { d.contains($0.spot) }
            .map { PayoffPoint(spot: $0.spot, pnl: min(max($0.pnl, y.lowerBound), y.upperBound)) }
    }

    private var chart: some View {
        let expiry = visibleExpiry
        let current = visibleCurrent
        let d = domain
        let breakevens = self.breakevens.filter { d.contains($0) }
        let rows = markerRows
        let tagRows = (rows.values.max() ?? 0) + 1
        return Chart {
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

            if let band = sigmaBand {
                RuleMark(x: .value("−1σ", band.lowerBound))
                    .foregroundStyle(Color.indigo.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                RuleMark(x: .value("+1σ", band.upperBound))
                    .foregroundStyle(Color.indigo.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

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

            RuleMark(x: .value("Spot", spot))
                .foregroundStyle(Color.gray)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))

            ForEach(markers) { marker in
                let row = rows[marker.id] ?? 0
                RuleMark(x: .value("Strike", marker.strike))
                    .foregroundStyle((marker.isLong ? Color.green : Color.red).opacity(draggingMarker == marker.id ? 0.9 : 0.45))
                    .lineStyle(StrokeStyle(lineWidth: draggingMarker == marker.id ? 2 : 1))
                    .annotation(position: .top, spacing: 2 + CGFloat(row) * Self.tagRowHeight) {
                        MarkerTag(marker: marker, isDragging: draggingMarker == marker.id)
                    }
            }

            ForEach(breakevens, id: \.self) { be in
                PointMark(x: .value("Break-even", be), y: .value("P/L", 0.0))
                    .foregroundStyle(Color.purple)
                    .symbolSize(36)
                    .annotation(position: .bottom, spacing: 4) {
                        Text(be.fixed(2))
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    }
            }

            if draggingMarker == nil, let price = selectedPrice, let values = valueAt?(price) {
                RuleMark(x: .value("Výběr", price))
                    .foregroundStyle(Color.primary.opacity(0.35))
                PointMark(x: .value("Výběr", price), y: .value("P/L", values.expiry))
                    .foregroundStyle(Color.blue)
                PointMark(x: .value("Výběr", price), y: .value("P/L", values.current))
                    .foregroundStyle(Color.orange)
            }
        }
        .chartForegroundStyleScale([
            "Zisk": Color.green.opacity(0.10),
            "Ztráta": Color.red.opacity(0.10),
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartYScale(domain: yDomain)
        .padding(.top, 6 + CGFloat(tagRows) * Self.tagRowHeight) // místo pro štítky striků
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    // Vysoká priorita: při tažení po grafu se neposouvá stránka (jinak graf „poskakuje“).
                    .highPriorityGesture(dragGesture(proxy: proxy, geometry: geometry))
            }
        }
    }

    static let tagRowHeight: CGFloat = 30

    /// Štítky striků blízko sebe se rozloží do více řad, aby se nepřekrývaly.
    private var markerRows: [UUID: Int] {
        let span = max(domain.upperBound - domain.lowerBound, 1)
        let threshold = span * 0.13
        var rows: [UUID: Int] = [:]
        var lastInRow: [Int: Double] = [:]
        for marker in markers.sorted(by: { $0.strike < $1.strike }) {
            var row = 0
            while let last = lastInRow[row], marker.strike - last < threshold { row += 1 }
            rows[marker.id] = row
            lastInRow[row] = marker.strike
        }
        return rows
    }

    private func dragGesture(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let plotAnchor = proxy.plotFrame else { return }
                let plot = geometry[plotAnchor]

                if !gestureActive {
                    gestureActive = true
                    frozenDomain = domain
                    frozenYDomain = yDomain
                    draggingMarker = hitMarker(at: value.startLocation, proxy: proxy, plot: plot)
                }

                let x = min(max(value.location.x - plot.minX, 0), plot.width)
                guard let price = proxy.value(atX: x, as: Double.self) else { return }

                if let id = draggingMarker {
                    onDragMarker?(id, price)
                } else {
                    let clamped = min(max(price, domain.lowerBound), domain.upperBound)
                    selectedPrice = clamped
                    onSelectPrice?(clamped)
                }
            }
            .onEnded { _ in
                if let id = draggingMarker {
                    onDragMarkerEnded?(id)
                }
                draggingMarker = nil
                gestureActive = false
                frozenDomain = nil
                frozenYDomain = nil
            }
    }

    /// Štítek striku pod prstem (v horní části grafu, nebo kdekoli blízko čáry striku).
    private func hitMarker(at location: CGPoint, proxy: ChartProxy, plot: CGRect) -> UUID? {
        guard onDragMarker != nil else { return nil }
        let aboveChart = location.y < plot.minY
        let tolerance: CGFloat = aboveChart ? 28 : 14
        let rows = markerRows
        // Nad grafem: řada štítku podle výšky prstu.
        let touchedRow = aboveChart ? max(Int((plot.minY - 2 - location.y) / Self.tagRowHeight), 0) : nil
        var best: (id: UUID, distance: CGFloat)?
        for marker in markers {
            if let touchedRow, (rows[marker.id] ?? 0) != touchedRow, rows.values.contains(touchedRow) { continue }
            guard let position = proxy.position(forX: marker.strike) else { continue }
            let distance = abs(plot.minX + position - location.x)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (marker.id, distance)
            }
        }
        return best?.id
    }
}

private struct MarkerTag: View {
    let marker: StrikeMarker
    let isDragging: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(marker.label)
                .font(.caption2.weight(.bold))
            Text(marker.strike.strikeLabel)
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .glassEffect(.regular.tint((marker.isLong ? Color.green : Color.red).opacity(0.8)).interactive(),
                     in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .scaleEffect(isDragging ? 1.15 : 1)
        .shadow(radius: isDragging ? 3 : 0)
    }
}
