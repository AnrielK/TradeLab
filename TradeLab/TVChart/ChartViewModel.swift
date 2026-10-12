import SwiftUI
import Observation

@MainActor
@Observable
final class ChartViewModel {

    // MARK: Data

    private(set) var bars: [Bar] = []
    var viewport = Viewport()

    var symbol: String = UserDefaults.standard.string(forKey: "lastSymbol") ?? "NASDAQ:NVDA"
    var resolution: String = UserDefaults.standard.string(forKey: "lastResolution") ?? "1D"
    var status: String = ""
    var errorMessage: String?
    var isConnected = false

    // MARK: Vzhled a nástroje

    var chartKind: String = "Candlestick"

    // MARK: Vložení do TradeLabu

    /// Vypnuté indikátory (malý graf v detailu tickeru); sestava zůstává uložená.
    var indicatorsEnabled = true {
        didSet { recomputeIndicators() }
    }
    /// Vodorovné čáry dodané zvenku (striky a break-even opční pozice).
    var priceLines: [ChartPriceLine] = []
    /// Hlavička s tickerem, změnou, OHLC a stavem (vložený graf ji skrývá).
    var showsLegend = true
    /// Zapisovat symbol/interval/historii do UserDefaults? Vložený graf nemá
    /// přepisovat poslední stav celoobrazovkového grafu.
    var persistsSession = true
    /// Pevně daný výřez (1D, 5D, 1M… jako v aplikaci TradingView). Když je
    /// nastavený, výřez se po načtení historie nastaví podle něj, ne z uložení.
    var preferredSpan: ChartSpan?
    /// Kolik barů historie si říct serveru.
    var historyBars = 400
    var activeTool: String = DrawToolKind.cursor.rawValue
    /// Nové kresby vznikají bílé a tenké; barvu i tloušťku lze změnit
    /// u konkrétního objektu v jeho editoru.
    var drawColor: String = "#ffffff"
    var drawWidth: Double = 1
    var drawDash: Int = 0
    /// Odsazení poslední svíčky od cenové osy, ve svíčkách.
    var rightMarginBars: Double =
        UserDefaults.standard.object(forKey: "rightMarginBars") as? Double ?? 6 {
        didSet { UserDefaults.standard.set(rightMarginBars, forKey: "rightMarginBars") }
    }

    /// Výška panelu oscilátorů jako podíl plochy grafu.
    var oscHeightRatio: Double =
        UserDefaults.standard.object(forKey: "oscHeightRatio") as? Double ?? 0.24 {
        didSet { UserDefaults.standard.set(oscHeightRatio, forKey: "oscHeightRatio") }
    }

