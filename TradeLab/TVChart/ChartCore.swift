import SwiftUI

// MARK: - Výřez

/// Co je zrovna vidět. Drží se v „indexech svíček“, ne v čase — díky tomu
/// zůstávají kresby i indikátory na místě při posunu i zoomu.
struct Viewport: Equatable, Codable {
    /// Index nejpravější viditelné svíčky. Může přesáhnout počet barů,
    /// pak vznikne prázdné místo vpravo (jako v TradingView).
    var rightIndex: Double = 0
    /// Kolik svíček se vejde do šířky.
    var barsVisible: Double = 120

    /// Svislé měřítko. 1 = automatické (vejde se vše viditelné),
    /// >1 roztažené, <1 zmáčknuté. Mění se tažením po cenové ose.
    var priceZoom: Double = 1
    /// Posun ceny nahoru/dolů v podílu viditelného rozsahu.
    var priceShift: Double = 0

    /// true, když si měřítko řídí uživatel a ne autoscale.
    var manualPriceScale: Bool { priceZoom != 1 || priceShift != 0 }

    var leftIndex: Double { rightIndex - barsVisible + 1 }

    static let minBars: Double = 12
    static let maxBars: Double = 2000

    mutating func zoom(factor: Double, anchorRatio: Double) {
        let newCount = (barsVisible / factor).clamped(to: Self.minBars...Self.maxBars)
        // drž pod prstem stejnou svíčku
        let anchorIndex = leftIndex + barsVisible * anchorRatio
        barsVisible = newCount
        rightIndex = anchorIndex + newCount * (1 - anchorRatio) - 1
    }

    mutating func pan(bars: Double) {
        rightIndex += bars
    }

    static let minPriceZoom: Double = 0.15
    static let maxPriceZoom: Double = 12

    /// Roztažení i zmáčknutí cenové osy.
    mutating func zoomPrice(factor: Double) {
        priceZoom = (priceZoom * factor).clamped(to: Self.minPriceZoom...Self.maxPriceZoom)
    }

    mutating func shiftPrice(byFraction f: Double) {
        priceShift = (priceShift + f).clamped(to: -2.5...2.5)
    }

    mutating func resetPriceScale() {
        priceZoom = 1
        priceShift = 0
    }

    /// Nenech uživatele odscrollovat úplně mimo data.
    /// `margin` je odsazení poslední svíčky od cenové osy ve svíčkách.
    mutating func clamp(barCount: Int, margin: Double = 0) {
        guard barCount > 0 else { return }
        let maxRight = Double(barCount - 1) + max(margin, barsVisible * 0.45)
        let minRight = barsVisible * 0.4
        rightIndex = rightIndex.clamped(to: minRight...max(minRight, maxRight))
    }
}

// MARK: - Geometrie

/// Rozměry a převody mezi daty a body na obrazovce. Počítá se při každém
/// překreslení z aktuální velikosti plátna.
struct ChartGeometry {
    let size: CGSize
    let viewport: Viewport
    let priceMin: Double
    let priceMax: Double
    let volumeMax: Double
    /// Rozsah hodnot pro každý panel oscilátoru zvlášť. Prázdné, když žádný
    /// neběží. Každý indikátor pod grafem má vlastní panel, ať se nekreslí
    /// jeden přes druhý.
    let oscRanges: [ClosedRange<Double>]
    /// Překlad mezi časem kresby a indexem svíčky.
    let indexer: TimeIndexer
    /// Podíl výšky pro panel oscilátorů (0,12–0,5).
    var oscHeightRatio: CGFloat = 0.24
    /// Podíl výšky pro objem; 0 = objem je vypnutý.
    var volumeRatio: CGFloat = 0.16

    static let axisWidth: CGFloat = 58
    static let timeAxisHeight: CGFloat = 20



    /// Celá kreslicí plocha bez os.
    var plotWidth: CGFloat { max(1, size.width - Self.axisWidth) }
    var bodyHeight: CGFloat { max(1, size.height - Self.timeAxisHeight) }

