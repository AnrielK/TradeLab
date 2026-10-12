import SwiftUI

// MARK: - Definice

struct IndicatorParam: Identifiable, Hashable {
    let key: String
    let label: String
    let def: Double
    let min: Double
    let max: Double
    var step: Double = 1

    var id: String { key }
    var isInteger: Bool { step >= 1 }
}

struct IndicatorDef: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    /// true = kreslí se přes svíčky, false = vlastní panel dole
    let overlay: Bool
    let params: [IndicatorParam]
}

struct IndicatorStyle: Hashable, Codable {
    var colorHex: String = "#4aa8ff"
    var width: Double = 2
    /// 0 plná, 1 tečkovaná, 2 čárkovaná, 3 dlouhé čárky
    var lineStyle: Int = 0
    var opacity: Double = 1
    /// Doplňkové barvy pro indikátory s víc složkami (Squeeze).
    var extraHex: [String] = []

    func extra(_ i: Int, _ fallback: String) -> Color {
        Color(hex: i < extraHex.count ? extraHex[i] : fallback).opacity(opacity)
    }

    static let lineStyleNames = ["Plná", "Tečkovaná", "Čárkovaná", "Dlouhé čárky"]

    var color: Color { Color(hex: colorHex).opacity(opacity) }

    var dashPattern: [CGFloat] {
        switch lineStyle {
        case 1: return [2, 4]
        case 2: return [7, 5]
        case 3: return [14, 6]
        default: return []
        }
    }
}

// MARK: - Instance

/// Jedna běžící instance. Stejný druh může běžet vícekrát (SMA 20 i SMA 200),
/// proto vlastní `id` a vlastní parametry i styl.
struct IndicatorInstance: Identifiable, Hashable, Codable {
    var id = UUID()
    let defId: String
    var params: [String: Double]
    var style: IndicatorStyle

    enum CodingKeys: String, CodingKey { case id, defId, params, style }

    var def: IndicatorDef? { Indicators.def(id: defId) }

    var label: String {
        guard let def else { return defId.uppercased() }
        let vals = def.params.map { p -> String in
            let v = params[p.key] ?? p.def
            return p.isInteger ? String(Int(v)) : String(format: "%.1f", v)
        }
        return vals.isEmpty ? def.name : "\(def.name) \(vals.joined(separator: ", "))"
    }

    func value(_ key: String) -> Double {
        params[key] ?? def?.params.first { $0.key == key }?.def ?? 0
    }

    func intValue(_ key: String) -> Int { Int(value(key)) }
}

// MARK: - Spočítaný výstup

/// Hodnota indikátoru přiřazená ke konkrétní svíčce (index do pole barů).
struct IndicatorPoint {
    let index: Int
    let value: Double
}

/// Jedna vykreslovaná složka indikátoru (linie nebo histogram).
struct IndicatorLine {
    enum Kind { case line, histogram, dots }
    var kind: Kind = .line
    var points: [IndicatorPoint]
    var color: Color
    var width: Double
    var dash: [CGFloat]
    /// Histogram si barvu určuje podle znaménka.
    var positiveColor: Color? = nil
    var negativeColor: Color? = nil
    /// Barva pro každý bod zvlášť (Squeeze mění barvu podle stavu).
    var pointColors: [Color]? = nil
}

/// Výsledek výpočtu jedné instance.
struct IndicatorOutput {
    let instanceId: UUID
    let overlay: Bool
    /// Do kterého panelu pod grafem patří; nil u překryvných.
    var pane: Int? = nil
    let lines: [IndicatorLine]
    /// Popisek do rohu panelu.
    var label: String = ""
    var labelColor: Color = .white
}

// MARK: - Katalog

enum Indicators {

