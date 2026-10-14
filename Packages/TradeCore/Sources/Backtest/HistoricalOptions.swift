import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OptionsMath

/// Kotace jednoho kontraktu na konci dne.
public struct HistoricalOptionQuote: Hashable, Sendable {
    public var date: String          // yyyy-MM-dd
    public var expiration: String    // yyyy-MM-dd
    public var strike: Double
    public var type: OptionType
    public var bid: Double
    public var ask: Double
    public var iv: Double?
    public var delta: Double?

    public init(date: String, expiration: String, strike: Double, type: OptionType, bid: Double, ask: Double,
                iv: Double? = nil, delta: Double? = nil) {
        self.date = date
        self.expiration = expiration
        self.strike = strike
        self.type = type
        self.bid = bid
        self.ask = ask
        self.iv = iv
        self.delta = delta
    }

    public var mid: Double { (bid + ask) / 2 }
    public var halfSpread: Double { max(ask - bid, 0) / 2 }
    var key: String { HistoricalOptionQuote.makeKey(type, strike) }
    static func makeKey(_ type: OptionType, _ strike: Double) -> String { "\(type.rawValue)\(strike)" }
}

/// Zdroj historických opčních řetězců.
public protocol HistoricalOptionsSource: Sendable {
    /// Řetězec (všechny expirace, striky v rozsahu) v prvním dni z `candidates` (od nejnovějšího),
    /// pro který má zdroj data – jeden dotaz na den.
    func chain(symbol: String, candidates: [String], minStrike: Double, maxStrike: Double) async throws
        -> (date: String, quotes: [HistoricalOptionQuote])?
    /// Kotace vybraných kontraktů jedné expirace v zadaných dnech.
    func history(symbol: String, expiration: String, strikes: [Double], days: [String]) async throws
        -> [HistoricalOptionQuote]
    /// IV rank (0–100) po dnech, pokud ho zdroj má.
    func ivRank(symbol: String, days: [String]) async throws -> [String: Double]
}

public enum HistoricalDay {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func string(_ date: Date) -> String { formatter.string(from: date) }
    public static func date(_ string: String) -> Date? { formatter.date(from: string) }
    public static func adding(_ days: Int, to day: String) -> String {
        guard let date = date(day) else { return day }
        return string(date.addingTimeInterval(Double(days) * 86_400))
    }
    public static func days(from a: String, to b: String) -> Double {
        guard let x = date(a), let y = date(b) else { return 0 }
        return y.timeIntervalSince(x) / 86_400
    }
}

// MARK: - DoltHub

