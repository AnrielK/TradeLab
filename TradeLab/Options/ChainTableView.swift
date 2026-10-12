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
                                isLoading: store.loading.contains(date),
                                legCount: legCount(for: date)
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
            .scrollEdgeEffectStyle(.soft, for: .top)
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
            model.focusedExpiration = expanded
        }
        .onChange(of: expanded) { _, newValue in
            model.focusedExpiration = newValue
        }
    }

    /// Počet nohou tiketu v dané expiraci (pro zvýraznění v přehledu).
    private func legCount(for date: Date) -> Int {
        guard model.strategy.underlying.uppercased() == store.symbol.uppercased() else { return 0 }
        return model.strategy.optionLegs.filter { $0.expiration == date }.count
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
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color(white: 0.85))
        .frame(height: 34)
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
    var legCount: Int = 0

    var body: some View {
        let monthly = ExpirationCalendar.isMonthly(date)
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(date.chainLabel)
                    .font(.system(size: 12, weight: isExpanded || legCount > 0 ? .semibold : .regular))
                    .monospacedDigit()
                if !monthly {
                    Text("W")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(ChainTheme.badge, in: RoundedRectangle(cornerRadius: 4))
                }
                if legCount > 0 {
                    // Expirace s vybranými nohami.
                    Text("\(legCount)")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(ChainTheme.itm, in: Circle())
                }
                Spacer(minLength: 4)
                if isExpanded {
                    Text("Cally").font(.system(size: 12)).foregroundStyle(Color(white: 0.85))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity)

            Text("\(Int(OptionChain.daysToExpiry(date).rounded(.down)))d")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .frame(width: 64)
                .frame(maxHeight: .infinity)
                .background(ChainTheme.centerColumn)

            HStack(spacing: 6) {
                if isExpanded {
                    Text("Puty").font(.system(size: 12)).foregroundStyle(Color(white: 0.85))
                }
                Spacer(minLength: 4)
                ivText
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .frame(height: 32)
        .background(monthly ? ChainTheme.monthly : ChainTheme.weekly)
        .overlay(alignment: .leading) {
            if legCount > 0 {
                Rectangle().fill(ChainTheme.itm).frame(width: 4)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ChainTheme.separator).frame(height: 1)
        }
    }

    @ViewBuilder
    private var ivText: some View {
        if let summary, let iv = summary.atmVolatility {
            HStack(spacing: 4) {
                Text("IV \(iv.percent)")
                if let move = summary.oneSigmaMove {
                    Text("(±\(move.fixed(2)))").foregroundStyle(Color(white: 0.75))
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else if isLoading {
            ProgressView().controlSize(.mini).tint(.white)
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
            .padding(.vertical, 7)
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
                        Rectangle().fill(ChainTheme.itm).frame(height: 1)
                        HStack {
                            // Cally: ITM nad čarou, puty: ITM pod čarou.
                            HStack(spacing: 1) {
                                Image(systemName: "arrowtriangle.up.fill")
                                Text("ITM")
                            }
                            .offset(y: -6)
                            Spacer()
                            HStack(spacing: 1) {
                                Text("ITM")
                                Image(systemName: "arrowtriangle.down.fill")
                            }
                            .offset(y: 6)
                        }
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ChainTheme.itm)
                        .padding(.horizontal, 4)
                        // Kapka aktuální ceny na pravém okraji sloupce striků (špička míří ke striku).
                        Image(systemName: "drop")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(ChainTheme.short)
                            .rotationEffect(.degrees(-90))
                            .offset(x: StrikeRuler.markerOffset + 7)
                            .accessibilityLabel("Spot \(spot.fixed(2))")
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

    private static let strikeWidth: CGFloat = 64
    /// Vodorovný posun prstu, od kterého se noha přepne call ↔ put.
    private static let flipThreshold: CGFloat = 110
    private var showsDetails: Bool { showDelta || showOpenInterest }

    @State private var dragOffset: CGSize = .zero
    /// Tažená noha – blok zůstává v původním řádku a jede s prstem, noha se přesouvá živě.
    @State private var dragGhost: DragGhost?

    private struct DragGhost {
        let legID: UUID
        let originType: OptionType
    }

    private var draggingType: OptionType? { dragGhost?.originType }
    private var rowHeight: CGFloat { showsDetails ? 42 : 34 }

    var body: some View {
        let call = chain.contract(.call, strike: strike)
        let put = chain.contract(.put, strike: strike)
        let callPosition = model.position(of: call, expiration: chain.expiration)
        let putPosition = model.position(of: put, expiration: chain.expiration)
        let spot = chain.underlyingPrice

        HStack(spacing: 0) {
            side(contract: call, position: callPosition, inTheMoney: strike < spot, edge: .leading)

            Text(strike.strikeLabel)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.trailing, 6)
                .frame(width: Self.strikeWidth)
                .frame(maxHeight: .infinity)
                .background(ChainTheme.strikeColumn)
                .overlay(alignment: .trailing) { StrikeRuler() }
                .highPriorityGesture(
                    legDrag(legID: strikeDragTarget(call: call, callPosition: callPosition, put: put, putPosition: putPosition)?.legID ?? Self.noLeg,
                            type: strikeDragTarget(call: call, callPosition: callPosition, put: put, putPosition: putPosition)?.type ?? .call),
                    isEnabled: strikeDragTarget(call: call, callPosition: callPosition, put: put, putPosition: putPosition) != nil
                )

            side(contract: put, position: putPosition, inTheMoney: strike > spot, edge: .trailing)
        }
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ChainTheme.separator).frame(height: 1)
        }
        .overlay {
            // Rámeček vybrané nohy obepíná i strike (call: vlevo + strike, put: strike + vpravo).
            GeometryReader { geometry in
                let sideWidth = (geometry.size.width - Self.strikeWidth) / 2
                let frameWidth = sideWidth + Self.strikeWidth
                if let callPosition {
                    Rectangle()
                        .stroke(callPosition > 0 ? ChainTheme.long : ChainTheme.short, lineWidth: 2)
                        .frame(width: frameWidth - 2, height: geometry.size.height - 2)
                        .position(x: frameWidth / 2, y: geometry.size.height / 2)
                }
                if let putPosition {
                    Rectangle()
                        .stroke(putPosition > 0 ? ChainTheme.long : ChainTheme.short, lineWidth: 2)
                        .frame(width: frameWidth - 2, height: geometry.size.height - 2)
                        .position(x: sideWidth + frameWidth / 2, y: geometry.size.height / 2)
                }
            }
            .allowsHitTesting(false)
        }
        .zIndex(draggingType == nil ? 0 : 10)
    }

    private func side(contract: OptionContract?, position: Int?, inTheMoney: Bool, edge: HorizontalEdge) -> some View {
        let color = ChainTheme.priceColor(change: contract?.change)
        let detail = details(contract)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                QuoteCell(value: contract?.bid, color: color) { tap(contract, .short) }
                QuoteCell(value: contract?.ask, color: color) { tap(contract, .long) }
            }
            if showsDetails {
                // Delta pod bidem, OI pod askem – přes celou šířku pole bid–ask.
                HStack(spacing: 0) {
                    Text(detail.delta).frame(maxWidth: .infinity)
                    Text(detail.openInterest).frame(maxWidth: .infinity)
                }
                .font(.system(size: 9))
                .foregroundStyle(Color(white: 0.55))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.bottom, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(inTheMoney ? ChainTheme.rowInTheMoney : ChainTheme.row)
        .overlay(alignment: edge == .leading ? .leading : .trailing) {
            if let info = blockInfo(side: edge == .leading ? .call : .put, position: position, contract: contract) {
                draggableBlock(quantity: info.quantity, legID: info.legID, type: edge == .leading ? .call : .put)
            }
        }
        .highPriorityGesture(
            legDrag(legID: blockInfo(side: edge == .leading ? .call : .put, position: position, contract: contract)?.legID ?? Self.noLeg,
                    type: edge == .leading ? .call : .put),
            isEnabled: blockInfo(side: edge == .leading ? .call : .put, position: position, contract: contract) != nil
        )
    }

    private static let noLeg = UUID()

    /// Strike patří do rámečku vybrané nohy – táhne se call, jinak put.
    private func strikeDragTarget(call: OptionContract?, callPosition: Int?, put: OptionContract?, putPosition: Int?) -> (legID: UUID, type: OptionType)? {
        if let info = blockInfo(side: .call, position: callPosition, contract: call) { return (info.legID, .call) }
        if let info = blockInfo(side: .put, position: putPosition, contract: put) { return (info.legID, .put) }
        return nil
    }

    /// Co zobrazit v bloku: taženou nohu (v původním řádku) nebo nohu, která tu leží.
    private func blockInfo(side type: OptionType, position: Int?, contract: OptionContract?) -> (quantity: Int, legID: UUID)? {
        if let ghost = dragGhost, ghost.originType == type {
            guard let leg = model.strategy.legs.first(where: { $0.id == ghost.legID }) else { return nil }
            return (leg.side == .long ? leg.quantity : -leg.quantity, leg.id)
        }
        guard let position, let contract, let leg = model.leg(for: contract, expiration: chain.expiration),
              leg.id != model.draggingLegID else { return nil }
        return (position, leg.id)
    }

    // MARK: - Tažení nohy (nahoru/dolů = strike, do strany = call ↔ put)

    private func draggableBlock(quantity: Int, legID: UUID, type: OptionType) -> some View {
        let isDragging = draggingType == type
        let deleting = isDragging && inDeleteZone(type)
        return PositionBlock(quantity: quantity)
            .overlay(alignment: type == .call ? .trailing : .leading) {
                if deleting {
                    Text("Smazat")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ChainTheme.short, in: Capsule())
                        .fixedSize()
                        .offset(x: type == .call ? 52 : -52)
                } else if isDragging, let target = dragTarget(from: type) {
                    Text("\(target.strike.strikeLabel) \(target.type == .call ? "C" : "P")")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ChainTheme.itm, in: Capsule())
                        .fixedSize()
                        .offset(x: type == .call ? 48 : -48)
                }
            }
            .opacity(deleting ? 0.5 : 1)
            .scaleEffect(isDragging ? 1.12 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.6 : 0), radius: 6)
            .offset(isDragging ? dragOffset : .zero)
    }

    /// Tažení vybrané nohy – funguje za celé označené pole (strana i strike), ne jen za blok s počtem.
    private func legDrag(legID: UUID, type: OptionType) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragGhost == nil {
                    dragGhost = DragGhost(legID: legID, originType: type)
                    model.draggingLegID = legID
                }
                dragOffset = value.translation
                guard !inDeleteZone(type),
                      let target = dragTarget(from: type),
                      let destination = chain.contract(target.type, strike: target.strike) else { return }
                // Noha se přesouvá živě – tiket i rámeček sledují prst.
                model.moveLeg(id: legID, to: destination, chain: chain)
            }
            .onEnded { _ in
                if inDeleteZone(type) {
                    model.deleteLeg(id: legID)
                }
                dragGhost = nil
                dragOffset = .zero
                model.draggingLegID = nil
                model.saveStrategy()
            }
    }

    /// Tažení ven ze strany tabulky (call doleva, put doprava) nohu smaže.
    private func inDeleteZone(_ type: OptionType) -> Bool {
        type == .call ? dragOffset.width < -50 : dragOffset.width > 50
    }

    /// Cílový kontrakt podle posunu prstu: řádky = striky, přes polovinu = druhý typ.
    private func dragTarget(from type: OptionType) -> (strike: Double, type: OptionType)? {
        var targetType = type
        if type == .call, dragOffset.width > Self.flipThreshold { targetType = .put }
        if type == .put, dragOffset.width < -Self.flipThreshold { targetType = .call }
        let strikes = chain.contracts(targetType).map(\.strike).sorted()
        guard let index = StrikeLadder.nearestIndex(to: strike, in: strikes) else { return nil }
        let steps = Int((dragOffset.height / rowHeight).rounded())
        let target = min(max(index + steps, 0), strikes.count - 1)
        return (strikes[target], targetType)
    }

    private func details(_ contract: OptionContract?) -> (delta: String, openInterest: String) {
        guard let contract else { return ("", "") }
        var delta = ""
        if showDelta, let greeks = contract.greeks(spot: chain.underlyingPrice, rate: model.riskFreeRate) {
            delta = "Δ " + greeks.delta.fixed(2)
        }
        var openInterest = ""
        if showOpenInterest, let oi = contract.openInterest {
            openInterest = "OI " + oi.formatted(.number.notation(.compactName))
        }
        return (delta, openInterest)
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
                .font(.system(size: 13))
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
            .font(.system(size: 15, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 28)
            .frame(maxHeight: .infinity)
            .background(quantity > 0 ? ChainTheme.long : ChainTheme.short)
    }
}

/// Stupnice (čárky) na pravém okraji sloupce striků.
struct StrikeRuler: View {
    /// Vodorovný posun značky spotu od středu řádku (pravý okraj sloupce striků).
    static let markerOffset: CGFloat = 32 - 4

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 4
            var y: CGFloat = 2
            var index = 0
            while y < size.height {
                let length: CGFloat = index % 5 == 0 ? 7 : 4
                var path = Path()
                path.move(to: CGPoint(x: size.width - length, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(Color(white: 0.38)), lineWidth: 0.8)
                y += step
                index += 1
            }
        }
        .frame(width: 8)
        .allowsHitTesting(false)
    }
}
