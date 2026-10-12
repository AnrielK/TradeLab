import Foundation
import Observation
import MarketData
import OptionsMath

enum AppTab: Hashable {
    case market
    case options
    case calculator
}

@MainActor
@Observable
final class AppModel {
    let client = YahooFinanceClient.shared
    let chainStore: ChainStore

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
        chainStore = ChainStore(client: YahooFinanceClient.shared)
        let defaults = UserDefaults.standard
        watchlist = defaults.stringArray(forKey: Self.watchlistKey) ?? ["SPY", "QQQ", "AAPL", "NVDA", "MSFT", "TSLA"]
        optionsSymbol = defaults.string(forKey: Self.optionsSymbolKey) ?? "AAPL"
        if let data = defaults.data(forKey: Self.strategyKey),
           let saved = try? JSONDecoder().decode(OptionStrategy.self, from: data),
           saved.optionLegs.allSatisfy({ $0.expiration != nil }) {
            // Nohy bez expirace (starší teoretické šablony) se nenačítají – nejdou přecenit z řetězce.
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
        selectOptionsSymbol(symbol)
        selectedTab = .options
    }

    /// Ticker pro záložku Opce (např. po otevření detailu na záložce Trh) bez přepnutí záložky.
    func selectOptionsSymbol(_ symbol: String) {
        let s = symbol.uppercased()
        guard !s.isEmpty, s != optionsSymbol else { return }
        optionsSymbol = s
        UserDefaults.standard.set(s, forKey: Self.optionsSymbolKey)
    }

    /// Expirace rozbalená v tabulce – šablony strategií se staví na ní.
    var focusedExpiration: Date? = nil

    /// Expirace pro šablonu: rozbalená v tabulce, jinak nejbližší ke ~30 dnům.
    var templateExpiration: Date? {
        if let focusedExpiration, chainStore.expirations.contains(focusedExpiration) { return focusedExpiration }
        return chainStore.expirations.min {
            abs(OptionChain.daysToExpiry($0) - 30) < abs(OptionChain.daysToExpiry($1) - 30)
        }
    }

    // MARK: - Tiket z opčního řetězce

    private func isTicket(for symbol: String) -> Bool {
        strategy.underlying.uppercased() == symbol.uppercased()
    }

    /// Klepnutí na bid (prodej) nebo ask (nákup).
    /// Stejný kontrakt a směr nohu odebere, opačný směr ji otočí, jinak se noha přidá.
    func toggleLeg(_ contract: OptionContract, side: PositionSide, chain: OptionChain) {
        if !isTicket(for: chain.symbol) {
            strategy = OptionStrategy(underlying: chain.symbol)
        }
        strategySpot = chain.underlyingPrice
        let candidate = chain.leg(for: contract, side: side, quantity: max(strategy.spreadCount, 1), rate: riskFreeRate)
        if let index = strategy.legs.firstIndex(where: { $0.isSameContract(as: candidate) }) {
            if strategy.legs[index].side == side {
                strategy.legs.remove(at: index)
            } else {
                strategy.legs[index].side = side
            }
        } else {
            strategy.legs.append(candidate)
        }
        renameStrategy()
        saveStrategy()
    }

    /// Pozice v tiketu pro daný kontrakt: +n long, −n short, nil = není.
    func position(of contract: OptionContract?, expiration: Date) -> Int? {
        guard let contract, isTicket(for: chainStore.symbol) else { return nil }
        let instrument: LegInstrument = contract.type == .call ? .call : .put
        guard let leg = strategy.legs.first(where: {
            $0.instrument == instrument && $0.strike == contract.strike && $0.expiration == expiration
        }) else { return nil }
        return leg.side == .long ? leg.quantity : -leg.quantity
    }

    func leg(for contract: OptionContract, expiration: Date) -> StrategyLeg? {
        let instrument: LegInstrument = contract.type == .call ? .call : .put
        return strategy.legs.first {
            $0.instrument == instrument && $0.strike == contract.strike && $0.expiration == expiration
        }
    }

    /// Přesune nohu na jiný kontrakt téže expirace (tažení v tabulce).
    func moveLeg(id: UUID, to contract: OptionContract, chain: OptionChain) {
        guard let index = strategy.legs.firstIndex(where: { $0.id == id }) else { return }
        let old = strategy.legs[index]
        var moved = chain.leg(for: contract, side: old.side, quantity: old.quantity, rate: riskFreeRate)
        moved.id = old.id
        guard !strategy.legs.contains(where: { $0.id != id && $0.isSameContract(as: moved) }) else { return }
        strategy.legs[index] = moved
        renameStrategy()
        saveStrategy()
    }

    /// Lze strategii posouvat po řetězci (všechny opční nohy mají expiraci z řetězce)?
    var canAdjustFromChain: Bool {
        let options = strategy.optionLegs
        return !options.isEmpty && options.allSatisfy { $0.expiration != nil } && isTicket(for: chainStore.symbol)
    }

    private func strikes(for leg: StrategyLeg) -> [Double] {
        guard let expiration = leg.expiration else { return [] }
        return chainStore.chains[expiration]?.strikes ?? []
    }

    func shiftStrikes(by steps: Int) async {
        guard let shifted = strategy.shiftingStrikes(by: steps, strikes: strikes(for:)) else { return }
        strategy = shifted
        await repriceStrategy()
    }

    func changeWidth(by steps: Int) async {
        guard let changed = strategy.changingWidth(by: steps, strikes: strikes(for:)) else { return }
        strategy = changed
        await repriceStrategy()
    }

