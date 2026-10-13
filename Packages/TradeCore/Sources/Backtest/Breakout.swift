import Foundation

/// Nastavení strategie Breakout / Breakdown z konsolidace.
public struct BreakoutSettings: Hashable, Codable, Sendable {
    /// Délka konsolidace (svíčky), ze které se bere rezistence / support.
    public var lookback: Int
    /// Minimální počet swingových dotyků hladiny.
    public var minTouches: Int
    /// Tolerance dotyku jako zlomek ceny (0.01 = 1 %).
    public var tolerance: Double
    /// Vstupy: 1) těsně před průrazem absolutního vrcholu, 2) po čistém průrazu, 3) první pullback (PNR).
    public var preBreakout: Bool
    public var breakout: Bool
    public var pullback: Bool
    /// Týdenní graf: KP 10/20/40 seřazeny ve směru obchodu a PSAR ve směru.
    public var weeklyFilter: Bool
    /// Denní graf: SMA 20/50/100 seřazeny ve směru a PSAR ve směru.
    public var dailyFilter: Bool
    /// Konsolidace = SMA 20 a 50 se v ní aspoň jednou překřížily.
    public var requireMACross: Bool
    /// Volné místo k další rezistenci (supportu) v násobcích ATR; bez další hladiny (nový vrchol) vždy.
    public var headroomATR: Double
    /// Stop: vzdálenější z 1× ATR a předchozí svíčky.
    public var stopATR: Double
    /// Cíl: Fibonacciho extenze konsolidace (1.272 / 1.618), aspoň 1,5× ATR.
    public var targetFib: Double
    /// Kolik svíček po průrazu se čeká na pullback.
    public var pullbackBars: Int

    public init(lookback: Int = 120, minTouches: Int = 2, tolerance: Double = 0.01, preBreakout: Bool = true,
                breakout: Bool = true, pullback: Bool = true, weeklyFilter: Bool = true, dailyFilter: Bool = true,
                requireMACross: Bool = true, headroomATR: Double = 2, stopATR: Double = 1, targetFib: Double = 1.272,
                pullbackBars: Int = 20) {
        self.lookback = lookback
        self.minTouches = minTouches
        self.tolerance = tolerance
        self.preBreakout = preBreakout
        self.breakout = breakout
        self.pullback = pullback
        self.weeklyFilter = weeklyFilter
        self.dailyFilter = dailyFilter
        self.requireMACross = requireMACross
        self.headroomATR = headroomATR
        self.stopATR = stopATR
        self.targetFib = targetFib
        self.pullbackBars = pullbackBars
    }
}

/// Typ vstupu.
public enum BreakoutEntry: String, Codable, Hashable, Sendable, CaseIterable {
    case preBreakout
    case breakout
    case pullback

    public func name(direction: Int) -> String {
        switch self {
        case .preBreakout: return direction > 0 ? "Těsně před breakoutem" : "Těsně před breakdownem"
        case .breakout: return direction > 0 ? "Breakout" : "Breakdown"
        case .pullback: return "Pullback PNR"
        }
    }
}

public struct BreakoutSignal: Hashable, Codable, Sendable {
    public var index: Int
    public var date: Date
    public var entry: BreakoutEntry
    /// 1 long (breakout), −1 short (breakdown).
    public var direction: Int
    /// Prorazená (testovaná) hladina.
    public var level: Double
    public var price: Double
    public var stop: Double
    public var target: Double
}

/// Konsolidace těsně pod rezistencí (nad supportem) – kandidát na průraz.
public struct BreakoutWatch: Hashable, Codable, Sendable {
    public var direction: Int
    public var level: Double
    /// Vzdálenost od hladiny v násobcích ATR.
    public var distanceATR: Double
}

public struct BreakoutEvaluation: Sendable {
    /// Cílová pozice po zavření každé svíčky.
    public var targets: [Int]
    public var signals: [BreakoutSignal]
    /// Stav po poslední svíčce.
    public var watch: BreakoutWatch?
    public var atr: Double?
    /// Konsolidace na poslední svíčce podle směru (1 rezistence nad cenou, −1 support pod ní).
    public var zones: [Int: BreakoutZone] = [:]
}