    /// Celková výška všech panelů; víc než 62 % plochy jim nedáme.
    var oscTotalHeight: CGFloat {
        guard !oscRanges.isEmpty else { return 0 }
        let wanted = oscHeightRatio * CGFloat(oscRanges.count)
        return bodyHeight * min(0.62, wanted)
    }

    /// Panely jdou pod sebou odshora dolů v pořadí indikátorů.
    func oscRect(_ pane: Int) -> CGRect {
        guard !oscRanges.isEmpty, pane >= 0, pane < oscRanges.count else { return .zero }
        let each = oscTotalHeight / CGFloat(oscRanges.count)
        let top = bodyHeight - oscTotalHeight + each * CGFloat(pane)
        return CGRect(x: 0, y: top, width: plotWidth, height: each)
    }

    /// Cenová část (svíčky) — nad objemem a případnými panely.
    var priceRect: CGRect {
        let bottom = oscRanges.isEmpty ? bodyHeight : bodyHeight - oscTotalHeight - 6
        return CGRect(x: 0, y: 0, width: plotWidth, height: max(1, bottom))
    }

    var volumeRect: CGRect {
        let h = priceRect.height * volumeRatio
        return CGRect(x: 0, y: priceRect.maxY - h, width: plotWidth, height: h)
    }

    /// Svíčky se kreslí jen nad objemem, ať se nepřekrývají.
    /// S vypnutým objemem zaberou celou cenovou část.
    var candleRect: CGRect {
        let bottom = volumeRatio > 0 ? volumeRect.minY - 4 : priceRect.maxY
        return CGRect(x: 0, y: 0, width: plotWidth, height: max(1, bottom))
    }

    var barWidth: CGFloat { plotWidth / CGFloat(viewport.barsVisible) }

    // --- převody ---

    func x(for index: Double) -> CGFloat {
        CGFloat(index - viewport.leftIndex + 0.5) * barWidth
    }

    func index(for x: CGFloat) -> Double {
        viewport.leftIndex + Double(x / barWidth) - 0.5
    }

    /// Vodorovná pozice bodu kresby.
    func x(forTime time: Double) -> CGFloat {
        x(for: indexer.index(for: time))
    }

    func time(forX x: CGFloat) -> Double {
        indexer.time(for: index(for: x))
    }

    func y(for price: Double) -> CGFloat {
        guard priceMax > priceMin else { return candleRect.midY }
        let t = (price - priceMin) / (priceMax - priceMin)
        return candleRect.maxY - CGFloat(t) * candleRect.height
    }

    func price(for y: CGFloat) -> Double {
        guard candleRect.height > 0 else { return priceMin }
        let t = Double((candleRect.maxY - y) / candleRect.height)
        return priceMin + t * (priceMax - priceMin)
    }

    func volumeY(for value: Double) -> CGFloat {
        guard volumeMax > 0 else { return volumeRect.maxY }
        return volumeRect.maxY - CGFloat(value / volumeMax) * volumeRect.height
    }

    /// Ve kterém panelu oscilátoru leží daná svislá pozice; nil = cenová část.
    func pane(atY y: CGFloat) -> Int? {
        for i in oscRanges.indices where oscRect(i).contains(CGPoint(x: 1, y: y)) {
            return i
        }
        return nil
    }

    /// Opak oscY — hodnota indikátoru pod prstem.
    func oscValue(forY y: CGFloat, pane: Int) -> Double {
        guard pane >= 0, pane < oscRanges.count else { return 0 }
        let rect = oscRect(pane)
        let r = oscRanges[pane]
        guard rect.height > 0 else { return r.lowerBound }
        let t = Double((rect.maxY - y) / rect.height)
        return r.lowerBound + t * (r.upperBound - r.lowerBound)
    }