    static let overlays: [IndicatorDef] = [
        IndicatorDef(id: "sma", name: "SMA", detail: "Klouzavý průměr",
                     symbol: "chart.line.flattrend.xyaxis", overlay: true,
                     params: [IndicatorParam(key: "length", label: "Perioda",
                                             def: 20, min: 1, max: 500)]),
        IndicatorDef(id: "ema", name: "EMA", detail: "Exponenciální průměr",
                     symbol: "chart.line.uptrend.xyaxis", overlay: true,
                     params: [IndicatorParam(key: "length", label: "Perioda",
                                             def: 50, min: 1, max: 500)]),
        IndicatorDef(id: "bb", name: "Bollinger", detail: "Pásma kolem průměru",
                     symbol: "chart.bar.doc.horizontal", overlay: true,
                     params: [IndicatorParam(key: "length", label: "Perioda",
                                             def: 20, min: 2, max: 500),
                              IndicatorParam(key: "mult", label: "Odchylky",
                                             def: 2, min: 0.1, max: 10, step: 0.1)]),
        IndicatorDef(id: "vwap", name: "VWAP", detail: "Vážený průměr objemem",
                     symbol: "scalemass", overlay: true, params: [])
    ]

    static let oscillators: [IndicatorDef] = [
        IndicatorDef(id: "rsi", name: "RSI", detail: "Relativní síla",
                     symbol: "waveform.path.ecg", overlay: false,
                     params: [IndicatorParam(key: "length", label: "Perioda",
                                             def: 14, min: 2, max: 200)]),
        squeeze,
        IndicatorDef(id: "macd", name: "MACD", detail: "Konvergence průměrů",
                     symbol: "waveform.path", overlay: false,
                     params: [IndicatorParam(key: "fast", label: "Rychlá",
                                             def: 12, min: 1, max: 200),
                              IndicatorParam(key: "slow", label: "Pomalá",
                                             def: 26, min: 1, max: 400),
                              IndicatorParam(key: "signal", label: "Signál",
                                             def: 9, min: 1, max: 100)])
    ]

    /// TTM Squeeze — Bollingerova pásma uvnitř Keltnerova kanálu značí
    /// stlačení volatility; histogram ukazuje momentum.
    static let squeeze = IndicatorDef(
        id: "squeeze", name: "Squeeze", detail: "TTM Squeeze — stlačení a momentum",
        symbol: "arrow.left.and.right.square", overlay: false,
        params: [
            IndicatorParam(key: "bbLength", label: "Perioda BB", def: 20, min: 2, max: 200),
            IndicatorParam(key: "bbMult", label: "Odchylky BB", def: 2, min: 0.1, max: 10, step: 0.1),
            IndicatorParam(key: "kcLength", label: "Perioda KC", def: 20, min: 2, max: 200),
            IndicatorParam(key: "kcMult", label: "Násobek KC", def: 1.5, min: 0.1, max: 10, step: 0.1),
            IndicatorParam(key: "momLength", label: "Perioda momenta", def: 20, min: 2, max: 200)
        ])

    static let all: [IndicatorDef] = overlays + oscillators

    static func def(id: String) -> IndicatorDef? { all.first { $0.id == id } }

    /// Popisky doplňkových barev pro editor, podle druhu indikátoru.
    static func extraColorLabels(for defId: String) -> [String] {
        defId == "squeeze"
            ? ["Momentum roste (+)", "Momentum klesá (+)",
               "Momentum klesá (−)", "Momentum roste (−)",
               "Stlačení zapnuto", "Stlačení vypnuto"]
            : []
    }

    static let squeezeDefaultColors = [
        "#59d0d8", "#4aa8ff", "#e0566b", "#e0a83c", "#e6edf3", "#6a7b8c"
    ]

    static let palette = [
        "#4aa8ff", "#e0a83c", "#b58cff", "#2ea98c",
        "#e0566b", "#e6edf3", "#ff8f4a", "#59d0d8"
    ]
}

// MARK: - Výpočty

enum IndicatorMath {

