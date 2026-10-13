import Foundation

/// Nastavení strategie Odraz od klouzavých průměrů (SMA 20/50/100/200).
public struct MABounceSettings: Hashable, Codable, Sendable {
    /// Které průměry se obchodují.
    public var ma20: Bool
    public var ma50: Bool
    public var ma100: Bool
    public var ma200: Bool
    /// 2svíčkový pattern (reverzní svíčka níž než předchozí dvě) a 1svíčkový (pinbar).
    public var twoCandle: Bool
    public var oneCandle: Bool
    /// Průměr byl testovaný už dřív (v posledních `priorBars` svíčkách).
    public var priorTest: Bool
    public var priorBars: Int
    /// U 20 MA: týdenní cena nad 10 MA a týdenní KP 10/20/40 rostou.
    public var weeklyFilter: Bool
    /// U 50 MA: stochastic (21, 3) v přeprodané zóně pod 30 (u shortu nad 70).
    public var stochasticFilter: Bool
    /// Mezi swingem pullbacku a cílem není rezistence (support).
    public var headroom: Bool
    /// Stop pod reverzní svíčku, aspoň `stopATR` × ATR.
    public var stopATR: Double
    /// Cíl: Fibonacciho extenze pullbacku, omezená na `minRR`–`maxRR` × riziko.
    public var targetFib: Double
    public var minRR: Double
    public var maxRR: Double
    /// Swing před pullbackem z posledních N svíček.
    public var swingBars: Int

    public init(ma20: Bool = true, ma50: Bool = true, ma100: Bool = true, ma200: Bool = true,
                twoCandle: Bool = true, oneCandle: Bool = true, priorTest: Bool = true, priorBars: Int = 60,
                weeklyFilter: Bool = true, stochasticFilter: Bool = true, headroom: Bool = true,
                stopATR: Double = 1, targetFib: Double = 1.618, minRR: Double = 1.5, maxRR: Double = 3,
                swingBars: Int = 20) {
        self.ma20 = ma20
        self.ma50 = ma50
        self.ma100 = ma100
        self.ma200 = ma200
        self.twoCandle = twoCandle
        self.oneCandle = oneCandle
        self.priorTest = priorTest
        self.priorBars = priorBars
        self.weeklyFilter = weeklyFilter
        self.stochasticFilter = stochasticFilter
        self.headroom = headroom
        self.stopATR = stopATR
        self.targetFib = targetFib
        self.minRR = minRR
        self.maxRR = maxRR
        self.swingBars = swingBars
    }

    func isEnabled(_ period: Int) -> Bool {
        switch period {
        case 20: return ma20
        case 50: return ma50
        case 100: return ma100
        default: return ma200
        }
    }

    var enabledPeriods: [Int] { MABounceStrategy.periods.filter(isEnabled) }
}

public struct MABounceSignal: Hashable, Codable, Sendable {
    public var index: Int
    public var date: Date
    /// Průměr, od kterého se cena odrazila (20, 50, 100, 200).
    public var period: Int
    public var direction: Int
    /// Hodnota průměru na reverzní svíčce.
    public var level: Double
    public var price: Double
    public var stop: Double
    public var target: Double
}

/// Cena se v trendu vrací k průměru – kandidát na odraz.
public struct MABounceWatch: Hashable, Codable, Sendable {
    public var direction: Int
    public var period: Int
    public var level: Double
    public var distanceATR: Double
}

public struct MABounceEvaluation: Sendable {
    public var targets: [Int]
    public var signals: [MABounceSignal]
    public var watch: MABounceWatch?
    public var atr: Double?
}

/// Odraz od klouzavých průměrů s reverzním svíčkovým patternem (denní svíčky, filtr týdenního grafu u 20 MA).
/// Referenční implementace v Pythonu je stejná po svíčkách (export do QuantConnectu).
public enum MABounceStrategy {
    static let periods = [20, 50, 100, 200]
    static let pivotWindow = 3
    static let atrPeriod = 14

    public static func evaluate(_ bars: [BacktestBar], settings: MABounceSettings, allowShort: Bool) -> MABounceEvaluation {
        var state = State(s: settings, allowShort: allowShort)
        var targets: [Int] = []
        targets.reserveCapacity(bars.count)
        for bar in bars { targets.append(state.update(bar)) }
        return MABounceEvaluation(targets: targets, signals: state.signals, watch: state.watch(),
                                  atr: state.atr.last ?? nil)
    }

    struct State {
        let s: MABounceSettings
        let allowShort: Bool
        var bars: [BacktestBar] = []
        var closes: [Double] = []
        var trs: [Double] = []
        var atr: [Double?] = []
        var ma: [Int: [Double?]] = [20: [], 50: [], 100: [], 200: []]
        var rawK: [Double?] = []
        var slowK: [Double?] = []
        var pivotHigh: [Int] = []
        var pivotLow: [Int] = []
        var weekKey: Int? = nil
        var weekClose = 0.0
        var weeklyCloses: [Double] = []
        var weeklyState = 0
        var position = 0
        var stop = 0.0, target = 0.0
        var signals: [MABounceSignal] = []

        var directions: [Int] { allowShort ? [1, -1] : [1] }