    func oscY(for value: Double, pane: Int) -> CGFloat {
        let rect = oscRect(pane)
        guard pane >= 0, pane < oscRanges.count else { return rect.midY }
        let r = oscRanges[pane]
        guard r.upperBound > r.lowerBound else { return rect.midY }
        let t = (value - r.lowerBound) / (r.upperBound - r.lowerBound)
        return rect.maxY - CGFloat(t) * rect.height
    }
}

// MARK: - Převod index <-> čas

/// Překlad mezi indexem svíčky a časem. Kresby se ukládají v čase, takže
/// sedí i po přepnutí rozlišení — index 50 znamená na 1D něco jiného než na 4h.
struct TimeIndexer {
    /// Časy svíček, vzestupně.
    let times: [Double]
    /// Typický rozestup svíček v sekundách — uvnitř dat.
    let spacing: Double
    /// Průměrný rozestup včetně mezer (víkendy, svátky). Používá se za okraji
    /// dat: bod 10 svíček za koncem je u denních barů ~14 kalendářních dní,
    /// ne 10 — s mediánem by objekt po přepnutí rozlišení ujel.
    let outerSpacing: Double

    init(bars: [Bar]) {
        times = bars.map(\.time)
        // medián rozestupu je odolnější než průměr (víkendy, mezery v obchodování)
        if times.count > 2 {
            var deltas: [Double] = []
            deltas.reserveCapacity(times.count - 1)
            for i in 1..<times.count { deltas.append(times[i] - times[i - 1]) }
            deltas.sort()
            spacing = Swift.max(1, deltas[deltas.count / 2])
            outerSpacing = Swift.max(
                1, (times[times.count - 1] - times[0]) / Double(times.count - 1))
        } else {
            spacing = 60
            outerSpacing = 60
        }
    }

    /// Čas -> zlomkový index svíčky.
    func index(for time: Double) -> Double {
        guard let first = times.first, let last = times.last else { return 0 }
        if time <= first { return (time - first) / outerSpacing }
        if time >= last { return Double(times.count - 1) + (time - last) / outerSpacing }

        // binární hledání nejbližší nižší svíčky
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid } else { hi = mid }
        }
        let span = times[hi] - times[lo]
        let frac = span > 0 ? (time - times[lo]) / span : 0
        return Double(lo) + frac
    }

    /// Zlomkový index -> čas.
    func time(for index: Double) -> Double {
        guard let first = times.first, let last = times.last else { return 0 }
        if index <= 0 { return first + index * outerSpacing }
        if index >= Double(times.count - 1) {
            return last + (index - Double(times.count - 1)) * outerSpacing
        }
        let lo = Int(index.rounded(.down))
        let hi = Swift.min(lo + 1, times.count - 1)
        let frac = index - Double(lo)
        return times[lo] + (times[hi] - times[lo]) * frac
    }
}

// MARK: - Kresby

/// Bod kresby v datových souřadnicích — čas a cena. Čas (ne index svíčky)
/// znamená, že objekt sedí na stejném místě i po přepnutí rozlišení.
struct DrawPoint: Codable, Hashable {
    var time: Double
    var price: Double

    /// Index z dřívějších verzí — po načtení se převede na čas a zahodí.
    var legacyIndex: Double?

    init(time: Double, price: Double) {
        self.time = time
        self.price = price
    }

    enum CodingKeys: String, CodingKey { case time, price, index }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        price = try c.decode(Double.self, forKey: .price)
        if let t = try c.decodeIfPresent(Double.self, forKey: .time) {
            time = t
        } else {
            // starší data měla jen index; převod udělá ChartViewModel,
            // až bude znát bary
            time = 0
            legacyIndex = try c.decodeIfPresent(Double.self, forKey: .index)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(price, forKey: .price)
    }
}

/// Jedna hladina Fibonacciho retracementu.
struct FibLevelSetting: Codable, Hashable, Identifiable {
    var ratio: Double
    var visible: Bool = true
    var colorHex: String

    var id: Double { ratio }
    /// Záporné hladiny jsou extenze za kotvou 0 (−0,272 → 127,2 %).
    var percentText: String { String(format: "%.2f%%", (ratio < 0 ? 1 - ratio : ratio) * 100) }
}

