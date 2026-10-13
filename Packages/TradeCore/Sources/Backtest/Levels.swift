import Foundation

/// Horizontální hladina (support / rezistence) složená z několika swingů.
public struct PriceLevel: Hashable, Sendable {
    public enum Kind: String, Sendable { case support, resistance }

    public var price: Double
    public var kind: Kind
    /// Počet swingových bodů (pivotů), které hladinu tvoří.
    public var touches: Int
    public var firstTouch: Date
    public var lastTouch: Date
    /// Relativní síla 0–1 (dotyky vážené čerstvostí).
    public var strength: Double
}

/// Trendová linie přes swingová minima (support) nebo maxima (rezistence).
public struct TrendLine: Hashable, Sendable {
    public var kind: PriceLevel.Kind
    public var startDate: Date
    public var startPrice: Double
    public var endDate: Date
    public var endPrice: Double
    public var touches: Int
    /// Hodnota linie na poslední svíčce.
    public var priceNow: Double
    public var strength: Double
    /// Index první kotvy a sklon na svíčku (pro výpočet hodnoty linie v libovolném baru).
    public var startIndex: Int = 0
    public var slopePerBar: Double = 0

    public var isRising: Bool { endPrice > startPrice }

    public func value(at index: Int) -> Double {
        startPrice + slopePerBar * Double(index - startIndex)
    }
}

public struct LevelAnalysis: Sendable {
    public var lastClose: Double
    public var atr: Double
    public var levels: [PriceLevel]
    public var trendLines: [TrendLine]
}

/// Hledání silných hladin a trendových linií ze swingů (pivotů).
public enum LevelFinder {
    struct Pivot: Hashable {
        var index: Int
        var price: Double
        var isHigh: Bool
    }

    /// Swingové maximum/minimum: extrém v okně ±`window` svíček.
    static func pivots(_ bars: [BacktestBar], window k: Int) -> [Pivot] {
        guard bars.count > 2 * k else { return [] }
        var result: [Pivot] = []
        for i in k..<(bars.count - k) {
            let range = (i - k)...(i + k)
            let high = bars[i].high
            let low = bars[i].low
            if range.allSatisfy({ $0 == i || bars[$0].high < high || ($0 > i && bars[$0].high <= high) }) {
                result.append(Pivot(index: i, price: high, isHigh: true))
            }
            if range.allSatisfy({ $0 == i || bars[$0].low > low || ($0 > i && bars[$0].low >= low) }) {
                result.append(Pivot(index: i, price: low, isHigh: false))
            }
        }
        return result
    }

    /// Průměrný true range.
    static func atr(_ bars: [BacktestBar], period: Int = 14) -> Double {
        guard bars.count > 1 else { return bars.first.map { $0.high - $0.low } ?? 0 }
        let ranges = (1..<bars.count).map { i -> Double in
            let b = bars[i], prev = bars[i - 1].close
            return max(b.high - b.low, abs(b.high - prev), abs(b.low - prev))
        }
        let recent = ranges.suffix(period)
        return recent.reduce(0, +) / Double(recent.count)
    }

    public static func analyze(_ bars: [BacktestBar], window: Int = 3, maxLevels: Int = 6,
                               maxTrendLines: Int = 2) -> LevelAnalysis {
        guard let last = bars.last else { return LevelAnalysis(lastClose: 0, atr: 0, levels: [], trendLines: []) }
        let atr = Self.atr(bars)
        let tolerance = max(atr * 0.5, last.close * 0.003)
        let pivots = Self.pivots(bars, window: window)
        return LevelAnalysis(
            lastClose: last.close,
            atr: atr,
            levels: levels(bars, pivots: pivots, tolerance: tolerance, maxLevels: maxLevels),
            trendLines: trendLines(bars, pivots: pivots, tolerance: tolerance, maxPerSide: maxTrendLines))
    }

    // MARK: - Hladiny

