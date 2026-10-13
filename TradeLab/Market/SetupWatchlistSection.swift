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
                     ? "Skener projde likvidní akcie a hledá čerstvé vzory (odrazy a průrazy S/R a trendlinií, break & retest, pullbacky) vhodné pro opční spready."
                     : "Žádný čerstvý setup. Zkus delší stáří signálu nebo jiný seznam tickerů.")
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
                Text("Watchlist · opční setupy")
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
                Text("Sken \(date.formatted(date: .abbreviated, time: .shortened)) · \(scanner.scannedCount) tickerů · denní svíčky, signál nejvýš \(scanner.settings.maxAge) sv. starý. Strategie podle percentilu HV: vysoká volatilita → kredit, nízká → debet. Nejde o doporučení k obchodu.")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: hit.direction > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(color)
                Text(hit.symbol).font(.headline)
                if hit.withTrend {
                    Text("s trendem")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(color.opacity(0.15), in: Capsule())
                        .foregroundStyle(color)
                }
                Spacer()
                if isOpening {
                    ProgressView().controlSize(.small)
                } else {
                    Text(hit.suggestedPlay.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hit.suggestedPlay.isCredit ? .orange : .blue)
                }
            }
            Text(hit.patterns.map(\.name).joined(separator: " · ")
                 + (hit.barsAgo == 0 ? " · dnes" : " · před \(hit.barsAgo) sv."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Text(hit.close.usd).monospacedDigit()
                if let change = hit.changePercent {
                    Text(change.signedPercent)
                        .foregroundStyle(Color.pnl(change))
                        .monospacedDigit()
                }
                if let rank = hit.volatilityRank {
                    Text("HV \(Int(rank.rounded())). pct")
                }
                if let ratio = result.ivToHv {
                    Text("IV/HV \(ratio.fixed(2))")
                }
                Spacer()
                if let liquidity = result.liquidity {
                    if !liquidity.isLiquid {
                        Label("nelikvidní", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    } else {
                        Text("OI \(liquidity.atmOpenInterest.formatted())")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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

                Section("Vzory") {
                    ForEach(SetupPattern.allCases) { pattern in
                        Toggle(pattern.name, isOn: Binding(
                            get: { scanner.settings.patterns.contains(pattern) },
                            set: { on in
                                scanner.settings.patterns.removeAll { $0 == pattern }
                                if on { scanner.settings.patterns.append(pattern) }
                            }))
                    }
                }

                Section {
                    Stepper("Signál nejvýš \(scanner.settings.maxAge) sv. starý", value: $scanner.settings.maxAge, in: 0...10)
                    Toggle("Hledat i medvědí setupy", isOn: $scanner.settings.allowBearish)
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
