import Foundation

/// Čára do grafu podle strategie.
public struct SetupShape: Hashable, Sendable {
    public enum Role: String, Sendable {
        case support, resistance, supportLine, resistanceLine, movingAverage, entry, stop, target
    }

    public var role: Role
    /// Krátký popisek („R 512.30“, „TL support“, „Stop 498.10“).
    public var label: String
    public var startDate: Date
    public var startPrice: Double
    public var endDate: Date
    public var endPrice: Double
    /// Vodorovná hladina přes celý graf.
    public var isHorizontal: Bool

    static func level(_ role: Role, _ name: String, _ price: Double, at date: Date) -> SetupShape {
        SetupShape(role: role, label: "\(name) \(String(format: "%.2f", price))", startDate: date, startPrice: price,
                   endDate: date, endPrice: price, isHorizontal: true)
    }
}

/// Co strategie na grafu právě vidí: hladiny, linie, vstup, stop a cíl.
public struct SetupPicture: Sendable {
    public var title: String
    public var direction: Int
    public var shapes: [SetupShape]
    public var entry: Double?
    public var stop: Double?
    public var target: Double?
}

public enum SetupGeometry {
    /// Kresba pro aktuální stav strategie na posledních svíčkách: otevřený vstup (se stopem a cílem),
    /// jinak kandidát, jinak samotná struktura (konsolidace, trojúhelník, trendlinie). `nil` = nic k zakreslení.
    public static func picture(for strategy: BacktestStrategy, bars: [BacktestBar], allowShort: Bool = true) -> SetupPicture? {
        guard bars.count > 30 else { return nil }
        switch strategy {
        case .buyAndHold: return nil
        case .breakout(let s): return breakout(bars, s, allowShort)
        case .maBounce(let s): return maBounce(bars, s, allowShort)
        case .trendline(let s): return trendline(bars, s, allowShort)
        }
    }

    static func trade(_ shapes: inout [SetupShape], entry: Double, stop: Double, target: Double, at date: Date) {
        shapes.append(.level(.entry, "Vstup", entry, at: date))
        shapes.append(.level(.stop, "Stop", stop, at: date))
        shapes.append(.level(.target, "Cíl", target, at: date))
    }

    static func zoneShapes(_ zone: BreakoutZone, direction d: Int, at date: Date) -> [SetupShape] {
        let top = d == 1 ? zone.level : zone.other
        let bottom = d == 1 ? zone.other : zone.level
        return [.level(.resistance, "R", top, at: date), .level(.support, "S", bottom, at: date)]
    }

    static func breakout(_ bars: [BacktestBar], _ s: BreakoutSettings, _ allowShort: Bool) -> SetupPicture? {
        let e = BreakoutStrategy.evaluate(bars, settings: s, allowShort: allowShort)
        let last = bars[bars.count - 1].date
        if let signal = e.signals.last, e.targets.last == signal.direction {
            var shapes: [SetupShape] = [.level(signal.direction > 0 ? .resistance : .support,
                                               signal.direction > 0 ? "R" : "S", signal.level, at: last)]
            trade(&shapes, entry: signal.price, stop: signal.stop, target: signal.target, at: last)
            return SetupPicture(title: signal.entry.name(direction: signal.direction), direction: signal.direction,
                                shapes: shapes, entry: signal.price, stop: signal.stop, target: signal.target)
        }
        if let w = e.watch, let zone = e.zones[w.direction] {
            return SetupPicture(title: w.direction > 0 ? "Konsolidace pod rezistencí" : "Konsolidace nad supportem",
                                direction: w.direction, shapes: zoneShapes(zone, direction: w.direction, at: last),
                                entry: nil, stop: nil, target: nil)
        }
        if let (d, zone) = e.zones.sorted(by: { $0.key > $1.key }).first {
            return SetupPicture(title: "Konsolidace", direction: 0, shapes: zoneShapes(zone, direction: d, at: last),
                                entry: nil, stop: nil, target: nil)
        }
        return nil
    }