/// Veřejná databáze `post-no-preference/options` na DoltHubu (EOD řetězce US akcií od 2019, bez klíče).
public actor DoltHubOptionsSource: HistoricalOptionsSource {
    public static let base = "https://www.dolthub.com/api/v1alpha1/post-no-preference/options/master"

    private let session: URLSession
    private let cacheDirectory: URL?
    private var memory: [String: [[String: Any]]] = [:]
    public private(set) var requestCount = 0

    public init(cacheDirectory: URL? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config)
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Řádky odpovědi `{"query_execution_status":"Success","rows":[{…}]}`.
    static func parseRows(_ data: Data) throws -> [[String: Any]] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HistoricalOptionsError.badResponse("neplatný JSON")
        }
        let status = json["query_execution_status"] as? String ?? ""
        guard status == "Success" || status == "RowLimit" else {
            let message = json["query_execution_message"] as? String ?? status
            throw HistoricalOptionsError.badResponse(message)
        }
        return json["rows"] as? [[String: Any]] ?? []
    }

    static func parseQuote(_ row: [String: Any]) -> HistoricalOptionQuote? {
        guard let date = row["date"] as? String,
              let expiration = row["expiration"] as? String,
              let strike = number(row["strike"]),
              let cp = (row["call_put"] as? String)?.lowercased(),
              let bid = number(row["bid"]), let ask = number(row["ask"]), ask > 0 else { return nil }
        let type: OptionType = cp.hasPrefix("c") ? .call : .put
        return HistoricalOptionQuote(date: date, expiration: expiration, strike: strike, type: type,
                                     bid: max(bid, 0), ask: ask, iv: number(row["vol"]), delta: number(row["delta"]))
    }

    func query(_ sql: String) async throws -> [[String: Any]] {
        if let cached = memory[sql] { return cached }
        let file = cacheDirectory?.appendingPathComponent(Self.hash(sql) + ".json")
        if let file, let data = try? Data(contentsOf: file), let rows = try? Self.parseRows(data) {
            memory[sql] = rows
            return rows
        }
        var components = URLComponents(string: Self.base)!
        components.queryItems = [URLQueryItem(name: "q", value: sql)]
        guard let url = components.url else { throw HistoricalOptionsError.badResponse("URL") }

        var lastError: Error = HistoricalOptionsError.badResponse("bez odpovědi")
        for attempt in 0..<3 {
            try Task.checkCancellation()
            requestCount += 1
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    let rows = try Self.parseRows(data)
                    memory[sql] = rows
                    if let file { try? data.write(to: file, options: .atomic) }
                    return rows
                }
                lastError = HistoricalOptionsError.badResponse("HTTP \(status)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
        }
        throw lastError
    }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // Primární klíč tabulek začíná datem – dotazy proto vždy na konkrétní dny (date = / date IN),
    // rozsah dat přes všechny tickery server nestihne („context deadline exceeded“).

    static func dayList(_ days: [String]) -> String {
        days.map(quote).joined(separator: ",")
    }

    public func chain(symbol: String, candidates: [String], minStrike: Double, maxStrike: Double) async throws
        -> (date: String, quotes: [HistoricalOptionQuote])? {
        for day in candidates {
            let rows = try await query("""
                SELECT date, expiration, strike, call_put, bid, ask, vol, delta FROM option_chain \
                WHERE date=\(Self.quote(day)) AND act_symbol=\(Self.quote(symbol.uppercased())) \
                AND strike BETWEEN \(String(format: "%.2f", minStrike)) AND \(String(format: "%.2f", maxStrike))
                """)
            let quotes = rows.compactMap(Self.parseQuote)
            if !quotes.isEmpty { return (day, quotes) }
        }
        return nil
    }

    public func history(symbol: String, expiration: String, strikes: [Double], days: [String]) async throws
        -> [HistoricalOptionQuote] {
        let list = Set(strikes).sorted().map { String(format: "%.2f", $0) }.joined(separator: ",")
        let s = Self.quote(symbol.uppercased())
        let queries = Self.chunks(days, size: 25).map { chunk in
            """
            SELECT date, expiration, strike, call_put, bid, ask, vol, delta FROM option_chain \
            WHERE date IN (\(Self.dayList(chunk))) AND act_symbol=\(s) \
            AND expiration=\(Self.quote(expiration)) AND strike IN (\(list))
            """
        }
        return try await concurrentRows(queries).compactMap(Self.parseQuote)
    }

    static func chunks(_ days: [String], size: Int) -> [[String]] {
        stride(from: 0, to: days.count, by: size).map { Array(days[$0..<min($0 + size, days.count)]) }
    }

    /// Víc dotazů najednou (nejvýš 4 souběžně), výsledky spojené.
    func concurrentRows(_ queries: [String]) async throws -> [[String: Any]] {
        if queries.isEmpty { return [] }
        if queries.count == 1 { return try await query(queries[0]) }
        var all: [[String: Any]] = []
        for batch in stride(from: 0, to: queries.count, by: 4).map({ Array(queries[$0..<min($0 + 4, queries.count)]) }) {
            let results = try await withThrowingTaskGroup(of: Int.self) { group -> Int in
                for sql in batch {
                    group.addTask { _ = try await self.query(sql); return 0 }
                }
                return try await group.reduce(0, +)
            }
            _ = results
            for sql in batch { all += memory[sql] ?? [] }
        }
        return all
    }

    public func ivRank(symbol: String, days: [String]) async throws -> [String: Double] {
        let s = Self.quote(symbol.uppercased())
        let queries = Self.chunks(days, size: 40).map { chunk in
            """
            SELECT date, iv_current, iv_year_high, iv_year_low FROM volatility_history \
            WHERE date IN (\(Self.dayList(chunk))) AND act_symbol=\(s)
            """
        }
        var result: [String: Double] = [:]
        for row in try await concurrentRows(queries) {
            guard let day = row["date"] as? String, let iv = Self.number(row["iv_current"]),
                  let high = Self.number(row["iv_year_high"]), let low = Self.number(row["iv_year_low"]),
                  high > low else { continue }
            result[day] = min(max((iv - low) / (high - low) * 100, 0), 100)
        }
        return result
    }
}

