import SwiftUI
import Backtest

/// Watchlist opčních setupů na záložce Trh (pod Sledovanými).
struct SetupWatchlistSection: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false
    @State private var opening: String? = nil

    private var scanner: SetupScannerModel { model.scanner }

    var body: some View {
        Section {
            if let error = scanner.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if scanner.isScanning {
                HStack(spacing: 10) {
                    ProgressView(value: Double(scanner.progress.done), total: Double(max(scanner.progress.total, 1)))
                    Text("\(scanner.progress.done)/\(scanner.progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if scanner.visibleResults.isEmpty && !scanner.isScanning {
                Text(scanner.lastScan == nil
                     ? "Skener projde likvidní akcie a hledá breakouty a breakdowny z konsolidace odrazy od klouzavých průměrů 20/50/100/200, trojúhelníky a trendlinie – i kandidáty, kteří na signál teprve čekají."
                     : "Žádný setup. Zkus delší stáří signálu, vypnout některý filtr nebo jiný seznam tickerů.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(scanner.visibleResults) { result in
                NavigationLink(value: result.hit.symbol) {
                    SetupRow(result: result, isOpening: opening == result.id)
                }
                .swipeActions(edge: .trailing) {
                    Button("Skrýt", systemImage: "eye.slash") { scanner.hide(result.id) }
                        .tint(.gray)
                    Button("Opce", systemImage: "list.bullet.rectangle") { open(result) }
                        .tint(.blue)
                }
                .swipeActions(edge: .leading) {
                    if !model.watchlist.contains(result.hit.symbol) {
                        Button("Sledovat", systemImage: "star") { model.addToWatchlist(result.hit.symbol) }
                            .tint(.orange)
                    }
                }
                .contextMenu {
                    Button("Otevřít \(result.hit.suggestedPlay.name) v Opcích", systemImage: "list.bullet.rectangle") {
                        open(result)
                    }
                    if !model.watchlist.contains(result.hit.symbol) {
                        Button("Přidat do Sledovaných", systemImage: "star") { model.addToWatchlist(result.hit.symbol) }
                    }
                    Button("Skrýt do příštího skenu", systemImage: "eye.slash") { scanner.hide(result.id) }
                }
            }
        } header: {
            HStack {
                Text("Watchlist · setupy")
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                Button {
                    Task { await scanner.scan(watchlist: model.watchlist, rate: model.riskFreeRate) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(scanner.isScanning)
            }
            .textCase(nil)
        } footer: {
            if let date = scanner.lastScan {
                Text("Sken \(date.formatted(date: .abbreviated, time: .shortened)) · \(scanner.scannedCount) tickerů · denní svíčky, vstup nejvýš \(scanner.settings.maxAge) sv. starý. Opční strategie podle percentilu HV: vysoká volatilita → kredit, nízká → debet. Nejde o doporučení k obchodu.")
            }
        }
        .sheet(isPresented: $showSettings) { ScannerSettingsView() }
        .task {
            if scanner.isStale && !scanner.isScanning {
                await scanner.scan(watchlist: model.watchlist, rate: model.riskFreeRate)
            }
        }
    }

    private func open(_ result: ScanResult) {
        guard opening == nil else { return }
        opening = result.id
        Task {
            defer { opening = nil }
            do {
                let (strategy, spot) = try await scanner.buildStrategy(for: result, rate: model.riskFreeRate)
                model.openAgentStrategy(strategy, spot: spot)
            } catch {
                scanner.errorMessage = "\(result.hit.symbol): \(error.localizedDescription)"
            }
        }
    }
}

struct SetupRow: View {
    let result: ScanResult
    var isOpening = false

    private var hit: SetupHit { result.hit }
    private var color: Color { hit.direction > 0 ? .green : .red }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: hit.direction > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(color)
                    Text(hit.symbol).font(.headline)
                    Text(hit.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background((hit.isEntry ? color : Color.secondary).opacity(0.15), in: Capsule())
                        .foregroundStyle(hit.isEntry ? color : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isOpening {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(hit.suggestedPlay.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(hit.suggestedPlay.isCredit ? .orange : .blue)
                            .lineLimit(1)
                    }
                }
                Text(levelsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack(spacing: 10) {
                    Text(hit.close.usd)
                    if let change = hit.changePercent {
                        Text(change.signedPercent).foregroundStyle(Color.pnl(change))
                    }
                    if let rank = hit.volatilityRank {
                        Text("HV \(Int(rank.rounded())). pct")
                    }
                    if let ratio = result.ivToHv {
                        Text("IV/HV \(ratio.fixed(2))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            if let liquidity = result.liquidity {
                VStack(spacing: 2) {
                    if liquidity.isLiquid {
                        Text("OI")
                        Text(liquidity.atmOpenInterest.formatted(.number.notation(.compactName)))
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.subheadline)
                        Text("nelikvidní")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private var levelsText: String {
        let kind = hit.levelName
        if !hit.isEntry {
            let distance = hit.distanceATR.map { " · \($0.fixed(1))× ATR" } ?? ""
            return "\(kind) \(hit.level.strikeLabel)\(distance)"
        }
        var parts = ["\(kind) \(hit.level.strikeLabel)"]
        if let stop = hit.stop { parts.append("stop \(stop.strikeLabel)") }
        if let target = hit.target { parts.append("cíl \(target.strikeLabel)") }
        parts.append(hit.barsAgo == 0 ? "dnes" : "před \(hit.barsAgo) sv.")
        return parts.joined(separator: " · ")
    }
}

struct ScannerSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var customText = ""

    var body: some View {
        @Bindable var scanner = model.scanner
        NavigationStack {
            Form {
                Section {
                    Picker("Tickery", selection: $scanner.settings.universe) {
                        ForEach(ScanUniverse.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if scanner.settings.universe == .custom {
                        TextField("AAPL, AMD, XOM…", text: $customText, axis: .vertical)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: customText) { _, text in
                                scanner.settings.customTickers = text
                                    .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                                    .map { $0.uppercased() }
                            }
                    }
                } header: {
                    Text("Co skenovat")
                } footer: {
                    Text(scanner.settings.universe == .liquid
                         ? "Sledované + \(SetupScannerModel.liquidUniverse.count) likvidních akcií a ETF s týdenními opcemi."
                         : "\(scanner.universe(watchlist: model.watchlist).count) tickerů.")
                }

                Section {
                    Toggle("Breakout / Breakdown", isOn: $scanner.settings.useBreakout)
                    Toggle("Odraz od klouzavých průměrů", isOn: $scanner.settings.useMABounce)
                    Toggle("Trendlinie a trojúhelník", isOn: $scanner.settings.useTrendline)
                    Toggle("Kandidáti (čekají na signál)", isOn: $scanner.settings.includeWatch)
                } header: {
                    Text("Strategie")
                } footer: {
                    Text("Kandidát u breakoutu = konsolidace se splněnými filtry do 1,5× ATR pod rezistencí (nad supportem). U odrazu = cena se v trendu vrací k průměru (do 1× ATR). U trendlinie = cena uvnitř trojúhelníku, nebo do 1× ATR od trendline.")
                }

                Section("Trendlinie a trojúhelník") {
                    Toggle("Průraz trojúhelníku", isOn: $scanner.settings.trendline.triangle)
                    Toggle("Odraz od trendline", isOn: $scanner.settings.trendline.bounce)
                    Toggle("Průraz trendline", isOn: $scanner.settings.trendline.breakout)
                    Toggle("Týdenní graf v trendu", isOn: $scanner.settings.trendline.weeklyFilter)
                    Toggle("Denní SMA 50 > 100 > 200", isOn: $scanner.settings.trendline.dailyFilter)
                }

                Section("Odraz od KP") {
                    Toggle("SMA 20", isOn: $scanner.settings.maBounce.ma20)
                    Toggle("SMA 50", isOn: $scanner.settings.maBounce.ma50)
                    Toggle("SMA 100", isOn: $scanner.settings.maBounce.ma100)
                    Toggle("SMA 200", isOn: $scanner.settings.maBounce.ma200)
                    Toggle("Průměr testovaný už dřív", isOn: $scanner.settings.maBounce.priorTest)
                    Toggle("20 MA: týdenní trend", isOn: $scanner.settings.maBounce.weeklyFilter)
                    Toggle("50 MA: stochastic pod 30", isOn: $scanner.settings.maBounce.stochasticFilter)
                    Toggle("Žádná rezistence před cílem", isOn: $scanner.settings.maBounce.headroom)
                }

                Section {
                    Toggle("1. Těsně před breakoutem", isOn: $scanner.settings.breakout.preBreakout)
                    Toggle("2. Po breakoutu", isOn: $scanner.settings.breakout.breakout)
                    Toggle("3. První pullback PNR", isOn: $scanner.settings.breakout.pullback)
                } header: {
                    Text("Breakout / Breakdown")
                }

                Section("Breakout – podmínky") {
                    Toggle("Týdenní graf v trendu (KP + PSAR)", isOn: $scanner.settings.breakout.weeklyFilter)
                    Toggle("Denní KP seřazeny + PSAR", isOn: $scanner.settings.breakout.dailyFilter)
                    Toggle("Konsolidace: KP 20 × 50 se kříží", isOn: $scanner.settings.breakout.requireMACross)
                    Stepper("Konsolidace z \(scanner.settings.breakout.lookback) svíček",
                            value: $scanner.settings.breakout.lookback, in: 40...250, step: 10)
                    Stepper("Volno k další hladině: \(scanner.settings.breakout.headroomATR.fixed(1))× ATR",
                            value: $scanner.settings.breakout.headroomATR, in: 0...5, step: 0.5)
                }

                Section {
                    Stepper("Vstup nejvýš \(scanner.settings.maxAge) sv. starý", value: $scanner.settings.maxAge, in: 0...10)
                    Toggle("Hledat i breakdowny (short)", isOn: $scanner.settings.allowBearish)
                    Stepper("Kredit od \(Int(scanner.settings.highVolRank)). percentilu HV",
                            value: $scanner.settings.highVolRank, in: 20...80, step: 10)
                    Stepper("Expirace ~\(scanner.settings.daysToExpiry) dní", value: $scanner.settings.daysToExpiry,
                            in: 7...90, step: 7)
                    Toggle("Skrýt nelikvidní opce", isOn: $scanner.settings.hideIlliquid)
                } header: {
                    Text("Filtr a návrh strategie")
                } footer: {
                    Text("Likvidní = open interest ATM callu a putu aspoň \(AppModel.minTemplateOpenInterest.formatted()) a spread bid/ask do 10 %. „Opce“ u řádku sestaví spread z reálných kontraktů: short noha ~30Δ, šířka ~5 % ceny.")
                }

                Section {
                    Button {
                        dismiss()
                        Task { await model.scanner.scan(watchlist: model.watchlist, rate: model.riskFreeRate) }
                    } label: {
                        Text("Skenovat teď").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                    .buttonStyle(.glassProminent)
                    .listRowBackground(Color.clear)
                    .disabled(scanner.isScanning)
                }
            }
            .navigationTitle("Skener setupů")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
            }
            .onAppear { customText = scanner.settings.customTickers.joined(separator: ", ") }
        }
    }
}
