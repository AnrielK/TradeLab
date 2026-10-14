import SwiftUI
import Charts
import Observation
import MarketData
import Backtest

enum StrategyKind: String, CaseIterable, Identifiable {
    case breakout = "Breakout / Breakdown"
    case maBounce = "Odraz od klouzavých průměrů"
    case trendline = "Trendlinie a trojúhelník"
    case hold = "Buy & hold"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .breakout:
            return "Konsolidace (boční trend, aspoň 2 dotyky hladiny, KP 20 × 50 se kříží). Týdenní graf v trendu (KP 10/20/40 seřazeny, PSAR ve směru), denní KP 20/50/100 seřazeny a PSAR ve směru, daleko od další hladiny. Stop 1× ATR nebo pod předchozí svíčku, cíl Fibonacciho extenze konsolidace."
        case .maBounce:
            return "V trendu (KP seřazeny) se cena vrátí k SMA 20, 50, 100 nebo 200 a vytvoří reverzní pattern: reverzní svíčka s tělem nad průměrem a stínem skrz něj (níž než předchozí svíčky, nebo pinbar), potvrzující býčí svíčka s vyšším dnem zavře nad ní. Průměr testovaný už dřív; u 20 MA týdenní graf v trendu, u 50 MA stochastic pod 30. Stop pod reverzní svíčku (aspoň 1× ATR), cíl Fibonacciho extenze pullbacku v rozmezí 1,5–3 R. Short zrcadlově."
        case .trendline:
            return "Linie přes potvrzené swingy (aspoň 2 dotyky, zavírací ceny je nepřekročí). Průraz trojúhelníku (klesající/plochá rezistence a rostoucí/plochý support se sbíhají): čistá svíčka za linií, cíl výška trojúhelníku. Průraz trendline (klesající rezistence nahoru, rostoucí support dolů): cíl Fibonacciho extenze, aspoň 1,5 R. Odraz od rostoucí (klesající) trendline s reverzním patternem jako u odrazu od KP. Filtr týdenního grafu a denních SMA 50/100/200, stop 1× ATR nebo za předchozí / reverzní svíčku."
        case .hold: return "Koupit a držet."
        }
    }
}

/// Odkud jsou ceny opcí v opčním backtestu.
enum OptionsPricing: String, CaseIterable, Identifiable {
    case simulated = "Simulace"
    case historical = "Historická data"
    var id: String { rawValue }
}

/// Sdílený zdroj historických opčních kotací (DoltHub) s diskovou cache.
enum HistoricalOptionsData {
    static let shared = DoltHubOptionsSource(
        cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dolthub-options"))
    /// Data v databázi začínají v roce 2019.
    static let firstDay = HistoricalDay.date("2019-02-01")!
}

enum BacktestInstrument: String, CaseIterable, Identifiable {
    case stock = "Akcie"
    case options = "Opce"
    var id: String { rawValue }
}

struct CurvePoint: Identifiable {
    let date: Date
    let value: Double
    let series: String
    var id: String { series + "\(date.timeIntervalSince1970)" }
}

@MainActor
@Observable
final class BacktestModel {
    var symbol = ""
    var range: HistoryRange = .fiveYears
    var kind: StrategyKind = .breakout
    var breakout = BreakoutSettings()
    var maBounce = MABounceSettings()
    var trendline = TrendlineSettings()
    var instrument: BacktestInstrument = .stock
    var optionsAuto = true
    var neutralCondor = false
    var fixedBullish: OptionPlay = .bullCallSpread
    var fixedBearish: OptionPlay = .bearPutSpread
    var daysToExpiry = 35
    var shortDelta = 0.30
    var widthPct = 5.0
    var riskPerTradePct = 5.0
    var ivMultiplier = 1.1
    var highVolRank = 50.0
    var creditTakeProfitPct = 50.0
    /// Opce se drží přesně jako akciový obchod strategie (stop a cíl strategie).
    var followStrategy = true
    var rollBeforeExpiry = false
    var creditStopMultiple = 2.0
    var debitTakeProfitPct = 100.0
    var debitStopPct = 50.0
    var optionsResult: OptionsBacktestResult? = nil
    var optionsPricing: OptionsPricing = .simulated
    var progressText: String? = nil
    var allowShort = false
    var costBps = 5.0
    var compareSPY = true

