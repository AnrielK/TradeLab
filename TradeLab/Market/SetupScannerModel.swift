import Foundation
import Observation
import MarketData
import OptionsMath
import Backtest

/// Z čeho skener vybírá tickery.
enum ScanUniverse: String, CaseIterable, Codable, Identifiable {
    case liquid = "Likvidní US"
    case watchlist = "Sledované"
    case custom = "Vlastní"

    var id: String { rawValue }
}

/// Nastavení skeneru (ukládá se).
struct ScannerSettings: Codable, Equatable {
    var universe: ScanUniverse = .liquid
    var customTickers: [String] = []
    var breakout = BreakoutSettings()
    var maBounce = MABounceSettings()
    /// Které strategie skener hledá.
    var useBreakout = true
    var useMABounce = true
    /// Ukazovat i kandidáty těsně pod rezistencí / nad supportem (zatím bez vstupu).
    var includeWatch = true
    var maxAge: Int = 3
    var allowBearish = true
    var highVolRank: Double = 50
    var daysToExpiry = 35
    var hideIlliquid = false
}

/// Likvidita opcí u peněz pro expiraci kolem `daysToExpiry`.
struct OptionLiquidity: Codable, Hashable {
    var expiration: Date
    /// Open interest ATM callu + putu.
    var atmOpenInterest: Int
    /// Průměrný spread bid/ask ATM jako zlomek mid ceny.
    var atmSpread: Double?
    var impliedVolatility: Double?

    var isLiquid: Bool {
        atmOpenInterest >= AppModel.minTemplateOpenInterest && (atmSpread ?? 1) <= 0.10
    }
}

struct ScanResult: Identifiable, Codable, Hashable {
    var hit: SetupHit
    var liquidity: OptionLiquidity?
    var id: String { hit.symbol }

    /// IV / HV – nad ~1,2 jsou opce drahé (výhodnější kredit), pod 1 levné (debet).
    var ivToHv: Double? {
        guard let iv = liquidity?.impliedVolatility, let hv = hit.historicalVolatility, hv > 0 else { return nil }
        return iv / hv
    }
}

@MainActor
@Observable
final class SetupScannerModel {
    /// Likvidní opcovatelné akcie a ETF (týdenní opce, vysoký open interest).
    static let liquidUniverse = [
        "SPY", "QQQ", "IWM", "DIA", "XLF", "XLE", "XLK", "SMH", "GLD", "SLV", "TLT",
        "AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA", "AVGO", "AMD", "NFLX",
        "CRM", "ORCL", "ADBE", "INTC", "MU", "QCOM", "ARM", "SMCI", "PLTR", "COIN", "MSTR",
        "SHOP", "UBER", "PYPL", "SNOW", "BA", "DIS", "JPM", "BAC", "GS", "WFC", "C", "V", "MA",
        "XOM", "CVX", "KO", "PEP", "WMT", "COST", "HD", "MCD", "NKE", "SBUX", "UNH", "LLY",
        "PFE", "MRK", "ABBV", "JNJ", "CAT", "DE", "GE", "F", "GM",
    ]

    var settings: ScannerSettings { didSet { save() } }
    private(set) var results: [ScanResult] = []
    private(set) var lastScan: Date? = nil
    private(set) var scannedCount = 0
    private(set) var isScanning = false
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    var errorMessage: String? = nil
    private var hidden: Set<String> = []

    private let client = YahooFinanceClient.shared
    private static let settingsKey = "scannerSettings"
    private static let resultsKey = "scannerResults"
    private static let dateKey = "scannerDate"
    private static let countKey = "scannerCount"