public enum HistoricalOptionsError: Error, LocalizedError {
    case badResponse(String)
    case noData(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let m): return "Historická opční data: \(m)"
        case .noData(let m): return m
        }
    }
}

// MARK: - Backtest nad historickými kotacemi

extension OptionsBacktest {
    struct HistoricalPosition {
        var play: OptionPlay
        var legs: [OptionLegSpec]
        var expiration: String
        var entryDate: Date
        var entrySpot: Double
        var entryPremium: Double
        var contracts: Double
        var maxLossPerShare: Double
        var equityAtEntry: Double
        var entryCosts: Double
        var signal: Int
        var iv: Double
        var rank: Double
        var isRoll = false
        /// Kotace nohou po dnech.
        var quotes: [String: [String: HistoricalOptionQuote]]
        var lastQuotes: [String: HistoricalOptionQuote]
    }

    /// Backtest se skutečnými historickými kotacemi (EOD) místo Black-Scholes.
    ///
    /// Vstup i výstup za kotace konce dne: nákup za mid + `spreadFill` × polovina spreadu, prodej za mid − totéž
    /// (0 = mid, 1 = bid/ask). Přecenění na mid. Strategie se vybírá stejně jako v simulaci; „vysoká volatilita“
    /// podle IV ranku zdroje (jinak HV rank).
    public static func runHistorical(bars: [BacktestBar], symbol: String, config: OptionsBacktestConfig,
                                     source: HistoricalOptionsSource, spreadFill: Double = 0.5,
                                     onProgress: (@Sendable (String) async -> Void)? = nil) async throws
        -> OptionsBacktestResult {
        let n = bars.count
        let hold = BacktestEngine.run(bars: bars, config: BacktestConfig(strategy: .buyAndHold, costBps: 0,
                                                                       riskFreeRate: config.riskFreeRate,
                                                                       initialCapital: config.initialCapital))
        guard n > 30, let first = bars.first, let last = bars.last else {
            throw HistoricalOptionsError.noData("Málo dat podkladu.")
        }

        let signals = config.signal.targets(bars: bars, allowShort: config.allowBearish)
        let years = max(last.date.timeIntervalSince(first.date) / (365.25 * 86_400), 1 / 365)
        let hv = rollingVolatility(bars.map(\.close), window: 20, periodsPerYear: Double(n) / years)
        let rankWindow = max(Int((Double(n) / years).rounded()), 20)
        await onProgress?("Načítám IV rank…")
        let tradingDays = bars.map { HistoricalDay.string($0.date) }
        // IV rank stačí jednou týdně (každý 5. obchodní den), mezi tím se bere poslední známý.
        let rankDays = stride(from: 0, to: tradingDays.count, by: 5).map { tradingDays[$0] }
        let ivRanks = (try? await source.ivRank(symbol: symbol, days: rankDays)) ?? [:]
        func rank(at i: Int) -> Double? {
            let day = HistoricalDay.string(bars[i].date)
            if let r = ivRanks[day] { return r }
            for back in 1...7 {
                if let r = ivRanks[HistoricalDay.adding(-back, to: day)] { return r }
            }
            return volRank(hv, at: i, window: rankWindow)
        }

        var equity = config.initialCapital
        var peak = equity
        var points = [EquityPoint(date: first.date, equity: equity, drawdown: 0, position: 0)]
        var trades: [OptionTrade] = []
        var position: HistoricalPosition? = nil
        var rollSignal: Int? = nil
        var waitingEntry: Int? = nil     // vstup strategie, na který ještě chybí volatilita
        var pending: (play: OptionPlay, signal: Int, rank: Double, roll: Bool)? = nil
        var skipped = 0
        var lastFailure: Error? = nil

        func fill(_ quote: HistoricalOptionQuote, buying: Bool) -> Double {
            buying ? quote.mid + spreadFill * quote.halfSpread : max(quote.mid - spreadFill * quote.halfSpread, 0)
        }

        for i in 1..<n {
            try Task.checkCancellation()
            let bar = bars[i]
            let day = HistoricalDay.string(bar.date)

            if position == nil, let plan = pending {
                await onProgress?("Obchod \(trades.count + 1): \(plan.play.name) \(day)")
                do {
                    position = try await openHistorical(plan.play, symbol: symbol, day: day, date: bar.date, spot: bar.close,
                                                        candidates: (max(0, i - 4)...i).reversed().map { tradingDays[$0] },
                                                        futureDays: Array(tradingDays[i...]),
                                                        equity: equity, signal: plan.signal, rank: plan.rank,
                                                        config: config, source: source, fill: fill)
                    position?.isRoll = plan.roll
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Výpadek jednoho dotazu nemá shodit celý backtest – vstup se vynechá.
                    lastFailure = error
                    position = nil
                }
                if position == nil { skipped += 1 }
            }
            pending = nil

            var marked = equity
            if var current = position {
                if let today = current.quotes[day] {
                    for (key, quote) in today { current.lastQuotes[key] = quote }
                }
                let daysLeft = HistoricalDay.days(from: day, to: current.expiration)
                let expired = daysLeft <= 0
                let value: Double = expired
                    ? intrinsicValue(current.legs, spot: bar.close)
                    : current.legs.reduce(0) { total, leg in
                        let quote = current.lastQuotes[HistoricalOptionQuote.makeKey(leg.type, leg.strike)]
                        return total + Double(leg.side) * (quote?.mid ?? 0)
                    }
                let pnlPerShare = value - current.entryPremium
                marked = current.equityAtEntry - current.entryCosts + pnlPerShare * 100 * current.contracts

                var reason: String? = nil
                if signals[i] != current.signal {
                    reason = config.followStrategy ? "výstup strategie" : "změna signálu"
                } else if expired {
                    reason = "expirace"
                } else if config.followStrategy {
                    if daysLeft <= Double(config.exitDaysToExpiry) { reason = "rolování" }
                } else if current.play.isCredit {
                    let credit = -current.entryPremium
                    if pnlPerShare >= credit * config.creditTakeProfit { reason = "cíl zisku" }
                    else if -pnlPerShare >= credit * config.creditStop { reason = "stop" }
                } else {
                    let debit = current.entryPremium
                    if pnlPerShare >= debit * config.debitTakeProfit { reason = "cíl zisku" }
                    else if -pnlPerShare >= debit * config.debitStop { reason = "stop" }
                }
                if reason == nil, daysLeft <= Double(config.exitDaysToExpiry) { reason = "čas" }

                if let reason {
                    let exitValue: Double = expired ? value : current.legs.reduce(0) { total, leg in
                        guard let quote = current.lastQuotes[HistoricalOptionQuote.makeKey(leg.type, leg.strike)] else {
                            return total
                        }
                        return total + Double(leg.side) * fill(quote, buying: leg.side < 0)
                    }
                    let exitCosts = expired ? 0 : config.commission * Double(current.legs.count) * current.contracts
                    let pnl = (exitValue - current.entryPremium) * 100 * current.contracts - current.entryCosts - exitCosts
                    equity = current.equityAtEntry + pnl
                    marked = equity
                    trades.append(OptionTrade(
                        id: trades.count, play: current.play, legs: current.legs, entryDate: current.entryDate,
                        exitDate: bar.date, expiration: HistoricalDay.date(current.expiration) ?? bar.date,
                        entrySpot: current.entrySpot, exitSpot: bar.close, entryPremium: current.entryPremium,
                        exitValue: exitValue, contracts: current.contracts,
                        maxLoss: current.maxLossPerShare * 100 * current.contracts, pnl: pnl, exitReason: reason,
                        impliedVol: current.iv, volRank: current.rank, isRoll: current.isRoll))
                    rollSignal = config.followStrategy && (reason == "rolování" || reason == "expirace")
                        && signals[i] == current.signal ? current.signal : nil
                    position = nil
                } else {
                    position = current
                }
            }

            if position == nil, i < n - 1 {
                if signals[i] != (i > 1 ? signals[i - 1] : 0) { waitingEntry = signals[i] }
                if waitingEntry != signals[i] { waitingEntry = nil }
                let isRoll = rollSignal != nil && rollSignal == signals[i]
                if waitingEntry != nil || isRoll, let r = rank(at: i),
                   let play = choose(signal: signals[i], rank: r, config: config) {
                    pending = (play, signals[i], r, isRoll && waitingEntry == nil)
                    waitingEntry = nil
                }
            }
            if position == nil { rollSignal = nil }

            peak = max(peak, marked)
            let exposure = position.map { $0.play.direction == 0 ? 1 : $0.play.direction } ?? 0
            points.append(EquityPoint(date: bar.date, equity: marked, drawdown: marked / peak - 1, position: exposure))
        }

        if let current = position {
            let value = current.legs.reduce(0) { total, leg in
                total + Double(leg.side) * (current.lastQuotes[HistoricalOptionQuote.makeKey(leg.type, leg.strike)]?.mid ?? 0)
            }
            let pnl = (value - current.entryPremium) * 100 * current.contracts - current.entryCosts
            trades.append(OptionTrade(
                id: trades.count, play: current.play, legs: current.legs, entryDate: current.entryDate, exitDate: nil,
                expiration: HistoricalDay.date(current.expiration) ?? last.date, entrySpot: current.entrySpot,
                exitSpot: last.close, entryPremium: current.entryPremium, exitValue: value, contracts: current.contracts,
                maxLoss: current.maxLossPerShare * 100 * current.contracts, pnl: pnl, exitReason: "otevřený",
                impliedVol: current.iv, volRank: current.rank, isRoll: current.isRoll))
        }

        if trades.isEmpty, let lastFailure { throw lastFailure }

        let summary = trades.map { t in
            BacktestTrade(id: t.id, side: t.play.direction == 0 ? 1 : t.play.direction, entryDate: t.entryDate,
                          entryPrice: t.entrySpot, exitDate: t.exitDate, exitPrice: t.exitSpot, returnPct: t.returnOnRisk)
        }
        let metrics = BacktestEngine.metrics(equity: points, trades: summary, riskFreeRate: config.riskFreeRate)
        var result = OptionsBacktestResult(config: config, equity: points, trades: trades, metrics: metrics,
                                           buyAndHold: hold.buyAndHold, buyAndHoldMetrics: hold.buyAndHoldMetrics)
        result.pricing = "Historické kotace (DoltHub, EOD), plnění mid ± \(Int(spreadFill * 100)) % poloviny spreadu"
        result.skippedEntries = skipped
        return result
    }