    var result: BacktestResult? = nil
    var benchmark: [CurvePoint] = []
    /// Ticker posledního běhu (pro graf obchodů) a stav zakreslení.
    var chartSymbol: String = ""
    var chartStatus: String? = nil
    var dataLabel: String = ""
    var isRunning = false
    var errorMessage: String? = nil

    var strategy: BacktestStrategy {
        switch kind {
        case .breakout: return .breakout(breakout)
        case .maBounce: return .maBounce(maBounce)
        case .trendline: return .trendline(trendline)
        case .hold: return .buyAndHold
        }
    }

    func optionsConfig(riskFreeRate: Double) -> OptionsBacktestConfig {
        OptionsBacktestConfig(
            signal: strategy,
            selection: optionsAuto ? .auto(neutralCondor: neutralCondor)
                                   : .fixed(bullish: fixedBullish, bearish: allowShort ? fixedBearish : nil),
            allowBearish: allowShort,
            daysToExpiry: daysToExpiry, shortDelta: shortDelta, widthPct: widthPct / 100,
            ivMultiplier: ivMultiplier, highVolRank: highVolRank, riskPerTrade: riskPerTradePct / 100,
            creditTakeProfit: creditTakeProfitPct / 100, debitTakeProfit: debitTakeProfitPct / 100,
            creditStop: creditStopMultiple, debitStop: debitStopPct / 100, followStrategy: followStrategy,
            rollBeforeExpiry: rollBeforeExpiry, riskFreeRate: riskFreeRate)
    }