    init() {
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(ScannerSettings.self, from: $0) } ?? ScannerSettings()
        results = defaults.data(forKey: Self.resultsKey)
            .flatMap { try? JSONDecoder().decode([ScanResult].self, from: $0) } ?? []
        lastScan = defaults.object(forKey: Self.dateKey) as? Date
        scannedCount = defaults.integer(forKey: Self.countKey)
    }

    /// Výsledky k zobrazení (bez skrytých, volitelně bez nelikvidních).
    var visibleResults: [ScanResult] {
        results.filter { !hidden.contains($0.id) && (!settings.hideIlliquid || $0.liquidity?.isLiquid == true) }
    }

    /// Sken je starší než jeden obchodní den.
    var isStale: Bool {
        guard let lastScan else { return true }
        return Date().timeIntervalSince(lastScan) > 18 * 3600
    }

    func universe(watchlist: [String]) -> [String] {
        let list: [String]
        switch settings.universe {
        case .liquid: list = watchlist + Self.liquidUniverse
        case .watchlist: list = watchlist
        case .custom: list = settings.customTickers
        }
        var seen = Set<String>()
        return list.map { $0.uppercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func hide(_ symbol: String) { hidden.insert(symbol) }

    func scan(watchlist: [String], rate: Double) async {
        guard !isScanning else { return }
        let symbols = universe(watchlist: watchlist)
        guard !symbols.isEmpty else {
            errorMessage = "Seznam tickerů je prázdný."
            return
        }
        isScanning = true
        errorMessage = nil
        hidden = []
        progress = (0, symbols.count)
        defer { isScanning = false }

        let settings = self.settings
        let client = self.client
        var hits: [SetupHit] = []
        var failures = 0

        // Svíčky a vzory – souběžně po několika tickerech.
        await withTaskGroup(of: (SetupHit?, Bool).self) { group in
            var iterator = symbols.makeIterator()
            func addNext() {
                guard let symbol = iterator.next() else { return }
                group.addTask {
                    do {
                        let data = try await client.dailyHistory(symbol: symbol, range: .twoYears)
                        let bars = BacktestData.yahooBars(data.bars)
                        let hit = SetupScanner.scan(symbol: symbol, bars: bars,
                                                    breakout: settings.useBreakout ? settings.breakout : nil,
                                                    maBounce: settings.useMABounce ? settings.maBounce : nil,
                                                    maxAge: settings.maxAge, allowBearish: settings.allowBearish,
                                                    includeWatch: settings.includeWatch,
                                                    highVolRank: settings.highVolRank)
                        return (hit, true)
                    } catch {
                        return (nil, false)
                    }
                }
            }
            for _ in 0..<6 { addNext() }
            while let next = await group.next() {
                let (hit, ok) = next
                if let hit { hits.append(hit) }
                if !ok { failures += 1 }
                progress.done += 1
                addNext()
            }
        }

        // Likvidita opcí jen u nalezených tickerů.
        var liquidity: [String: OptionLiquidity] = [:]
        await withTaskGroup(of: (String, OptionLiquidity?).self) { group in
            for hit in hits {
                group.addTask {
                    (hit.symbol, try? await Self.liquidity(symbol: hit.symbol, days: settings.daysToExpiry,
                                                           rate: rate, client: client))
                }
            }
            for await (symbol, info) in group { liquidity[symbol] = info }
        }

        results = hits
            .map { ScanResult(hit: $0, liquidity: liquidity[$0.symbol]) }
            .sorted { a, b in
                let ea = a.hit.isEntry, eb = b.hit.isEntry
                if ea != eb { return ea }
                let la = a.liquidity?.isLiquid == true, lb = b.liquidity?.isLiquid == true
                if la != lb { return la }
                return a.hit.score > b.hit.score
            }
        lastScan = Date()
        scannedCount = symbols.count - failures
        if failures == symbols.count { errorMessage = "Nepodařilo se stáhnout data – zkontroluj připojení." }
        save()
        saveResults()
    }

    // MARK: - Opce

    /// Řetězec pro expiraci nejblíž `days` dní (aspoň 7 dní).
    nonisolated static func chain(symbol: String, days: Int, client: YahooFinanceClient) async throws -> OptionChain {
        let first = try await client.optionChain(symbol: symbol)
        let candidates = first.expirationDates.filter { OptionChain.daysToExpiry($0) >= 7 }
        guard let target = candidates.min(by: {
            abs(OptionChain.daysToExpiry($0) - Double(days)) < abs(OptionChain.daysToExpiry($1) - Double(days))
        }), target != first.expiration else { return first }
        return try await client.optionChain(symbol: symbol, expiration: target)
    }

    nonisolated static func liquidity(symbol: String, days: Int, rate: Double,
                                      client: YahooFinanceClient) async throws -> OptionLiquidity {
        let chain = try await chain(symbol: symbol, days: days, client: client)
        let spot = chain.underlyingPrice
        let strikes = Set(chain.calls.map(\.strike)).intersection(chain.puts.map(\.strike)).sorted()
        let atm = StrikeLadder.nearest(to: spot, in: strikes)
        let call = atm.flatMap { chain.contract(.call, strike: $0) }
        let put = atm.flatMap { chain.contract(.put, strike: $0) }
        let contracts = [call, put].compactMap { $0 }
        let spreads = contracts.compactMap { c -> Double? in
            guard let bid = c.bid, let ask = c.ask, ask > 0, let mid = c.mid, mid > 0 else { return nil }
            return (ask - bid) / mid
        }
        let ivs = contracts.compactMap { $0.estimatedVolatility(spot: spot, rate: rate) }
        return OptionLiquidity(
            expiration: chain.expiration,
            atmOpenInterest: contracts.reduce(0) { $0 + ($1.openInterest ?? 0) },
            atmSpread: spreads.isEmpty ? nil : spreads.reduce(0, +) / Double(spreads.count),
            impliedVolatility: ivs.isEmpty ? nil : ivs.reduce(0, +) / Double(ivs.count))
    }

    /// Navržený spread z reálných kontraktů: short noha ~30Δ, šířka ~5 % ceny, jen striky s OI ≥ 1 000.
    func buildStrategy(for result: ScanResult, rate: Double) async throws -> (OptionStrategy, Double) {
        let hit = result.hit
        let chain = try await Self.chain(symbol: hit.symbol, days: settings.daysToExpiry, client: client)
        let spot = chain.underlyingPrice
        let width = spot * 0.05
        let shortDelta = 0.30

        func strikes(_ type: OptionType) -> [Double] {
            let all = chain.contracts(type)
            let liquid = all.filter { ($0.openInterest ?? 0) >= AppModel.minTemplateOpenInterest }
            return (liquid.count >= 4 ? liquid : all).map(\.strike).sorted()
        }
        func byDelta(_ type: OptionType) -> Double? {
            let available = Set(strikes(type))
            return chain.contracts(type)
                .filter { available.contains($0.strike) }
                .compactMap { c -> (Double, Double)? in
                    guard let d = c.greeks(spot: spot, rate: rate)?.delta else { return nil }
                    return (c.strike, abs(abs(d) - shortDelta))
                }
                .min { $0.1 < $1.1 }?.0
        }
        func leg(_ type: OptionType, _ strike: Double?, _ side: PositionSide) throws -> StrategyLeg {
            guard let strike, let contract = chain.contract(type, strike: strike) else {
                throw ScanError("V řetězci \(hit.symbol) chybí vhodný strike.")
            }
            return chain.leg(for: contract, side: side, rate: rate)
        }
        func other(_ type: OptionType, from strike: Double?, offset: Double) -> Double? {
            guard let strike else { return nil }
            let list = strikes(type).filter { offset > 0 ? $0 > strike : $0 < strike }
            return StrikeLadder.nearest(to: strike + offset, in: list)
        }

        let legs: [StrategyLeg]
        switch hit.suggestedPlay {
        case .bullPutSpread:
            let short = byDelta(.put)
            legs = [try leg(.put, other(.put, from: short, offset: -width), .long), try leg(.put, short, .short)]
        case .bearCallSpread:
            let short = byDelta(.call)
            legs = [try leg(.call, short, .short), try leg(.call, other(.call, from: short, offset: width), .long)]
        case .bullCallSpread:
            let long = StrikeLadder.nearest(to: spot, in: strikes(.call))
            legs = [try leg(.call, long, .long), try leg(.call, other(.call, from: long, offset: width), .short)]
        case .bearPutSpread:
            let long = StrikeLadder.nearest(to: spot, in: strikes(.put))
            legs = [try leg(.put, other(.put, from: long, offset: -width), .short), try leg(.put, long, .long)]
        case .ironCondor:
            let sp = byDelta(.put), sc = byDelta(.call)
            legs = [try leg(.put, other(.put, from: sp, offset: -width), .long), try leg(.put, sp, .short),
                    try leg(.call, sc, .short), try leg(.call, other(.call, from: sc, offset: width), .long)]
        case .longCall:
            legs = [try leg(.call, StrikeLadder.nearest(to: spot, in: strikes(.call)), .long)]
        case .longPut:
            legs = [try leg(.put, StrikeLadder.nearest(to: spot, in: strikes(.put)), .long)]
        }
        let strategy = OptionStrategy(name: hit.suggestedPlay.name, underlying: hit.symbol, legs: legs)
        return (strategy, spot)
    }

    // MARK: - Ukládání

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private func saveResults() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(results) { defaults.set(data, forKey: Self.resultsKey) }
        defaults.set(lastScan, forKey: Self.dateKey)
        defaults.set(scannedCount, forKey: Self.countKey)
    }
}

struct ScanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