/// Nastavení Fibonacciho objektu — hladiny, jejich vzhled a podbarvení.
struct FibSettings: Codable, Hashable {
    var levels: [FibLevelSetting]
    var showBackground: Bool = true
    var backgroundOpacity: Double = 0.06
    var backgroundHex: String?          // nil = pruh vezme barvu své hladiny
    var lineOpacity: Double = 0.9
    var showLabels: Bool = true
    /// Prodloužit hladiny až k cenové ose.
    var extendRight: Bool = true

    static let `default` = FibSettings(levels: [
        FibLevelSetting(ratio: 0,     colorHex: "#9aa7b4"),
        FibLevelSetting(ratio: 0.236, colorHex: "#e0566b"),
        FibLevelSetting(ratio: 0.382, colorHex: "#e0a83c"),
        FibLevelSetting(ratio: 0.5,   colorHex: "#5fbf7a"),
        FibLevelSetting(ratio: 0.618, colorHex: "#2ea98c"),
        FibLevelSetting(ratio: 0.786, colorHex: "#4aa8ff"),
        FibLevelSetting(ratio: 1,     colorHex: "#9aa7b4"),
        FibLevelSetting(ratio: 1.272, visible: false, colorHex: "#b58cff"),
        FibLevelSetting(ratio: 1.618, visible: false, colorHex: "#b58cff")
    ])

    enum CodingKeys: String, CodingKey {
        case levels, showBackground, backgroundOpacity, backgroundHex
        case lineOpacity, showLabels, extendRight
    }

    init(levels: [FibLevelSetting], showBackground: Bool = true,
         backgroundOpacity: Double = 0.06, backgroundHex: String? = nil,
         lineOpacity: Double = 0.9, showLabels: Bool = true,
         extendRight: Bool = true) {
        self.levels = levels
        self.showBackground = showBackground
        self.backgroundOpacity = backgroundOpacity
        self.backgroundHex = backgroundHex
        self.lineOpacity = lineOpacity
        self.showLabels = showLabels
        self.extendRight = extendRight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        levels = try c.decodeIfPresent([FibLevelSetting].self, forKey: .levels)
            ?? FibSettings.default.levels
        showBackground = try c.decodeIfPresent(Bool.self, forKey: .showBackground) ?? true
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.06
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex)
        lineOpacity = try c.decodeIfPresent(Double.self, forKey: .lineOpacity) ?? 0.9
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        extendRight = try c.decodeIfPresent(Bool.self, forKey: .extendRight) ?? true
    }
}

struct Drawing: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var tool: String
    var points: [DrawPoint]
    var colorHex: String
    var width: Double
    /// 0 plná, 1 tečkovaná, 2 čárkovaná
    var dash: Int
    var text: String?
    /// Skryté objekty zůstanou uložené, jen se nekreslí.
    var visible: Bool = true
    /// Zamčený objekt se nedá vybrat ani táhnout — chrání před nechtěným posunem.
    var locked: Bool = false
    /// Nastavení hladin, jen u Fibonacciho.
    var fib: FibSettings?

    var color: Color { Color(hex: colorHex) }

    /// Název do seznamu objektů.
    var displayName: String {
        if let t = text, !t.isEmpty { return t }
        return DrawToolKind(rawValue: tool)?.title ?? tool
    }

    // Starší uložená data nemají `visible` — ať se dají načíst dál.
    enum CodingKeys: String, CodingKey {
        case id, tool, points, colorHex, width, dash, text, visible, locked, fib
    }

    init(id: UUID = UUID(), tool: String, points: [DrawPoint], colorHex: String,
         width: Double, dash: Int, text: String? = nil,
         visible: Bool = true, locked: Bool = false, fib: FibSettings? = nil) {
        self.id = id; self.tool = tool; self.points = points
        self.colorHex = colorHex; self.width = width; self.dash = dash
        self.text = text; self.visible = visible; self.locked = locked
        // Fibonacci si nastavení nese s sebou, ať jde ladit každý zvlášť
        self.fib = fib ?? (tool == DrawToolKind.fib.rawValue ? .default : nil)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tool = try c.decode(String.self, forKey: .tool)
        points = try c.decode([DrawPoint].self, forKey: .points)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        width = try c.decode(Double.self, forKey: .width)
        dash = try c.decode(Int.self, forKey: .dash)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        fib = try c.decodeIfPresent(FibSettings.self, forKey: .fib)
            ?? (tool == DrawToolKind.fib.rawValue ? .default : nil)
    }

    /// Body, za které jde objekt chytit a táhnout jednotlivě.
    /// Volná kresba jich má moc, ta se posouvá jen celá.
    var hasPointHandles: Bool {
        DrawToolKind(rawValue: tool) != .brush
    }

    var dashPattern: [CGFloat] {
        switch dash {
        case 1: return [2, 4]
        case 2: return [8, 5]
        default: return []
        }
    }
}