    func run(client: YahooFinanceClient, riskFreeRate: Double) async {
        let ticker = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ticker.isEmpty else { return }
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            let historicalOptions = instrument == .options && optionsPricing == .historical
            // Historické opční kotace jsou denní – podklad pak vždy z denních dat Yahoo.
            let source = historicalOptions ? .yahoo : BacktestSource.current
            let interval = historicalOptions ? .day : BacktestInterval.current
            let series = try await BacktestData.load(symbol: ticker, range: range, source: source,
                                                     interval: interval, client: client)
            let bars = historicalOptions ? series.bars.filter { $0.date >= HistoricalOptionsData.firstDay } : series.bars
            guard bars.count > 30 else {
                errorMessage = "Málo dat pro backtest (\(bars.count) svíček)."
                return
            }
            let config = BacktestConfig(strategy: strategy, allowShort: allowShort, costBps: costBps,
                                        riskFreeRate: riskFreeRate)
            if instrument == .options {
                let optionsConfig = self.optionsConfig(riskFreeRate: riskFreeRate)
                if historicalOptions {
                    progressText = "Stahuji historické opční kotace…"
                    defer { progressText = nil }
                    optionsResult = try await OptionsBacktest.runHistorical(
                        bars: bars, symbol: ticker, config: optionsConfig, source: HistoricalOptionsData.shared,
                        onProgress: { text in await MainActor.run { self.progressText = text } })
                } else {
                    optionsResult = await Task.detached(priority: .userInitiated) {
                        OptionsBacktest.run(bars: bars, config: optionsConfig)
                    }.value
                }
            } else {
                result = await Task.detached(priority: .userInitiated) {
                    BacktestEngine.run(bars: bars, config: config)
                }.value
            }
            dataLabel = series.label
            chartSymbol = ticker
            if UserDefaults.standard.object(forKey: BacktestTradeChart.enabledKey) as? Bool ?? true {
                await drawTrades(bars: bars, client: client)
            }

            benchmark = []
            if compareSPY, ticker != "SPY",
               let spy = try? await BacktestData.load(symbol: "SPY", range: range, source: source,
                                                      interval: interval, client: client) {
                let start = bars[0].date
                benchmark = BacktestEngine.normalized(spy.bars, from: start)
                    .map { CurvePoint(date: $0.date, value: $0.value, series: "SPY") }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Obchody posledního běhu jako kresby do grafu TVChart.
    func drawTrades(bars: [BacktestBar], client: YahooFinanceClient) async {
        let items: [BacktestTradeChart.Item]
        if instrument == .options, let r = optionsResult {
            items = r.trades.map { t in
                BacktestTradeChart.Item(side: t.play.direction == 0 ? 1 : t.play.direction, entryDate: t.entryDate,
                                        entryPrice: t.entrySpot, exitDate: t.exitDate, exitPrice: t.exitSpot,
                                        result: t.pnl.signedUSDWhole, won: t.pnl > 0,
                                        label: t.play.name + (t.isRoll ? " (přerolováno)" : ""))
            }
        } else if let r = result {
            items = r.trades.map { t in
                BacktestTradeChart.Item(side: t.side, entryDate: t.entryDate, entryPrice: t.entryPrice,
                                        exitDate: t.exitDate, exitPrice: t.exitPrice,
                                        result: t.returnPct.signedPercent, won: t.returnPct > 0, label: nil)
            }
        } else {
            return
        }
        guard !chartSymbol.isEmpty else { return }
        lastBars = bars
        do {
            let count = try await BacktestTradeChart.draw(symbol: chartSymbol, bars: bars, strategy: strategy,
                                                          allowShort: allowShort, items: items, client: client)
            chartStatus = count == 0 ? "Žádné obchody k zakreslení." : "Zakresleno obchodů: \(count)."
        } catch {
            chartStatus = "Graf obchodů se nepodařilo připravit: \(error.localizedDescription)"
        }
    }

    var lastBars: [BacktestBar] = []

    /// Ceny upravené o dividendy (poměr adjClose / close), ať výnos odpovídá skutečnosti.
    static func backtestBars(_ bars: [PriceBar]) -> [BacktestBar] {
        BacktestData.yahooBars(bars)
    }
}

struct BacktestView: View {
    @Environment(AppModel.self) private var model
    @State private var bt = BacktestModel()
    @State private var quantConnectScript: QuantConnectScript? = nil
    @AppStorage(BacktestSource.defaultsKey) private var source: BacktestSource = .yahoo
    @AppStorage(BacktestInterval.defaultsKey) private var interval: BacktestInterval = .day

    var body: some View {
        @Bindable var bt = bt
        NavigationStack {
            List {
                instrumentSection
                settingsSection
                if bt.instrument == .options { optionsSection }
                dataSection
                quantConnectSection
                if let error = bt.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if bt.instrument == .options {
                    if let result = bt.optionsResult {
                        metricsSection(name: "Opce", m: result.metrics, h: result.buyAndHoldMetrics,
                                       footer: optionsFooter(result))
                        playsSection(result)
                        equitySection(equity: result.equity, hold: result.buyAndHold)
                        drawdownSection(equity: result.equity)
                        tradeChartSection
                        optionTradesSection(result)
                    }
                } else if let result = bt.result {
                    metricsSection(result)
                    equitySection(result)
                    drawdownSection(result)
                    tradeChartSection
                    tradesSection(result)
                }
            }
            .navigationTitle("Backtest")
            .sheet(item: $quantConnectScript) { QuantConnectExportSheet(script: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { AgentToolbarButton() }
            }
            .onAppear {
                if bt.symbol.isEmpty { bt.symbol = model.optionsSymbol }
            }
        }
    }

    // MARK: - Nastavení

    private var settingsSection: some View {
        @Bindable var bt = bt
        return Section {
            LabeledContent("Ticker") {
                TextField("SPY", text: $bt.symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            Picker("Období", selection: $bt.range) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Strategie", selection: $bt.kind) {
                ForEach(StrategyKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            Text(bt.kind.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if bt.kind == .trendline {
                trendlineSettings
                Toggle(bt.instrument == .options ? "Povolit medvědí strategie (short)" : "Povolit short",
                       isOn: $bt.allowShort)
            }
            if bt.kind == .maBounce {
                maBounceSettings
                Toggle(bt.instrument == .options ? "Povolit medvědí strategie (short odrazy)" : "Povolit short (odraz dolů)",
                       isOn: $bt.allowShort)
            }
            if bt.kind == .breakout {
                breakoutSettings
                Toggle(bt.instrument == .options ? "Povolit medvědí strategie (breakdown)" : "Povolit short (breakdown)",
                       isOn: $bt.allowShort)
            }
            Stepper("Náklady: \(bt.costBps.fixed(0)) bp / obchod", value: $bt.costBps, in: 0...50, step: 1)
            Toggle("Srovnat se SPY", isOn: $bt.compareSPY)

            Button {
                Task { await bt.run(client: model.client, riskFreeRate: model.riskFreeRate) }
            } label: {
                HStack {
                    if bt.isRunning { ProgressView().controlSize(.small) }
                    Text(bt.isRunning ? (bt.progressText ?? "Počítám…") : "Spustit backtest")
                        .lineLimit(1)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(bt.isRunning || bt.symbol.isEmpty)
            .listRowBackground(Color.clear)
        } header: {
            Text("Nastavení")
        } footer: {
            Text("Signál se počítá ze zavírací ceny svíčky a obchod proběhne za otevírací cenu další svíčky.")
        }
    }

    @ViewBuilder
    private var trendlineSettings: some View {
        @Bindable var bt = bt
        Toggle("Průraz trojúhelníku", isOn: $bt.trendline.triangle)
        Toggle("Odraz od trendline", isOn: $bt.trendline.bounce)
        Toggle("Průraz trendline", isOn: $bt.trendline.breakout)
        Stepper("Linie ze swingů \(bt.trendline.lookback) svíček", value: $bt.trendline.lookback, in: 40...250, step: 10)
        Stepper("Dotyky linie: aspoň \(bt.trendline.minTouches)", value: $bt.trendline.minTouches, in: 2...5)
        Stepper("Tolerance: \((bt.trendline.tolerance * 100).fixed(2)) %", value: $bt.trendline.tolerance,
                in: 0.0025...0.03, step: 0.0025)
        Toggle("Týdenní graf v trendu (KP + PSAR)", isOn: $bt.trendline.weeklyFilter)
        Toggle("Denní SMA 50 > 100 > 200 ve směru", isOn: $bt.trendline.dailyFilter)
        Toggle("Odraz: žádná rezistence před cílem", isOn: $bt.trendline.headroom)
        Stepper("Stop aspoň \(bt.trendline.stopATR.fixed(1))× ATR", value: $bt.trendline.stopATR, in: 0.5...2, step: 0.25)
        Picker("Cíl (Fibonacci)", selection: $bt.trendline.targetFib) {
            Text("127,2 %").tag(1.272)
            Text("161,8 %").tag(1.618)
        }
        Stepper("Cíl nejméně \(bt.trendline.minRR.fixed(1)) R", value: $bt.trendline.minRR, in: 1...3, step: 0.5)
    }

    @ViewBuilder
    private var maBounceSettings: some View {
        @Bindable var bt = bt
        Toggle("SMA 20 (20 > 50 > 100 > 200, týdenní trend)", isOn: $bt.maBounce.ma20)
        Toggle("SMA 50 (20 > 50 > 100 > 200, stochastic)", isOn: $bt.maBounce.ma50)
        Toggle("SMA 100 (50 > 100 > 200)", isOn: $bt.maBounce.ma100)
        Toggle("SMA 200 (100 > 200)", isOn: $bt.maBounce.ma200)
        Toggle("2svíčkový reverzní pattern", isOn: $bt.maBounce.twoCandle)
        Toggle("1svíčkový pattern (pinbar)", isOn: $bt.maBounce.oneCandle)
        Toggle("Průměr testovaný už dřív", isOn: $bt.maBounce.priorTest)
        if bt.maBounce.priorTest {
            Stepper("Předchozí test do \(bt.maBounce.priorBars) svíček", value: $bt.maBounce.priorBars, in: 20...200, step: 10)
        }
        Toggle("20 MA: týdenní cena nad 10 MA, KP rostou", isOn: $bt.maBounce.weeklyFilter)
        Toggle("50 MA: stochastic pod 30 (short nad 70)", isOn: $bt.maBounce.stochasticFilter)
        Toggle("Žádná rezistence před cílem", isOn: $bt.maBounce.headroom)
        Stepper("Stop: pod reverzní svíčku, aspoň \(bt.maBounce.stopATR.fixed(1))× ATR", value: $bt.maBounce.stopATR,
                in: 0.5...2, step: 0.25)
        Picker("Cíl (Fibonacciho extenze)", selection: $bt.maBounce.targetFib) {
            Text("127,2 %").tag(1.272)
            Text("161,8 %").tag(1.618)
        }
        Stepper("Cíl nejméně \(bt.maBounce.minRR.fixed(1)) R", value: $bt.maBounce.minRR, in: 1...3, step: 0.5)
        Stepper("Cíl nejvýš \(bt.maBounce.maxRR.fixed(1)) R", value: $bt.maBounce.maxRR, in: 1.5...6, step: 0.5)
    }

    @ViewBuilder
    private var breakoutSettings: some View {
        @Bindable var bt = bt
        Toggle("1. Těsně před breakoutem (jen u absolutního vrcholu)", isOn: $bt.breakout.preBreakout)
        Toggle("2. Po breakoutu (čistá svíčka nad hladinou)", isOn: $bt.breakout.breakout)
        Toggle("3. První pullback PNR", isOn: $bt.breakout.pullback)
        Stepper("Konsolidace z \(bt.breakout.lookback) svíček", value: $bt.breakout.lookback, in: 40...250, step: 10)
        Stepper("Dotyky hladiny: aspoň \(bt.breakout.minTouches)", value: $bt.breakout.minTouches, in: 1...5)
        Stepper("Tolerance dotyku: \((bt.breakout.tolerance * 100).fixed(2)) %", value: $bt.breakout.tolerance,
                in: 0.0025...0.03, step: 0.0025)
        Toggle("Týdenní graf v trendu (KP + PSAR)", isOn: $bt.breakout.weeklyFilter)
        Toggle("Denní KP seřazeny + PSAR", isOn: $bt.breakout.dailyFilter)
        Toggle("Konsolidace: KP 20 × 50 se kříží", isOn: $bt.breakout.requireMACross)
        Stepper("Volno k další hladině: \(bt.breakout.headroomATR.fixed(1))× ATR", value: $bt.breakout.headroomATR,
                in: 0...5, step: 0.5)
        Stepper("Stop: \(bt.breakout.stopATR.fixed(1))× ATR nebo předchozí svíčka", value: $bt.breakout.stopATR,
                in: 0.5...3, step: 0.5)
        Picker("Cíl (Fibonacci)", selection: $bt.breakout.targetFib) {
            Text("127,2 %").tag(1.272)
            Text("161,8 %").tag(1.618)
        }
        Stepper("Pullback do \(bt.breakout.pullbackBars) svíček po průrazu", value: $bt.breakout.pullbackBars,
                in: 5...40, step: 5)
    }

    private var quantConnectSection: some View {
        Section {
            Button {
                let instrument: QuantConnectExport.Instrument = bt.instrument == .options ? .options : .stock
                let text = QuantConnectExport.script(
                    instrument: instrument, ticker: bt.symbol, range: bt.range, strategy: bt.strategy,
                    allowShort: bt.allowShort, costBps: bt.costBps,
                    options: bt.instrument == .options ? bt.optionsConfig(riskFreeRate: 0.04) : nil)
                quantConnectScript = QuantConnectScript(
                    text: text, fileName: QuantConnectExport.fileName(ticker: bt.symbol, instrument: instrument),
                    isOptions: instrument == .options)
            } label: {
                Label("Export pro QuantConnect", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(bt.symbol.isEmpty)
        } footer: {
            Text("Vygeneruje Python skript (LEAN) s aktuální strategií a nastavením k ověření na datech QuantConnectu – stačí free plán a webový editor.")
        }
    }

    private var instrumentSection: some View {
        @Bindable var bt = bt
        return Section {
            Picker("Obchodovat", selection: $bt.instrument) {
                ForEach(BacktestInstrument.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(bt.instrument == .stock
                 ? "Strategie obchoduje přímo podklad."
                 : "Strategie dává jen směr (long / short / bez signálu) a podle situace se otevře opční strategie. Ceny opcí se simulují – historické kotace opcí nejsou volně dostupné.")
        }
    }

    private var optionsSection: some View {
        @Bindable var bt = bt
        return Section {
            Picker("Ceny opcí", selection: $bt.optionsPricing) {
                ForEach(OptionsPricing.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(bt.optionsPricing == .simulated
                 ? "Black-Scholes s IV z historické volatility – rychlé, libovolné období i interval."
                 : "Skutečné kotace konce dne z veřejné databáze DoltHub (od 2019, denní data). Vstup a výstup za mid ± polovinu spreadu, vysoká volatilita podle IV ranku. První běh stahuje data déle, pak se berou z cache.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Výběr strategie", selection: $bt.optionsAuto) {
                Text("Podle situace").tag(true)
                Text("Pevně").tag(false)
            }
            .pickerStyle(.segmented)
            if bt.optionsAuto {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Býčí signál: vysoká volatilita → **bull put spread** (kredit), nízká → **bull call spread** (debet).")
                    Text("Medvědí signál (s povoleným short): vysoká → **bear call spread**, nízká → **bear put spread**.")
                    Text("Bez signálu: volitelně **iron condor** při vysoké volatilitě.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle("Iron condor bez signálu", isOn: $bt.neutralCondor)
                Stepper("Vysoká volatilita od \(Int(bt.highVolRank)). percentilu", value: $bt.highVolRank, in: 20...80, step: 10)
            } else {
                Picker("Býčí signál", selection: $bt.fixedBullish) {
                    ForEach(OptionPlay.allCases.filter { $0.direction == 1 }, id: \.self) { Text($0.name).tag($0) }
                }
                Picker("Medvědí signál", selection: $bt.fixedBearish) {
                    ForEach(OptionPlay.allCases.filter { $0.direction == -1 }, id: \.self) { Text($0.name).tag($0) }
                }
                .disabled(!bt.allowShort)
            }
            Stepper("Expirace: \(bt.daysToExpiry) dní", value: $bt.daysToExpiry, in: 7...120, step: 7)
            Stepper("Short noha: \(Int(bt.shortDelta * 100))Δ", value: $bt.shortDelta, in: 0.10...0.45, step: 0.05)
            Stepper("Šířka spreadu: \(bt.widthPct.fixed(1)) % ceny", value: $bt.widthPct, in: 1...15, step: 0.5)
            Stepper("Riziko na obchod: \(bt.riskPerTradePct.fixed(0)) % kapitálu", value: $bt.riskPerTradePct, in: 1...20, step: 1)
            Toggle("Výstup podle strategie (stop a cíl strategie)", isOn: $bt.followStrategy)
            if bt.followStrategy {
                Toggle("Přerolovat před expirací", isOn: $bt.rollBeforeExpiry)
            }
            if !bt.followStrategy {
                Stepper("Kredit: cíl \(Int(bt.creditTakeProfitPct)) % max. zisku", value: $bt.creditTakeProfitPct, in: 20...100, step: 10)
                Stepper("Kredit: stop \(bt.creditStopMultiple.fixed(1))× kreditu", value: $bt.creditStopMultiple, in: 0.5...4, step: 0.5)
                Stepper("Debet: cíl +\(Int(bt.debitTakeProfitPct)) %", value: $bt.debitTakeProfitPct, in: 20...300, step: 10)
                Stepper("Debet: stop −\(Int(bt.debitStopPct)) %", value: $bt.debitStopPct, in: 20...100, step: 10)
            }
            if bt.optionsPricing == .simulated {
                Stepper("IV = HV × \(bt.ivMultiplier.fixed(1))", value: $bt.ivMultiplier, in: 0.7...1.6, step: 0.1)
            }
        } header: {
            Text("Opční strategie")
        } footer: {
            Text(bt.followStrategy
                 ? "Opce kopírují obchody strategie: otevřou se při vstupu a zavřou při výstupu strategie (její stop nebo cíl), stejně jako akcie. Každý signál se obchoduje jen jednou – když se pozice zavře dřív (7 dní před expirací), do trvajícího signálu se znovu nevstupuje; zapnuté přerolování ji místo toho přesune do nové expirace. Volatilita = realizovaná volatilita 20 svíček, „vysoká“ podle percentilu za poslední rok."
                 : "Vlastní výstup opcí: cíl a stop na prémii, 7 dní před expirací nebo při výstupu strategie. Každý signál se obchoduje jen jednou – po zavření se do trvajícího signálu znovu nevstupuje. Volatilita = realizovaná volatilita 20 svíček, „vysoká“ podle percentilu za poslední rok.")
        }
    }

    @AppStorage(BacktestTradeChart.enabledKey) private var drawTradesInChart = true

    private var tradeChartSection: some View {
        Section {
            Toggle("Zakreslit obchody do grafu", isOn: $drawTradesInChart)
            if !bt.chartSymbol.isEmpty {
                EmbeddedTVChart(symbol: bt.chartSymbol)
                    .id(bt.chartSymbol)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        } header: {
            Text("Graf obchodů")
        } footer: {
            Text((bt.chartStatus.map { $0 + " " } ?? "") + "Zelená zóna vstup → cíl, červená vstup → stop, čárkovaně cesta k výstupu; ▲/▼ otevření, ✕ zavření s výsledkem. Linie strategie (hladina, trendline, průměr) ke každému vstupu. Kresby jsou i ve velkém grafu a nahradí se dalším backtestem.")
        }
        .onChange(of: drawTradesInChart) { _, on in
            Task {
                if on {
                    await bt.drawTrades(bars: bt.lastBars, client: model.client)
                } else {
                    await BacktestTradeChart.clear(symbol: bt.chartSymbol)
                    bt.chartStatus = nil
                }
            }
        }
    }

    private func optionsFooter(_ result: OptionsBacktestResult) -> String {
        var text = "\(result.pricing). Obchody strategie: \(result.strategyTradeCount)"
        if result.rollCount > 0 { text += " (+ \(result.rollCount) přerolování před expirací)" }
        text += ". Win rate a Ø obchod jsou vůči riziku opčního obchodu (max. ztráta \(bt.riskPerTradePct.fixed(0)) % kapitálu), "
        text += "akcie obchodují celým kapitálem – výnos se proto liší, i když jsou vstupy a výstupy stejné."
        if result.skippedEntries > 0 { text += " Vynechané vstupy bez kotací: \(result.skippedEntries)." }
        return text
    }

    private func playsSection(_ result: OptionsBacktestResult) -> some View {
        Section {
            ForEach(result.playCounts) { item in
                HStack {
                    Text(item.play.name)
                    Spacer()
                    Text("\(item.count)×").foregroundStyle(.secondary)
                    Text(item.pnl.signedUSDWhole)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.pnl(item.pnl))
                        .frame(minWidth: 80, alignment: .trailing)
                }
                .font(.footnote)
                .monospacedDigit()
            }
        } header: {
            Text("Zvolené opční strategie")
        }
    }

    private func optionTradesSection(_ result: OptionsBacktestResult) -> some View {
        Section {
            if result.trades.isEmpty {
                Text("Žádné obchody").foregroundStyle(.secondary)
            }
            ForEach(result.trades.suffix(40).reversed()) { trade in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(trade.play.name)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(trade.play.direction >= 0 ? (trade.play.direction == 0 ? Color.purple : ChainTheme.long) : ChainTheme.short,
                                        in: Capsule())
                        Text(trade.legsText).font(.caption.monospaced())
                        Spacer()
                        Text(trade.pnl.signedUSDWhole)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.pnl(trade.pnl))
                    }
                    Text((trade.isRoll ? "přerolováno · " : "") + "\(trade.entryDate.formatted(date: .numeric, time: .omitted)) → \(trade.exitDate?.formatted(date: .numeric, time: .omitted) ?? "otevřený") · \(trade.exitReason) · \(trade.entryPremium < 0 ? "kredit" : "debet") \(abs(trade.entryPremium).fixed(2)) · IV \(trade.impliedVol.percent) · HV rank \(Int(trade.volRank)) · RoR \(trade.returnOnRisk.signedPercent)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
        } header: {
            Text("Opční obchody (posledních \(min(result.trades.count, 40)) z \(result.trades.count))")
        }
    }

    private var dataSection: some View {
        Section {
            Picker("Zdroj dat", selection: $source) {
                ForEach(BacktestSource.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if source == .tradingView {
                Picker("Interval", selection: $interval) {
                    ForEach(BacktestInterval.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if !bt.dataLabel.isEmpty, bt.result != nil || bt.optionsResult != nil {
                Text("Poslední běh: \(bt.dataLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Data")
        } footer: {
            Text(source == .yahoo
                 ? "Yahoo Finance: denní svíčky upravené o dividendy."
                 : "TradingView (nepřihlášený přístup): svíčky 1D, 1W, 4H nebo 1H, upravené o dividendy, když to server dovolí, jinak jen o splity. U hodinových dat je historie kratší (limit počtu svíček). Platí i pro backtesty agenta.")
        }
    }

    // MARK: - Výsledky

    private func metricsSection(_ result: BacktestResult) -> some View {
        metricsSection(name: result.config.strategy.name, m: result.metrics, h: result.buyAndHoldMetrics,
                       footer: nil)
    }

    private func metricsSection(name: String, m: BacktestMetrics, h: BacktestMetrics, footer: String?) -> some View {
        return Section {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text(name).font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                    Text("Buy & hold").font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                metricRow("Celkový výnos", m.totalReturn.signedPercent, h.totalReturn.signedPercent, m.totalReturn - h.totalReturn)
                metricRow("CAGR", m.cagr.signedPercent, h.cagr.signedPercent, m.cagr - h.cagr)
                metricRow("Max. drawdown", m.maxDrawdown.percent, h.maxDrawdown.percent, m.maxDrawdown - h.maxDrawdown)
                metricRow("Sharpe", m.sharpe.fixed(2), h.sharpe.fixed(2), m.sharpe - h.sharpe)
                metricRow("Sortino", m.sortino.fixed(2), h.sortino.fixed(2), m.sortino - h.sortino)
                metricRow("Volatilita", m.volatility.percent, h.volatility.percent, h.volatility - m.volatility)
                metricRow("Calmar", m.calmar.fixed(2), h.calmar.fixed(2), m.calmar - h.calmar)
                metricRow("Expozice", m.exposure.percent, h.exposure.percent, nil)
                metricRow("Obchody", "\(m.tradeCount)", "\(h.tradeCount)", nil)
                metricRow("Win rate", m.winRate.map { $0.percent } ?? "–", "–", nil)
                metricRow("Ø obchod", m.averageTrade.map { $0.signedPercent } ?? "–", "–", nil)
            }
            .font(.footnote)
            .monospacedDigit()
        } header: {
            Text("Metriky")
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    private func metricRow(_ title: String, _ strategy: String, _ hold: String, _ edge: Double?) -> GridRow<some View> {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(strategy)
                .fontWeight(.semibold)
                .foregroundStyle(edge.map { $0 > 0 ? Color.green : ($0 < 0 ? Color.red : Color.primary) } ?? Color.primary)
            Text(hold).foregroundStyle(.secondary)
        }
    }

    private func equitySection(_ result: BacktestResult) -> some View {
        equitySection(equity: result.equity, hold: result.buyAndHold)
    }

    private func equitySection(equity: [EquityPoint], hold: [EquityPoint]) -> some View {
        let start = equity.first?.equity ?? 1
        let holdStart = hold.first?.equity ?? 1
        let strategyCurve = equity.map { CurvePoint(date: $0.date, value: $0.equity / start * 100, series: "Strategie") }
        let holdCurve = hold.map { CurvePoint(date: $0.date, value: $0.equity / holdStart * 100, series: "Buy & hold") }
        let all = strategyCurve + holdCurve + bt.benchmark
        return Section {
            Chart(all) { point in
                LineMark(
                    x: .value("Datum", point.date),
                    y: .value("Hodnota", point.value),
                    series: .value("Řada", point.series)
                )
                .foregroundStyle(by: .value("Řada", point.series))
                .lineStyle(StrokeStyle(lineWidth: point.series == "Strategie" ? 2 : 1.2))
            }
            .chartForegroundStyleScale([
                "Strategie": Color.orange,
                "Buy & hold": Color.blue,
                "SPY": Color.gray,
            ])
            .chartYScale(type: .log)
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 240)
        } header: {
            Text("Kapitál (start = 100, log. osa)")
        }
    }

    private func drawdownSection(_ result: BacktestResult) -> some View {
        drawdownSection(equity: result.equity)
    }

    private func drawdownSection(equity: [EquityPoint]) -> some View {
        Section {
            Chart(equity, id: \.date) { point in
                AreaMark(
                    x: .value("Datum", point.date),
                    yStart: .value("Nula", 0.0),
                    yEnd: .value("Drawdown", point.drawdown * 100)
                )
                .foregroundStyle(Color.red.opacity(0.35))
            }
            .chartYAxisLabel("%")
            .frame(height: 140)
        } header: {
            Text("Drawdown strategie")
        }
    }

    private func tradesSection(_ result: BacktestResult) -> some View {
        Section {
            if result.trades.isEmpty {
                Text("Žádné obchody").foregroundStyle(.secondary)
            }
            ForEach(result.trades.suffix(40).reversed()) { trade in
                HStack {
                    Text(trade.side > 0 ? "LONG" : "SHORT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(trade.side > 0 ? ChainTheme.long : ChainTheme.short, in: Capsule())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(trade.entryDate.formatted(date: .numeric, time: .omitted)) → \(trade.exitDate?.formatted(date: .numeric, time: .omitted) ?? "otevřený")")
                            .font(.caption)
                        Text("\(trade.entryPrice.fixed(2)) → \(trade.exitPrice.fixed(2))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(trade.returnPct.signedPercent)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.pnl(trade.returnPct))
                }
                .monospacedDigit()
            }
        } header: {
            Text("Obchody (posledních \(min(result.trades.count, 40)) z \(result.trades.count))")
        }
    }
}
