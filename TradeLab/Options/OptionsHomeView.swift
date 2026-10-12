import SwiftUI
import MarketData
import OptionsMath

enum OptionsMode: String, CaseIterable, Identifiable {
    case table = "Tabulka"
    case curve = "Payoff"

    var id: String { rawValue }
}

struct OptionsHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: OptionsMode = .table
    @State private var symbolInput = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Picker("Režim", selection: $mode) {
                    ForEach(OptionsMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch mode {
                case .table:
                    ChainTableView(mode: $mode)
                case .curve:
                    PayoffWorkspaceView()
                }
            }
            .navigationTitle("Opce")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        TextField("Ticker", text: $symbolInput)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .onSubmit(submit)
                        Button("Načíst", action: submit)
                    }
                }
            }
            .onAppear { symbolInput = model.optionsSymbol }
            .onChange(of: model.optionsSymbol) { _, newValue in symbolInput = newValue }
            .task(id: model.optionsSymbol) {
                await model.chainStore.load(symbol: model.optionsSymbol, rate: model.riskFreeRate)
            }
        }
    }

    private var header: some View {
        let store = model.chainStore
        return HStack(alignment: .firstTextBaseline) {
            Text(store.symbol.isEmpty ? model.optionsSymbol : store.symbol)
                .font(.title2.weight(.bold))
            if store.underlyingPrice > 0 {
                Text(store.underlyingPrice.usd)
                    .font(.headline)
                    .monospacedDigit()
            }
            if let quote = store.quote, let change = quote.change, let pct = quote.changePercent {
                Text("\(change.signedUSD) (\(pct.signedPercent))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color.pnl(change))
            }
            Spacer()
            if store.isLoadingSymbol { ProgressView() }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func submit() {
        let symbol = symbolInput.trimmingCharacters(in: .whitespaces).uppercased()
        guard !symbol.isEmpty else { return }
        model.openOptions(for: symbol)
    }
}

// MARK: - Tabulka expirací a řetězce

struct ChainTableView: View {
    @Binding var mode: OptionsMode
    @Environment(AppModel.self) private var model
    @State private var expanded: Date?
    @State private var strikesAround = 8

    private var store: ChainStore { model.chainStore }

    var body: some View {
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
                    }
                }
            }
            .padding(.bottom, ticketVisible ? 190 : 0)
        }
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
        .refreshable { await store.refresh(rate: model.riskFreeRate) }
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
            ChainGrid(chain: chain, summary: store.summaries[date], strikesAround: $strikesAround)
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

struct ExpirationHeader: View {
    let date: Date
    let summary: ExpirationSummary?
    let isExpanded: Bool
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(date.expiryLabel)
                .font(.subheadline.weight(.semibold))
            if let summary, !summary.isMonthly {
                Text("W")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            Text("\(Int(OptionChain.daysToExpiry(date).rounded(.down))) d")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .frame(width: 56)
            Spacer()
            if let summary, let iv = summary.atmVolatility {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("IV \(iv.percent)")
                    if let move = summary.oneSigmaMove {
                        Text("±\(move.fixed(2))").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .monospacedDigit()
            } else if isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isExpanded ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Řetězec jedné expirace

struct ChainGrid: View {
    let chain: OptionChain
    let summary: ExpirationSummary?
    @Binding var strikesAround: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let all = chain.strikes
        let atmIndex = StrikeLadder.nearestIndex(to: chain.underlyingPrice, in: all) ?? 0
        let lower = max(atmIndex - strikesAround, 0)
        let upper = min(atmIndex + strikesAround, max(all.count - 1, 0))
        let visible = all.isEmpty ? [] : Array(all[lower...upper])
        let spot = chain.underlyingPrice
        let sigma = summary?.oneSigmaMove

        VStack(spacing: 0) {
            ChainColumnHeader()
            if lower > 0 {
                moreButton("Další striky", systemImage: "chevron.up")
            }
            ForEach(Array(visible.enumerated()), id: \.element) { index, strike in
                let previous = index > 0 ? visible[index - 1] : -Double.infinity
                if let sigma, crosses(spot - sigma, previous, strike) {
                    SeparatorLine(label: "1 SD", color: .indigo, dashed: true)
                }
                if crosses(spot, previous, strike) {
                    SeparatorLine(label: "\(spot.fixed(2))", color: .yellow, dashed: false)
                }
                if let sigma, crosses(spot + sigma, previous, strike) {
                    SeparatorLine(label: "1 SD", color: .indigo, dashed: true)
                }
                StrikeRow(chain: chain, strike: strike)
            }
            if upper < all.count - 1 {
                moreButton("Další striky", systemImage: "chevron.down")
            }
        }
    }

    private func crosses(_ boundary: Double, _ previous: Double, _ strike: Double) -> Bool {
        boundary > previous && boundary <= strike
    }

    private func moreButton(_ title: String, systemImage: String) -> some View {
        Button {
            strikesAround += 8
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

struct ChainColumnHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 28)
            Text("Bid").frame(maxWidth: .infinity)
            Text("Ask").frame(maxWidth: .infinity)
            Text("Strike").frame(width: 64)
            Text("Bid").frame(maxWidth: .infinity)
            Text("Ask").frame(maxWidth: .infinity)
            Color.clear.frame(width: 28)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            HStack {
                Text("CALLY").padding(.leading, 30)
                Spacer()
                Text("PUTY").padding(.trailing, 30)
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.tertiary)
            .offset(y: -6)
        }
        .padding(.top, 6)
    }
}

struct SeparatorLine: View {
    let label: String
    let color: Color
    let dashed: Bool