    static func intrinsicValue(_ legs: [OptionLegSpec], spot: Double) -> Double {
        legs.reduce(0) { $0 + Double($1.side) * BlackScholes.intrinsic($1.type, spot: spot, strike: $1.strike) }
    }

    /// Otevře pozici z historického řetězce dne `day` (nebo posledního dne před ním).
    static func openHistorical(_ play: OptionPlay, symbol: String, day: String, date: Date, spot: Double,
                               candidates: [String], futureDays: [String], equity: Double,
                               signal: Int, rank: Double, config: OptionsBacktestConfig,
                               source: HistoricalOptionsSource,
                               fill: (HistoricalOptionQuote, Bool) -> Double) async throws -> HistoricalPosition? {
        let target = config.daysToExpiry
        guard let available = try await source.chain(symbol: symbol, candidates: candidates,
                                                     minStrike: spot * 0.6, maxStrike: spot * 1.4) else { return nil }
        let expirations = Set(available.quotes.map(\.expiration)).filter {
            let d = HistoricalDay.days(from: available.date, to: $0)
            return d >= Double(max(target - 14, 5)) && d <= Double(target + 21)
        }
        guard let expiration = expirations.min(by: {
            abs(HistoricalDay.days(from: day, to: $0) - Double(target)) < abs(HistoricalDay.days(from: day, to: $1) - Double(target))
        }) else { return nil }
        let quotes = available.quotes.filter { $0.expiration == expiration }
        let calls = quotes.filter { $0.type == .call && $0.ask > 0 }.sorted { $0.strike < $1.strike }
        let puts = quotes.filter { $0.type == .put && $0.ask > 0 }.sorted { $0.strike < $1.strike }
        let width = spot * config.widthPct
        let days = max(HistoricalDay.days(from: available.date, to: expiration), 1)

        func delta(_ q: HistoricalOptionQuote) -> Double {
            if let d = q.delta, d != 0 { return abs(d) }
            let vol = q.iv.flatMap { $0 > 0 ? $0 : nil } ?? 0.3
            return abs(BlackScholes.greeks(q.type, OptionParameters(spot: spot, strike: q.strike, days: days,
                                                                    rate: config.riskFreeRate, volatility: vol)).delta)
        }
        func byDelta(_ list: [HistoricalOptionQuote], _ target: Double, otm: (Double) -> Bool) -> HistoricalOptionQuote? {
            list.filter { otm($0.strike) && $0.bid > 0 }.min { abs(delta($0) - target) < abs(delta($1) - target) }
        }
        func nearest(_ list: [HistoricalOptionQuote], to strike: Double, where ok: (Double) -> Bool) -> HistoricalOptionQuote? {
            list.filter { ok($0.strike) }.min { abs($0.strike - strike) < abs($1.strike - strike) }
        }
        func atm(_ list: [HistoricalOptionQuote]) -> HistoricalOptionQuote? {
            list.min { abs($0.strike - spot) < abs($1.strike - spot) }
        }

        var legs: [(OptionLegSpec, HistoricalOptionQuote)] = []
        switch play {
        case .bullPutSpread:
            guard let short = byDelta(puts, config.shortDelta, otm: { $0 < spot }),
                  let long = nearest(puts, to: short.strike - width, where: { $0 < short.strike }) else { return nil }
            legs = [(OptionLegSpec(type: .put, side: -1, strike: short.strike), short),
                    (OptionLegSpec(type: .put, side: 1, strike: long.strike), long)]
        case .bearCallSpread:
            guard let short = byDelta(calls, config.shortDelta, otm: { $0 > spot }),
                  let long = nearest(calls, to: short.strike + width, where: { $0 > short.strike }) else { return nil }
            legs = [(OptionLegSpec(type: .call, side: -1, strike: short.strike), short),
                    (OptionLegSpec(type: .call, side: 1, strike: long.strike), long)]
        case .bullCallSpread:
            guard let long = atm(calls),
                  let short = nearest(calls, to: long.strike + width, where: { $0 > long.strike }) else { return nil }
            legs = [(OptionLegSpec(type: .call, side: 1, strike: long.strike), long),
                    (OptionLegSpec(type: .call, side: -1, strike: short.strike), short)]
        case .bearPutSpread:
            guard let long = atm(puts),
                  let short = nearest(puts, to: long.strike - width, where: { $0 < long.strike }) else { return nil }
            legs = [(OptionLegSpec(type: .put, side: 1, strike: long.strike), long),
                    (OptionLegSpec(type: .put, side: -1, strike: short.strike), short)]
        case .ironCondor:
            let d = min(config.shortDelta, 0.2)
            guard let sp = byDelta(puts, d, otm: { $0 < spot }),
                  let lp = nearest(puts, to: sp.strike - width, where: { $0 < sp.strike }),
                  let sc = byDelta(calls, d, otm: { $0 > spot }),
                  let lc = nearest(calls, to: sc.strike + width, where: { $0 > sc.strike }) else { return nil }
            legs = [(OptionLegSpec(type: .put, side: 1, strike: lp.strike), lp),
                    (OptionLegSpec(type: .put, side: -1, strike: sp.strike), sp),
                    (OptionLegSpec(type: .call, side: -1, strike: sc.strike), sc),
                    (OptionLegSpec(type: .call, side: 1, strike: lc.strike), lc)]
        case .longCall:
            guard let q = atm(calls) else { return nil }
            legs = [(OptionLegSpec(type: .call, side: 1, strike: q.strike), q)]
        case .longPut:
            guard let q = atm(puts) else { return nil }
            legs = [(OptionLegSpec(type: .put, side: 1, strike: q.strike), q)]
        }

        let premium = legs.reduce(0) { $0 + Double($1.0.side) * fill($1.1, $1.0.side > 0) }
        let specs = legs.map(\.0)
        let putWidth = abs((specs.filter { $0.type == .put }.map(\.strike).max() ?? 0) - (specs.filter { $0.type == .put }.map(\.strike).min() ?? 0))
        let callWidth = abs((specs.filter { $0.type == .call }.map(\.strike).max() ?? 0) - (specs.filter { $0.type == .call }.map(\.strike).min() ?? 0))
        let spreadWidth = max(putWidth, callWidth)
        let maxLoss: Double
        if play.isCredit {
            guard -premium > 0.01 else { return nil }
            maxLoss = spreadWidth + premium
        } else {
            guard premium > 0.01 else { return nil }
            maxLoss = premium
        }
        guard maxLoss > 0 else { return nil }

        let holdingDays = futureDays.filter { $0 <= expiration }
        let history = try await source.history(symbol: symbol, expiration: expiration, strikes: specs.map(\.strike),
                                                days: holdingDays)
        var byDay: [String: [String: HistoricalOptionQuote]] = [:]
        for q in history { byDay[q.date, default: [:]][q.key] = q }
        var lastQuotes: [String: HistoricalOptionQuote] = [:]
        for (spec, q) in legs { lastQuotes[HistoricalOptionQuote.makeKey(spec.type, spec.strike)] = q }

        let contracts = equity * config.riskPerTrade / (maxLoss * 100)
        let iv = legs.compactMap { $0.1.iv }.first ?? 0
        return HistoricalPosition(play: play, legs: specs, expiration: expiration, entryDate: date, entrySpot: spot,
                                  entryPremium: premium, contracts: contracts, maxLossPerShare: maxLoss,
                                  equityAtEntry: equity, entryCosts: config.commission * Double(specs.count) * contracts,
                                  signal: play.direction == 0 ? 0 : signal, iv: iv, rank: rank,
                                  quotes: byDay, lastQuotes: lastQuotes)
    }
}