    static func levels(_ bars: [BacktestBar], pivots: [Pivot], tolerance: Double, maxLevels: Int) -> [PriceLevel] {
        guard let last = bars.last, !pivots.isEmpty else { return [] }
        let n = Double(bars.count)

        // Shlukování pivotů podle ceny.
        var clusters: [[Pivot]] = []
        for pivot in pivots.sorted(by: { $0.price < $1.price }) {
            if var cluster = clusters.last {
                let mean = cluster.map(\.price).reduce(0, +) / Double(cluster.count)
                if abs(pivot.price - mean) <= tolerance {
                    cluster.append(pivot)
                    clusters[clusters.count - 1] = cluster
                    continue
                }
            }
            clusters.append([pivot])
        }

        var scored: [(level: PriceLevel, score: Double)] = []
        for cluster in clusters where cluster.count >= 2 {
            let price = cluster.map(\.price).reduce(0, +) / Double(cluster.count)
            let score = cluster.reduce(0) { $0 + 0.5 + 0.5 * Double($1.index) / n }
            let indices = cluster.map(\.index)
            let level = PriceLevel(
                price: price,
                kind: price <= last.close ? .support : .resistance,
                touches: cluster.count,
                firstTouch: bars[indices.min()!].date,
                lastTouch: bars[indices.max()!].date,
                strength: 0)
            scored.append((level, score))
        }
        guard let best = scored.map(\.score).max(), best > 0 else { return [] }

        // Nejsilnější hladiny, ale vyvážené kolem aktuální ceny.
        let ranked = scored.sorted { $0.score > $1.score }
        let supports = ranked.filter { $0.level.kind == .support }.prefix((maxLevels + 1) / 2)
        let resistances = ranked.filter { $0.level.kind == .resistance }.prefix((maxLevels + 1) / 2)
        var chosen = Array(supports) + Array(resistances)
        if chosen.count < maxLevels {
            let rest = ranked.filter { item in !chosen.contains { $0.level == item.level } }
            chosen += rest.prefix(maxLevels - chosen.count)
        }
        return chosen.prefix(maxLevels).map { item in
            var level = item.level
            level.strength = (item.score / best * 100).rounded() / 100
            return level
        }.sorted { $0.price > $1.price }
    }

    // MARK: - Trendové linie

    static func trendLines(_ bars: [BacktestBar], pivots: [Pivot], tolerance: Double, maxPerSide: Int) -> [TrendLine] {
        let lows = Array(pivots.filter { !$0.isHigh }.suffix(14))
        let highs = Array(pivots.filter { $0.isHigh }.suffix(14))
        return bestLines(bars, pivots: lows, kind: .support, tolerance: tolerance, max: maxPerSide)
            + bestLines(bars, pivots: highs, kind: .resistance, tolerance: tolerance, max: maxPerSide)
    }

    static func bestLines(_ bars: [BacktestBar], pivots: [Pivot], kind: PriceLevel.Kind,
                          tolerance: Double, max count: Int, lastIndex upTo: Int? = nil) -> [TrendLine] {
        guard pivots.count >= 2, let last = bars.indices.last else { return [] }
        let lastIndex = min(upTo ?? last, last)
        var candidates: [(line: TrendLine, score: Double, a: Int, slope: Double)] = []

        for i in 0..<(pivots.count - 1) {
            for j in (i + 1)..<pivots.count {
                let a = pivots[i], b = pivots[j]
                guard b.index - a.index >= 3 else { continue }
                let slope = (b.price - a.price) / Double(b.index - a.index)
                func value(_ index: Int) -> Double { a.price + slope * Double(index - a.index) }

                // Linie nesmí být proražená zavírací cenou od prvního bodu do dneška.
                var broken = false
                for k in a.index...lastIndex {
                    let close = bars[k].close
                    if kind == .support ? close < value(k) - tolerance : close > value(k) + tolerance {
                        broken = true
                        break
                    }
                }
                if broken { continue }

                let touches = pivots[i...].filter { abs($0.price - value($0.index)) <= tolerance }.count
                guard touches >= 2 else { continue }
                let span = Double(lastIndex - a.index) / Double(max(lastIndex + 1, 1))
                let recency = Double(pivots[j].index) / Double(max(lastIndex, 1))
                let score = Double(touches) + span + recency
                let now = value(lastIndex)
                guard now > 0 else { continue }
                let line = TrendLine(kind: kind,
                                     startDate: bars[a.index].date, startPrice: a.price,
                                     endDate: bars[b.index].date, endPrice: b.price,
                                     touches: touches, priceNow: now, strength: 0,
                                     startIndex: a.index, slopePerBar: slope)
                candidates.append((line, score, a.index, slope))
            }
        }
        guard let best = candidates.map(\.score).max() else { return [] }

        // Vybrat nejlepší a vynechat skoro stejné linie (podobná hodnota dnes i sklon).
        var chosen: [(line: TrendLine, score: Double, a: Int, slope: Double)] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let duplicate = chosen.contains { other in
                abs(other.line.priceNow - candidate.line.priceNow) <= tolerance * 2
                    || abs(other.slope - candidate.slope) <= abs(other.slope) * 0.15 && abs(other.a - candidate.a) < 10
            }
            if duplicate { continue }
            chosen.append(candidate)
            if chosen.count == count { break }
        }
        return chosen.map { item in
            var line = item.line
            line.strength = (item.score / best * 100).rounded() / 100
            return line
        }
    }
}