/// Hladina konsolidace a její protější kraj.
public struct BreakoutZone: Hashable, Sendable {
    public var level: Double
    public var other: Double
}

/// Breakout nad rezistenci / breakdown pod support z konsolidace (denní svíčky, filtr týdenního grafu).
///
/// Vše se počítá jen z dat do aktuální svíčky (pivoty potvrzené až po 3 svíčkách, týden až po jeho uzavření).
/// Referenční implementace v Pythonu je stejná po svíčkách (export do QuantConnectu).
public enum BreakoutStrategy {
    static let pivotWindow = 3
    static let atrPeriod = 14

    public static func evaluate(_ bars: [BacktestBar], settings s: BreakoutSettings, allowShort: Bool) -> BreakoutEvaluation {
        var state = State(settings: s, allowShort: allowShort)
        var targets: [Int] = []
        targets.reserveCapacity(bars.count)
        for bar in bars {
            targets.append(state.update(bar))
        }
        var zones: [Int: BreakoutZone] = [:]
        if bars.count > 2 {
            for d in [1, -1] {
                if let z = state.zone(d) { zones[d] = BreakoutZone(level: z.level, other: z.other) }
            }
        }
        return BreakoutEvaluation(targets: targets, signals: state.signals, watch: state.watch(),
                                  atr: state.atr.last ?? nil, zones: zones)
    }

    /// Klíč týdne (ISO rok × 100 + týden) v UTC.
    static func weekKey(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return (c.yearForWeekOfYear ?? 0) * 100 + (c.weekOfYear ?? 0)
    }

    // MARK: - Parabolic SAR

    struct Psar {
        let step = 0.02
        let maximum = 0.2
        var bars: [(h: Double, l: Double, c: Double)] = []
        var up: Bool? = nil
        var sar = 0.0, ep = 0.0, af = 0.0

        mutating func update(h: Double, l: Double, c: Double) -> Bool? {
            bars.append((h, l, c))
            let n = bars.count
            if n == 1 { return nil }
            if n == 2 {
                let first = bars[0]
                let rising = c > first.c
                up = rising
                af = step
                if rising { sar = first.l; ep = max(h, first.h) } else { sar = first.h; ep = min(l, first.l) }
                return up
            }
            let p = bars[n - 2], pp = bars[n - 3]
            var next = sar + af * (ep - sar)
            if up == true {
                next = min(next, p.l, pp.l)
                if l < next {
                    up = false; next = ep; ep = l; af = step
                } else if h > ep {
                    ep = h; af = min(af + step, maximum)
                }
            } else {
                next = max(next, p.h, pp.h)
                if h > next {
                    up = true; next = ep; ep = h; af = step
                } else if l < ep {
                    ep = l; af = min(af + step, maximum)
                }
            }
            sar = next
            return up
        }
    }

    static func smaLast(_ values: [Double], _ period: Int) -> Double? {
        guard values.count >= period else { return nil }
        return values[(values.count - period)...].reduce(0, +) / Double(period)
    }

    // MARK: - Stav po svíčkách

    struct Event {
        var level: Double
        var other: Double
        var index: Int
        var extended: Bool
    }

    struct Candidate {
        var priority: Int
        var entry: BreakoutEntry
        var direction: Int
        var level: Double
        var other: Double
    }

    struct State {
        let s: BreakoutSettings
        let allowShort: Bool
        var bars: [BacktestBar] = []
        var closes: [Double] = []
        var trs: [Double] = []
        var atr: [Double?] = []
        var maDiff: [Int?] = []
        var sma20: [Double?] = [], sma50: [Double?] = [], sma100: [Double?] = []
        var psar = Psar()
        var psarUp: [Bool?] = []
        var pivotHigh: [Int] = []
        var pivotLow: [Int] = []
        var weekKey: Int? = nil
        var week: (o: Double, h: Double, l: Double, c: Double)? = nil
        var weeklyCloses: [Double] = []
        var weeklyPsar = Psar()
        var weeklyUp: Bool? = nil
        var weeklyTrend = 0
        var position = 0
        var stop = 0.0, target = 0.0
        var events: [Int: Event] = [:]
        var pending: [Int: (level: Double, other: Double)] = [:]
        var used: Set<String> = []
        var signals: [BreakoutSignal] = []

