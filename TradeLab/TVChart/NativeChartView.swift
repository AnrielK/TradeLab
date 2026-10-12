import SwiftUI
import UIKit

/// Nativní graf: vykreslení do Canvasu + gesta. Nahrazuje původní WKWebView.
struct NativeChartView: View {
    @Bindable var vm: ChartViewModel

    @State private var canvasSize: CGSize = .zero
    @State private var panStart: Viewport?
    @State private var zoomStart: Viewport?
    @State private var axisStart: Viewport?
    /// Kříž zapnutý podržením prstu — dokud běží, graf se neposouvá.
    @State private var crosshairActive = false
    /// Kříž se zapnul právě tímhle dotykem — zvednutí prstu ho tedy
    /// nesmí rovnou schovat.
    @State private var crosshairJustActivated = false
    /// Poslední místo dotyku. Podržení samo o sobě polohu nenese,
    /// tak si ji beru z probíhajícího dotyku.
    @State private var lastTouch: CGPoint = .zero
    @State private var crosshair: CGPoint?
    /// Rozkreslený objekt (první bod už je položený).
    /// Body, které už uživatel potvrdil klepnutím.
    @State private var draftPoints: [DrawPoint] = []
    /// Bod položený zvednutím prstu — jde ho ještě přetáhnout,
    /// potvrdí se až dalším klepnutím.
    @State private var pendingPoint: DrawPoint?
    @State private var brushPoints: [DrawPoint] = []
    @State private var dragOrigin: DragOrigin?

    /// Co se právě táhne — jeden bod (`pointIndex`), nebo celý objekt.
    private struct DragOrigin {
        let id: UUID
        let points: [DrawPoint]
        let start: CGPoint
        let pointIndex: Int?
    }
    @State private var textPrompt = false
    @State private var textInput = ""
    @State private var pendingTextPoint: DrawPoint?

