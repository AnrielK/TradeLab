import Foundation

/// Nastavení strategie Trendlinie a trojúhelník.
public struct TrendlineSettings: Hashable, Codable, Sendable {
    /// Vstupy: průraz trojúhelníku, odraz od trendline, průraz trendline.
    public var triangle: Bool
    public var bounce: Bool
    public var breakout: Bool
    /// Linie ze swingů posledních N svíček.
    public var lookback: Int
    /// Minimální počet swingů na linii (včetně kotev).
    public var minTouches: Int
    /// Tolerance dotyku a překročení linie zavírací cenou (zlomek ceny).
    public var tolerance: Double
    /// Linie se sklonem do ± `flat` × cena za svíčku je plochá.
    public var flat: Double
    /// Týdenní KP 10/20/40 seřazeny + PSAR ve směru.
    public var weeklyFilter: Bool
    /// Denní SMA 50 > 100 > 200 ve směru.
    public var dailyFilter: Bool
    /// Odraz: mezi swingem a cílem není rezistence (support).
    public var headroom: Bool
    public var stopATR: Double
    /// Cíl průrazu trendline a odrazu: Fibonacciho extenze (1.272 / 1.618).
    public var targetFib: Double
    public var minRR: Double
    public var maxRR: Double
    public var swingBars: Int
    /// Reverzní patterny u odrazu.
    public var twoCandle: Bool
    public var oneCandle: Bool

    public init(triangle: Bool = true, bounce: Bool = true, breakout: Bool = true, lookback: Int = 120,
                minTouches: Int = 2, tolerance: Double = 0.01, flat: Double = 0.0003, weeklyFilter: Bool = true,
                dailyFilter: Bool = true, headroom: Bool = true, stopATR: Double = 1, targetFib: Double = 1.618,
                minRR: Double = 1.5, maxRR: Double = 3, swingBars: Int = 20, twoCandle: Bool = true,
                oneCandle: Bool = true) {
        self.triangle = triangle
        self.bounce = bounce
        self.breakout = breakout
        self.lookback = lookback
        self.minTouches = minTouches
        self.tolerance = tolerance
        self.flat = flat
        self.weeklyFilter = weeklyFilter
        self.dailyFilter = dailyFilter
        self.headroom = headroom
        self.stopATR = stopATR
        self.targetFib = targetFib
        self.minRR = minRR
        self.maxRR = maxRR
        self.swingBars = swingBars
        self.twoCandle = twoCandle
        self.oneCandle = oneCandle
    }
}

public enum TrendlineEntry: String, Codable, Hashable, Sendable, CaseIterable {
    case triangle
    case breakout
    case bounce

    public func name(direction: Int) -> String {
        switch self {
        case .triangle: return direction > 0 ? "Průraz trojúhelníku" : "Průraz trojúhelníku dolů"
        case .breakout: return direction > 0 ? "Průraz trendline" : "Průraz trendline dolů"
        case .bounce: return "Odraz od trendline"
        }
    }
}

/// Trendová linie přes dva swingy.
public struct SwingLine: Hashable, Codable, Sendable {
    public var startIndex: Int
    public var startPrice: Double
    public var endIndex: Int
    public var endPrice: Double
    public var slope: Double
    public var touches: Int

    public func value(at x: Int) -> Double { startPrice + slope * Double(x - startIndex) }

    var key: (Int, Int, Int) { (touches, endIndex, endIndex - startIndex) }
}

public struct TrendlineSignal: Hashable, Codable, Sendable {
    public var index: Int
    public var date: Date
    public var entry: TrendlineEntry
    public var direction: Int
    /// Hodnota linie na svíčce vstupu.
    public var level: Double
    public var price: Double
    public var stop: Double
    public var target: Double
}

/// Kandidát: cena uvnitř trojúhelníku, nebo u trendline.
public struct TrendlineWatch: Hashable, Codable, Sendable {
    public var entry: TrendlineEntry
    public var direction: Int
    public var level: Double
    public var distanceATR: Double
}

/// Trojúhelník na poslední svíčce (pro graf a skener).
public struct TrianglePattern: Hashable, Sendable {
    public var resistance: SwingLine
    public var support: SwingLine
    public var height: Double