    /// Průměr jako lomená čára po 5 svíčkách přes posledních `span` svíček.
    static func movingAverage(_ bars: [BacktestBar], period: Int, span: Int = 80) -> [SetupShape] {
        let sma = TA.sma(bars.map(\.close), period)
        let n = bars.count
        var shapes: [SetupShape] = []
        var i = max(period - 1, n - span)
        while i < n - 1 {
            let j = min(i + 5, n - 1)
            if let a = sma[i], let b = sma[j] {
                shapes.append(SetupShape(role: .movingAverage, label: "KP \(period)", startDate: bars[i].date,
                                         startPrice: a, endDate: bars[j].date, endPrice: b, isHorizontal: false))
            }
            i = j
        }
        return shapes
    }

    static func maBounce(_ bars: [BacktestBar], _ s: MABounceSettings, _ allowShort: Bool) -> SetupPicture? {
        let e = MABounceStrategy.evaluate(bars, settings: s, allowShort: allowShort)
        let last = bars[bars.count - 1].date
        if let signal = e.signals.last, e.targets.last == signal.direction {
            var shapes = movingAverage(bars, period: signal.period)
            trade(&shapes, entry: signal.price, stop: signal.stop, target: signal.target, at: last)
            return SetupPicture(title: "Odraz od KP \(signal.period)", direction: signal.direction, shapes: shapes,
                                entry: signal.price, stop: signal.stop, target: signal.target)
        }
        if let w = e.watch {
            return SetupPicture(title: "Test KP \(w.period)", direction: w.direction,
                                shapes: movingAverage(bars, period: w.period), entry: nil, stop: nil, target: nil)
        }
        return nil
    }

    static func lineShape(_ line: SwingLine, _ bars: [BacktestBar], support: Bool, name: String) -> SetupShape {
        let end = bars.count - 1
        return SetupShape(role: support ? .supportLine : .resistanceLine, label: "TL \(name)",
                          startDate: bars[line.startIndex].date, startPrice: line.startPrice,
                          endDate: bars[end].date, endPrice: line.value(at: end), isHorizontal: false)
    }

    static func triangleShapes(_ t: TrianglePattern, _ bars: [BacktestBar]) -> [SetupShape] {
        [lineShape(t.resistance, bars, support: false, name: "rezistence trojúhelníku"),
         lineShape(t.support, bars, support: true, name: "support trojúhelníku")]
    }

    static func trendline(_ bars: [BacktestBar], _ s: TrendlineSettings, _ allowShort: Bool) -> SetupPicture? {
        let e = TrendlineStrategy.evaluate(bars, settings: s, allowShort: allowShort)
        let last = bars[bars.count - 1].date
        if let signal = e.signals.last, e.targets.last == signal.direction {
            var shapes: [SetupShape]
            // Odraz long = rostoucí support, průraz long = klesající rezistence (u shortu naopak).
            let support = signal.entry == .bounce ? signal.direction > 0 : signal.direction < 0
            if signal.entry == .triangle, let other = signal.otherLine {
                let resistance = signal.direction > 0 ? signal.line : other
                let sup = signal.direction > 0 ? other : signal.line
                shapes = [lineShape(resistance, bars, support: false, name: "rezistence trojúhelníku"),
                          lineShape(sup, bars, support: true, name: "support trojúhelníku")]
            } else {
                shapes = [lineShape(signal.line, bars, support: support,
                                    name: support ? "support" : "rezistence")]
            }
            trade(&shapes, entry: signal.price, stop: signal.stop, target: signal.target, at: last)
            return SetupPicture(title: signal.entry.name(direction: signal.direction), direction: signal.direction,
                                shapes: shapes, entry: signal.price, stop: signal.stop, target: signal.target)
        }
        if let t = e.triangle {
            let d = e.watch?.entry == .triangle ? e.watch!.direction : 0
            return SetupPicture(title: "Trojúhelník (\(t.kind))", direction: d, shapes: triangleShapes(t, bars),
                                entry: nil, stop: nil, target: nil)
        }
        var shapes: [SetupShape] = []
        if let line = e.supportLine { shapes.append(lineShape(line, bars, support: true, name: "support")) }
        if let line = e.resistanceLine { shapes.append(lineShape(line, bars, support: false, name: "rezistence")) }
        guard !shapes.isEmpty else { return nil }
        let title = e.watch?.entry == .bounce ? "Test trendline" : "Trendlinie"
        return SetupPicture(title: title, direction: e.watch?.direction ?? 0, shapes: shapes,
                            entry: nil, stop: nil, target: nil)
    }
}

