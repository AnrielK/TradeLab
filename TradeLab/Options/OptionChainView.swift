import SwiftUI
import MarketData
import OptionsMath

struct OptionsHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var symbolInput = ""

    var body: some View {
        NavigationStack {
            OptionChainView(symbol: model.optionsSymbol)
                .navigationTitle("Opce")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack {
                            TextField("Ticker", text: $symbolInput)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                                .onSubmit(submit)
                            Button("Načíst", action: submit)
                        }
                    }
                }
                .onAppear { symbolInput = model.optionsSymbol }
                .onChange(of: model.optionsSymbol) { _, newValue in symbolInput = newValue }
        }
    }

    private func submit() {
        let s = symbolInput.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return }
        model.openOptions(for: s)
    }
}

struct OptionChainView: View {
    let symbol: String
    @Environment(AppModel.self) private var model
    @State private var chain: OptionChain?
    @State private var selectedExpiration: Date?
    @State private var type: OptionType = .call
    @State private var showAllStrikes = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingContract: OptionContract?
    @State private var addedMessage: String?

    private let strikesAroundSpot = 8

    var body: some View {
        List {
            if let chain {
                Section {
                    HStack {
                        Text(chain.symbol).font(.headline)
                        Spacer()
                        Text(chain.underlyingPrice.usd).monospacedDigit()
                    }
                    Picker("Expirace", selection: $selectedExpiration) {
                        ForEach(chain.expirationDates, id: \.self) { date in
                            Text(expirationLabel(date)).tag(Optional(date))
                        }
                    }
                    Picker("Typ", selection: $type) {
                        Text("Cally").tag(OptionType.call)
                        Text("Puty").tag(OptionType.put)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Všechny striky", isOn: $showAllStrikes)
                }

                Section {
                    ContractHeader()
                    ForEach(visibleContracts(chain)) { contract in
                        Button {
                            pendingContract = contract
                        } label: {
                            ContractRow(contract: contract, spot: chain.underlyingPrice, rate: model.riskFreeRate)
                        }
                        .tint(.primary)
                        .listRowBackground(contract.inTheMoney ? Color.accentColor.opacity(0.08) : nil)
                    }
                } footer: {
                    Text("Delta a IV jsou dopočtené z mid ceny (Black-Scholes, sazba \(model.riskFreeRate.percent)). Klepnutím přidáš kontrakt do strategie.")
                }
            } else if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Načítám řetězec…")
                    Spacer()
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Zkusit znovu") { Task { await load(expiration: selectedExpiration) } }
                }
            }
        }
        .confirmationDialog(
            "Přidat do strategie",
            isPresented: Binding(get: { pendingContract != nil }, set: { if !$0 { pendingContract = nil } }),
            titleVisibility: .visible,
            presenting: pendingContract
        ) { contract in
            Button("Koupit (long)") { add(contract, side: .long) }
            Button("Prodat (short)") { add(contract, side: .short) }
            Button("Zrušit", role: .cancel) {}
        } message: { contract in
            Text("\(contract.contractSymbol) · mid \(contract.mid.map { $0.usd } ?? "–")")
        }
        .safeAreaInset(edge: .bottom) {
            if !model.strategy.legs.isEmpty {
                Button {
                    model.selectedTab = .strategy
                } label: {
                    HStack {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        Text(addedMessage ?? "Strategie: \(model.strategy.legs.count) noh(y)")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .tint(.primary)
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
        }
        .task(id: symbol) {
            chain = nil
            selectedExpiration = nil
            await load(expiration: nil)
        }
        .onChange(of: selectedExpiration) { _, newValue in
            guard let newValue, let chain, newValue != chain.expiration else { return }
            Task { await load(expiration: newValue) }
        }
        .refreshable { await load(expiration: selectedExpiration) }
    }

    private func visibleContracts(_ chain: OptionChain) -> [OptionContract] {
        let all = chain.contracts(type)
        guard !showAllStrikes, all.count > strikesAroundSpot * 2 else { return all }
        let atmIndex = all.enumerated().min { abs($0.element.strike - chain.underlyingPrice) < abs($1.element.strike - chain.underlyingPrice) }?.offset ?? 0
        let lower = max(atmIndex - strikesAroundSpot, 0)
        let upper = min(atmIndex + strikesAroundSpot, all.count - 1)
        return Array(all[lower...upper])
    }

    private func expirationLabel(_ date: Date) -> String {
        let days = Int(OptionChain.daysToExpiry(date).rounded(.down))
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC")!
        return "\(date.formatted(style)) (\(days) d)"
    }

    private func add(_ contract: OptionContract, side: PositionSide) {
        guard let chain else { return }
        model.addLeg(from: contract, side: side, chain: chain)
        let verb = side == .long ? "Koupeno" : "Prodáno"
        addedMessage = "\(verb) \(contract.type == .call ? "C" : "P") \(contract.strike.fixed(1)) · \(model.strategy.legs.count) noh(y)"
    }

    private func load(expiration: Date?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await model.client.optionChain(symbol: symbol, expiration: expiration)
            chain = loaded
            selectedExpiration = loaded.expiration
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ContractHeader: View {
    var body: some View {
        HStack {
            Text("Strike").frame(maxWidth: .infinity, alignment: .leading)
            Text("Bid / Ask").frame(maxWidth: .infinity, alignment: .trailing)
            Text("IV").frame(width: 52, alignment: .trailing)
            Text("Δ").frame(width: 46, alignment: .trailing)
            Text("OI").frame(width: 56, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

private struct ContractRow: View {
    let contract: OptionContract
    let spot: Double
    let rate: Double

    var body: some View {
        let iv = contract.estimatedVolatility(spot: spot, rate: rate)
        let greeks = contract.greeks(spot: spot, rate: rate)
        HStack {
            Text(contract.strike.fixed(contract.strike.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(contract.bid.map { $0.fixed(2) } ?? "–") / \(contract.ask.map { $0.fixed(2) } ?? "–")")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(iv.map { ($0 * 100).fixed(0) + "%" } ?? "–")
                .frame(width: 52, alignment: .trailing)
            Text(greeks.map { $0.delta.fixed(2) } ?? "–")
                .frame(width: 46, alignment: .trailing)
            Text(contract.openInterest.map { compact($0) } ?? "–")
                .frame(width: 56, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}