    public var kind: String {
        if abs(resistance.slope) < abs(support.slope) * 0.25 { return "rostoucí" }
        if abs(support.slope) < abs(resistance.slope) * 0.25 { return "klesající" }
        return "symetrický"
    }
}

public struct TrendlineEvaluation: Sendable {
    public var targets: [Int]
    public var signals: [TrendlineSignal]
    public var watch: TrendlineWatch?
    public var triangle: TrianglePattern?
    public var atr: Double?
}

/// Trendlinie a trojúhelník: průraz trojúhelníku, odraz od trendline a průraz trendline (long i short).
/// Linie jen z potvrzených swingů, vše po svíčkách bez pohledu do budoucnosti.
/// Referenční implementace v Pythonu je stejná (export do QuantConnectu).
public enum TrendlineStrategy {
    static let pivotWindow = 3
    static let atrPeriod = 14
    static let maxPivots = 8

    public static func evaluate(_ bars: [BacktestBar], settings: TrendlineSettings, allowShort: Bool) -> TrendlineEvaluation {
        var state = State(s: settings, allowShort: allowShort)
        var targets: [Int] = []
        targets.reserveCapacity(bars.count)
        for bar in bars { targets.append(state.update(bar)) }
        let last = state.lastLines()
        return TrendlineEvaluation(targets: targets, signals: state.signals, watch: state.watch(lines: last),
                                   triangle: last.flatMap { state.triangle(state.bars.count - 1, $0.highs, $0.lows) },
                                   atr: state.atr.last ?? nil)
    }

    typealias Lines = [Int: SwingLine]

    struct Pending {
        var entry: TrendlineEntry
        var line: SwingLine
        var height: Double
        var top: Double
        var other: Double
    }

    struct Candidate {
        var priority: Int
        var entry: TrendlineEntry
        var direction: Int
        var line: SwingLine
        var height: Double
        var top: Double
        var other: Double
    }

    struct State {
        let s: TrendlineSettings
        let allowShort: Bool
        var bars: [BacktestBar] = []
        var closes: [Double] = []
        var trs: [Double] = []
        var atr: [Double?] = []
        var sma50: [Double?] = [], sma100: [Double?] = [], sma200: [Double?] = []
        var pivotHigh: [Int] = []
        var pivotLow: [Int] = []
        var weekKey: Int? = nil
        var week: (o: Double, h: Double, l: Double, c: Double)? = nil
        var weeklyCloses: [Double] = []
        var weeklyPsar = BreakoutStrategy.Psar()
        var weeklyUp: Bool? = nil
        var weeklyTrend = 0
        var position = 0
        var stop = 0.0, target = 0.0
        var pending: [Int: Pending] = [:]
        var signals: [TrendlineSignal] = []

        init(s: TrendlineSettings, allowShort: Bool) {
            self.s = s
            self.allowShort = allowShort
        }

        mutating func weekly(_ bar: BacktestBar) {
            let key = BreakoutStrategy.weekKey(bar.date)
            if let current = weekKey, key != current, let w = week {
                weeklyCloses.append(w.c)
                weeklyUp = weeklyPsar.update(h: w.h, l: w.l, c: w.c)
                if let s10 = BreakoutStrategy.smaLast(weeklyCloses, 10), let s20 = BreakoutStrategy.smaLast(weeklyCloses, 20),
                   let s40 = BreakoutStrategy.smaLast(weeklyCloses, 40) {
                    weeklyTrend = s10 > s20 && s20 > s40 ? 1 : (s10 < s20 && s20 < s40 ? -1 : 0)
                } else {
                    weeklyTrend = 0
                }
                week = nil
            }
            weekKey = key
            if var w = week {
                w.h = max(w.h, bar.high)
                w.l = min(w.l, bar.low)
                w.c = bar.close
                week = w
            } else {
                week = (bar.open, bar.high, bar.low, bar.close)
            }
        }

