import Foundation
import Observation
import MarketData
import Backtest

/// Nastavení živého testování strategií na demo účtu.
struct PaperSettings: Codable, Equatable {
    /// Vstupy podle strategií otevírat automaticky při vyhodnocení.
    var autoTrade = true
    var useBreakout = true
    var useMABounce = true
    var useTrendline = true
    /// Riziko na obchod (vzdálenost ke stopu) v % účtu a max. velikost pozice v % účtu.
    var riskPct = 1.0
    var maxPositionPct = 20.0
    var maxPositions = 8
    var allowShort = true
    /// Vstup nejvýš tolik svíček po signálu (aplikace nemusí být otevřená každý den).
    var maxSignalAge = 2
}

/// Demo účet: virtuálních 10 000 USD, strategie obchodují „naživo“ na denních svíčkách.
///
/// Při vyhodnocení (otevření záložky, návrat do aplikace, ručně) se pozice přecení aktuální cenou
/// a zavřou na stopu / cíli; pak se projdou tickery skeneru a čerstvé vstupy strategií se otevřou
/// za aktuální cenu se stopem a cílem strategie. Každý signál se obchoduje jen jednou.
@MainActor
@Observable
final class PaperTradingModel {
    private(set) var account: PaperAccount { didSet { save() } }
    var settings: PaperSettings { didSet { save() } }
    private(set) var lastRun: Date? = nil
    private(set) var isRunning = false
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private(set) var log: [String] = []
    var errorMessage: String? = nil

    private let client = YahooFinanceClient.shared
    private static let accountKey = "paper.account"
    private static let settingsKey = "paper.settings"
    private static let runKey = "paper.lastRun"

