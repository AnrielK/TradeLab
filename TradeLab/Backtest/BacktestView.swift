import SwiftUI
import Charts
import Observation
import MarketData
import Backtest

enum StrategyKind: String, CaseIterable, Identifiable {
    case sma = "SMA cross"
    case macd = "MACD cross"
    case rsi = "RSI reversion"
    case breakRetest = "Break & retest"
    case reversal = "Reversal"
    case maBounce = "Odraz od průměru"
    case levelBounce = "Odraz od S/R"
    case levelBreakout = "Průraz S/R"
    case trendlineBounce = "Odraz od trendline"
    case trendlineBreakout = "Průraz trendline"
    case swingPullback = "Swing pullback (TradeLab)"
    case hold = "Buy & hold"

    /// Strategie nad supporty, rezistencemi a trendliniemi (sdílené parametry).
    var isStructure: Bool {
        [.levelBounce, .levelBreakout, .trendlineBounce, .trendlineBreakout].contains(self)
    }

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .sma: return "Long, když je rychlý SMA nad pomalým."
        case .macd: return "Long, když je MACD nad signální linkou."
        case .rsi: return "Nákup při přeprodanosti, prodej při překoupenosti."
        case .breakRetest: return "Průraz rezistence (max. high za N svíček), návrat k prolomené hladině a zavření nad ní. Stop pod hladinou, trailing výstup pod low posledních N/2 svíček."
        case .reversal: return "Po přeprodanosti (RSI) býčí obratová svíčka – zelená a zavření nad high předchozí. Stop pod swing low, výstup při překoupenosti nebo medvědí obratové svíčce."
        case .maBounce: return "V trendu (cena nad pomalým SMA, průměr roste) se cena dotkne průměru a zavře nad ním zelenou svíčkou. Výstup při zavření pod průměrem."
        case .levelBounce: return "Hladiny ze swingů posledních N svíček (aspoň 2 dotyky). Dotyk supportu a zelené zavření nad ním → long. Cíl na nejbližší rezistenci (jinak R:R), stop při zavření pod supportem."
        case .levelBreakout: return "Zavření nad rezistencí o toleranci, předchozí zavření pod ní → long. Stop při návratu pod hladinu, cíl na další rezistenci (jinak R:R)."
        case .trendlineBounce: return "Trendlinie přes swingová minima, kterou zavření neprorazilo. Dotyk linie a zelené zavření nad ní → long. Stop pod linií (posouvá se s ní), cíl R:R."
        case .trendlineBreakout: return "Zavření nad rezistenční trendlinií (přes swingová maxima) o toleranci → long. Stop při návratu pod linii, cíl R:R."
        case .swingPullback: return "Vlastní swingová strategie: v trendu (nad SMA 200, EMA 50 roste) pullback do zóny 0,382–0,786 swingu nebo k EMA 20, RSI pod 45 a otáčí, zelená svíčka nad high předchozí. Stop pod minimem pullbacku, cíl na extenzi 1,272, výstup i pod EMA 50."
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
    var kind: StrategyKind = .sma
    var smaFast = 50
    var smaSlow = 200
    var macdFast = 12
    var macdSlow = 26
    var macdSignal = 9
    var rsiPeriod = 14
    var rsiLower = 30.0
    var rsiUpper = 70.0
    var breakLookback = 20
    var retestBars = 5
    var breakTolerancePct = 1.0
    var reversalPeriod = 14
    var reversalLower = 30.0
    var reversalUpper = 70.0
    var bouncePeriod = 20
    var bounceTrend = 200
    var bounceTolerancePct = 1.0
    var bounceEMA = true
    var structureLookback = 120
    var structureTolerancePct = 0.5
    var rewardRisk = 2.0
    var pullbackTrend = 200
    var pullbackSwing = 20
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
    var creditStopMultiple = 2.0
    var debitTakeProfitPct = 100.0
    var debitStopPct = 50.0
    var optionsResult: OptionsBacktestResult? = nil
    var optionsPricing: OptionsPricing = .simulated
    var progressText: String? = nil
    var fibExit = false
    var fibLookback = 20
    var fibTarget = 1.272
    var fibStop = 0.786
    var allowShort = false
    var costBps = 5.0
    var compareSPY = true

    var result: BacktestResult? = nil
    var benchmark: [CurvePoint] = []
    var dataLabel: String = ""
    var isRunning = false
    var errorMessage: String? = nil