    static func sma(_ bars: [Bar], _ n: Int) -> [IndicatorPoint] {
        guard n > 0, bars.count >= n else { return [] }
        var out: [IndicatorPoint] = []
        out.reserveCapacity(bars.count - n + 1)
        var sum = 0.0
        for i in bars.indices {
            sum += bars[i].close
            if i >= n { sum -= bars[i - n].close }
            if i >= n - 1 { out.append(IndicatorPoint(index: i, value: sum / Double(n))) }
        }
        return out
    }

    static func ema(_ bars: [Bar], _ n: Int) -> [IndicatorPoint] {
        guard n > 0, bars.count >= n else { return [] }
        let k = 2.0 / (Double(n) + 1)
        var prev = bars[0..<n].reduce(0) { $0 + $1.close } / Double(n)
        var out = [IndicatorPoint(index: n - 1, value: prev)]
        for i in n..<bars.count {
            prev = bars[i].close * k + prev * (1 - k)
            out.append(IndicatorPoint(index: i, value: prev))
        }
        return out
    }

    /// Vrací (horní, střední, dolní).
    static func bollinger(_ bars: [Bar], _ n: Int, _ mult: Double)
    -> ([IndicatorPoint], [IndicatorPoint], [IndicatorPoint]) {
        guard n > 1, bars.count >= n else { return ([], [], []) }
        var up: [IndicatorPoint] = [], mid: [IndicatorPoint] = [], lo: [IndicatorPoint] = []
        for i in (n - 1)..<bars.count {
            let win = bars[(i - n + 1)...i]
            let m = win.reduce(0) { $0 + $1.close } / Double(n)
            let variance = win.reduce(0) { $0 + ($1.close - m) * ($1.close - m) } / Double(n)
            let sd = variance.squareRoot()
            up.append(IndicatorPoint(index: i, value: m + mult * sd))
            mid.append(IndicatorPoint(index: i, value: m))
            lo.append(IndicatorPoint(index: i, value: m - mult * sd))
        }
        return (up, mid, lo)
    }

    static func vwap(_ bars: [Bar]) -> [IndicatorPoint] {
        var pv = 0.0, vv = 0.0
        return bars.enumerated().map { i, b in
            let tp = (b.high + b.low + b.close) / 3
            let v = b.volume ?? 0
            pv += tp * v; vv += v
            return IndicatorPoint(index: i, value: vv > 0 ? pv / vv : b.close)
        }
    }

    static func rsi(_ bars: [Bar], _ n: Int) -> [IndicatorPoint] {
        guard n > 1, bars.count > n else { return [] }
        var gain = 0.0, loss = 0.0
        for i in 1...n {
            let ch = bars[i].close - bars[i - 1].close
            if ch >= 0 { gain += ch } else { loss -= ch }
        }
        gain /= Double(n); loss /= Double(n)

        func rsiValue(_ g: Double, _ l: Double) -> Double {
            l == 0 ? 100 : 100 - 100 / (1 + g / l)
        }

        var out = [IndicatorPoint(index: n, value: rsiValue(gain, loss))]
        guard bars.count > n + 1 else { return out }
        for i in (n + 1)..<bars.count {
            let ch = bars[i].close - bars[i - 1].close
            gain = (gain * Double(n - 1) + Swift.max(ch, 0)) / Double(n)
            loss = (loss * Double(n - 1) + Swift.max(-ch, 0)) / Double(n)
            out.append(IndicatorPoint(index: i, value: rsiValue(gain, loss)))
        }
        return out
    }

    /// EMA počítaná nad už spočítanou řadou (pro signální linku MACD).
    static func ema(points: [IndicatorPoint], _ n: Int) -> [IndicatorPoint] {
        guard n > 0, points.count >= n else { return [] }
        let k = 2.0 / (Double(n) + 1)
        var prev = points[0..<n].reduce(0) { $0 + $1.value } / Double(n)
        var out = [IndicatorPoint(index: points[n - 1].index, value: prev)]
        for i in n..<points.count {
            prev = points[i].value * k + prev * (1 - k)
            out.append(IndicatorPoint(index: points[i].index, value: prev))
        }
        return out
    }