    init() {
        let d = UserDefaults.standard
        account = d.data(forKey: Self.accountKey).flatMap { try? JSONDecoder().decode(PaperAccount.self, from: $0) }
            ?? PaperAccount(startingCash: 10_000)
        settings = d.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(PaperSettings.self, from: $0) }
            ?? PaperSettings()
        lastRun = d.object(forKey: Self.runKey) as? Date
    }

    var isStale: Bool { lastRun.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true }

    func reset(cash: Double = 10_000) {
        account = PaperAccount(startingCash: cash)
        log = ["Účet vynulován na \(cash.usdWhole)."]
    }

    // MARK: - Ruční obchody

    /// Otevře pozici za aktuální cenu (ze skeneru nebo ručně).
    func open(symbol: String, side: Int, stop: Double?, target: Double?, source: String) async {
        do {
            let price = try await client.quote(symbol: symbol).price
            let shares = account.shares(entry: price, stop: stop, riskFraction: settings.riskPct / 100,
                                        maxFraction: settings.maxPositionPct / 100)
            guard shares > 0 else {
                errorMessage = "\(symbol): na pozici nezbývá hotovost."
                return
            }
            if account.open(symbol: symbol, side: side, shares: shares, price: price, date: Date(),
                            stop: stop, target: target, source: source) != nil {
                note("\(side > 0 ? "Long" : "Short") \(symbol) \(Int(shares)) ks za \(price.usd) · \(source)")
            }
        } catch {
            errorMessage = "\(symbol): \(error.localizedDescription)"
        }
    }

    func updateLevels(_ id: UUID, stop: Double?, target: Double?) {
        guard let i = account.positions.firstIndex(where: { $0.id == id }) else { return }
        account.positions[i].stop = stop
        account.positions[i].target = target
        note("Upraven stop / cíl \(account.positions[i].symbol)")
    }

    func close(_ position: PaperPosition) async {
        let price = (try? await client.quote(symbol: position.symbol).price) ?? position.lastPrice
        if let trade = account.close(position.id, price: price, date: Date(), reason: "ručně") {
            note("Zavřeno \(trade.symbol) za \(price.usd): \(trade.pnl.signedUSDWhole)")
        }
    }

    // MARK: - Vyhodnocení

    func runIfStale(watchlist: [String], scanner: SetupScannerModel) async {
        guard isStale, !isRunning else { return }
        await run(watchlist: watchlist, scanner: scanner)
    }

    func run(watchlist: [String], scanner: SetupScannerModel) async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        defer {
            isRunning = false
            lastRun = Date()
            UserDefaults.standard.set(lastRun, forKey: Self.runKey)
        }

        // 1) Přecenění a výstupy na stopu / cíli.
        var prices: [String: Double] = [:]
        for symbol in Set(account.positions.map(\.symbol)) {
            if let q = try? await client.quote(symbol: symbol) { prices[symbol] = q.price }
        }
        for trade in account.mark(prices: prices, date: Date()) {
            note("\(trade.reason == "cíl" ? "Cíl" : "Stop") \(trade.symbol) za \(trade.exitPrice.usd): \(trade.pnl.signedUSDWhole)")
        }

        // 2) Nové vstupy strategií.
        guard settings.autoTrade else { return }
        let symbols = scanner.universe(watchlist: watchlist)
        let s = settings
        let scan = scanner.settings
        progress = (0, symbols.count)
        let client = self.client
        var hits: [(SetupHit, Date)] = []
        await withTaskGroup(of: (SetupHit, Date)?.self) { group in
            var iterator = symbols.makeIterator()
            func addNext() {
                guard let symbol = iterator.next() else { return }
                group.addTask {
                    guard let data = try? await client.dailyHistory(symbol: symbol, range: .twoYears) else { return nil }
                    let bars = Self.completedBars(BacktestData.yahooBars(data.bars))
                    guard let hit = SetupScanner.scan(symbol: symbol, bars: bars,
                                                      breakout: s.useBreakout ? scan.breakout : nil,
                                                      maBounce: s.useMABounce ? scan.maBounce : nil,
                                                      trendline: s.useTrendline ? scan.trendline : nil,
                                                      maxAge: s.maxSignalAge, allowBearish: s.allowShort,
                                                      includeWatch: false),
                          hit.isEntry, hit.barsAgo < bars.count else { return nil }
                    return (hit, bars[bars.count - 1 - hit.barsAgo].date)
                }
            }
            for _ in 0..<6 { addNext() }
            while let next = await group.next() {
                if let next { hits.append(next) }
                progress.done += 1
                addNext()
            }
        }

        for (hit, signalDate) in hits.sorted(by: { $0.0.score > $1.0.score }) {
            guard account.positions.count < s.maxPositions else { break }
            let key = "\(hit.symbol)|\(hit.strategy.rawValue)|\(hit.direction)|\(Int(signalDate.timeIntervalSince1970))"
            guard !account.tradedSignals.contains(key),
                  !account.positions.contains(where: { $0.symbol == hit.symbol }) else { continue }
            guard let quote = try? await client.quote(symbol: hit.symbol) else { continue }
            let price = quote.price
            // Cena už prošla stopem nebo cílem → signál propadl.
            let probe = PaperPosition(symbol: hit.symbol, side: hit.direction, shares: 1, entryPrice: price,
                                      entryDate: Date(), stop: hit.stop, target: hit.target, source: "")
            guard probe.exitReason(at: price) == nil else {
                account.tradedSignals.append(key)
                continue
            }
            let shares = account.shares(entry: price, stop: hit.stop, riskFraction: s.riskPct / 100,
                                        maxFraction: s.maxPositionPct / 100)
            guard shares > 0 else { continue }
            if account.open(symbol: hit.symbol, side: hit.direction, shares: shares, price: price, date: Date(),
                            stop: hit.stop, target: hit.target, source: hit.title) != nil {
                account.tradedSignals.append(key)
                note("\(hit.direction > 0 ? "Long" : "Short") \(hit.symbol) \(Int(shares)) ks za \(price.usd) · \(hit.title)")
            }
        }
        if account.tradedSignals.count > 500 { account.tradedSignals.removeFirst(account.tradedSignals.count - 500) }
    }

    /// Jen uzavřené denní svíčky: dnešní svíčka během obchodování (do 16:00 v New Yorku) se vynechá.
    nonisolated static func completedBars(_ bars: [BacktestBar], now: Date = Date()) -> [BacktestBar] {
        guard let last = bars.last else { return bars }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let sameDay = calendar.isDate(last.date, inSameDayAs: now)
        let hour = calendar.component(.hour, from: now)
        return sameDay && hour < 16 ? Array(bars.dropLast()) : bars
    }

    private func note(_ text: String) {
        let time = Date().formatted(date: .abbreviated, time: .shortened)
        log.insert("\(time) · \(text)", at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(account) { d.set(data, forKey: Self.accountKey) }
        if let data = try? JSONEncoder().encode(settings) { d.set(data, forKey: Self.settingsKey) }
    }
}
