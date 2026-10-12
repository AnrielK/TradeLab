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
                ModeTabs(mode: $mode)

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


extension ModeTabs {
    /// Šablony strategií – staví se z reálného řetězce rozbalené (nebo ~30denní) expirace.
    var strategyMenu: some View {
        Menu {
            Section(model.templateExpiration.map { "Expirace " + $0.chainLabel } ?? "Načti řetězec") {
                ForEach(StrategyTemplate.allCases) { template in
                    Button {
                        isApplying = true
                        Task {
                            await model.applyTemplate(template)
                            isApplying = false
                        }
                    } label: {
                        Text(template.displayName)
                        Text(template.summary)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isApplying {
                    ProgressView().controlSize(.mini)
                }
                Text(model.strategy.optionLegs.isEmpty ? "Strategie" : model.strategy.name)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(model.templateExpiration == nil)
    }
}

/// Záložky „TABULKA / PAYOFF“ s podtržením jako v brokerské aplikaci.
struct ModeTabs: View {
    @Binding var mode: OptionsMode
    @Environment(AppModel.self) private var model
    @State private var isApplying = false
    @AppStorage("chain.showDelta") private var showDelta = true
    @AppStorage("chain.showOI") private var showOpenInterest = true

    var body: some View {
        HStack(spacing: 28) {
            ForEach(OptionsMode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue.uppercased())
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(mode == item ? Color.primary : Color.secondary)
                        Rectangle()
                            .fill(mode == item ? Color.primary : Color.clear)
                            .frame(height: 3)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
            strategyMenu
                .padding(.bottom, 8)
            if mode == .table {
                Menu {
                    Toggle("Delta", isOn: $showDelta)
                    Toggle("Open interest", isOn: $showOpenInterest)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(Color.secondary)
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
    }
}