    /// Vrací (linie, signál, histogram).
    static func macd(_ bars: [Bar], fast: Int, slow: Int, signal: Int)
    -> ([IndicatorPoint], [IndicatorPoint], [IndicatorPoint]) {
        let ef = ema(bars, fast), es = ema(bars, slow)
        guard !ef.isEmpty, !es.isEmpty else { return ([], [], []) }

        var fastByIndex: [Int: Double] = [:]
        ef.forEach { fastByIndex[$0.index] = $0.value }

        let line = es.compactMap { p -> IndicatorPoint? in
            guard let f = fastByIndex[p.index] else { return nil }
            return IndicatorPoint(index: p.index, value: f - p.value)
        }
        let sig = ema(points: line, signal)

        var sigByIndex: [Int: Double] = [:]
        sig.forEach { sigByIndex[$0.index] = $0.value }

        let hist = line.compactMap { p -> IndicatorPoint? in
            guard let s = sigByIndex[p.index] else { return nil }
            return IndicatorPoint(index: p.index, value: p.value - s)
        }
        return (line, sig, hist)
    }

    /// Lineární regrese (hodnota na konci okna) — jádro TTM momenta.
    static func linreg(_ values: [Double], _ n: Int) -> [Double?] {
        guard n > 1 else { return values.map { $0 } }
        var out = [Double?](repeating: nil, count: values.count)
        let xMean = Double(n - 1) / 2
        var sxx = 0.0
        for i in 0..<n { sxx += (Double(i) - xMean) * (Double(i) - xMean) }
        guard sxx > 0 else { return out }

        for end in (n - 1)..<values.count {
            let win = values[(end - n + 1)...end]
            let yMean = win.reduce(0, +) / Double(n)
            var sxy = 0.0
            for (i, v) in win.enumerated() {
                sxy += (Double(i) - xMean) * (v - yMean)
            }
            let slope = sxy / sxx
            // hodnota regresní přímky na posledním bodě okna
            out[end] = yMean + slope * (Double(n - 1) - xMean)
        }
        return out
    }

    /// TTM Squeeze. Vrací momentum a příznak stlačení pro každý bar.
    static func squeeze(_ bars: [Bar], bbLength: Int, bbMult: Double,
                        kcLength: Int, kcMult: Double, momLength: Int)
    -> (momentum: [IndicatorPoint], squeezeOn: [Int: Bool]) {
        let n = bars.count
        guard n > Swift.max(bbLength, Swift.max(kcLength, momLength)) else { return ([], [:]) }

        let closes = bars.map(\.close)
        var flags: [Int: Bool] = [:]

        for i in (Swift.max(bbLength, kcLength) - 1)..<n {
            // Bollinger
            let bbWin = closes[(i - bbLength + 1)...i]
            let basis = bbWin.reduce(0, +) / Double(bbLength)
            let variance = bbWin.reduce(0) { $0 + ($1 - basis) * ($1 - basis) } / Double(bbLength)
            let dev = bbMult * variance.squareRoot()

            // Keltner — průměr pravého rozpětí
            let kcWin = bars[(i - kcLength + 1)...i]
            let ma = kcWin.reduce(0) { $0 + $1.close } / Double(kcLength)
            var trSum = 0.0
            for (k, b) in kcWin.enumerated() {
                let idx = i - kcLength + 1 + k
                let prevClose = idx > 0 ? bars[idx - 1].close : b.open
                trSum += Swift.max(b.high - b.low,
                                   Swift.max(abs(b.high - prevClose), abs(b.low - prevClose)))
            }
            let rangeMA = trSum / Double(kcLength)

            // stlačení = Bollinger celý uvnitř Keltnera
            flags[i] = (basis - dev > ma - rangeMA * kcMult)
                && (basis + dev < ma + rangeMA * kcMult)
        }

        // momentum: odchylka ceny od středu rozpětí, prohnaná regresí
        var source = [Double](repeating: 0, count: n)
        for i in 0..<n {
            guard i >= momLength - 1 else { continue }
            let win = bars[(i - momLength + 1)...i]
            let highest = win.map(\.high).max() ?? 0
            let lowest = win.map(\.low).min() ?? 0
            let smaClose = win.reduce(0) { $0 + $1.close } / Double(momLength)
            source[i] = bars[i].close - ((highest + lowest) / 2 + smaClose) / 2
        }
        let reg = linreg(source, momLength)

        var momentum: [IndicatorPoint] = []
        for i in (momLength * 2)..<n {
            guard let v = reg[i] else { continue }
            momentum.append(IndicatorPoint(index: i, value: v))
        }
        return (momentum, flags)
    }