    func changeQuantity(by delta: Int) {
        let count = max(strategy.spreadCount + delta, 1)
        strategy = strategy.withSpreadCount(count)
        saveStrategy()
    }

    /// Tažení striku v grafu: noha se přichytí na nejbližší dostupný strike.
    /// Nohy z řetězce se přecení z cache řetězce, ruční nohy teoreticky z Black-Scholes.
    func dragLeg(id: UUID, toPrice price: Double) {
        guard let index = strategy.legs.firstIndex(where: { $0.id == id }),
              strategy.legs[index].instrument != .stock else { return }
        var leg = strategy.legs[index]

        if let expiration = leg.expiration, let chain = chainStore.chains[expiration] {
            guard let strike = StrikeLadder.nearest(to: price, in: chain.strikes), strike != leg.strike else { return }
            leg.strike = strike
            leg = chain.repriced(leg, rate: riskFreeRate)
        } else {
            let reference = strategySpot > 0 ? strategySpot : price
            let strike = StrikeGrid.round(price, spot: reference)
            guard strike > 0, strike != leg.strike else { return }
            leg.strike = strike
            leg.premium = theoreticalPremium(for: leg)
            leg.bid = nil
            leg.ask = nil
        }
        // Nedovolit dvě stejné nohy na stejném kontraktu.
        guard !strategy.legs.contains(where: { $0.id != id && $0.isSameContract(as: leg) && $0.side == leg.side }) else { return }
        strategy.legs[index] = leg
        renameStrategy()
    }

    func finishLegDrag() {
        saveStrategy()
    }

    /// Posune všechny opční nohy o `steps` expirací (striky přichytí k nejbližším dostupným).
    func shiftExpiration(by steps: Int) async {
        let dates = chainStore.expirations
        guard !dates.isEmpty else { return }
        var copy = strategy
        for i in copy.legs.indices where copy.legs[i].instrument != .stock {
            guard let current = copy.legs[i].expiration,
                  let index = dates.firstIndex(of: current) else { return }
            let target = index + steps
            guard dates.indices.contains(target) else { return }
            guard let chain = await chainStore.chain(for: dates[target], rate: riskFreeRate) else { return }
            copy.legs[i].expiration = dates[target]
            if let strike = StrikeLadder.nearest(to: copy.legs[i].strike, in: chain.strikes) {
                copy.legs[i].strike = strike
            }
        }
        strategy = copy
        await repriceStrategy()
    }

    /// Načte aktuální kotace pro všechny nohy z řetězce.
    func repriceStrategy() async {
        for leg in strategy.legs {
            guard leg.instrument != .stock, let expiration = leg.expiration,
                  let chain = await chainStore.chain(for: expiration, rate: riskFreeRate) else { continue }
            let repriced = chain.repriced(leg, rate: riskFreeRate)
            if let index = strategy.legs.firstIndex(where: { $0.id == leg.id }) {
                strategy.legs[index] = repriced
            }
        }
        if chainStore.underlyingPrice > 0, isTicket(for: chainStore.symbol) {
            strategySpot = chainStore.underlyingPrice
        }
        renameStrategy()
        saveStrategy()
    }

    private func renameStrategy() {
        strategy.name = strategy.legs.isEmpty ? "Vlastní strategie" : StrategyClassifier.name(for: strategy)
    }

    // MARK: - Strategie

    /// Šablona z reálného řetězce: striky se přichytí k existujícím kontraktům vybrané expirace
    /// a ceny (bid/ask/mid, IV) se vezmou z trhu.
    func applyTemplate(_ template: StrategyTemplate) async {
        guard let expiration = templateExpiration,
              let chain = await chainStore.chain(for: expiration, rate: riskFreeRate) else {
            lastError = "Nejdřív načti opční řetězec."
            return
        }
        let spot = chain.underlyingPrice
        let volatility = chainStore.summaries[expiration]?.atmVolatility ?? 0.3
        let theoretical = template.build(underlying: chain.symbol, spot: spot,
                                         daysToExpiry: OptionChain.daysToExpiry(expiration),
                                         volatility: volatility, market: market)

        var legs: [StrategyLeg] = []
        // Striky se přiřazují v pořadí od nejnižšího, aby se dvě různé nohy nesmrskly na jeden strike.
        let ordered = theoretical.legs.enumerated().sorted { $0.element.strike < $1.element.strike }
        var assigned: [Int: StrategyLeg] = [:]
        var previousTheoretical: Double?
        var previousStrike: Double?
        for (index, leg) in ordered {
            guard let type = leg.instrument.optionType else {
                var stock = leg
                stock.strike = spot
                assigned[index] = stock
                continue
            }
            let available = chain.contracts(type).map(\.strike).sorted()
            guard var strike = StrikeLadder.nearest(to: leg.strike, in: available) else { continue }
            // Původně různé striky musí zůstat různé.
            if let prevT = previousTheoretical, let prevS = previousStrike, leg.strike > prevT, strike <= prevS,
               let next = available.first(where: { $0 > prevS }) {
                strike = next
            }
            previousTheoretical = leg.strike
            previousStrike = strike
            guard let contract = chain.contract(type, strike: strike) else { continue }
            assigned[index] = chain.leg(for: contract, side: leg.side, quantity: leg.quantity, rate: riskFreeRate)
        }
        for index in theoretical.legs.indices {
            if let leg = assigned[index] { legs.append(leg) }
        }
        guard !legs.isEmpty else { return }

        strategy = OptionStrategy(name: template.displayName, underlying: chain.symbol, legs: legs)
        strategySpot = spot
        lastError = nil
        renameStrategy()
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
        renameStrategy()
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