    var strategy: BacktestStrategy {
        switch kind {
        case .sma: return .smaCross(fast: smaFast, slow: smaSlow)
        case .macd: return .macdCross(fast: macdFast, slow: macdSlow, signal: macdSignal)
        case .rsi: return .rsiReversion(period: rsiPeriod, lower: rsiLower, upper: rsiUpper)
        case .breakRetest:
            return .breakRetest(lookback: breakLookback, retestBars: retestBars, tolerance: breakTolerancePct / 100)
        case .reversal: return .reversal(period: reversalPeriod, lower: reversalLower, upper: reversalUpper)
        case .maBounce:
            return .maBounce(period: bouncePeriod, trendPeriod: bounceTrend, tolerance: bounceTolerancePct / 100,
                             exponential: bounceEMA)
        case .levelBounce:
            return .levelBounce(lookback: structureLookback, tolerance: structureTolerancePct / 100, rewardRisk: rewardRisk)
        case .levelBreakout:
            return .levelBreakout(lookback: structureLookback, tolerance: structureTolerancePct / 100, rewardRisk: rewardRisk)
        case .trendlineBounce:
            return .trendlineBounce(lookback: structureLookback, tolerance: structureTolerancePct / 100, rewardRisk: rewardRisk)
        case .trendlineBreakout:
            return .trendlineBreakout(lookback: structureLookback, tolerance: structureTolerancePct / 100, rewardRisk: rewardRisk)
        case .swingPullback:
            return .swingPullback(trendPeriod: pullbackTrend, swingLookback: pullbackSwing)
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
            creditStop: creditStopMultiple, debitStop: debitStopPct / 100, riskFreeRate: riskFreeRate)
    }

    var exitRule: ExitRule {
        fibExit ? .fibonacci(lookback: fibLookback, target: fibTarget, stop: fibStop) : .strategy
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
                                        riskFreeRate: riskFreeRate, exit: exitRule)
            // Strukturní strategie počítají hladiny v každé svíčce – mimo hlavní vlákno.
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

    /// Ceny upravené o dividendy (poměr adjClose / close), ať výnos odpovídá skutečnosti.
    static func backtestBars(_ bars: [PriceBar]) -> [BacktestBar] {
        BacktestData.yahooBars(bars)
    }
}