    var body: some View {
        HStack(spacing: 4) {
            line
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
            line
        }
        .frame(height: 12)
    }

    private var line: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
        }
    }
}

struct StrikeRow: View {
    let chain: OptionChain
    let strike: Double
    @Environment(AppModel.self) private var model

    var body: some View {
        let call = chain.contract(.call, strike: strike)
        let put = chain.contract(.put, strike: strike)
        let callPosition = model.position(of: call, expiration: chain.expiration)
        let putPosition = model.position(of: put, expiration: chain.expiration)
        let spot = chain.underlyingPrice

        HStack(spacing: 0) {
            PositionTag(quantity: callPosition)
            HStack(spacing: 0) {
                QuoteCell(value: call?.bid, isSelected: (callPosition ?? 0) < 0, tint: .red) { tap(call, .short) }
                QuoteCell(value: call?.ask, isSelected: (callPosition ?? 0) > 0, tint: .green) { tap(call, .long) }
            }
            .background(strike < spot ? Color.accentColor.opacity(0.08) : Color.clear)

            Text(strike.strikeLabel)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 64, height: 40)
                .background(Color(uiColor: .tertiarySystemBackground))

            HStack(spacing: 0) {
                QuoteCell(value: put?.bid, isSelected: (putPosition ?? 0) < 0, tint: .red) { tap(put, .short) }
                QuoteCell(value: put?.ask, isSelected: (putPosition ?? 0) > 0, tint: .green) { tap(put, .long) }
            }
            .background(strike > spot ? Color.accentColor.opacity(0.08) : Color.clear)
            PositionTag(quantity: putPosition)
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func tap(_ contract: OptionContract?, _ side: PositionSide) {
        guard let contract else { return }
        model.toggleLeg(contract, side: side, chain: chain)
    }
}

struct QuoteCell: View {
    let value: Double?
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(value.map { $0.fixed(2) } ?? "–")
                .font(.callout)
                .monospacedDigit()
                .underline(value != nil, color: Color.secondary.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4).stroke(tint, lineWidth: 2).padding(2)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
    }
}

struct PositionTag: View {
    let quantity: Int?

    var body: some View {
        ZStack {
            if let quantity {
                Text(quantity > 0 ? "+\(quantity)" : "\(quantity)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 30)
                    .background(quantity > 0 ? Color.green : Color.red, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(width: 28)
    }
}

// MARK: - Tiket

struct TicketBar: View {
    @Environment(AppModel.self) private var model
    let onAnalyze: () -> Void

    var body: some View {
        let strategy = model.strategy
        let quote = strategy.netQuote
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ticketTitle(strategy, quote: quote))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    model.clearStrategy()
                } label: {
                    Image(systemName: "trash")
                }
            }
            if let quote {
                NetQuoteBar(quote: quote)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(strategy.legs) { leg in
                        LegChip(leg: leg)
                    }
                }
            }
            Button(action: onAnalyze) {
                Label("Payoff a úpravy", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}

func ticketTitle(_ strategy: OptionStrategy, quote: NetQuote?) -> String {
    let count = strategy.spreadCount
    var title = "\(count)× \(strategy.name)"
    if let quote {
        title += " · \(quote.isDebit ? "debet" : "kredit") \(abs(quote.mid).fixed(2))"
    }
    return title
}

struct NetQuoteBar: View {
    let quote: NetQuote

    var body: some View {
        let unit = quote.isDebit ? "db" : "cr"
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Bid").font(.caption2).foregroundStyle(.secondary)
                Text("\(quote.low.fixed(2)) \(unit)")
            }
            Spacer()
            VStack(spacing: 1) {
                Text("Mid").font(.caption2).foregroundStyle(.secondary)
                Text("\(abs(quote.mid).fixed(2)) \(unit)").fontWeight(.bold)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Ask").font(.caption2).foregroundStyle(.secondary)
                Text("\(quote.high.fixed(2)) \(unit)")
            }
        }
        .font(.callout)
        .monospacedDigit()
    }
}

struct LegChip: View {
    let leg: StrategyLeg

    private var label: String {
        let sign = leg.side == .long ? "+" : "−"
        switch leg.instrument {
        case .call, .put:
            let type = leg.instrument == .call ? "C" : "P"
            let expiry = leg.expiration.map { " " + $0.shortExpiryLabel } ?? ""
            return "\(sign)\(leg.quantity) \(type) \(leg.strike.strikeLabel)\(expiry)"
        case .stock:
            return "\(sign)\(leg.quantity * 100) akcií"
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((leg.side == .long ? Color.green : Color.red).opacity(0.18), in: Capsule())
    }
}