        init(settings: BreakoutSettings, allowShort: Bool) {
            self.s = settings
            self.allowShort = allowShort
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
            atr.append(i >= atrPeriod
                       ? trs[(trs.count - atrPeriod)...].reduce(0, +) / Double(atrPeriod) : nil)
            sma20.append(smaLast(closes, 20))
            sma50.append(smaLast(closes, 50))
            sma100.append(smaLast(closes, 100))
            if let a = sma20[i], let b = sma50[i] { maDiff.append(a > b ? 1 : -1) } else { maDiff.append(nil) }
            psarUp.append(psar.update(h: bar.high, l: bar.low, c: bar.close))
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

        mutating func weekly(_ bar: BacktestBar) {
            let key = BreakoutStrategy.weekKey(bar.date)
            if let current = weekKey, key != current, let w = week {
                weeklyCloses.append(w.c)
                weeklyUp = weeklyPsar.update(h: w.h, l: w.l, c: w.c)
                if let s10 = smaLast(weeklyCloses, 10), let s20 = smaLast(weeklyCloses, 20),
                   let s40 = smaLast(weeklyCloses, 40) {
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

        func filters(_ d: Int) -> Bool {
            let i = bars.count - 1
            if d == -1 && !allowShort { return false }
            if s.weeklyFilter && !(weeklyTrend == d && weeklyUp == (d == 1)) { return false }
            if s.dailyFilter {
                guard let a = sma20[i], let b = sma50[i], let c = sma100[i], psarUp[i] == (d == 1) else { return false }
                if d == 1 && !(a > b && b > c) { return false }
                if d == -1 && !(a < b && b < c) { return false }
            }
            return true
        }

        func zone(_ d: Int) -> (level: Double, other: Double)? {
            let i = bars.count - 1
            let start = i - s.lookback
            guard start >= 0 else { return nil }
            let window = bars[start..<i]
            let level: Double, other: Double, touches: Int
            let last = i - 1 - pivotWindow
            if d == 1 {
                level = window.map(\.high).max()!
                other = window.map(\.low).min()!
                touches = pivotHigh.filter { $0 >= start && $0 <= last && bars[$0].high >= level * (1 - s.tolerance) }.count
            } else {
                level = window.map(\.low).min()!
                other = window.map(\.high).max()!
                touches = pivotLow.filter { $0 >= start && $0 <= last && bars[$0].low <= level * (1 + s.tolerance) }.count
            }
            guard touches >= s.minTouches else { return nil }
            if s.requireMACross {
                let signs = maDiff[start..<i].compactMap { $0 }
                guard signs.count > 1, (1..<signs.count).contains(where: { signs[$0] != signs[$0 - 1] }) else { return nil }
            }
            return (level, other)
        }

        func headroomOK(_ d: Int, price: Double, atr: Double) -> Bool {
            if d == 1 {
                let above = pivotHigh.map { bars[$0].high }.filter { $0 > price }
                guard let nearest = above.min() else { return true }
                return nearest - price >= s.headroomATR * atr
            }
            let below = pivotLow.map { bars[$0].low }.filter { $0 < price }
            guard let nearest = below.max() else { return true }
            return price - nearest >= s.headroomATR * atr
        }

        static func reversal(_ d: Int, _ bar: BacktestBar) -> Bool {
            let body = abs(bar.close - bar.open)
            if d == 1 {
                if bar.close > bar.open { return true }
                let wick = min(bar.open, bar.close) - bar.low
                return wick >= 2 * body && wick > 0
            }
            if bar.close < bar.open { return true }
            let wick = bar.high - max(bar.open, bar.close)
            return wick >= 2 * body && wick > 0
        }

        mutating func update(_ bar: BacktestBar) -> Int {
            bars.append(bar)
            weekly(bar)
            indicators(bar)
            let i = bars.count - 1
            guard i >= 2, let atr = atr[i] else { return position }
            let prev = bars[i - 1]

            var exited = false
            if position == 1 && (bar.close <= stop || bar.close >= target) {
                position = 0; exited = true
            } else if position == -1 && (bar.close >= stop || bar.close <= target) {
                position = 0; exited = true
            }

            var candidates: [Candidate] = []
            for d in [1, -1] {
                let sd = Double(d)
                let z = zone(d)
                func clean(_ lv: Double) -> Bool {
                    (bar.open - lv) * sd > 0 && (bar.close - lv) * sd > 0 && (bar.close - bar.open) * sd > 0
                }

                let waiting = pending[d]
                pending[d] = nil
                if let waiting, clean(waiting.level) {
                    candidates.append(Candidate(priority: 0, entry: .breakout, direction: d,
                                                level: waiting.level, other: waiting.other))
                }

                if let z {
                    if (bar.close - z.level) * sd > 0 {
                        events[d] = Event(level: z.level, other: z.other, index: i, extended: false)
                        if clean(z.level) {
                            candidates.append(Candidate(priority: 0, entry: .breakout, direction: d,
                                                        level: z.level, other: z.other))
                        } else {
                            pending[d] = z
                        }
                    } else if s.preBreakout && (z.level - bar.close) * sd <= atr && (z.level - bar.close) * sd >= 0 {
                        let earlier = bars[0..<i]
                        let extreme = d == 1 ? earlier.map(\.high).max()! : earlier.map(\.low).min()!
                        if z.level == extreme && !used.contains("\(d)|\(z.level)") {
                            candidates.append(Candidate(priority: 2, entry: .preBreakout, direction: d,
                                                        level: z.level, other: z.other))
                        }
                    }
                }

                if let event = events[d], event.index < i {
                    let lv = event.level
                    if i - event.index > s.pullbackBars || (lv - bar.close) * sd > 0.5 * atr {
                        events[d] = nil
                    } else if event.extended {
                        let touched = d == 1 ? bar.low - lv <= 0.5 * atr : lv - bar.high <= 0.5 * atr
                        if touched && (bar.close - lv) * sd > 0 && Self.reversal(d, bar) {
                            candidates.append(Candidate(priority: 1, entry: .pullback, direction: d,
                                                        level: lv, other: event.other))
                        }
                    }
                    if events[d] != nil && (d == 1 ? bar.high - lv >= atr : lv - bar.low >= atr) {
                        events[d]?.extended = true
                    }
                }
            }

            if position == 0 && !exited {
                for c in candidates.enumerated().sorted(by: { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }).map(\.element) {
                    if !s.breakout && c.entry == .breakout { continue }
                    if !s.pullback && c.entry == .pullback { continue }
                    guard filters(c.direction), headroomOK(c.direction, price: bar.close, atr: atr) else { continue }
                    let d = c.direction
                    if d == 1 {
                        stop = min(prev.low, bar.close - s.stopATR * atr)
                        target = max(c.other + (c.level - c.other) * s.targetFib, bar.close + 1.5 * atr)
                    } else {
                        stop = max(prev.high, bar.close + s.stopATR * atr)
                        target = min(c.other - (c.other - c.level) * s.targetFib, bar.close - 1.5 * atr)
                    }
                    position = d
                    signals.append(BreakoutSignal(index: i, date: bar.date, entry: c.entry, direction: d,
                                                  level: c.level, price: bar.close, stop: stop, target: target))
                    used.insert("\(d)|\(c.level)")
                    if c.entry != .preBreakout {
                        events[d] = nil
                        pending[d] = nil
                    }
                    break
                }
            }
            return position
        }

        func watch() -> BreakoutWatch? {
            let i = bars.count - 1
            guard i >= 2, let atr = atr[i], position == 0 else { return nil }
            let close = bars[i].close
            var best: BreakoutWatch? = nil
            for d in [1, -1] {
                guard let z = zone(d), filters(d) else { continue }
                let distance = (z.level - close) * Double(d) / atr
                if distance >= 0 && distance <= 1.5 && (best == nil || distance < best!.distanceATR) {
                    best = BreakoutWatch(direction: d, level: z.level, distanceATR: distance)
                }
            }
            return best
        }
    }
}