        mutating func indicators(_ bar: BacktestBar) {
            let i = bars.count - 1
            closes.append(bar.close)
            if i == 0 {
                trs.append(bar.high - bar.low)
            } else {
                let pc = closes[closes.count - 2]
                trs.append(max(bar.high - bar.low, abs(bar.high - pc), abs(bar.low - pc)))
            }
            atr.append(i >= atrPeriod ? trs[(trs.count - atrPeriod)...].reduce(0, +) / Double(atrPeriod) : nil)
            sma50.append(BreakoutStrategy.smaLast(closes, 50))
            sma100.append(BreakoutStrategy.smaLast(closes, 100))
            sma200.append(BreakoutStrategy.smaLast(closes, 200))
            let k = pivotWindow
            let p = i - k
            if p >= k {
                let hp = bars[p].high, lp = bars[p].low
                let left = bars[(p - k)..<p]
                let right = bars[(p + 1)...i]
                if left.allSatisfy({ $0.high < hp }) && right.allSatisfy({ $0.high <= hp }) { pivotHigh.append(p) }
                if left.allSatisfy({ $0.low > lp }) && right.allSatisfy({ $0.low >= lp }) { pivotLow.append(p) }
            }
        }

        // MARK: Linie

        func lines(high: Bool, _ i: Int) -> Lines {
            let source = high ? pivotHigh : pivotLow
            let piv = Array(source.filter { $0 >= i - s.lookback && $0 <= i - 1 - pivotWindow }.suffix(maxPivots))
            var best: Lines = [:]
            guard piv.count >= 2 else { return best }
            for a in 0..<piv.count {
                for b in (a + 1)..<piv.count {
                    let p1 = piv[a], p2 = piv[b]
                    if p2 - p1 < 5 { continue }
                    let y1 = high ? bars[p1].high : bars[p1].low
                    let y2 = high ? bars[p2].high : bars[p2].low
                    let slope = (y2 - y1) / Double(p2 - p1)
                    var ok = true
                    for j in p1..<i {
                        let v = y1 + slope * Double(j - p1)
                        let c = bars[j].close
                        if (high && c > v * (1 + s.tolerance)) || (!high && c < v * (1 - s.tolerance)) {
                            ok = false
                            break
                        }
                    }
                    if !ok { continue }
                    var touches = 0
                    for q in piv where q >= p1 {
                        let v = y1 + slope * Double(q - p1)
                        let y = high ? bars[q].high : bars[q].low
                        if abs(y - v) <= s.tolerance * v { touches += 1 }
                    }
                    if touches < s.minTouches { continue }
                    let ref = closes[i - 1]
                    let cls = abs(slope) <= s.flat * ref ? 0 : (slope > 0 ? 1 : -1)
                    let line = SwingLine(startIndex: p1, startPrice: y1, endIndex: p2, endPrice: y2,
                                         slope: slope, touches: touches)
                    if let current = best[cls], !(line.key > current.key) { continue }
                    best[cls] = line
                }
            }
            return best
        }

        static func pick(_ lines: Lines, _ classes: [Int]) -> SwingLine? {
            var chosen: SwingLine? = nil
            for c in classes {
                guard let line = lines[c] else { continue }
                if chosen == nil || line.key > chosen!.key { chosen = line }
            }
            return chosen
        }

        func triangle(_ i: Int, _ highs: Lines, _ lows: Lines) -> TrianglePattern? {
            guard let res = Self.pick(highs, [-1, 0]), let sup = Self.pick(lows, [0, 1]) else { return nil }
            guard res.slope - sup.slope < -s.flat * closes[i - 1] else { return nil }
            let start = min(res.startIndex, sup.startIndex)
            guard max(res.startIndex, sup.startIndex) < min(res.endIndex, sup.endIndex) else { return nil }
            let w0 = res.value(at: start) - sup.value(at: start)
            let w1 = res.value(at: i) - sup.value(at: i)
            guard w0 > 0, w1 > 0, w1 <= 0.6 * w0 else { return nil }
            let c = closes[i - 1]
            guard sup.value(at: i - 1) <= c && c <= res.value(at: i - 1) else { return nil }
            return TrianglePattern(resistance: res, support: sup, height: w0)
        }

        mutating func lastLines() -> (highs: Lines, lows: Lines)? {
            let i = bars.count - 1
            guard i >= 3 else { return nil }
            return (lines(high: true, i), lines(high: false, i))
        }

        // MARK: Filtry a plány

