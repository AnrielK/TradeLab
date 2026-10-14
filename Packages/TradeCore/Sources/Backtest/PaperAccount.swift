import Foundation

/// Otevřená pozice na demo účtu (akcie long / short).
public struct PaperPosition: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var symbol: String
    /// 1 long, −1 short.
    public var side: Int
    public var shares: Double
    public var entryPrice: Double
    public var entryDate: Date
    public var stop: Double?
    public var target: Double?
    /// Odkud obchod přišel („Breakout“, „Odraz od KP 50“, „Ručně“…).
    public var source: String
    /// Poslední známá cena.
    public var lastPrice: Double

    public init(id: UUID = UUID(), symbol: String, side: Int, shares: Double, entryPrice: Double, entryDate: Date,
                stop: Double?, target: Double?, source: String) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.shares = shares
        self.entryPrice = entryPrice
        self.entryDate = entryDate
        self.stop = stop
        self.target = target
        self.source = source
        self.lastPrice = entryPrice
    }

    public var marketValue: Double { Double(side) * shares * lastPrice }
    public var unrealizedPnL: Double { Double(side) * shares * (lastPrice - entryPrice) }
    public var returnPct: Double { entryPrice > 0 ? Double(side) * (lastPrice / entryPrice - 1) : 0 }

    /// Zasáhla cena stop nebo cíl? Vrací důvod výstupu.
    public func exitReason(at price: Double) -> String? {
        if side > 0 {
            if let stop, price <= stop { return "stop" }
            if let target, price >= target { return "cíl" }
        } else {
            if let stop, price >= stop { return "stop" }
            if let target, price <= target { return "cíl" }
        }
        return nil
    }
}

/// Uzavřený obchod demo účtu.
public struct PaperTrade: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var symbol: String
    public var side: Int
    public var shares: Double
    public var entryPrice: Double
    public var entryDate: Date
    public var exitPrice: Double
    public var exitDate: Date
    public var source: String
    public var reason: String

    public var pnl: Double { Double(side) * shares * (exitPrice - entryPrice) }
    public var returnPct: Double { entryPrice > 0 ? Double(side) * (exitPrice / entryPrice - 1) : 0 }
}

/// Virtuální účet pro živé testování strategií: hotovost, pozice, historie. Bez poplatků;
/// short připíše hotovost z prodeje a pozice se oceňuje se záporným znaménkem.
public struct PaperAccount: Codable, Hashable, Sendable {
    public var startingCash: Double
    public var cash: Double
    public var positions: [PaperPosition]
    public var history: [PaperTrade]
    public var createdAt: Date
    /// Signály, které už se obchodovaly (každý signál jen jednou).
    public var tradedSignals: [String]

    public init(startingCash: Double = 10_000, now: Date = Date()) {
        self.startingCash = startingCash
        self.cash = startingCash
        self.positions = []
        self.history = []
        self.createdAt = now
        self.tradedSignals = []
    }

    public var equity: Double { cash + positions.reduce(0) { $0 + $1.marketValue } }
    public var totalPnL: Double { equity - startingCash }
    public var realizedPnL: Double { history.reduce(0) { $0 + $1.pnl } }
    public var winRate: Double? {
        history.isEmpty ? nil : Double(history.filter { $0.pnl > 0 }.count) / Double(history.count)
    }

    /// Velikost pozice: riziko `riskFraction` účtu na vzdálenost ke stopu, nejvýš `maxFraction` účtu
    /// a u longu nejvýš dostupná hotovost. Celé kusy.
    public func shares(entry: Double, stop: Double?, riskFraction: Double, maxFraction: Double) -> Double {
        guard entry > 0 else { return 0 }
        let cap = equity * maxFraction / entry
        var count = cap
        if let stop, abs(entry - stop) > 0 {
            count = min(cap, equity * riskFraction / abs(entry - stop))
        }
        count = min(count, max(cash, 0) / entry)
        return max(0, count.rounded(.down))
    }

    @discardableResult
    public mutating func open(symbol: String, side: Int, shares: Double, price: Double, date: Date,
                              stop: Double?, target: Double?, source: String) -> PaperPosition? {
        guard shares > 0, price > 0 else { return nil }
        if side > 0 && shares * price > cash + 1e-9 { return nil }
        let position = PaperPosition(symbol: symbol.uppercased(), side: side, shares: shares, entryPrice: price,
                                     entryDate: date, stop: stop, target: target, source: source)
        cash -= Double(side) * shares * price
        positions.append(position)
        return position
    }

    @discardableResult
    public mutating func close(_ id: UUID, price: Double, date: Date, reason: String) -> PaperTrade? {
        guard let index = positions.firstIndex(where: { $0.id == id }) else { return nil }
        let p = positions.remove(at: index)
        cash += Double(p.side) * p.shares * price
        let trade = PaperTrade(id: p.id, symbol: p.symbol, side: p.side, shares: p.shares, entryPrice: p.entryPrice,
                               entryDate: p.entryDate, exitPrice: price, exitDate: date, source: p.source,
                               reason: reason)
        history.insert(trade, at: 0)
        return trade
    }

    /// Přecení pozice na `prices` a zavře ty, které zasáhly stop nebo cíl. Vrací uzavřené obchody.
    @discardableResult
    public mutating func mark(prices: [String: Double], date: Date) -> [PaperTrade] {
        var closed: [PaperTrade] = []
        for position in positions {
            guard let price = prices[position.symbol] else { continue }
            if let i = positions.firstIndex(where: { $0.id == position.id }) { positions[i].lastPrice = price }
            if let reason = position.exitReason(at: price),
               let trade = close(position.id, price: price, date: date, reason: reason) {
                closed.append(trade)
            }
        }
        return closed
    }
}
