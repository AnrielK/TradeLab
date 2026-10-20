import Foundation
import Observation
import MarketData
import OptionsMath

/// Cache opčních řetězců jednoho podkladu po expiracích.
@MainActor
@Observable
final class ChainStore {
    private let client: YahooFinanceClient

    var symbol: String = ""
    var quote: QuoteSnapshot? = nil
    var underlyingPrice: Double = 0
    var expirations: [Date] = []
    var chains: [Date: OptionChain] = [:]
    var summaries: [Date: ExpirationSummary] = [:]
    var loading: Set<Date> = []
    var isLoadingSymbol = false
    var errorMessage: String? = nil

    // Open interest přes expirace
    var oiProfile: OpenInterestProfile? = nil
    /// Max pain nejbližší měsíční expirace v profilu.
    var oiMaxPain: MaxPain? = nil
    var oiGammaFlip: Double? = nil
    /// Načteno / celkem expirací při načítání profilu.
    var oiProgress: (done: Int, total: Int)? = nil
    private var oiTask: Task<Void, Never>? = nil

    private var loadedAt: [Date: Date] = [:]
    private var prefetchTask: Task<Void, Never>? = nil

    /// Jak dlouho považovat řetězec za čerstvý.
    let maxAge: TimeInterval = 60

    init(client: YahooFinanceClient) {
        self.client = client
    }

    func load(symbol rawSymbol: String, rate: Double, force: Bool = false) async {
        let symbol = rawSymbol.uppercased()
        guard !symbol.isEmpty else { return }
        if symbol != self.symbol {
            reset()
            self.symbol = symbol
        } else if !force, !expirations.isEmpty {
            return
        }

        isLoadingSymbol = true
        defer { isLoadingSymbol = false }
        do {
            let first = try await client.optionChain(symbol: symbol)
            guard symbol == self.symbol else { return }
            expirations = first.expirationDates
            store(first, key: first.expiration, rate: rate)
            errorMessage = nil
            quote = try? await client.quote(symbol: symbol)
            prefetchSummaries(rate: rate)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Řetězec pro expiraci – z cache, nebo načtený ze sítě.
    @discardableResult
    func chain(for date: Date, rate: Double, maxAge: TimeInterval? = nil) async -> OptionChain? {
        let age = maxAge ?? self.maxAge
        if let cached = chains[date], let stamp = loadedAt[date], Date().timeIntervalSince(stamp) < age {
            return cached
        }
        let symbol = self.symbol
        loading.insert(date)
        defer { loading.remove(date) }
        do {
            let chain = try await client.optionChain(symbol: symbol, expiration: date)
            guard symbol == self.symbol else { return nil }
            store(chain, key: date, rate: rate)
            return chain
        } catch {
            errorMessage = error.localizedDescription
            return chains[date]
        }
    }

    func refresh(rate: Double) async {
        await client.clearCache()
        loadedAt.removeAll()
        await load(symbol: symbol, rate: rate, force: true)
    }

    /// Postupně dotáhne souhrny (IV, očekávaný pohyb) pro nejbližší expirace.
    func prefetchSummaries(rate: Double, limit: Int = 16) {
        prefetchTask?.cancel()
        let symbol = self.symbol
        let dates = expirations.prefix(limit).filter { summaries[$0] == nil }
        prefetchTask = Task { [weak self] in
            for date in dates {
                guard let self, !Task.isCancelled, self.symbol == symbol else { return }
                await self.chain(for: date, rate: rate)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Načte všechny expirace do `maxDays` dní (po 3 najednou) a sečte z nich open interest.
    /// Řetězce mladší než 15 minut se berou z cache – OI se mění jen jednou denně.
    func loadOpenInterest(maxDays: Double, rate: Double, force: Bool = false) async {
        if !force, let profile = oiProfile, profile.symbol == symbol, profile.maxDays == maxDays,
           Date().timeIntervalSince(profile.computedAt) < 900 { return }
        oiTask?.cancel()
        let symbol = self.symbol
        let task = Task { [weak self] in
            guard let self else { return }
            let now = Date()
            let dates = self.expirations.filter {
                let d = OptionChain.daysToExpiry($0, from: now)
                return d > 0 && d <= maxDays
            }
            guard !dates.isEmpty else {
                self.oiProfile = nil
                self.oiProgress = nil
                return
            }
            self.oiProgress = (0, dates.count)
            let age: TimeInterval = force ? 0 : 900
            var index = 0
            while index < dates.count {
                guard !Task.isCancelled, self.symbol == symbol else { return }
                let batch = Array(dates[index..<min(index + 3, dates.count)])
                index += batch.count
                await withTaskGroup(of: Void.self) { group in
                    for date in batch {
                        group.addTask { _ = await self.chain(for: date, rate: rate, maxAge: age) }
                    }
                }
                self.oiProgress = (index, dates.count)
            }
            guard !Task.isCancelled, self.symbol == symbol else { return }
            let chains = dates.compactMap { self.chains[$0] }
            let monthly = chains.first { ExpirationCalendar.isMonthly($0.expiration) } ?? chains.first
            let computed = await Task.detached(priority: .userInitiated) {
                let profile = OpenInterestProfile(chains: chains, maxDays: maxDays, rate: rate, now: now)
                return (profile, profile.gammaFlip(), monthly?.maxPain)
            }.value
            guard !Task.isCancelled, self.symbol == symbol else { return }
            self.oiProfile = computed.0
            self.oiGammaFlip = computed.1
            self.oiMaxPain = computed.2
            self.oiProgress = nil
        }
        oiTask = task
        await task.value
    }

    private func store(_ chain: OptionChain, key: Date, rate: Double) {
        chains[key] = chain
        loadedAt[key] = Date()
        summaries[key] = chain.summary(rate: rate)
        underlyingPrice = chain.underlyingPrice
    }

    private func reset() {
        prefetchTask?.cancel()
        quote = nil
        underlyingPrice = 0
        expirations = []
        chains = [:]
        summaries = [:]
        loadedAt = [:]
        loading = []
        errorMessage = nil
        oiTask?.cancel()
        oiProfile = nil
        oiMaxPain = nil
        oiGammaFlip = nil
        oiProgress = nil
    }
}