    var body: some View {
        GeometryReader { proxy in
            let geo = vm.geometry(for: proxy.size)

            Canvas { ctx, size in
                guard size.width > 0 else { return }
                // víc úrovní na ose; počet se řídí výškou, ať se nepřekrývají
                let target = max(6, min(16, Int(geo.candleRect.height / 46)))
                let levels = ChartRenderer.priceLevels(min: geo.priceMin,
                                                       max: geo.priceMax, target: target)
                let dec = ChartRenderer.decimals(for: vm.lastBar?.close ?? 1)

                ChartRenderer.drawGrid(&ctx, geo: geo, levels: levels)
                if vm.volumeMode == .overlay {
                    ChartRenderer.drawVolumeOverlay(&ctx, geo: geo, bars: vm.bars)
                } else {
                    ChartRenderer.drawVolume(&ctx, geo: geo, bars: vm.bars)
                }
                ChartRenderer.drawVolumeProfile(&ctx, geo: geo,
                                                bins: vm.volumeBins(for: geo),
                                                settings: vm.volumeProfile)
                ChartRenderer.drawCandles(&ctx, geo: geo, bars: vm.bars, kind: vm.chartKind)
                ChartRenderer.drawIndicators(&ctx, geo: geo, outputs: vm.indicatorOutputs)
                ChartRenderer.drawPriceLines(&ctx, geo: geo, lines: vm.priceLines, decimals: dec)

                if let last = vm.lastBar {
                    ChartRenderer.drawLastPrice(&ctx, geo: geo, bar: last, decimals: dec)
                }

                ChartRenderer.drawDrawings(&ctx, geo: geo,
                                           drawings: vm.drawings.filter(\.visible),
                                           selected: vm.selectedDrawing)

                // rozkreslený objekt se ukazuje průběžně
                if let preview = previewDrawing() {
                    ChartRenderer.drawOne(&ctx, geo: geo, drawing: preview, selected: false)
                }

                ChartRenderer.drawVolumeAxis(&ctx, geo: geo, bars: vm.bars)
                ChartRenderer.drawOscValues(&ctx, geo: geo, outputs: vm.indicatorOutputs)
                ChartRenderer.drawAxisBorders(&ctx, geo: geo)
                ChartRenderer.drawPriceAxis(&ctx, geo: geo, levels: levels, decimals: dec)
                ChartRenderer.drawTimeAxis(&ctx, geo: geo, bars: vm.bars,
                                           resolution: vm.resolution)

                if let c = crosshair {
                    // Kříž stojí na svíčce, ne mezi nimi — datum tak nikdy
                    // nepadne na víkend nebo svátek, kdy se neobchoduje.
                    let snapped = snapToBar(c, geo: geo)
                    // V panelu indikátoru ukazuj hodnotu toho indikátoru,
                    // ne cenu z hlavního grafu.
                    let inPane = geo.pane(atY: c.y)
                    let value = inPane.map { geo.oscValue(forY: c.y, pane: $0) }
                        ?? geo.price(for: c.y)
                    let valueDec = inPane == nil
                        ? dec
                        : (abs(value) < 10 ? 3 : 2)
                    ChartRenderer.drawCrosshair(&ctx, geo: geo, at: snapped.point,
                                                price: value, decimals: valueDec)
                    ChartRenderer.drawTimeBadge(&ctx, geo: geo, x: snapped.point.x,
                                                time: snapped.time)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(geo: geo))
            .simultaneousGesture(magnifyGesture(geo: geo))
            .simultaneousGesture(crosshairGesture(geo: geo))
            .overlay(alignment: .topLeading) { countdownBadge(geo: geo) }
            .overlay(alignment: .trailing) { priceAxisHandle(geo: geo) }
            .overlay(alignment: .topLeading) { addLineButton(geo: geo, in: proxy.size) }
            .onAppear {
                canvasSize = proxy.size
                vm.updateOrientation(landscape: proxy.size.width > proxy.size.height)
            }
            .onChange(of: vm.activeTool) { _, _ in cancelDraft() }
            .onChange(of: proxy.size) { _, new in
                // Každá orientace má vlastní uložené přiblížení.
                vm.updateOrientation(landscape: new.width > new.height)

                // Při rotaci se velikost mění postupně; bez vypnuté animace
                // se každý mezikrok animoval zvlášť a otáčení se trhalo.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { canvasSize = new }
            }
        }
        .background(Color(hex: "#0d1117"))
        // Bez tohohle SwiftUI animuje každý mezikrok změny velikosti zvlášť
        // a otáčení působí pomalu.
        .animation(nil, value: canvasSize)
        .overlay(alignment: .topLeading) { legend }
        .alert("Text", isPresented: $textPrompt) {
            TextField("Popisek", text: $textInput)
            Button("Přidat") { commitText() }
            Button("Zrušit", role: .cancel) { pendingTextPoint = nil; textInput = "" }
        }
    }

    // MARK: Legenda

    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(vm.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChartTheme.ink)
                if let b = vm.lastBar {
                    let dec = ChartRenderer.decimals(for: b.close)
                    Text(ChartRenderer.format(b.close, decimals: dec))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ChartTheme.ink)
                    Text(vm.changeText)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(vm.changeIsUp ? ChartTheme.up : ChartTheme.down)
                }
            }

            if let b = vm.hoverBar ?? vm.lastBar {
                let dec = ChartRenderer.decimals(for: b.close)
                let c = b.close >= b.open ? ChartTheme.up : ChartTheme.down
                HStack(spacing: 8) {
                    ohlcItem("O", b.open, dec, c)
                    ohlcItem("H", b.high, dec, c)
                    ohlcItem("L", b.low, dec, c)
                    ohlcItem("C", b.close, dec, c)
                }
            }

            // Nahoře jen ty, co se kreslí přes svíčky. Oscilátory mají
            // popisek u svého panelu dole.
            ForEach(vm.indicatorsEnabled ? vm.indicators.filter { $0.def?.overlay ?? true } : []) { ind in
                Text(ind.label)
                    .font(.system(size: 11))
                    .foregroundStyle(ind.style.color)
            }

            if !vm.status.isEmpty {
                Text(vm.status)
                    .font(.system(size: 10))
                    .foregroundStyle(vm.errorMessage != nil ? ChartTheme.down : ChartTheme.inkDim)
            }
        }
        .padding(.leading, 10)
        .padding(.top, 8)
        .allowsHitTesting(false)
    }

    private func ohlcItem(_ label: String, _ value: Double,
                          _ dec: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(ChartTheme.inkDim)
            Text(ChartRenderer.format(value, decimals: dec))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    /// Odpočet do uzavření svíčky. Je to samostatná vrstva s vlastním
    /// časovačem — kdyby visel v Canvasu, překresloval by se každou sekundu
    /// celý graf a rotace i posun by se kvůli tomu trhaly.
    @ViewBuilder
    private func countdownBadge(geo: ChartGeometry) -> some View {
        if let last = vm.lastBar {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                if let text = vm.candleCountdown(now: timeline.date) {
                    Text(text)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(ChartTheme.ink)
                        .frame(width: ChartGeometry.axisWidth - 4, height: 14)
                        .background(
                            (last.close >= last.open ? ChartTheme.up : ChartTheme.down)
                                .opacity(0.28),
                            in: RoundedRectangle(cornerRadius: 3))
                        .position(x: geo.plotWidth + ChartGeometry.axisWidth / 2,
                                  y: geo.y(for: last.close) + 17)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Tlačítko „+“ u cenovky kříže — přidá vodorovnou čáru na té ceně.
    @ViewBuilder
    private func addLineButton(geo: ChartGeometry, in size: CGSize) -> some View {
        if let c = crosshair, c.y > 10, c.y < geo.candleRect.maxY,
           geo.pane(atY: c.y) == nil {
            Button {
                let price = geo.price(for: c.y)
                vm.addDrawing(tool: DrawToolKind.hline.rawValue,
                              points: [DrawPoint(time: geo.time(forX: c.x), price: price)])
                crosshairActive = false
                if !vm.crosshairPinned { crosshair = nil; vm.hoverIndex = nil }
            } label: {
                ZStack {
                    Circle()
                        .fill(ChartTheme.panel)
                        .overlay(Circle().stroke(ChartTheme.border, lineWidth: 0.5))
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChartTheme.ink)
                }
                .frame(width: 18, height: 18)
                .frame(width: 24, height: 24)      // jen mírně větší než ikona
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // sedí těsně vlevo od cenovky na ose
            .position(x: geo.plotWidth - 12, y: c.y)
        }
    }

    /// Neviditelný pruh přes cenovou osu — tažením se graf svisle roztahuje
    /// i zmáčkne, dvojklep vrátí automatické měřítko.
    private func priceAxisHandle(geo: ChartGeometry) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(width: ChartGeometry.axisWidth)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if axisStart == nil { axisStart = vm.viewport }
                        guard let start = axisStart else { return }
                        var vp = start
                        // tažení nahoru roztahuje, dolů zmáčkne
                        let factor = exp(-Double(value.translation.height) / 160)
                        vp.priceZoom = (start.priceZoom * factor)
                            .clamped(to: Viewport.minPriceZoom...Viewport.maxPriceZoom)
                        vm.viewport = vp
                    }
                    .onEnded { _ in
                        axisStart = nil
                        vm.saveViewport()
                    }
            )
            .onTapGesture(count: 2) { vm.resetPriceScale() }
            .overlay(alignment: .bottom) {
                if vm.viewport.manualPriceScale {
                    Text("auto")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ChartTheme.inkDim, in: Capsule())
                        .padding(.bottom, ChartGeometry.timeAxisHeight + 4)
                        .onTapGesture { vm.resetPriceScale() }
                }
            }
    }

    // MARK: Gesta

    private func dragGesture(geo: ChartGeometry) -> some Gesture {
        // Jeden rozpoznávač pro celý dotyk. Se dvěma gesty (tažení + klepnutí)
        // si SwiftUI vybíral tažení i u ťuknutí a klepnutí se nikdy
        // nevyhodnotilo — kříž pak nešel schovat.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let tool = DrawToolKind(rawValue: vm.activeTool) ?? .cursor
                lastTouch = value.location

                // dokud se prst prakticky nepohnul, nic neděláme —
                // teprve na konci se rozhodne, jestli to bylo ťuknutí
                guard hypot(value.translation.width,
                            value.translation.height) >= 3 else { return }

                // Kříž jen tam, kde ho uživatel chce: po podržení prstu,
                // při kreslení, nebo když je připnutý. Prostý posun grafu
                // ho nevyvolává.
                if crosshairActive || tool.isDrawing || tool == .cross
                    || vm.crosshairPinned {
                    crosshair = value.location
                    vm.hoverIndex = Int(geo.index(for: value.location.x).rounded())
                }

                // 1) volná kresba
                if tool == .brush {
                    brushPoints.append(dataPoint(value.location, geo: geo))
                    return
                }

                // 2) kreslicí nástroj: graf se nehýbe, kříž jen jede za prstem
                //    v obou osách. Bod se položí až po zvednutí prstu, aby
                //    šlo v klidu zamířit.
                if tool.isDrawing { return }

                // 3) úprava existující kresby — buď za bod, nebo za tělo
                if tool == .cursor {
                    if dragOrigin == nil {
                        dragOrigin = grabDrawing(at: value.startLocation, geo: geo)
                        if let g = dragOrigin {
                            vm.selectedDrawing = g.id
                            vm.beginDragEdit()      // jeden krok undo za celé tažení
                        }
                    }
                    if let origin = dragOrigin {
                        if let pi = origin.pointIndex {
                            // jeden bod jde kamkoliv, zbytek objektu zůstává
                            vm.moveDrawingPoint(origin.id, pointIndex: pi,
                                                to: dataPoint(value.location, geo: geo))
                        } else {
                            let dTime = geo.time(forX: value.location.x)
                                - geo.time(forX: origin.start.x)
                            let dPrice = geo.price(for: value.location.y)
                                - geo.price(for: origin.start.y)
                            vm.moveDrawing(origin.id, points: origin.points.map {
                                DrawPoint(time: $0.time + dTime, price: $0.price + dPrice)
                            })
                        }
                        return
                    }
                }

                // 4) nitkový kříž jako nástroj — jen sleduje prst
                if tool == .cross { return }

                // 5) aktivní kříž má přednost před posunem grafu
                if crosshairActive { return }

                // 6) posun grafu; se zapnutým ručním měřítkem i svisle
                if panStart == nil { panStart = vm.viewport }
                if let start = panStart {
                    var vp = start
                    vp.pan(bars: -Double(value.translation.width / geo.barWidth))
                    vp.clamp(barCount: vm.bars.count, margin: vm.rightMarginBars)
                    if start.manualPriceScale, geo.candleRect.height > 0 {
                        let span = geo.priceMax - geo.priceMin
                        let dPrice = Double(value.translation.height / geo.candleRect.height) * span
                        vp.priceShift = start.priceShift
                            + (span != 0 ? dPrice / span : 0)
                    }
                    vm.viewport = vp
                }
            }
            .onEnded { value in
                let tool = DrawToolKind(rawValue: vm.activeTool) ?? .cursor

                // Krátký pohyb = ťuknutí. Řeší schování kříže, výběr
                // objektu i pokládání bodů kresby.
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 8 {
                    panStart = nil
                    dragOrigin = nil
                    brushPoints = []
                    if crosshairJustActivated {
                        crosshairJustActivated = false   // kříž právě naskočil
                    } else {
                        handleTap(at: value.location, geo: geo)
                    }
                    return
                }
                crosshairJustActivated = false

                if tool == .brush {
                    if brushPoints.count > 1 {
                        vm.addDrawing(tool: tool.rawValue, points: brushPoints)
                        vm.finishTool()
                    }
                    brushPoints = []
                } else if tool.isDrawing {
                    crosshair = value.location
                    if draftPoints.isEmpty {
                        // první bod se jen zaměřuje — potvrdí ho až klepnutí
                        pendingPoint = dataPoint(value.location, geo: geo)
                    } else {
                        // druhý bod se vytáhne tažením a zvednutím je hotovo
                        finishDrawing(at: value.location, geo: geo)
                    }
                } else if dragOrigin != nil {
                    vm.endDragEdit()            // posun se uloží až tady
                }

                if panStart != nil { vm.saveViewport() }
                panStart = nil
                dragOrigin = nil

                if !vm.crosshairPinned, !crosshairActive,
                   tool != .cross, draftPoints.isEmpty {
                    crosshair = nil
                    vm.hoverIndex = nil
                }
            }
    }

    /// Klepnutí kamkoliv po grafu potvrdí bod tam, kde stojí kříž.
    /// U dvoubodových nástrojů se druhý bod dá vytáhnout tažením.
    private func placePoint(at location: CGPoint, geo: ChartGeometry) {
        let tool = DrawToolKind(rawValue: vm.activeTool) ?? .cursor
        // rozpracovaný bod (kříž) má přednost před místem klepnutí
        let point = pendingPoint ?? dataPoint(location, geo: geo)

        switch tool {
        case .text:
            pendingPoint = nil
            pendingTextPoint = point
            textInput = ""
            textPrompt = true

        case .hline, .vline:
            pendingPoint = nil
            vm.addDrawing(tool: tool.rawValue, points: [point])
            if !vm.crosshairPinned { crosshair = nil }
            vm.finishTool()

        default:
            if draftPoints.isEmpty {
                draftPoints = [point]       // první bod hotový, kříž zůstane stát
                pendingPoint = nil
                crosshair = CGPoint(x: geo.x(forTime: point.time),
                                    y: geo.y(for: point.price))
            } else {
                finishDrawing(at: location, geo: geo)
            }
        }
    }

    /// Dokončí dvoubodový objekt druhým bodem.
    private func finishDrawing(at location: CGPoint, geo: ChartGeometry) {
        guard let first = draftPoints.first else { return }
        let tool = DrawToolKind(rawValue: vm.activeTool) ?? .cursor
        vm.addDrawing(tool: tool.rawValue,
                      points: [first, dataPoint(location, geo: geo)])
        draftPoints = []
        pendingPoint = nil
        if !vm.crosshairPinned { crosshair = nil }
        vm.finishTool()
    }

    /// Schová nitkový kříž zapnutý podržením prstu.
    private func dismissCrosshair() {
        crosshairActive = false
        if !vm.crosshairPinned {
            crosshair = nil
            vm.hoverIndex = nil
        }
    }

    /// Zruší rozdělanou kresbu (např. při přepnutí nástroje).
    private func cancelDraft() {
        draftPoints = []
        pendingPoint = nil
    }

    /// Podržení prstu zapne nitkový kříž, další tažení ho vede.
    /// Bez podržení se prstem normálně posouvá graf.
    private func crosshairGesture(geo: ChartGeometry) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }

                if !crosshairActive {
                    crosshairJustActivated = true
                    // krátké cvaknutí, ať je poznat, že kříž naskočil
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                crosshairActive = true
                panStart = nil                 // rozjetý posun zahodíme

                // Bez pohybu prstu je `drag` nil — vezmeme tedy místo
                // dotyku, aby se kříž ukázal hned po podržení.
                let point = drag?.location ?? lastTouch
                guard point != .zero else { return }
                crosshair = point
                vm.hoverIndex = Int(geo.index(for: point.x).rounded())
            }
    }

    private func magnifyGesture(geo: ChartGeometry) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.03)
            .onChanged { value in
                // Při rozjetém posunu nebo aktivním kříži zoom ignorujeme —
                // jinak jednoprstové tažení občas skočilo v měřítku.
                guard panStart == nil, !crosshairActive, dragOrigin == nil else { return }
                if zoomStart == nil { zoomStart = vm.viewport }
                guard let start = zoomStart else { return }
                var vp = start
                let ratio = geo.plotWidth > 0
                    ? Double(value.startAnchor.x)
                    : 0.5
                vp.zoom(factor: value.magnification, anchorRatio: ratio.clamped(to: 0...1))
                vp.clamp(barCount: vm.bars.count, margin: vm.rightMarginBars)
                vm.viewport = vp
            }
            .onEnded { _ in
                zoomStart = nil
                vm.saveViewport()
            }
    }

    private func handleTap(at location: CGPoint, geo: ChartGeometry) {
        let tool = DrawToolKind(rawValue: vm.activeTool) ?? .cursor

        if crosshairActive {
            dismissCrosshair()
            return
        }

        switch tool {
        case .cursor:
            vm.selectedDrawing = vm.drawings.last {
                $0.visible && !$0.locked && hitTest($0, at: location, geo: geo)
            }?.id

        case .erase:
            if let hit = vm.drawings.last(where: {
                $0.visible && !$0.locked && hitTest($0, at: location, geo: geo)
            }) {
                vm.removeDrawing(hit.id)
            }

        case .cross:
            crosshair = location
            vm.hoverIndex = Int(geo.index(for: location.x).rounded())

        default:
            placePoint(at: location, geo: geo)
        }
    }

    // MARK: Pomocné

    /// Co je pod prstem: nejdřív úchopový bod vybraného objektu, pak tělo
    /// libovolného objektu. Zamčené a skryté se přeskakují.
    private func grabDrawing(at location: CGPoint, geo: ChartGeometry) -> DragOrigin? {
        let candidates = vm.drawings.filter { $0.visible && !$0.locked }

        // 1) úchopový bod — nejdřív u vybraného, ať se dá trefit i v překryvu
        let ordered = candidates.sorted { a, b in
            (a.id == vm.selectedDrawing ? 1 : 0) > (b.id == vm.selectedDrawing ? 1 : 0)
        }
        for d in ordered where d.hasPointHandles {
            for (i, p) in d.points.enumerated() {
                let pt = CGPoint(x: geo.x(forTime: p.time), y: geo.y(for: p.price))
                if hypot(pt.x - location.x, pt.y - location.y) < handleRadius {
                    return DragOrigin(id: d.id, points: d.points,
                                      start: location, pointIndex: i)
                }
            }
        }

        // 2) tělo objektu
        if let hit = candidates.last(where: { hitTest($0, at: location, geo: geo) }) {
            return DragOrigin(id: hit.id, points: hit.points,
                              start: location, pointIndex: nil)
        }
        return nil
    }

    /// Dosah úchopu — prst je hrubší než myš.
    private var handleRadius: CGFloat { 22 }

    /// Nejbližší svíčka k dané pozici — kříž se na ni přichytí.
    /// Když je prst za posledním barem, vrací dopočítaný čas.
    private func snapToBar(_ location: CGPoint,
                           geo: ChartGeometry) -> (point: CGPoint, time: Double) {
        let raw = geo.index(for: location.x)
        let i = Int(raw.rounded())
        if i >= 0, i < vm.bars.count {
            return (CGPoint(x: geo.x(for: Double(i)), y: location.y), vm.bars[i].time)
        }
        return (location, geo.time(forX: location.x))
    }

    private func dataPoint(_ location: CGPoint, geo: ChartGeometry) -> DrawPoint {
        var time = geo.time(forX: location.x)
        var price = geo.price(for: location.y)

        // magnet: přichytit k nejbližší OHLC hodnotě
        if vm.magnet {
            let i = Int(geo.index(for: location.x).rounded())
            if i >= 0, i < vm.bars.count {
                let b = vm.bars[i]
                let candidates = [b.open, b.high, b.low, b.close]
                if let best = candidates.min(by: { abs($0 - price) < abs($1 - price) }) {
                    price = best
                    time = b.time
                }
            }
        }
        return DrawPoint(time: time, price: price)
    }

    private func previewDrawing() -> Drawing? {
        let tool = DrawToolKind(rawValue: vm.activeTool) ?? .cursor

        if tool == .brush, brushPoints.count > 1 {
            return vm.makeDrawing(tool: tool.rawValue, points: brushPoints)
        }
        guard canvasSize.width > 0 else { return nil }
        let geo = vm.geometry(for: canvasSize)

        // konec náhledu = rozpracovaný bod, jinak pozice kříže
        let live: DrawPoint? = pendingPoint
            ?? crosshair.map { dataPoint($0, geo: geo) }

        if let first = draftPoints.first, let live {
            return vm.makeDrawing(tool: tool.rawValue, points: [first, live])
        }
        // ještě před prvním potvrzeným bodem ukaž aspoň rozpracovaný bod
        if draftPoints.isEmpty, let p = pendingPoint, tool.pointCount != 1 {
            return vm.makeDrawing(tool: tool.rawValue, points: [p, p])
        }
        return nil
    }

    private func commitText() {
        guard let p = pendingTextPoint, !textInput.isEmpty else { return }
        vm.addDrawing(tool: DrawToolKind.text.rawValue, points: [p], text: textInput)
        pendingTextPoint = nil
        textInput = ""
        vm.finishTool()
    }

    /// Hrubý zásah — stačí, aby se dalo trefit prstem.
    private func hitTest(_ d: Drawing, at location: CGPoint, geo: ChartGeometry) -> Bool {
        let tolerance: CGFloat = 16
        let pts = d.points.map { CGPoint(x: geo.x(forTime: $0.time), y: geo.y(for: $0.price)) }
        guard !pts.isEmpty else { return false }

        switch DrawToolKind(rawValue: d.tool) ?? .trend {
        case .hline, .hray:
            return abs(location.y - pts[0].y) < tolerance
        case .vline:
            return abs(location.x - pts[0].x) < tolerance
        case .text:
            return hypot(location.x - pts[0].x, location.y - pts[0].y) < 40
        case .rect, .ellipse, .fib:
            guard pts.count > 1 else { return false }
            let r = CGRect(x: min(pts[0].x, pts[1].x), y: min(pts[0].y, pts[1].y),
                           width: abs(pts[1].x - pts[0].x), height: abs(pts[1].y - pts[0].y))
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(location)
        case .brush:
            return pts.contains { hypot($0.x - location.x, $0.y - location.y) < tolerance }
        default:
            guard pts.count > 1 else { return false }
            return distanceToSegment(location, pts[0], pts[1]) < tolerance
        }
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = t.clamped(to: 0...1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
