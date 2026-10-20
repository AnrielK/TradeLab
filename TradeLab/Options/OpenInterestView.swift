import SwiftUI
import Charts
import MarketData
import OptionsMath

/// Profil open interest sečtený přes všechny expirace do zvoleného horizontu:
/// call wall, put wall, gamma flip, max pain a graf po strikech.
struct OpenInterestView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("oi.horizon") private var horizon = 100
    @AppStorage("oi.weighting") private var weightingRaw = OpenInterestWeighting.gamma.rawValue
    @AppStorage("oi.range") private var rangePercent = 15
    @AppStorage(ChainStore.showOnChartKey) private var showOnChart = true

    private static let horizons = [30, 60, 100]
    private static let ranges = [10, 15, 25]

    private var weighting: OpenInterestWeighting {
        OpenInterestWeighting(rawValue: weightingRaw) ?? .gamma
    }

    var body: some View {
        let store = model.chainStore
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls

                if let progress = store.oiProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        Text("Expirace \(progress.done)/\(progress.total)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                if let profile = store.oiProfile, profile.symbol == store.symbol {
                    levelCards(profile)
                    chart(profile)
                    topList(profile)
                    howTo
                    footnote(profile)
                } else if store.oiProgress == nil {
                    ContentUnavailableView("Žádná data", systemImage: "chart.bar.xaxis",
                                           description: Text(store.errorMessage ?? "Pro tento ticker nejsou opce s open interest."))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .refreshable {
            await store.loadOpenInterest(maxDays: Double(horizon), rate: model.riskFreeRate, force: true)
        }
        .task(id: "\(store.symbol)|\(store.expirations.count)|\(horizon)") {
            guard !store.expirations.isEmpty else { return }
            await store.loadOpenInterest(maxDays: Double(horizon), rate: model.riskFreeRate)
        }
    }

    // MARK: - Ovládání

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Vážení", selection: $weightingRaw) {
                ForEach(OpenInterestWeighting.allCases) { w in
                    Text(w == .time ? "OI / √DTE" : w.label).tag(w.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Úrovně v grafu (call/put wall, gamma flip, max pain)", isOn: $showOnChart)
                .font(.caption)
                .tint(ChainTheme.sigma)

            HStack {
                Picker("Horizont", selection: $horizon) {
                    ForEach(Self.horizons, id: \.self) { Text("\($0) d").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Rozsah", selection: $rangePercent) {
                    ForEach(Self.ranges, id: \.self) { Text("±\($0) %").tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - Úrovně

    private func levelCards(_ profile: OpenInterestProfile) -> some View {
        let spot = profile.spot
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            LevelCard(title: "Call wall", color: ChainTheme.up,
                      price: profile.callWall(weighting)?.price, spot: spot,
                      detail: profile.callWall(weighting).map { format($0.value) })
            LevelCard(title: "Put wall", color: ChainTheme.down,
                      price: profile.putWall(weighting)?.price, spot: spot,
                      detail: profile.putWall(weighting).map { format($0.value) })
            LevelCard(title: "Gamma flip", color: ChainTheme.itm,
                      price: model.chainStore.oiGammaFlip, spot: spot,
                      detail: profile.totalGamma >= 0 ? "Celk. GEX kladné" : "Celk. GEX záporné")
            LevelCard(title: "Max pain", color: ChainTheme.sigma,
                      price: model.chainStore.oiMaxPain?.strike, spot: spot,
                      detail: model.chainStore.oiMaxPain.map { "exp. " + $0.expiration.shortExpiryLabel })
        }
    }

    private func chart(_ profile: OpenInterestProfile) -> some View {
        var rows = profile.strikes(within: Double(rangePercent) / 100)
        if rows.count < 6 { rows = profile.strikes(within: 0.4) }
        let callWall = profile.callWall(weighting)?.price
        let putWall = profile.putWall(weighting)?.price
        let flip = model.chainStore.oiGammaFlip
        let barHeight: CGFloat = rows.count > 60 ? 3 : rows.count > 30 ? 5 : 8

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(weighting == .gamma ? "GEX po strikech (USD / 1 %)" : "Open interest po strikech")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                legendDot(ChainTheme.up, "Cally")
                legendDot(ChainTheme.down, "Puty")
            }

            Chart {
                ForEach(rows) { row in
                    BarMark(xStart: .value("Od", 0), xEnd: .value("Call", plotted(row, .call)),
                            y: .value("Strike", row.strike), height: .fixed(barHeight))
                        .foregroundStyle(ChainTheme.up)
                    BarMark(xStart: .value("Od", 0), xEnd: .value("Put", plotted(row, .put)),
                            y: .value("Strike", row.strike), height: .fixed(barHeight))
                        .foregroundStyle(ChainTheme.down)
                }
                RuleMark(y: .value("Cena", profile.spot))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text(profile.spot.usd).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                if let flip, weighting == .gamma {
                    RuleMark(y: .value("Flip", flip))
                        .foregroundStyle(ChainTheme.itm)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                if let callWall {
                    RuleMark(y: .value("Call wall", callWall))
                        .foregroundStyle(ChainTheme.up.opacity(0.5))
                }
                if let putWall {
                    RuleMark(y: .value("Put wall", putWall))
                        .foregroundStyle(ChainTheme.down.opacity(0.5))
                }
            }
            .chartYScale(domain: yDomain(rows, spot: profile.spot))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(format(abs(v))) }
                    }
                }
            }
            .frame(height: max(320, CGFloat(rows.count) * (barHeight + 4)))
        }
        .padding(12)
        .background(ChainTheme.row, in: .rect(cornerRadius: 12))
    }

    /// Cally doprava, puty doleva (u GEX přirozeně záporné).
    private func plotted(_ row: StrikeOpenInterest, _ type: OptionType) -> Double {
        let v = row.value(type, weighting)
        return type == .put ? -abs(v) : v
    }

    private func yDomain(_ rows: [StrikeOpenInterest], spot: Double) -> ClosedRange<Double> {
        let low = min(rows.first?.strike ?? spot, spot)
        let high = max(rows.last?.strike ?? spot, spot)
        let pad = max((high - low) * 0.02, 0.5)
        return (low - pad)...(high + pad)
    }

    private func topList(_ profile: OpenInterestProfile) -> some View {
        let levels = profile.topLevels(8, weighting: weighting)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Největší úrovně").font(.subheadline.weight(.semibold))
            ForEach(levels, id: \.price) { level in
                let row = profile.strikes.first { $0.strike == level.price }
                HStack {
                    Text(level.price.strikeLabel)
                        .font(.body.weight(.semibold).monospacedDigit())
                        .frame(width: 70, alignment: .leading)
                    Text(distance(level.price, spot: profile.spot))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Spacer()
                    if let row {
                        Text("C " + format(row.value(.call, weighting)))
                            .foregroundStyle(ChainTheme.up)
                        Text("P " + format(abs(row.value(.put, weighting))))
                            .foregroundStyle(ChainTheme.down)
                    }
                }
                .font(.caption.monospacedDigit())
                Divider()
            }
        }
        .padding(12)
        .background(ChainTheme.row, in: .rect(cornerRadius: 12))
    }

    private func footnote(_ profile: OpenInterestProfile) -> some View {
        let pcr = profile.putCallRatio.map { $0.fixed(2) } ?? "–"
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(profile.expirations.count) expirací do \(Int(profile.maxDays)) dní · OI call \(compact(profile.totalCallOpenInterest)) · put \(compact(profile.totalPutOpenInterest)) · P/C \(pcr)")
            Text("Open interest se aktualizuje jednou denně a neříká, kdo je long. GEX předpokládá dealery long cally a short puty; nad gamma flipem trh spíš tlumí pohyby, pod ním je zesiluje.")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var howTo: some View {
        DisclosureGroup("Jak to použít") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• **Cena nad gamma flipem** (kladné GEX): dealeři zajišťují proti pohybu – trh má sklon k range mezi put a call wall. Hodí se prodej prémie (iron condor, kreditní spready) s krátkými striky za walls.")
                Text("• **Cena pod gamma flipem** (záporné GEX): zajištění pohyby zesiluje, volatilita roste. Spíš debetní strategie, menší pozice, širší stopy; průraz put wall může zrychlit.")
                Text("• **Call / put wall** = pravděpodobný odpor / support a cíl. Cíle breakoutu dávej těsně pod call wall, stop za put wall. Čistý průraz wall s objemem bývá silný signál (dealeři pak kupují s trhem).")
                Text("• **Max pain** táhne cenu hlavně v posledních dnech před měsíční expirací – pro krátké pozice do expirace, jinak slabý signál.")
                Text("• Úrovně jsou z denních dat; ber je jako kontext k hladinám skeneru, ne jako samostatný vstup.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .font(.subheadline.weight(.semibold))
        .padding(12)
        .background(ChainTheme.row, in: .rect(cornerRadius: 12))
    }

    // MARK: - Pomocné

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func format(_ value: Double) -> String {
        let text = abs(value).formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
        let sign = value < 0 ? "−" : ""
        return weighting == .gamma ? sign + "$" + text : sign + text
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func distance(_ price: Double, spot: Double) -> String {
        guard spot > 0 else { return "" }
        return (price / spot - 1).signedPercent
    }
}

private struct LevelCard: View {
    var title: String
    var color: Color
    var price: Double?
    var spot: Double
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(price.map { $0.strikeLabel } ?? "–")
                .font(.title3.weight(.bold).monospacedDigit())
            HStack(spacing: 6) {
                if let price, spot > 0 {
                    Text((price / spot - 1).signedPercent)
                        .foregroundStyle(Color.pnl(price - spot))
                }
                if let detail {
                    Text(detail).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.caption2.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(ChainTheme.row, in: .rect(cornerRadius: 10))
    }
}

extension ChainStore {
    static let showOnChartKey = "oi.showOnChart"

    /// OI úrovně jako čáry do grafu – jen když je profil načtený pro tento ticker a zobrazení je zapnuté.
    /// Čáry se nepočítají do měřítka grafu, takže vzdálené úrovně graf nezmačkají.
    func openInterestLines(for symbol: String) -> [ChartPriceLine] {
        let defaults = UserDefaults.standard
        let show = defaults.object(forKey: Self.showOnChartKey) as? Bool ?? true
        guard show, let profile = oiProfile, profile.symbol.uppercased() == symbol.uppercased() else { return [] }
        let weighting = defaults.string(forKey: "oi.weighting").flatMap(OpenInterestWeighting.init(rawValue:)) ?? .gamma
        var lines: [ChartPriceLine] = []
        if let wall = profile.callWall(weighting) {
            lines.append(ChartPriceLine(price: wall.price, label: "Call wall " + wall.price.strikeLabel,
                                        color: ChainTheme.up, fitsInScale: false))
        }
        if let wall = profile.putWall(weighting) {
            lines.append(ChartPriceLine(price: wall.price, label: "Put wall " + wall.price.strikeLabel,
                                        color: ChainTheme.down, fitsInScale: false))
        }
        if let flip = oiGammaFlip {
            lines.append(ChartPriceLine(price: flip, label: "γ flip " + flip.fixed(2),
                                        color: ChainTheme.itm, fitsInScale: false))
        }
        if let pain = oiMaxPain {
            lines.append(ChartPriceLine(price: pain.strike,
                                        label: "Max pain " + pain.strike.strikeLabel + " (" + pain.expiration.shortExpiryLabel + ")",
                                        color: ChainTheme.sigma, fitsInScale: false))
        }
        return lines
    }
}
