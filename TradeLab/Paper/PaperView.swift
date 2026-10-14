import SwiftUI
import Backtest

/// Záložka Demo: virtuální účet pro živé testování strategií.
struct PaperView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    private var paper: PaperTradingModel { model.paper }

    var body: some View {
        @Bindable var paper = model.paper
        NavigationStack {
            List {
                accountSection
                autoSection
                if let error = paper.errorMessage {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
                positionsSection
                if !paper.log.isEmpty {
                    Section("Události") {
                        ForEach(paper.log, id: \.self) { Text($0).font(.caption) }
                    }
                }
                historySection
            }
            .navigationTitle("Demo účet")
            .navigationDestination(for: UUID.self) { id in PaperPositionDetailView(positionID: id) }
            .navigationDestination(for: String.self) { SymbolDetailView(symbol: $0) }
            .refreshable { await run() }
            .task { await paper.runIfStale(watchlist: model.watchlist, scanner: model.scanner) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset", systemImage: "arrow.counterclockwise") { confirmReset = true }
                }
                ToolbarItem(placement: .topBarTrailing) { AgentToolbarButton() }
            }
            .confirmationDialog("Vynulovat demo účet na 10 000 USD? Pozice i historie se smažou.",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Vynulovat", role: .destructive) { paper.reset() }
            }
        }
    }

    private func run() async {
        await paper.run(watchlist: model.watchlist, scanner: model.scanner)
    }

    // MARK: - Účet

    private var accountSection: some View {
        let a = paper.account
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(a.equity.usd)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                Text("\(a.totalPnL.signedUSD) (\((a.totalPnL / max(a.startingCash, 1)).signedPercent)) od \(a.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.pnl(a.totalPnL))
            }
            LabeledContent("Hotovost", value: a.cash.usd)
            LabeledContent("Realizovaný zisk", value: a.realizedPnL.signedUSD)
            LabeledContent("Uzavřené obchody",
                           value: "\(a.history.count)" + (a.winRate.map { " · úspěšnost \($0.percent)" } ?? ""))
        } header: {
            Text("Účet")
        } footer: {
            Text("Virtuální peníze, bez poplatků. Ceny z Yahoo (mohou být o pár minut zpožděné).")
        }
    }

    // MARK: - Automatické obchodování

    private var autoSection: some View {
        @Bindable var paper = model.paper
        return Section {
            Toggle("Obchodovat strategie automaticky", isOn: $paper.settings.autoTrade)
            if paper.settings.autoTrade {
                Toggle("Breakout / Breakdown", isOn: $paper.settings.useBreakout)
                Toggle("Odraz od klouzavých průměrů", isOn: $paper.settings.useMABounce)
                Toggle("Trendlinie a trojúhelník", isOn: $paper.settings.useTrendline)
                Toggle("Povolit short", isOn: $paper.settings.allowShort)
                Stepper("Riziko na obchod: \(paper.settings.riskPct.fixed(1)) % účtu",
                        value: $paper.settings.riskPct, in: 0.25...5, step: 0.25)
                Stepper("Pozice nejvýš \(Int(paper.settings.maxPositionPct)) % účtu",
                        value: $paper.settings.maxPositionPct, in: 5...100, step: 5)
                Stepper("Nejvýš \(paper.settings.maxPositions) pozic", value: $paper.settings.maxPositions, in: 1...20)
            }
            Button {
                Task { await run() }
            } label: {
                HStack {
                    if paper.isRunning {
                        ProgressView().controlSize(.small)
                        Text("Vyhodnocuji \(paper.progress.done)/\(paper.progress.total)…")
                    } else {
                        Text("Vyhodnotit teď").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(paper.isRunning)
            .listRowBackground(Color.clear)
        } header: {
            Text("Živé testování strategií")
        } footer: {
            Text("Vyhodnocení proběhne při otevření záložky a návratu do aplikace (nejvýš jednou za 15 minut) nebo stažením dolů. Pozice se přecení aktuální cenou a zavřou na stopu nebo cíli strategie. Pak se projdou tickery skeneru (nastavení strategií i seznam tickerů ze skeneru) a čerstvé vstupy z uzavřených denních svíček se otevřou za aktuální cenu. Velikost: riziko ke stopu \(paper.settings.riskPct.fixed(1)) % účtu. Každý signál jen jednou. Aplikace na pozadí neběží – stop a cíl se kontrolují při vyhodnocení.\(paper.lastRun.map { " Naposledy: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "")")
        }
    }

    // MARK: - Pozice a historie

    private var positionsSection: some View {
        Section("Otevřené pozice") {
            if paper.account.positions.isEmpty {
                Text("Žádné otevřené pozice.").foregroundStyle(.secondary)
            }
            ForEach(paper.account.positions) { p in
                NavigationLink(value: p.id) {
                    PaperPositionRow(position: p)
                }
                .swipeActions {
                    Button("Zavřít", systemImage: "xmark.circle") {
                        Task { await paper.close(p) }
                    }
                    .tint(.red)
                }
            }
        }
    }

    private var historySection: some View {
        Section("Historie") {
            if paper.account.history.isEmpty {
                Text("Zatím žádné uzavřené obchody.").foregroundStyle(.secondary)
            }
            ForEach(paper.account.history.prefix(100)) { t in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(t.side > 0 ? "▲" : "▼") \(t.symbol)").font(.headline)
                        Text(t.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(t.pnl.signedUSDWhole)
                            .monospacedDigit()
                            .foregroundStyle(Color.pnl(t.pnl))
                    }
                    Text("\(Int(t.shares)) ks · \(t.entryPrice.fixed(2)) → \(t.exitPrice.fixed(2)) (\(t.returnPct.signedPercent)) · \(t.reason) · \(t.entryDate.formatted(date: .numeric, time: .omitted)) – \(t.exitDate.formatted(date: .numeric, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

struct PaperPositionRow: View {
    let position: PaperPosition

    var body: some View {
        let p = position
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(p.side > 0 ? "▲" : "▼") \(p.symbol)").font(.headline)
                Text(p.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(p.unrealizedPnL.signedUSDWhole)
                        .monospacedDigit()
                        .foregroundStyle(Color.pnl(p.unrealizedPnL))
                    Text(p.returnPct.signedPercent)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.pnl(p.unrealizedPnL))
                }
            }
            Text("\(Int(p.shares)) ks · vstup \(p.entryPrice.fixed(2)) · teď \(p.lastPrice.fixed(2))"
                 + (p.stop.map { " · stop \($0.fixed(2))" } ?? "") + (p.target.map { " · cíl \($0.fixed(2))" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Detail otevřené pozice: graf se vstupem, stopem a cílem, čísla obchodu, úprava stopu / cíle, zavření.
struct PaperPositionDetailView: View {
    let positionID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var stopText = ""
    @State private var targetText = ""

    private var position: PaperPosition? { model.paper.account.positions.first { $0.id == positionID } }

    var body: some View {
        if let p = position {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.unrealizedPnL.signedUSD)
                            .font(.largeTitle.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.pnl(p.unrealizedPnL))
                        Text("\(p.returnPct.signedPercent) · \(p.side > 0 ? "Long" : "Short") \(Int(p.shares)) ks · \(p.source)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    EmbeddedTVChart(symbol: p.symbol, priceLines: lines(p))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                Section("Obchod") {
                    LabeledContent("Vstup", value: "\(p.entryPrice.usd) · \(p.entryDate.formatted(date: .abbreviated, time: .shortened))")
                    LabeledContent("Aktuální cena", value: p.lastPrice.usd)
                    LabeledContent("Hodnota pozice", value: abs(p.marketValue).usd)
                    if let stop = p.stop {
                        LabeledContent("Stop", value: "\(stop.usd) (\(((stop / p.entryPrice - 1) * Double(p.side)).signedPercent))")
                        LabeledContent("Riziko", value: (Double(p.side) * (stop - p.entryPrice) * p.shares).signedUSDWhole)
                    }
                    if let target = p.target {
                        LabeledContent("Cíl", value: "\(target.usd) (\(((target / p.entryPrice - 1) * Double(p.side)).signedPercent))")
                    }
                    if let stop = p.stop, let target = p.target, abs(p.entryPrice - stop) > 0 {
                        LabeledContent("R:R", value: (abs(target - p.entryPrice) / abs(p.entryPrice - stop)).fixed(1))
                    }
                }

                Section {
                    LabeledContent("Stop") {
                        TextField("bez stopu", text: $stopText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Cíl") {
                        TextField("bez cíle", text: $targetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Uložit stop a cíl") {
                        model.paper.updateLevels(p.id, stop: Self.number(stopText), target: Self.number(targetText))
                    }
                } header: {
                    Text("Upravit")
                } footer: {
                    Text("Stop a cíl se kontrolují při vyhodnocení demo účtu.")
                }

                Section {
                    Button("Zavřít pozici za aktuální cenu", role: .destructive) {
                        Task {
                            await model.paper.close(p)
                            dismiss()
                        }
                    }
                    NavigationLink("Detail tickeru \(p.symbol)", value: p.symbol)
                }
            }
            .navigationTitle(p.symbol)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                stopText = p.stop.map { $0.fixed(2) } ?? ""
                targetText = p.target.map { $0.fixed(2) } ?? ""
            }
        } else {
            ContentUnavailableView("Pozice je zavřená", systemImage: "checkmark.circle",
                                   description: Text("Najdeš ji v historii demo účtu."))
        }
    }

    private func lines(_ p: PaperPosition) -> [ChartPriceLine] {
        var result = [ChartPriceLine(price: p.entryPrice, label: "Vstup " + p.entryPrice.fixed(2), color: .blue)]
        if let stop = p.stop { result.append(ChartPriceLine(price: stop, label: "Stop " + stop.fixed(2), color: .red)) }
        if let target = p.target {
            result.append(ChartPriceLine(price: target, label: "Cíl " + target.fixed(2), color: .green))
        }
        return result
    }

    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "\u{00a0}", with: "")
            .trimmingCharacters(in: .whitespaces))
    }
}