        func filters(_ d: Int) -> Bool {
            let i = bars.count - 1
            if d == -1 && !allowShort { return false }
            if s.weeklyFilter && !(weeklyTrend == d && weeklyUp == (d == 1)) { return false }
            if s.dailyFilter {
                guard let a = sma50[i], let b = sma100[i], let c = sma200[i] else { return false }
                if !((a - b) * Double(d) > 0 && (b - c) * Double(d) > 0) { return false }
            }
            return true
        }

        func clean(_ d: Int, _ level: Double) -> Bool {
            let bar = bars[bars.count - 1]
            let sd = Double(d)
            return (bar.open - level) * sd > 0 && (bar.close - level) * sd > 0 && (bar.close - bar.open) * sd > 0
        }

        func breakoutPlan(_ c: Candidate, _ atr: Double) -> (stop: Double, target: Double)? {
            let i = bars.count - 1
            let bar = bars[i], prev = bars[i - 1]
            let close = bar.close
            let d = c.direction, sd = Double(d)
            let lv = c.line.value(at: i)
            let stop = d == 1 ? min(prev.low, close - s.stopATR * atr) : max(prev.high, close + s.stopATR * atr)
            let risk = (close - stop) * sd
            var target: Double
            if c.entry == .triangle {
                target = lv + sd * c.height
                target = d == 1 ? max(target, close + 1.5 * atr) : min(target, close - 1.5 * atr)
            } else {
                target = c.other + (c.top - c.other) * s.targetFib
                target = d == 1 ? max(target, close + 1.5 * atr) : min(target, close - 1.5 * atr)
                if (target - close) * sd < s.minRR * risk { return nil }
            }
            return (stop, target)
        }

        func bouncePlan(_ d: Int, _ line: SwingLine, _ atr: Double) -> (stop: Double, target: Double)? {
            let i = bars.count - 1
            let r = i - 1
            guard r >= 2 else { return nil }
            let R = bars[r], C = bars[i]
            let v = line.value(at: r)
            let bodyLow = min(R.open, R.close), bodyHigh = max(R.open, R.close)
            let body = bodyHigh - bodyLow
            let range = R.high - R.low
            if d == 1 {
                guard bodyLow > v && R.low <= v * (1 + s.tolerance) else { return nil }
                let two = R.low < min(bars[r - 1].low, bars[r - 2].low)
                let wick = bodyLow - R.low
                let pin = range > 0 && wick >= 2 * body && wick >= 0.5 * range
                guard (s.twoCandle && two) || (s.oneCandle && pin) else { return nil }
                guard C.close > C.open && C.low > R.low && C.close > R.high else { return nil }
            } else {
                guard bodyHigh < v && R.high >= v * (1 - s.tolerance) else { return nil }
                let two = R.high > max(bars[r - 1].high, bars[r - 2].high)
                let wick = R.high - bodyHigh
                let pin = range > 0 && wick >= 2 * body && wick >= 0.5 * range
                guard (s.twoCandle && two) || (s.oneCandle && pin) else { return nil }
                guard C.close < C.open && C.high < R.high && C.close < R.low else { return nil }
            }
            let entry = C.close
            let window = bars[max(0, r - s.swingBars + 1)...r]
            if d == 1 {
                let stop = min(R.low, entry - s.stopATR * atr)
                let risk = entry - stop
                let swing = window.map(\.high).max()!
                let fib = R.low + (swing - R.low) * s.targetFib
                let target = min(max(fib, entry + s.minRR * risk), entry + s.maxRR * risk)
                if s.headroom && pivotHigh.contains(where: { bars[$0].high > swing && bars[$0].high < target }) {
                    return nil
                }
                return (stop, target)
            }
            let stop = max(R.high, entry + s.stopATR * atr)
            let risk = stop - entry
            let swing = window.map(\.low).min()!
            let fib = R.high - (R.high - swing) * s.targetFib
            let target = max(min(fib, entry - s.minRR * risk), entry - s.maxRR * risk)
            if s.headroom && pivotLow.contains(where: { bars[$0].low > target && bars[$0].low < swing }) {
                return nil
            }
            return (stop, target)
        }

        // MARK: Krok