    /// Jak zobrazit objem.
    enum VolumeMode: String, CaseIterable, Identifiable {
        case off, pane, overlay
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off:     return "Vypnuto"
            case .pane:    return "Vlastní pás"
            case .overlay: return "Přes graf"
            }
        }
    }

    var volumeMode: VolumeMode =
        VolumeMode(rawValue: UserDefaults.standard.string(forKey: "volumeMode") ?? "pane")
        ?? .pane {
        didSet { UserDefaults.standard.set(volumeMode.rawValue, forKey: "volumeMode") }
    }

    /// Zpětně kompatibilní zkratka pro zapnutý objem v jakékoliv podobě.
    var showVolume: Bool {
        get { volumeMode != .off }
        set { volumeMode = newValue ? .pane : .off }
    }

    /// Volume profil přes viditelný rozsah.
    var volumeProfile: VolumeProfileSettings = .load() {
        didSet { volumeProfile.save() }
    }

    var magnet = false
    var keepTool = false
    /// Kříž zůstane viditelný i po zvednutí prstu.
    var crosshairPinned = false

    // MARK: Kresby

    private(set) var drawings: [Drawing] = []
    var selectedDrawing: UUID?
    /// Je zařízení na šířku? Rozhoduje, pod jakým klíčem se výřez ukládá.
    @ObservationIgnored private(set) var isLandscape = false

    /// true, jakmile jsme kresby pro aktuální symbol načetli z disku.
    /// Dokud je false, není co ukládat — jen bychom přepsali uložená data.
    private var hasRestored = false
    private var undoStack: [[Drawing]] = []
    private var redoStack: [[Drawing]] = []

    // MARK: Indikátory

    private(set) var indicators: [IndicatorInstance] = []
    private(set) var indicatorOutputs: [IndicatorOutput] = []

    // MARK: Kurzor

    var hoverIndex: Int?
    var hoverBar: Bar? {
        guard let i = hoverIndex, i >= 0, i < bars.count else { return nil }
        return bars[i]
    }

    // MARK: Panely

    var sheet: BottomSheet?
    enum BottomSheet: String, Identifiable {
        case symbol, timeframe, drawings, objects, indicators, volumeProfile, more
        var id: String { rawValue }
    }

    /// Oblíbené intervaly — jimi se listuje v liště a jsou nahoře v panelu.
    var favoriteResolutions: [String] =
        UserDefaults.standard.stringArray(forKey: "favoriteResolutions")
        ?? Timeframes.defaultFavorites {
        didSet { UserDefaults.standard.set(favoriteResolutions,
                                           forKey: "favoriteResolutions") }
    }

    /// Naposledy otevřené symboly, nejnovější první.
    var recentSymbols: [String] =
        UserDefaults.standard.stringArray(forKey: "recentSymbols") ?? [] {
        didSet { UserDefaults.standard.set(recentSymbols, forKey: "recentSymbols") }
    }

    func toggleFavoriteResolution(_ value: String) {
        if let i = favoriteResolutions.firstIndex(of: value) {
            guard favoriteResolutions.count > 1 else { return }  // aspoň jeden
            favoriteResolutions.remove(at: i)
        } else {
            // drž pořadí podle katalogu, ať to neskáče
            var next = favoriteResolutions + [value]
            let order = Timeframes.all.map(\.value)
            next.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            favoriteResolutions = next
        }
    }

    func isFavorite(_ value: String) -> Bool { favoriteResolutions.contains(value) }

    // MARK: Listování v liště

    /// Popisky oblíbených intervalů pro kolečko v liště.
    var resolutionWheel: [String] { favoriteResolutions.map(Timeframes.label) }
    var resolutionIndex: Int { favoriteResolutions.firstIndex(of: resolution) ?? 0 }

    func selectResolution(at index: Int) {
        guard favoriteResolutions.indices.contains(index) else { return }
        let value = favoriteResolutions[index]
        guard value != resolution else { return }
        changeResolution(value)
    }

    /// Naposledy otevřené symboly bez burzy.
    var symbolWheel: [String] {
        recentSymbols.map { $0.split(separator: ":").last.map(String.init) ?? $0 }
    }
    var symbolIndex: Int { recentSymbols.firstIndex(of: symbol) ?? 0 }

    func selectSymbol(at index: Int) {
        guard recentSymbols.indices.contains(index) else { return }
        let value = recentSymbols[index]
        guard value != symbol else { return }
        symbol = value
        connect()
    }

    private let client = TVRealtimeClient()

    init() {
        loadIndicators()
        client.delegate = self
    }

    // MARK: Připojení

    func connect() {
        let typed = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !typed.isEmpty else { return }
        errorMessage = nil

        if typed.contains(":") { start(with: typed); return }

        status = "Hledám burzu pro \(typed)…"
        Task { [weak self] in
            guard let self else { return }
            guard let resolved = await SymbolResolver.shared.resolve(typed) else {
                let msg = "Symbol „\(typed)“ se nepodařilo najít. Zkus ho zadat i s burzou."
                self.errorMessage = msg
                self.status = msg
                self.isConnected = false
                return
            }
            self.start(with: resolved)
        }
    }

    private func start(with sym: String) {
        // historie symbolů pro listování v liště
        if persistsSession {
            var recent = recentSymbols.filter { $0 != sym }
            recent.insert(sym, at: 0)
            recentSymbols = Array(recent.prefix(12))
        }

        // Uložit jen to, co je opravdu načtené. Při startu aplikace je pole
        // ještě prázdné (historie nedorazila) a uložení by smazalo všechno,
        // co má uživatel na disku.
        if hasRestored { saveDrawings() }
        hasRestored = false
        symbol = sym
        if persistsSession {
            UserDefaults.standard.set(sym, forKey: "lastSymbol")
            UserDefaults.standard.set(resolution, forKey: "lastResolution")
        }

        bars = []
        drawings = []
        selectedDrawing = nil
        undoStack.removeAll(); redoStack.removeAll()
        recomputeIndicators()

        status = "Připojuji se · \(sym)"
        client.resolution = resolution
        client.historyBarCount = historyBars
        client.connect(symbol: sym)
        isConnected = true
    }

    func disconnect() {
        client.stop()
        isConnected = false
        status = "Odpojeno"
    }

    func toggle() { isConnected ? disconnect() : connect() }

    func changeResolution(_ value: String) {
        resolution = value
        if isConnected { connect() }
    }

    // MARK: Geometrie

    /// Vstupy, na kterých geometrie závisí. Když se nezmění, není co počítat.
    private struct GeoKey: Equatable {
        let width: CGFloat, height: CGFloat
        let right: Double, visible: Double, zoom: Double, shift: Double
        let bars: Int, lastTime: Double
        let indicators: Int, osc: Double, volume: Int
        let lines: [Double]
    }
    @ObservationIgnored private var geoKey: GeoKey?
    @ObservationIgnored private var geoCache: ChartGeometry?

    /// Projde všechny viditelné bary i body indikátorů, takže se to nevyplatí
    /// počítat vícekrát za snímek. Při rotaci se pohled vyhodnocuje často
    /// a bez cache se to znatelně trhalo.
    func geometry(for size: CGSize) -> ChartGeometry {
        let key = GeoKey(width: size.width, height: size.height,
                         right: viewport.rightIndex, visible: viewport.barsVisible,
                         zoom: viewport.priceZoom, shift: viewport.priceShift,
                         bars: bars.count, lastTime: bars.last?.time ?? 0,
                         indicators: indicatorOutputs.count,
                         osc: oscHeightRatio,
                         volume: volumeMode == .pane ? 1 : 0,
                         lines: priceLines.map(\.price))
        if key == geoKey, let geoCache { return geoCache }

        let geo = computeGeometry(for: size)
        geoKey = key
        geoCache = geo
        return geo
    }

    private func computeGeometry(for size: CGSize) -> ChartGeometry {
        var vp = viewport
        if vp.rightIndex == 0, !bars.isEmpty {
            vp.rightIndex = Double(bars.count - 1)
        }

        let indexer = TimeIndexer(bars: bars)
        let range = ChartRenderer.visibleRange(
            geo: ChartGeometry(size: size, viewport: vp, priceMin: 0, priceMax: 1,
                               volumeMax: 1, oscRanges: [], indexer: indexer,
                               oscHeightRatio: oscHeightRatio,
                               volumeRatio: volumeMode == .pane ? 0.16 : 0),
            count: bars.count)

        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        var volMax = 0.0
        for i in range {
            lo = Swift.min(lo, bars[i].low)
            hi = Swift.max(hi, bars[i].high)
            volMax = Swift.max(volMax, bars[i].volume ?? 0)
        }
        // překryvné indikátory se musí vejít taky
        for out in indicatorOutputs where out.overlay {
            for line in out.lines {
                for p in line.points where p.index >= range.lowerBound && p.index < range.upperBound {
                    lo = Swift.min(lo, p.value)
                    hi = Swift.max(hi, p.value)
                }
            }
        }
        // čáry opční pozice se musí vejít taky
        for line in priceLines where line.price > 0 {
            lo = Swift.min(lo, line.price)
            hi = Swift.max(hi, line.price)
        }
        if lo > hi { lo = 0; hi = 1 }
        let pad = (hi - lo) * 0.08
        lo -= pad; hi += pad

        // ruční svislé měřítko: roztažení/zmáčknutí kolem středu + posun
        if vp.manualPriceScale {
            let span = hi - lo
            let center = (lo + hi) / 2 - vp.priceShift * span
            let half = span / 2 / vp.priceZoom
            lo = center - half
            hi = center + half
        }

        // každý oscilátor má vlastní panel, takže i vlastní rozsah
        var oscRanges: [ClosedRange<Double>] = []
        for out in indicatorOutputs where !out.overlay {
            var oLo = Double.greatestFiniteMagnitude, oHi = -Double.greatestFiniteMagnitude
            for line in out.lines {
                for p in line.points where p.index >= range.lowerBound
                                        && p.index < range.upperBound {
                    oLo = Swift.min(oLo, p.value)
                    oHi = Swift.max(oHi, p.value)
                }
            }
            if oLo <= oHi {
                let pad = Swift.max((oHi - oLo) * 0.12, 0.0001)
                oscRanges.append((oLo - pad)...(oHi + pad))
            } else {
                oscRanges.append(-1...1)     // ať panel nezmizí, než dojdou data
            }
        }

        return ChartGeometry(size: size, viewport: vp, priceMin: lo, priceMax: hi,
                             volumeMax: volMax, oscRanges: oscRanges, indexer: indexer,
                             oscHeightRatio: oscHeightRatio,
                             volumeRatio: volumeMode == .pane ? 0.16 : 0)
    }

    /// Klíč pro cache profilu — mění se jen tehdy, když se opravdu změní vstup.
    private struct BinKey: Equatable {
        let from: Int, to: Int, rows: Int, bars: Int, enabled: Bool
    }
    @ObservationIgnored private var binKey: BinKey?
    @ObservationIgnored private var binCache: [VolumeBin] = []

    /// Pásma volume profilu pro daný výřez. Počítá se z viditelných svíček,
    /// takže se mění s posunem i zoomem — ale jen když je potřeba.
    /// Bez cache se profil počítal při každém překreslení a rotace se trhala.
    func volumeBins(for geo: ChartGeometry) -> [VolumeBin] {
        guard volumeProfile.enabled, !bars.isEmpty else { return [] }
        let range = ChartRenderer.visibleRange(geo: geo, count: bars.count)
        guard !range.isEmpty else { return [] }

        let key = BinKey(from: range.lowerBound, to: range.upperBound,
                         rows: volumeProfile.rows, bars: bars.count, enabled: true)
        if key == binKey { return binCache }

        // Pásma se odvozují z rozpětí viditelných svíček, ne z rozsahu osy.
        // Jinak by se profil přepočítal i při pouhém svislém posunu grafu,
        // kde se data nemění.
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for i in range where i >= 0 && i < bars.count {
            lo = Swift.min(lo, bars[i].low)
            hi = Swift.max(hi, bars[i].high)
        }
        guard lo < hi else { return [] }

        let bins = VolumeProfile.compute(bars: bars, range: range,
                                         priceMin: lo, priceMax: hi,
                                         rows: volumeProfile.rows)
        binKey = key
        binCache = bins
        return bins
    }

    // MARK: Odvozené hodnoty pro legendu

    var lastBar: Bar? { bars.last }

    var changeText: String {
        guard bars.count > 1, let a = bars.last else { return "" }
        let b = bars[bars.count - 2]
        let d = a.close - b.close
        let pct = b.close != 0 ? d / b.close * 100 : 0
        let dec = ChartRenderer.decimals(for: a.close)
        return String(format: "%@%.\(dec)f (%@%.2f %%)",
                      d >= 0 ? "+" : "", d, d >= 0 ? "+" : "", pct)
    }

    var changeIsUp: Bool {
        guard bars.count > 1 else { return true }
        return bars[bars.count - 1].close >= bars[bars.count - 2].close
    }

    /// Délka jedné svíčky v sekundách podle rozlišení.
    var resolutionSeconds: Double { Timeframes.seconds(resolution) }

    /// Kolik zbývá do uzavření poslední svíčky, ve tvaru H:MM:SS nebo MM:SS.
    func candleCountdown(now: Date = Date()) -> String? {
        guard let last = bars.last else { return nil }
        let closesAt = last.time + resolutionSeconds
        let remaining = closesAt - now.timeIntervalSince1970
        // u denních a delších svíček nemá vteřinový odpočet smysl přes víkend
        guard remaining > 0, remaining < resolutionSeconds * 1.5 else { return nil }

        let total = Int(remaining)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }

    var resolutionLabel: String { Timeframes.label(resolution) }

    var shortSymbol: String {
        symbol.split(separator: ":").last.map(String.init) ?? symbol
    }

    // MARK: Kresby

    func makeDrawing(tool: String, points: [DrawPoint], text: String? = nil) -> Drawing {
        Drawing(tool: tool, points: points, colorHex: drawColor,
                width: drawWidth, dash: drawDash, text: text)
    }

    func addDrawing(tool: String, points: [DrawPoint], text: String? = nil) {
        snapshot()
        drawings.append(makeDrawing(tool: tool, points: points, text: text))
        saveDrawings()
    }

    func toggleLock(_ id: UUID) {
        guard let i = drawings.firstIndex(where: { $0.id == id }) else { return }
        drawings[i].locked.toggle()
        if drawings[i].locked, selectedDrawing == id { selectedDrawing = nil }
        saveDrawings()
    }

    func setAllDrawingsLocked(_ locked: Bool) {
        guard drawings.contains(where: { $0.locked != locked }) else { return }
        snapshot()
        for i in drawings.indices { drawings[i].locked = locked }
        if locked { selectedDrawing = nil }
        saveDrawings()
    }

    /// Zavolej na začátku tažení — uloží stav, aby šel posun vrátit zpět.
    /// Samotný průběh tažení už snímek nedělá, jinak by undo krokovalo po pixelu.
    func beginDragEdit() {
        snapshot()
    }

    /// Konec tažení — až tady se posun uloží, ne po každém pixelu.
    func endDragEdit() {
        saveDrawings()
    }

    /// Posun jedním bodem — třeba začátek trendovky.
    func moveDrawingPoint(_ id: UUID, pointIndex: Int, to point: DrawPoint) {
        guard let i = drawings.firstIndex(where: { $0.id == id }),
              !drawings[i].locked,
              drawings[i].points.indices.contains(pointIndex) else { return }
        drawings[i].points[pointIndex] = point
    }

    func toggleVisibility(_ id: UUID) {
        guard let i = drawings.firstIndex(where: { $0.id == id }) else { return }
        drawings[i].visible.toggle()
        saveDrawings()
    }

    func setAllDrawingsVisible(_ visible: Bool) {
        guard drawings.contains(where: { $0.visible != visible }) else { return }
        snapshot()
        for i in drawings.indices { drawings[i].visible = visible }
        saveDrawings()
    }

    /// Úprava jednoho objektu ze seznamu (barva, tloušťka, styl, text).
    func updateDrawing(_ id: UUID, change: (inout Drawing) -> Void) {
        guard let i = drawings.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        change(&drawings[i])
        saveDrawings()
    }

    func drawing(_ id: UUID) -> Drawing? {
        drawings.first { $0.id == id }
    }

    // MARK: Svislé měřítko

    func zoomPrice(_ factor: Double) {
        viewport.zoomPrice(factor: factor)
    }

    func resetPriceScale() {
        viewport.resetPriceScale()
    }

    func removeDrawing(_ id: UUID) {
        snapshot()
        drawings.removeAll { $0.id == id }
        if selectedDrawing == id { selectedDrawing = nil }
        saveDrawings()
    }

    func moveDrawing(_ id: UUID, points: [DrawPoint]) {
        guard let i = drawings.firstIndex(where: { $0.id == id }),
              !drawings[i].locked else { return }
        drawings[i].points = points
    }

    func deleteSelected() {
        guard let id = selectedDrawing else { return }
        removeDrawing(id)
    }

    func clearDrawings() {
        guard !drawings.isEmpty else { return }
        snapshot()
        drawings = []
        selectedDrawing = nil
        saveDrawings()
    }

    func selectTool(_ id: String) {
        activeTool = id
        if id != DrawToolKind.cursor.rawValue { selectedDrawing = nil }
    }

    /// Po dokreslení se vrátíme na kurzor, pokud není nástroj zamčený.
    func finishTool() {
        if !keepTool { activeTool = DrawToolKind.cursor.rawValue }
    }

    func setChartKind(_ kind: String) { chartKind = kind }

    func toggleMagnet() { magnet.toggle() }

    func toggleKeepTool() { keepTool.toggle() }

    func setColor(_ hex: String) {
        drawColor = hex
        applyStyleToSelection { $0.colorHex = hex }
    }

    func setWidth(_ w: Double) {
        drawWidth = w
        applyStyleToSelection { $0.width = w }
    }

    func setDash(_ d: Int) {
        drawDash = d
        applyStyleToSelection { $0.dash = d }
    }

    private func applyStyleToSelection(_ change: (inout Drawing) -> Void) {
        guard let id = selectedDrawing,
              let i = drawings.firstIndex(where: { $0.id == id }) else { return }
        snapshot()
        change(&drawings[i])
    }

    // MARK: Zpět / vpřed

    private func snapshot() {
        undoStack.append(drawings)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(drawings)
        drawings = prev
        selectedDrawing = nil
        saveDrawings()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawings)
        drawings = next
        selectedDrawing = nil
        saveDrawings()
    }

    func fitContent() {
        guard !bars.isEmpty else { return }
        viewport.barsVisible = Swift.min(Double(bars.count), 150)
        viewport.rightIndex = Double(bars.count - 1) + rightMarginBars
        viewport.resetPriceScale()
        saveViewport()
    }

    /// Výřez podle `preferredSpan`: zobrazí právě bary daného období.
    func fitPreferredSpan() {
        guard let span = preferredSpan, !bars.isEmpty else { return }
        let count = span.barCount(in: bars)
        viewport.barsVisible = Swift.max(Double(count), Viewport.minBars)
        viewport.rightIndex = Double(bars.count - 1) + 1
        viewport.resetPriceScale()
    }

    /// Posun na poslední svíčku bez změny přiblížení.
    func scrollToEnd() {
        guard !bars.isEmpty else { return }
        viewport.rightIndex = Double(bars.count - 1) + rightMarginBars
        saveViewport()
    }

    func setRightMargin(_ bars: Double) {
        let delta = bars - rightMarginBars
        rightMarginBars = bars
        viewport.rightIndex += delta      // ať se pohled opticky neposune
        saveViewport()
    }

    // MARK: Uložení výřezu

    /// Orientace se do klíče počítá — na šířku je vidět jiný počet svíček,
    /// takže si každý režim drží vlastní přiblížení i svislé měřítko.
    private var viewportKey: String {
        "viewport::\(symbol)::\(resolution)::\(isLandscape ? "L" : "P")"
    }

    func saveViewport() {
        guard hasRestored, persistsSession, preferredSpan == nil, let data = try? JSONEncoder().encode(viewport) else { return }
        UserDefaults.standard.set(data, forKey: viewportKey)
    }

    /// Zavolá se při každé změně velikosti plátna. Při překlopení uloží
    /// výřez pro dosavadní orientaci a načte ten pro novou.
    func updateOrientation(landscape: Bool) {
        guard landscape != isLandscape else { return }
        saveViewport()              // ještě pod starým klíčem
        isLandscape = landscape
        if preferredSpan != nil { fitPreferredSpan(); return }
        if !restoreViewport() { fitContent() }
    }

    /// Vrátí true, když se podařilo obnovit dřívější přiblížení.
    @discardableResult
    func restoreViewport() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: viewportKey),
              var saved = try? JSONDecoder().decode(Viewport.self, from: data),
              saved.barsVisible >= Viewport.minBars
        else { return false }
        saved.clamp(barCount: bars.count, margin: rightMarginBars)
        viewport = saved
        return true
    }

    // MARK: Indikátory

    func addIndicator(_ def: IndicatorDef) {
        var params: [String: Double] = [:]
        def.params.forEach { params[$0.key] = $0.def }
        let color = Indicators.palette[indicators.count % Indicators.palette.count]
        var style = IndicatorStyle(colorHex: color)
        if def.id == "squeeze" { style.extraHex = Indicators.squeezeDefaultColors }
        indicators.append(IndicatorInstance(defId: def.id, params: params, style: style))
        recomputeIndicators()
        saveIndicators()
    }

    func updateIndicator(_ id: UUID, params: [String: Double]? = nil,
                         style: IndicatorStyle? = nil) {
        guard let i = indicators.firstIndex(where: { $0.id == id }) else { return }
        if let params {
            params.forEach { key, value in
                // hlídej rozsah z definice, ať výpočet nedostane nesmysl
                if let p = indicators[i].def?.params.first(where: { $0.key == key }) {
                    indicators[i].params[key] = value.clamped(to: p.min...p.max)
                } else {
                    indicators[i].params[key] = value
                }
            }
        }
        if let style { indicators[i].style = style }
        recomputeIndicators()
        saveIndicators()
    }

    func removeIndicator(_ id: UUID) {
        indicators.removeAll { $0.id == id }
        recomputeIndicators()
        saveIndicators()
    }

    func clearIndicators() {
        indicators = []
        recomputeIndicators()
        saveIndicators()
    }

    func count(of defId: String) -> Int {
        indicators.filter { $0.defId == defId }.count
    }

    private func recomputeIndicators() {
        guard indicatorsEnabled, !bars.isEmpty else { indicatorOutputs = []; return }
        var pane = 0
        indicatorOutputs = indicators.map { inst in
            var out = IndicatorMath.compute(inst, bars: bars)
            if !out.overlay {
                out.pane = pane
                pane += 1
            }
            return out
        }
    }

    // MARK: Uložení indikátorů

    private let indicatorsKey = "indicators"

    func saveIndicators() {
        guard let data = try? JSONEncoder().encode(indicators) else { return }
        UserDefaults.standard.set(data, forKey: indicatorsKey)
    }

    /// Indikátory platí napříč symboly — načtou se jednou při startu.
    private func loadIndicators() {
        guard let data = UserDefaults.standard.data(forKey: indicatorsKey),
              let saved = try? JSONDecoder().decode([IndicatorInstance].self, from: data)
        else { return }
        indicators = saved.filter { Indicators.def(id: $0.defId) != nil }
    }

    // MARK: Uložení kreseb

    /// Klíč je jen podle symbolu — kresby se ukládají v čase, takže mají
    /// platit napříč všemi rozlišeními.
    private var drawingsKey: String { "drawings::\(symbol)" }

    /// Znovu načte kresby z úložiště (agent je mezitím mohl změnit).
    func reloadDrawingsFromStorage() {
        guard hasRestored,
              let data = UserDefaults.standard.data(forKey: drawingsKey),
              let saved = try? JSONDecoder().decode([Drawing].self, from: data) else { return }
        drawings = saved
    }

    func saveDrawings() {
        guard hasRestored else { return }
        guard let data = try? JSONEncoder().encode(drawings) else { return }
        UserDefaults.standard.set(data, forKey: drawingsKey)
    }

    func restoreDrawings() {
        guard let data = UserDefaults.standard.data(forKey: drawingsKey),
              var saved = try? JSONDecoder().decode([Drawing].self, from: data)
        else {
            hasRestored = true      // pro tenhle symbol zatím nic uloženého není
            return
        }

        // Kresby z verzí, které ukládaly index svíčky, převedeme na čas.
        // Bez toho by po přepnutí rozlišení skočily jinam.
        let indexer = TimeIndexer(bars: bars)
        var migrated = false
        for di in saved.indices {
            for pi in saved[di].points.indices where saved[di].points[pi].legacyIndex != nil {
                let idx = saved[di].points[pi].legacyIndex!
                saved[di].points[pi].time = indexer.time(for: idx)
                saved[di].points[pi].legacyIndex = nil
                migrated = true
            }
        }
        drawings = saved
        hasRestored = true

        // Převod hned uložíme. Bez toho by v úložišti zůstal index a při
        // každém přepnutí rozlišení by se převáděl znovu — jiným
        // převodníkem, takže by objekt pokaždé skočil jinam.
        if migrated { saveDrawings() }
    }
}