/// Plán obchodu strategie pro graf backtestu: stop, cíl a linie, ze kterých vstup vznikl.
public struct TradePlan: Hashable, Sendable {
    /// Svíčka signálu (obchod se otevře na otevření další svíčky).
    public var signalIndex: Int
    public var direction: Int
    public var title: String
    public var stop: Double
    public var target: Double
    public var shapes: [SetupShape]
}

extension SetupGeometry {
    /// Plány všech vstupů strategie (podle svíčky signálu). Buy & hold nemá žádné.
    public static func tradePlans(for strategy: BacktestStrategy, bars: [BacktestBar], allowShort: Bool) -> [TradePlan] {
        guard bars.count > 30 else { return [] }
        func segment(_ role: SetupShape.Role, _ label: String, from a: Int, _ pa: Double, to b: Int, _ pb: Double) -> SetupShape {
            SetupShape(role: role, label: label, startDate: bars[max(0, a)].date, startPrice: pa,
                       endDate: bars[min(b, bars.count - 1)].date, endPrice: pb, isHorizontal: false)
        }
        switch strategy {
        case .buyAndHold:
            return []
        case .breakout(let s):
            let e = BreakoutStrategy.evaluate(bars, settings: s, allowShort: allowShort)
            return e.signals.map { sig in
                let role: SetupShape.Role = sig.direction > 0 ? .resistance : .support
                let level = segment(role, sig.direction > 0 ? "R" : "S", from: sig.index - s.lookback, sig.level,
                                    to: sig.index, sig.level)
                return TradePlan(signalIndex: sig.index, direction: sig.direction,
                                 title: sig.entry.name(direction: sig.direction), stop: sig.stop, target: sig.target,
                                 shapes: [level])
            }
        case .maBounce(let s):
            let e = MABounceStrategy.evaluate(bars, settings: s, allowShort: allowShort)
            return e.signals.map { sig in
                let window = Array(bars[max(0, sig.index - 260)...sig.index])
                return TradePlan(signalIndex: sig.index, direction: sig.direction, title: "Odraz od KP \(sig.period)",
                                 stop: sig.stop, target: sig.target,
                                 shapes: movingAverage(window, period: sig.period, span: 40))
            }
        case .trendline(let s):
            let e = TrendlineStrategy.evaluate(bars, settings: s, allowShort: allowShort)
            return e.signals.map { sig in
                let support = sig.entry == .bounce ? sig.direction > 0 : sig.direction < 0
                var shapes = [segment(support ? .supportLine : .resistanceLine, "TL", from: sig.line.startIndex,
                                      sig.line.startPrice, to: sig.index, sig.line.value(at: sig.index))]
                if let other = sig.otherLine {
                    shapes.append(segment(sig.direction > 0 ? .supportLine : .resistanceLine, "TL",
                                          from: other.startIndex, other.startPrice, to: sig.index,
                                          other.value(at: sig.index)))
                }
                return TradePlan(signalIndex: sig.index, direction: sig.direction,
                                 title: sig.entry.name(direction: sig.direction), stop: sig.stop, target: sig.target,
                                 shapes: shapes)
            }
        }
    }
}
