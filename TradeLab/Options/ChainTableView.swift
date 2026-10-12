import SwiftUI
import MarketData
import OptionsMath

// MARK: - Tabulka expirací a řetězce

struct ChainTableView: View {
    @Binding var mode: OptionsMode
    @Environment(AppModel.self) private var model
    @State private var expanded: Date?
    @State private var strikesAround = 8
    @AppStorage("chain.showDelta") private var showDelta = true
    @AppStorage("chain.showOI") private var showOpenInterest = true

    private var store: ChainStore { model.chainStore }

    var body: some View {
        VStack(spacing: 0) {
            ChainColumnHeader()
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.expirations, id: \.self) { date in
                        Section {
                            if expanded == date {
                                expandedContent(for: date)
                            }
                        } header: {
                            ExpirationHeader(
                                date: date,
                                summary: store.summaries[date],
                                isExpanded: expanded == date,
                                isLoading: store.loading.contains(date)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(date) }
                            .task(id: date) {
                                guard store.summaries[date] == nil else { return }
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled, store.summaries[date] == nil else { return }
                                await store.chain(for: date, rate: model.riskFreeRate)
                            }
                        }
                    }
                }
                .padding(.bottom, bottomPadding)
            }
            .refreshable { await store.refresh(rate: model.riskFreeRate) }
        }
        .background(ChainTheme.row)
        .overlay {
            if store.expirations.isEmpty {
                if store.isLoadingSymbol {
                    ProgressView("Načítám řetězec…")
                } else if let error = store.errorMessage {
                    ContentUnavailableView {
                        Label("Opce se nepodařilo načíst", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Zkusit znovu") {
                            Task { await store.refresh(rate: model.riskFreeRate) }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if ticketVisible {
                TicketBar { mode = .curve }
            }
        }
        .onChange(of: store.expirations) { _, dates in
            if expanded == nil || !dates.contains(expanded!) {
                expanded = defaultExpiration(in: dates)
            }
        }
        .onAppear {
            if expanded == nil { expanded = defaultExpiration(in: store.expirations) }
        }
    }

    private var ticketVisible: Bool {
        !model.strategy.optionLegs.isEmpty
            && model.strategy.underlying.uppercased() == store.symbol.uppercased()
    }

    private var bottomPadding: CGFloat {
        ticketVisible ? 16 : 90
    }

    /// Výchozí rozbalená expirace: expirace z tiketu, jinak první s alespoň týdnem do expirace.
    private func defaultExpiration(in dates: [Date]) -> Date? {
        if ticketVisible, let exp = model.strategy.optionLegs.first?.expiration, dates.contains(exp) {
            return exp
        }
        return dates.first { OptionChain.daysToExpiry($0) >= 7 } ?? dates.first
    }

    @ViewBuilder
    private func expandedContent(for date: Date) -> some View {
        if let chain = store.chains[date] {
            ChainGrid(chain: chain, summary: store.summaries[date], strikesAround: $strikesAround,
                      showDelta: showDelta, showOpenInterest: showOpenInterest)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
                .task { await store.chain(for: date, rate: model.riskFreeRate) }
        }
    }

    private func toggle(_ date: Date) {
        if expanded == date {
            expanded = nil
        } else {
            expanded = date
            Task { await store.chain(for: date, rate: model.riskFreeRate) }
        }
    }
}

extension Date {
    /// „20. 11.“, u jiného roku „15. 1. 2027“.
    var chainLabel: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.component(.year, from: self)
        let currentYear = calendar.component(.year, from: Date())
        return year == currentYear ? shortExpiryLabel : expiryLabel
    }
}

// MARK: - Hlavičky

/// Šedá lišta s názvy sloupců (zůstává nahoře při scrollování).
struct ChainColumnHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            label("BID (PRODEJ)")
            label("ASK (NÁKUP)")
            HStack(spacing: 3) {
                Text("Strike")
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 8))
            }
            .frame(width: 64)
            label("BID (PRODEJ)")
            label("ASK (NÁKUP)")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color(white: 0.85))
        .frame(height: 40)
        .background(ChainTheme.headerBar)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .underline()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }
}