// MARK: - Data ze streamu

extension ChartViewModel: TVRealtimeClientDelegate {

    func client(_ client: TVRealtimeClient, didReceiveHistory newBars: [Bar]) {
        bars = newBars.sorted { $0.time < $1.time }
        recomputeIndicators()
        restoreDrawings()          // nastaví hasRestored, ať smí ukládat
        if preferredSpan != nil {
            fitPreferredSpan()
        } else if !restoreViewport() {
            fitContent()
        }
        status = "Živě · \(symbol)"
    }

    func client(_ client: TVRealtimeClient, didReceiveBar bar: Bar) {
        if let last = bars.last, last.time == bar.time {
            bars[bars.count - 1] = bar
        } else if let last = bars.last, bar.time < last.time {
            return                      // opožděný bar zahodíme
        } else {
            let edge = Double(bars.count - 1) + rightMarginBars
            let wasAtRightEdge = viewport.rightIndex >= edge - 1
            bars.append(bar)
            if wasAtRightEdge {
                viewport.rightIndex = Double(bars.count - 1) + rightMarginBars
            }
        }
        recomputeIndicators()
    }

    func client(_ client: TVRealtimeClient, didChangeStatus status: String) {
        self.status = status
    }

    func client(_ client: TVRealtimeClient, didFailWith error: Error) {
        errorMessage = error.localizedDescription
        status = error.localizedDescription
        isConnected = false
    }
}