    // MARK: Sestavení výstupu

    static func compute(_ inst: IndicatorInstance, bars: [Bar]) -> IndicatorOutput {
        let s = inst.style
        let overlay = inst.def?.overlay ?? true

        func line(_ pts: [IndicatorPoint], secondary: Bool = false) -> IndicatorLine {
            IndicatorLine(
                kind: .line,
                points: pts,
                color: secondary ? s.color.opacity(0.7) : s.color,
                width: secondary ? Swift.max(1, s.width - 1) : s.width,
                dash: secondary ? [6, 4] : s.dashPattern
            )
        }

        var lines: [IndicatorLine] = []
        switch inst.defId {
        case "sma":
            lines = [line(sma(bars, inst.intValue("length")))]
        case "ema":
            lines = [line(ema(bars, inst.intValue("length")))]
        case "vwap":
            lines = [line(vwap(bars))]
        case "bb":
            let (u, m, l) = bollinger(bars, inst.intValue("length"), inst.value("mult"))
            lines = [line(u), line(m, secondary: true), line(l)]
        case "rsi":
            lines = [line(rsi(bars, inst.intValue("length")))]
        case "squeeze":
            let (mom, flags) = squeeze(bars,
                                       bbLength: inst.intValue("bbLength"),
                                       bbMult: inst.value("bbMult"),
                                       kcLength: inst.intValue("kcLength"),
                                       kcMult: inst.value("kcMult"),
                                       momLength: inst.intValue("momLength"))

            // barva sloupce podle znaménka a směru — klasické schéma TTM
            let d = Indicators.squeezeDefaultColors
            var barColors: [Color] = []
            for (k, p) in mom.enumerated() {
                let prev = k > 0 ? mom[k - 1].value : p.value
                let rising = p.value >= prev
                if p.value >= 0 { barColors.append(rising ? s.extra(0, d[0]) : s.extra(1, d[1])) }
                else            { barColors.append(rising ? s.extra(3, d[3]) : s.extra(2, d[2])) }
            }

            // tečky na nule: stlačení zapnuto / vypnuto
            let dots = mom.map { IndicatorPoint(index: $0.index, value: 0) }
            let dotColors = mom.map { p in
                (flags[p.index] ?? false) ? s.extra(4, d[4]) : s.extra(5, d[5])
            }

            lines = [
                IndicatorLine(kind: .histogram, points: mom, color: s.color,
                              width: 1, dash: [], pointColors: barColors),
                IndicatorLine(kind: .dots, points: dots, color: s.color,
                              width: Swift.max(2, s.width), dash: [], pointColors: dotColors)
            ]

        case "macd":
            let (l, sg, h) = macd(bars,
                                  fast: inst.intValue("fast"),
                                  slow: inst.intValue("slow"),
                                  signal: inst.intValue("signal"))
            lines = [
                line(l),
                line(sg, secondary: true),
                IndicatorLine(kind: .histogram, points: h,
                              color: s.color, width: 1, dash: [],
                              positiveColor: ChartTheme.up.opacity(0.55 * s.opacity),
                              negativeColor: ChartTheme.down.opacity(0.55 * s.opacity))
            ]
        default:
            lines = []
        }

        return IndicatorOutput(instanceId: inst.id, overlay: overlay, lines: lines,
                               label: inst.label, labelColor: s.color)
    }
}
