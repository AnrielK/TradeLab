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
                // Ticker se vybírá na záložce Trh; tady je výběr strategie.
                ToolbarItem(placement: .topBarTrailing) {
                    StrategyMenuButton()
                }
            }
            .task(id: model.optionsSymbol) {
                await model.chainStore.load(symbol: model.optionsSymbol, rate: model.riskFreeRate)
            }
        }
    }

    private var header: some View {
        let store = model.chainStore
        return HStack(alignment: .firstTextBaseline) {
            Text(store.symbol.isEmpty ? model.optionsSymbol : store.symbol)
                .font(.title3.weight(.bold))
            if store.underlyingPrice > 0 {
                Text(store.underlyingPrice.usd)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            if let quote = store.quote, let change = quote.change, let pct = quote.changePercent {
                Text("\(change.signedUSD) (\(pct.signedPercent))")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.pnl(change))
            }
            Spacer()
            if store.isLoadingSymbol { ProgressView() }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}


/// Výběr šablony strategie – staví se z reálného řetězce rozbalené (nebo ~30denní) expirace.
struct StrategyMenuButton: View {
    @Environment(AppModel.self) private var model
    @State private var isApplying = false

    var body: some View {
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
            .padding(.horizontal, 4)
            // Pozadí dodá toolbar (Liquid Glass).
        }
        .disabled(model.templateExpiration == nil)
    }
}

/// Přepínač TABULKA / PAYOFF – nativní segmentový ovladač (v iOS 26 Liquid Glass) a nastavení sloupců.
struct ModeTabs: View {
    @Binding var mode: OptionsMode
    @AppStorage("chain.showDelta") private var showDelta = true
    @AppStorage("chain.showOI") private var showOpenInterest = true

    var body: some View {
        HStack(spacing: 10) {
            Picker("Režim", selection: $mode.animation(.smooth)) {
                ForEach(OptionsMode.allCases) { item in
                    Text(item.rawValue.uppercased()).tag(item)
                }
            }
            .pickerStyle(.segmented)

            Menu {
                Toggle("Delta", isOn: $showDelta)
                Toggle("Open interest", isOn: $showOpenInterest)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .opacity(mode == .table ? 1 : 0)
            .disabled(mode != .table)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}