        mutating func update(_ bar: BacktestBar) -> Int {
            bars.append(bar)
            weekly(bar)
            indicators(bar)
            let i = bars.count - 1
            guard i >= 3, let atr = atr[i] else { return position }

            var exited = false
            if position == 1 && (bar.close <= stop || bar.close >= target) {
                position = 0; exited = true
            } else if position == -1 && (bar.close >= stop || bar.close <= target) {
                position = 0; exited = true
            }

            let highs = lines(high: true, i)
            let lows = lines(high: false, i)
            let tri = s.triangle ? triangle(i, highs, lows) : nil
            var candidates: [Candidate] = []
            for d in [1, -1] {
                let sd = Double(d)
                let waiting = pending[d]
                pending[d] = nil
                if let w = waiting, clean(d, w.line.value(at: i)) {
                    candidates.append(Candidate(priority: w.entry == .triangle ? 0 : 1, entry: w.entry, direction: d,
                                                line: w.line, height: w.height, top: w.top, other: w.other))
                }
                if let tri {
                    let line = d == 1 ? tri.resistance : tri.support
                    if (bar.close - line.value(at: i)) * sd > 0 {
                        if clean(d, line.value(at: i)) {
                            candidates.append(Candidate(priority: 0, entry: .triangle, direction: d, line: line,
                                                        height: tri.height, top: 0, other: 0))
                        } else {
                            pending[d] = Pending(entry: .triangle, line: line, height: tri.height, top: 0, other: 0)
                        }
                    }
                }
                if s.breakout, let line = d == 1 ? highs[-1] : lows[1],
                   (bar.close - line.value(at: i)) * sd > 0,
                   (closes[i - 1] - line.value(at: i - 1)) * sd <= 0 {
                    let segment = bars[line.startIndex..<i]
                    let other = d == 1 ? segment.map(\.low).min()! : segment.map(\.high).max()!
                    if clean(d, line.value(at: i)) {
                        candidates.append(Candidate(priority: 1, entry: .breakout, direction: d, line: line,
                                                    height: 0, top: line.startPrice, other: other))
                    } else if pending[d] == nil {
                        pending[d] = Pending(entry: .breakout, line: line, height: 0, top: line.startPrice, other: other)
                    }
                }
                if s.bounce, let line = d == 1 ? lows[1] : highs[-1] {
                    candidates.append(Candidate(priority: 2, entry: .bounce, direction: d, line: line,
                                                height: 0, top: 0, other: 0))
                }
            }

            if position == 0 && !exited {
                let ordered = candidates.enumerated()
                    .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
                    .map(\.element)
                for c in ordered {
                    guard filters(c.direction) else { continue }
                    let plan = c.entry == .bounce ? bouncePlan(c.direction, c.line, atr) : breakoutPlan(c, atr)
                    guard let plan else { continue }
                    position = c.direction
                    stop = plan.stop
                    target = plan.target
                    signals.append(TrendlineSignal(index: i, date: bar.date, entry: c.entry, direction: c.direction,
                                                   level: c.line.value(at: i), price: bar.close,
                                                   stop: plan.stop, target: plan.target))
                    pending = [:]
                    break
                }
            }
            return position
        }

        func watch(lines last: (highs: Lines, lows: Lines)?) -> TrendlineWatch? {
            let i = bars.count - 1
            guard i >= 3, let atr = atr[i], position == 0, let last else { return nil }
            let close = bars[i].close
            if s.triangle, let tri = triangle(i, last.highs, last.lows) {
                for d in [1, -1] where filters(d) {
                    let lv = (d == 1 ? tri.resistance : tri.support).value(at: i)
                    let distance = (lv - close) * Double(d) / atr
                    if distance >= 0 { return TrendlineWatch(entry: .triangle, direction: d, level: lv, distanceATR: distance) }
                }
            }
            if s.bounce {
                for d in [1, -1] {
                    guard let line = d == 1 ? last.lows[1] : last.highs[-1], filters(d) else { continue }
                    let lv = line.value(at: i)
                    let distance = (close - lv) * Double(d) / atr
                    if distance >= 0 && distance <= 1 {
                        return TrendlineWatch(entry: .bounce, direction: d, level: lv, distanceATR: distance)
                    }
                }
            }
            return nil
        }
    }
}