struct BacktestView: View {
    @Environment(AppModel.self) private var model
    @State private var bt = BacktestModel()
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
                if let error = bt.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if bt.instrument == .options {
                    if let result = bt.optionsResult {
                        metricsSection(name: "Opce", m: result.metrics, h: result.buyAndHoldMetrics,
                                       footer: "\(result.pricing). Win rate a Ø obchod jsou vůči riziku obchodu." + (result.skippedEntries > 0 ? " Vynechané vstupy bez kotací: \(result.skippedEntries)." : ""))
                        playsSection(result)
                        equitySection(equity: result.equity, hold: result.buyAndHold)
                        drawdownSection(equity: result.equity)
                        optionTradesSection(result)
                    }
                } else if let result = bt.result {
                    metricsSection(result)
                    equitySection(result)
                    drawdownSection(result)
                    tradesSection(result)
                }
            }
            .navigationTitle("Backtest")
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

            switch bt.kind {
            case .sma:
                Stepper("Rychlý SMA: \(bt.smaFast)", value: $bt.smaFast, in: 2...200, step: 5)
                Stepper("Pomalý SMA: \(bt.smaSlow)", value: $bt.smaSlow, in: 10...400, step: 10)
            case .macd:
                Stepper("Rychlá EMA: \(bt.macdFast)", value: $bt.macdFast, in: 2...50)
                Stepper("Pomalá EMA: \(bt.macdSlow)", value: $bt.macdSlow, in: 5...100)
                Stepper("Signál: \(bt.macdSignal)", value: $bt.macdSignal, in: 2...30)
            case .rsi:
                Stepper("Perioda RSI: \(bt.rsiPeriod)", value: $bt.rsiPeriod, in: 2...50)
                Stepper("Nákup pod: \(Int(bt.rsiLower))", value: $bt.rsiLower, in: 5...50, step: 5)
                Stepper("Prodej nad: \(Int(bt.rsiUpper))", value: $bt.rsiUpper, in: 50...95, step: 5)
            case .breakRetest:
                Stepper("Hladina z \(bt.breakLookback) svíček", value: $bt.breakLookback, in: 5...200, step: 5)
                Stepper("Retest do \(bt.retestBars) svíček", value: $bt.retestBars, in: 1...30)
                Stepper("Tolerance: \(bt.breakTolerancePct.fixed(2)) %", value: $bt.breakTolerancePct, in: 0...5, step: 0.25)
            case .reversal:
                Stepper("Perioda RSI: \(bt.reversalPeriod)", value: $bt.reversalPeriod, in: 2...50)
                Stepper("Přeprodanost pod: \(Int(bt.reversalLower))", value: $bt.reversalLower, in: 5...50, step: 5)
                Stepper("Překoupenost nad: \(Int(bt.reversalUpper))", value: $bt.reversalUpper, in: 50...95, step: 5)
            case .maBounce:
                Picker("Průměr", selection: $bt.bounceEMA) {
                    Text("EMA").tag(true)
                    Text("SMA").tag(false)
                }
                .pickerStyle(.segmented)
                Stepper("Perioda průměru: \(bt.bouncePeriod)", value: $bt.bouncePeriod, in: 5...200, step: 5)
                Stepper("Trend SMA: \(bt.bounceTrend)", value: $bt.bounceTrend, in: 20...400, step: 10)
                Stepper("Tolerance: \(bt.bounceTolerancePct.fixed(2)) %", value: $bt.bounceTolerancePct, in: 0...5, step: 0.25)
            case .levelBounce, .levelBreakout, .trendlineBounce, .trendlineBreakout:
                Stepper("Struktura z \(bt.structureLookback) svíček", value: $bt.structureLookback, in: 30...400, step: 10)
                Stepper("Tolerance: \(bt.structureTolerancePct.fixed(2)) %", value: $bt.structureTolerancePct, in: 0.1...3, step: 0.1)
                Stepper("Cíl R:R \(bt.rewardRisk.fixed(1))", value: $bt.rewardRisk, in: 0.5...5, step: 0.5)
            case .swingPullback:
                Stepper("Trend SMA: \(bt.pullbackTrend)", value: $bt.pullbackTrend, in: 50...300, step: 10)
                Stepper("Swing z \(bt.pullbackSwing) svíček", value: $bt.pullbackSwing, in: 10...60, step: 5)
            case .hold:
                EmptyView()
            }

            if bt.kind != .hold {
                Toggle(bt.instrument == .options ? "Povolit medvědí strategie" : "Povolit short", isOn: $bt.allowShort)
            }

            if bt.instrument == .stock {
                Toggle("Fibonacciho výstup", isOn: $bt.fibExit.animation())
            }
            if bt.fibExit, bt.instrument == .stock {
                Stepper("Swing z \(bt.fibLookback) svíček", value: $bt.fibLookback, in: 5...200, step: 5)
                Picker("Cíl (extenze)", selection: $bt.fibTarget) {
                    Text("1.0 – předchozí extrém").tag(1.0)
                    Text("1.272").tag(1.272)
                    Text("1.618").tag(1.618)
                    Text("2.0").tag(2.0)
                }
                Picker("Stop (retracement)", selection: $bt.fibStop) {
                    Text("0.5").tag(0.5)
                    Text("0.618").tag(0.618)
                    Text("0.786").tag(0.786)
                    Text("1.0 – počátek swingu").tag(1.0)
                }
                Text("Při vstupu se vezme swing (nejvyšší high a nejnižší low) z posledních svíček. Obchod skončí na zavření nad cílem nebo pod stopem – nebo dřív, když vystoupí strategie. Po výstupu se znovu vstupuje až po novém signálu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Stepper("Kredit: cíl \(Int(bt.creditTakeProfitPct)) % max. zisku", value: $bt.creditTakeProfitPct, in: 20...100, step: 10)
            Stepper("Kredit: stop \(bt.creditStopMultiple.fixed(1))× kreditu", value: $bt.creditStopMultiple, in: 0.5...4, step: 0.5)
            Stepper("Debet: cíl +\(Int(bt.debitTakeProfitPct)) %", value: $bt.debitTakeProfitPct, in: 20...300, step: 10)
            Stepper("Debet: stop −\(Int(bt.debitStopPct)) %", value: $bt.debitStopPct, in: 20...100, step: 10)
            if bt.optionsPricing == .simulated {
                Stepper("IV = HV × \(bt.ivMultiplier.fixed(1))", value: $bt.ivMultiplier, in: 0.7...1.6, step: 0.1)
            }
        } header: {
            Text("Opční strategie")
        } footer: {
            Text("Volatilita = realizovaná volatilita 20 svíček, „vysoká“ podle percentilu za poslední rok. Výstup: cíl, stop, 7 dní před expirací nebo při změně signálu. Po stopu se čeká na nový signál.")
        }
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
                    Text("\(trade.entryDate.formatted(date: .numeric, time: .omitted)) → \(trade.exitDate?.formatted(date: .numeric, time: .omitted) ?? "otevřený") · \(trade.exitReason) · \(trade.entryPremium < 0 ? "kredit" : "debet") \(abs(trade.entryPremium).fixed(2)) · IV \(trade.impliedVol.percent) · HV rank \(Int(trade.volRank)) · RoR \(trade.returnOnRisk.signedPercent)")
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
                       footer: result.config.exit != .strategy ? result.config.title : nil)
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