/// Řádek expirace: datum + W | dny ve středovém sloupci | IV a ±1σ.
struct ExpirationHeader: View {
    let date: Date
    let summary: ExpirationSummary?
    let isExpanded: Bool
    let isLoading: Bool

    var body: some View {
        let monthly = ExpirationCalendar.isMonthly(date)
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(date.chainLabel)
                    .font(.system(size: 15, weight: isExpanded ? .semibold : .regular))
                    .monospacedDigit()
                if !monthly {
                    Text("W")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(ChainTheme.badge, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer(minLength: 4)
                if isExpanded {
                    Text("Cally").font(.system(size: 13)).foregroundStyle(Color(white: 0.85))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity)

            Text("\(Int(OptionChain.daysToExpiry(date).rounded(.down)))d")
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .frame(width: 64)
                .frame(maxHeight: .infinity)
                .background(ChainTheme.centerColumn)

            HStack(spacing: 6) {
                if isExpanded {
                    Text("Puty").font(.system(size: 13)).foregroundStyle(Color(white: 0.85))
                }
                Spacer(minLength: 4)
                ivText
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .frame(height: 50)
        .background(monthly ? ChainTheme.monthly : ChainTheme.weekly)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ChainTheme.separator).frame(height: 1)
        }
    }

    @ViewBuilder
    private var ivText: some View {
        if let summary, let iv = summary.atmVolatility {
            VStack(alignment: .trailing, spacing: 1) {
                Text("IV \(iv.percent)")
                if let move = summary.oneSigmaMove {
                    Text("±\(move.fixed(2))").foregroundStyle(Color(white: 0.75))
                }
            }
            .font(.system(size: 13))
            .monospacedDigit()
        } else if isLoading {
            ProgressView().controlSize(.small).tint(.white)
        } else {
            Text("–").foregroundStyle(Color(white: 0.6))
        }
    }
}

// MARK: - Řetězec jedné expirace

struct ChainGrid: View {
    let chain: OptionChain
    let summary: ExpirationSummary?
    @Binding var strikesAround: Int
    let showDelta: Bool
    let showOpenInterest: Bool

    var body: some View {
        let all = chain.strikes
        let atmIndex = StrikeLadder.nearestIndex(to: chain.underlyingPrice, in: all) ?? 0
        let lower = max(atmIndex - strikesAround, 0)
        let upper = min(atmIndex + strikesAround, max(all.count - 1, 0))
        let visible = all.isEmpty ? [] : Array(all[lower...upper])
        let spot = chain.underlyingPrice
        let sigma = summary?.oneSigmaMove

        VStack(spacing: 0) {
            if lower > 0 {
                moreButton(systemImage: "chevron.up")
            }
            ForEach(Array(visible.enumerated()), id: \.element) { index, strike in
                let previous = index > 0 ? visible[index - 1] : -Double.infinity
                if let sigma, crosses(spot - sigma, previous, strike) {
                    ChainLine(kind: .sigma).zIndex(1)
                }
                if crosses(spot, previous, strike) {
                    ChainLine(kind: .inTheMoney(spot)).zIndex(1)
                }
                if let sigma, crosses(spot + sigma, previous, strike) {
                    ChainLine(kind: .sigma).zIndex(1)
                }
                StrikeRow(chain: chain, strike: strike, showDelta: showDelta, showOpenInterest: showOpenInterest)
            }
            if upper < all.count - 1 {
                moreButton(systemImage: "chevron.down")
            }
        }
    }

    private func crosses(_ boundary: Double, _ previous: Double, _ strike: Double) -> Bool {
        boundary > previous && boundary <= strike
    }

    private func moreButton(systemImage: String) -> some View {
        Button {
            strikesAround += 8
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text("Další striky")
            }
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(ChainTheme.headerBar)
        }
        .buttonStyle(.plain)
    }
}

/// Čára mezi striky: spot (ITM hranice) nebo ±1σ. Nezabírá místo v layoutu.
struct ChainLine: View {
    enum Kind {
        case inTheMoney(Double)
        case sigma
    }

    let kind: Kind