// MARK: - Nástroje

enum DrawToolKind: String, CaseIterable {
    case cursor, cross
    case trend, ray, arrow, hline, hray, vline
    case rect, ellipse
    case fib, measure
    case brush, text, erase

    /// Kolik klepnutí nástroj potřebuje (brush kreslí tahem).
    var pointCount: Int {
        switch self {
        case .cursor, .cross, .erase: return 0
        case .hline, .vline, .text:   return 1
        case .brush:                  return -1   // volný tah
        default:                      return 2
        }
    }

    var isDrawing: Bool { self != .cursor && self != .cross && self != .erase }

    var title: String {
        switch self {
        case .cursor:  return "Výběr"
        case .cross:   return "Nitkový kříž"
        case .trend:   return "Trendová čára"
        case .ray:     return "Paprsek"
        case .arrow:   return "Šipka"
        case .hline:   return "Vodorovná čára"
        case .hray:    return "Vodorovný paprsek"
        case .vline:   return "Svislá čára"
        case .rect:    return "Obdélník"
        case .ellipse: return "Elipsa"
        case .fib:     return "Fib retracement"
        case .measure: return "Měřítko"
        case .brush:   return "Volná kresba"
        case .text:    return "Text"
        case .erase:   return "Guma"
        }
    }

    var symbolName: String {
        switch self {
        case .cursor:  return "cursorarrow"
        case .cross:   return "plus"
        case .trend:   return "line.diagonal"
        case .ray:     return "arrow.up.right"
        case .arrow:   return "arrow.up.right.square"
        case .hline:   return "minus"
        case .hray:    return "arrow.right"
        case .vline:   return "line.3.horizontal.decrease"
        case .rect:    return "rectangle"
        case .ellipse: return "circle"
        case .fib:     return "square.stack.3d.down.right"
        case .measure: return "ruler"
        case .brush:   return "scribble"
        case .text:    return "textformat"
        case .erase:   return "eraser"
        }
    }
}

// MARK: - Pomocné

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}

extension Color {
    /// Pro barvy zapsané jako "#rrggbb".
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue:  Double(v & 0xFF) / 255
        )
    }
}

/// Barvy grafu na jednom místě, ať se to nerozjede mezi vrstvami.
enum ChartTheme {
    static let up      = Color(hex: "#2ea98c")
    static let down    = Color(hex: "#e0566b")
    static let grid    = Color(white: 1, opacity: 0.05)
    /// Oddělovače kolem os — o něco výraznější než mřížka.
    static let border  = Color(white: 1, opacity: 0.14)
    static let axis    = Color(hex: "#8b98a5")
    static let ink     = Color(hex: "#e6edf3")
    static let inkDim  = Color(hex: "#8b98a5")
    static let cross   = Color(hex: "#4a5a6a")
    static let panel   = Color(hex: "#26313d")
}

extension Collection {
    /// Bezpečný přístup — u indikátorů se délky polí můžou lišit.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