/// Vodorovná čára přes graf se štítkem (strike, break-even…).
struct ChartPriceLine: Hashable, Identifiable {
    var price: Double
    var label: String
    var color: Color
    var dashed: Bool = true

    var id: String { "\(label)@\(price)" }
}

/// Období grafu jako v aplikaci TradingView (1D, 5D, 1M, 3M, YTD, 1Y, 5Y, Vše).
enum ChartSpan: Hashable {
    /// Posledních N obchodních dní (podle data v New Yorku).
    case sessions(Int)
    case seconds(TimeInterval)
    case yearToDate
    case all

    func barCount(in bars: [Bar]) -> Int {
        guard let last = bars.last else { return 0 }
        switch self {
        case .all:
            return bars.count
        case .seconds(let span):
            return bars.filter { $0.time >= last.time - span }.count
        case .yearToDate:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let year = calendar.component(.year, from: Date(timeIntervalSince1970: last.time))
            let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))?.timeIntervalSince1970 ?? 0
            return bars.filter { $0.time >= start }.count
        case .sessions(let n):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            var days: [DateComponents] = []
            var count = 0
            for bar in bars.reversed() {
                let day = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: bar.time))
                if days.last != day {
                    if days.count == n { break }
                    days.append(day)
                }
                count += 1
            }
            return count
        }
    }
}
