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
    }
}