        mutating func weekly(_ bar: BacktestBar) {
            let key = BreakoutStrategy.weekKey(bar.date)
            if let current = weekKey, key != current {
                weeklyCloses.append(weekClose)
                weeklyState = 0
                if weeklyCloses.count >= 41 {
                    let previous = Array(weeklyCloses.dropLast())
                    let now = [10, 20, 40].map { BreakoutStrategy.smaLast(weeklyCloses, $0)! }
                    let before = [10, 20, 40].map { BreakoutStrategy.smaLast(previous, $0)! }
                    let c = weeklyCloses[weeklyCloses.count - 1]
                    if c > now[0] && zip(now, before).allSatisfy({ $0 > $1 }) {
                        weeklyState = 1
                    } else if c < now[0] && zip(now, before).allSatisfy({ $0 < $1 }) {
                        weeklyState = -1
                    }
                }
            }
            weekKey = key
            weekClose = bar.close
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
            for p in periods { ma[p]!.append(BreakoutStrategy.smaLast(closes, p)) }
            if i >= 20 {
                let window = bars[(i - 20)...i]
                let hh = window.map(\.high).max()!
                let ll = window.map(\.low).min()!
                rawK.append(hh > ll ? 100.0 * (bar.close - ll) / (hh - ll) : 50.0)
            } else {
                rawK.append(nil)
            }
            if rawK.count >= 3 {
                let last3 = rawK[(rawK.count - 3)...]
                if last3.allSatisfy({ $0 != nil }) {
                    slowK.append(last3.map { $0! }.reduce(0, +) / 3)
                } else {
                    slowK.append(nil)
                }
            } else {
                slowK.append(nil)
            }
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

        func aligned(_ period: Int, _ i: Int, _ d: Int) -> Bool {
            let need: [Int]
            switch period {
            case 20, 50: need = [20, 50, 100, 200]
            case 100: need = [50, 100, 200]
            default: need = [100, 200]
            }
            var values: [Double] = []
            for p in need {
                guard let v = ma[p]![i] else { return false }
                values.append(v)
            }
            return (0..<(values.count - 1)).allSatisfy { (values[$0] - values[$0 + 1]) * Double(d) > 0 }
        }

        func testedBefore(_ period: Int, _ r: Int, _ d: Int) -> Bool {
            let start = max(0, r - s.priorBars)
            guard start < r - 4 else { return false }
            for j in start..<(r - 4) {
                guard let v = ma[period]![j] else { continue }
                let b = bars[j]
                if d == 1 && b.low <= v && b.close > v { return true }
                if d == -1 && b.high >= v && b.close < v { return true }
            }
            return false
        }

        func pattern(_ period: Int, _ i: Int, _ d: Int) -> Bool {
            let r = i - 1
            guard r >= 2, let v = ma[period]![r] else { return false }
            let R = bars[r], C = bars[i]
            let bodyLow = min(R.open, R.close), bodyHigh = max(R.open, R.close)
            let body = bodyHigh - bodyLow
            let range = R.high - R.low
            if d == 1 {
                guard bodyLow > v && R.low < v else { return false }
                let two = R.low < min(bars[r - 1].low, bars[r - 2].low)
                let wick = bodyLow - R.low
                let pin = range > 0 && wick >= 2 * body && wick >= 0.5 * range
                guard (s.twoCandle && two) || (s.oneCandle && pin) else { return false }
                return C.close > C.open && C.low > R.low && C.close > R.high
            }
            guard bodyHigh < v && R.high > v else { return false }
            let two = R.high > max(bars[r - 1].high, bars[r - 2].high)
            let wick = R.high - bodyHigh
            let pin = range > 0 && wick >= 2 * body && wick >= 0.5 * range
            guard (s.twoCandle && two) || (s.oneCandle && pin) else { return false }
            return C.close < C.open && C.high < R.high && C.close < R.low
        }

        func filters(_ period: Int, _ i: Int, _ d: Int) -> Bool {
            guard aligned(period, i, d) else { return false }
            if s.priorTest && !testedBefore(period, i - 1, d) { return false }
            if period == 20 && s.weeklyFilter && weeklyState != d { return false }
            if period == 50 && s.stochasticFilter {
                let ks = slowK[max(0, i - 3)...i].compactMap { $0 }
                guard !ks.isEmpty else { return false }
                if d == 1 && ks.min()! >= 30 { return false }
                if d == -1 && ks.max()! <= 70 { return false }
            }
            return true
        }

        func plan(_ i: Int, _ d: Int, _ atr: Double) -> (stop: Double, target: Double)? {
            let r = i - 1
            let R = bars[r]
            let entry = bars[i].close
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
            guard position == 0 && !exited else { return position }
            for d in directions {
                var done = false
                for period in periods where s.isEnabled(period) {
                    guard pattern(period, i, d) && filters(period, i, d) else { continue }
                    if let p = plan(i, d, atr) {
                        position = d
                        stop = p.stop
                        target = p.target
                        signals.append(MABounceSignal(index: i, date: bar.date, period: period, direction: d,
                                                      level: ma[period]![i - 1]!, price: bar.close,
                                                      stop: p.stop, target: p.target))
                        done = true
                    }
                    break
                }
                if done { break }
            }
            return position
        }

        func watch() -> MABounceWatch? {
            let i = bars.count - 1
            guard i >= 3, let atr = atr[i], position == 0 else { return nil }
            let bar = bars[i], prev = bars[i - 1]
            for d in directions {
                for period in periods where s.isEnabled(period) {
                    guard let v = ma[period]![i], aligned(period, i, d) else { continue }
                    if period == 20 && s.weeklyFilter && weeklyState != d { continue }
                    let distance = (bar.close - v) * Double(d) / atr
                    if distance >= 0 && distance <= 1 && (bar.close - prev.close) * Double(d) < 0 {
                        return MABounceWatch(direction: d, period: period, level: v, distanceATR: distance)
                    }
                }
            }
            return nil
        }
    }
}