    var body: some View {
        Color.clear
            .frame(height: 0)
            .overlay {
                switch kind {
                case .inTheMoney(let spot):
                    ZStack {
                        Rectangle().fill(ChainTheme.itm).frame(height: 1.5)
                        HStack {
                            Text("▲ ITM").offset(y: -9)
                            Spacer()
                            Text(spot.fixed(2))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(ChainTheme.itm, in: Capsule())
                                .foregroundStyle(.black)
                            Spacer()
                            Text("ITM ▼").offset(y: 9)
                        }
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(ChainTheme.itm)
                        .padding(.horizontal, 6)
                    }
                case .sigma:
                    ZStack(alignment: .leading) {
                        DashedLine()
                            .stroke(ChainTheme.sigma, style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                            .frame(height: 1)
                        Text("1 SD")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(white: 0.85))
                            .padding(.horizontal, 4)
                            .background(ChainTheme.row)
                            .padding(.leading, 6)
                    }
                }
            }
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

struct StrikeRow: View {
    let chain: OptionChain
    let strike: Double
    let showDelta: Bool
    let showOpenInterest: Bool
    @Environment(AppModel.self) private var model

    private var showsDetails: Bool { showDelta || showOpenInterest }
    private var rowHeight: CGFloat { showsDetails ? 56 : 46 }

    var body: some View {
        let call = chain.contract(.call, strike: strike)
        let put = chain.contract(.put, strike: strike)
        let callPosition = model.position(of: call, expiration: chain.expiration)
        let putPosition = model.position(of: put, expiration: chain.expiration)
        let spot = chain.underlyingPrice

        HStack(spacing: 0) {
            side(contract: call, position: callPosition, inTheMoney: strike < spot, edge: .leading)

            Text(strike.strikeLabel)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 64)
                .frame(maxHeight: .infinity)
                .background(ChainTheme.strikeColumn)

            side(contract: put, position: putPosition, inTheMoney: strike > spot, edge: .trailing)
        }
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ChainTheme.separator).frame(height: 1)
        }
    }

    private func side(contract: OptionContract?, position: Int?, inTheMoney: Bool, edge: HorizontalEdge) -> some View {
        let color = ChainTheme.priceColor(change: contract?.change)
        return VStack(spacing: 2) {
            HStack(spacing: 0) {
                QuoteCell(value: contract?.bid, color: color) { tap(contract, .short) }
                QuoteCell(value: contract?.ask, color: color) { tap(contract, .long) }
            }
            if showsDetails {
                Text(details(contract))
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.55))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(inTheMoney ? ChainTheme.rowInTheMoney : ChainTheme.row)
        .overlay {
            if let position {
                Rectangle()
                    .stroke(position > 0 ? ChainTheme.long : ChainTheme.short, lineWidth: 2)
            }
        }
        .overlay(alignment: edge == .leading ? .leading : .trailing) {
            if let position {
                PositionBlock(quantity: position)
            }
        }
    }

    /// „Δ 0,62 · OI 12 tis.“
    private func details(_ contract: OptionContract?) -> String {
        guard let contract else { return " " }
        var parts: [String] = []
        if showDelta, let greeks = contract.greeks(spot: chain.underlyingPrice, rate: model.riskFreeRate) {
            parts.append("Δ " + greeks.delta.fixed(2))
        }
        if showOpenInterest, let oi = contract.openInterest {
            parts.append("OI " + oi.formatted(.number.notation(.compactName)))
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func tap(_ contract: OptionContract?, _ side: PositionSide) {
        guard let contract else { return }
        model.toggleLeg(contract, side: side, chain: chain)
    }
}

struct QuoteCell: View {
    let value: Double?
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(value.map { $0.fixed(2) } ?? "–")
                .font(.system(size: 16))
                .monospacedDigit()
                .underline(value != nil, color: color.opacity(0.6))
                .foregroundStyle(value == nil ? Color(white: 0.45) : color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
    }
}

/// Barevný blok s počtem kontraktů u vybrané nohy.
struct PositionBlock: View {
    let quantity: Int

    var body: some View {
        Text(quantity > 0 ? "\(quantity)" : "\(quantity)")
            .font(.system(size: 18, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 34)
            .frame(maxHeight: .infinity)
            .background(quantity > 0 ? ChainTheme.long : ChainTheme.short)
    }
}
