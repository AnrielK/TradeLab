import Foundation
import Observation
import MarketData
import OptionsMath

enum AppTab: Hashable {
    case market
    case options
    case strategy
    case calculator
}

@MainActor
@Observable
final class AppModel {
    let client = YahooFinanceClient.shared

    var selectedTab: AppTab = .market

    // Sledované tickery
    private(set) var watchlist: [String]
    var quotes: [String: QuoteSnapshot] = [:]

    // Sazba pro ocenění
    var riskFreeRate: Double = 0.04
    var riskFreeRateIsLive = false

    // Opce
    var optionsSymbol: String

    // Builder strategie
    var strategy: OptionStrategy
    var strategySpot: Double
    var lastError: String? = nil

    private static let watchlistKey = "watchlist"
    private static let strategyKey = "strategy"
    private static let spotKey = "strategySpot"
    private static let optionsSymbolKey = "optionsSymbol"

    init() {
        let defaults = UserDefaults.standard
        watchlist = defaults.stringArray(forKey: Self.watchlistKey) ?? ["SPY", "QQQ", "AAPL", "NVDA", "MSFT", "TSLA"]
        optionsSymbol = defaults.string(forKey: Self.optionsSymbolKey) ?? "AAPL"
        if let data = defaults.data(forKey: Self.strategyKey),
           let saved = try? JSONDecoder().decode(OptionStrategy.self, from: data) {
            strategy = saved
        } else {
            strategy = OptionStrategy(underlying: "AAPL")
        }
        strategySpot = defaults.double(forKey: Self.spotKey)
    }

    var market: MarketContext { MarketContext(rate: riskFreeRate) }

    // MARK: - Watchlist

    func addToWatchlist(_ symbol: String) {
        let s = symbol.uppercased()
        guard !watchlist.contains(s) else { return }
        watchlist.append(s)
        saveWatchlist()
        Task { await refreshQuote(s) }
    }

    func removeFromWatchlist(at offsets: IndexSet) {
        watchlist.remove(atOffsets: offsets)
        saveWatchlist()
    }

    func moveWatchlist(from source: IndexSet, to destination: Int) {
        watchlist.move(fromOffsets: source, toOffset: destination)
        saveWatchlist()
    }

    private func saveWatchlist() {
        UserDefaults.standard.set(watchlist, forKey: Self.watchlistKey)
    }

    func refreshQuotes() async {
        let symbols = watchlist
        let client = client
        await withTaskGroup(of: (String, QuoteSnapshot?).self) { group in
            for symbol in symbols {
                group.addTask {
                    let quote = try? await client.quote(symbol: symbol)
                    return (symbol, quote)
                }
            }
            for await (symbol, quote) in group {
                if let quote { quotes[symbol] = quote }
            }
        }
    }

    func refreshQuote(_ symbol: String) async {
        if let quote = try? await client.quote(symbol: symbol) {
            quotes[symbol] = quote
        }
    }

    func refreshRiskFreeRate() async {
        if let rate = await client.riskFreeRate() {
            riskFreeRate = rate
            riskFreeRateIsLive = true
        }
    }

    // MARK: - Opce

    func openOptions(for symbol: String) {
        optionsSymbol = symbol.uppercased()
        UserDefaults.standard.set(optionsSymbol, forKey: Self.optionsSymbolKey)
        selectedTab = .options
    }

    /// Přidá kontrakt z řetězce jako nohu strategie (s tržní mid cenou a IV).
    func addLeg(from contract: OptionContract, side: PositionSide, chain: OptionChain) {
        if strategy.underlying.uppercased() != chain.symbol.uppercased() {
            strategy = OptionStrategy(underlying: chain.symbol)
        }
        strategySpot = chain.underlyingPrice
        let days = contract.daysToExpiry()
        let iv = contract.estimatedVolatility(spot: chain.underlyingPrice, rate: riskFreeRate) ?? 0.3
        let leg = StrategyLeg(
            instrument: contract.type == .call ? .call : .put,
            side: side,
            quantity: 1,
            strike: contract.strike,
            premium: contract.mid ?? 0,
            daysToExpiry: (days * 100).rounded() / 100,
            impliedVolatility: iv,
            contractSymbol: contract.contractSymbol
        )
        strategy.legs.append(leg)
        if strategy.legs.count == 1 { strategy.name = "Vlastní strategie" }
        saveStrategy()
    }

    // MARK: - Strategie

    func applyTemplate(_ template: StrategyTemplate) async {
        let symbol = (strategy.underlying.isEmpty ? optionsSymbol : strategy.underlying).uppercased()
        var volatility = 0.3
        do {
            let chart = try await client.chart(symbol: symbol, range: .sixMonths)
            strategySpot = chart.quote.price
            if let realized = Volatility.realized(closes: chart.bars.map(\.close), window: 60) {
                volatility = realized
            }
            lastError = nil
        } catch {
            lastError = "Nepodařilo se načíst cenu \(symbol): \(error.localizedDescription)"
        }
        guard strategySpot > 0 else { return }
        strategy = template.build(underlying: symbol, spot: strategySpot, daysToExpiry: 30,
                                  volatility: volatility, market: market)
        saveStrategy()
    }

    func refreshStrategySpot() async {
        guard !strategy.underlying.isEmpty else { return }
        if let quote = try? await client.quote(symbol: strategy.underlying) {
            strategySpot = quote.price
            saveStrategy()
        }
    }

    func upsertLeg(_ leg: StrategyLeg) {
        if let index = strategy.legs.firstIndex(where: { $0.id == leg.id }) {
            strategy.legs[index] = leg
        } else {
            strategy.legs.append(leg)
        }
        saveStrategy()
    }

    func deleteLeg(id: UUID) {
        strategy.legs.removeAll { $0.id == id }
        saveStrategy()
    }

    func deleteLegs(at offsets: IndexSet) {
        strategy.legs.remove(atOffsets: offsets)
        saveStrategy()
    }

    func clearStrategy() {
        strategy = OptionStrategy(underlying: strategy.underlying)
        saveStrategy()
    }

    /// Nová noha s teoretickou prémií (ATM call, 30 dní).
    func makeDefaultLeg() -> StrategyLeg {
        let spot = strategySpot > 0 ? strategySpot : 100
        let strike = StrikeGrid.round(spot, spot: spot)
        var leg = StrategyLeg(instrument: .call, side: .long, strike: strike, daysToExpiry: 30, impliedVolatility: 0.3)
        leg.premium = theoreticalPremium(for: leg)
        return leg
    }

    func theoreticalPremium(for leg: StrategyLeg) -> Double {
        guard let type = leg.instrument.optionType, strategySpot > 0 else { return leg.premium }
        let params = OptionParameters(spot: strategySpot, strike: leg.strike, days: leg.daysToExpiry,
                                      rate: riskFreeRate, volatility: leg.impliedVolatility)
        return (BlackScholes.price(type, params) * 100).rounded() / 100
    }

    func saveStrategy() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(strategy) {
            defaults.set(data, forKey: Self.strategyKey)
        }
        defaults.set(strategySpot, forKey: Self.spotKey)
    }
}
