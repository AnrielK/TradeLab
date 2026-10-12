import SwiftUI

/// Vykreslení celého grafu do jednoho Canvasu. Funkce jsou statické a čisté —
/// dostanou data a geometrii, nic si nedrží.
enum ChartRenderer {

    // MARK: Mřížka a osy

    /// Tenké oddělovače kolem os — graf tím dostane jasné hranice.
    static func drawAxisBorders(_ ctx: inout GraphicsContext, geo: ChartGeometry) {
        let color = ChartTheme.border

        // svislá u cenové osy
        var v = Path()
        v.move(to: CGPoint(x: geo.plotWidth, y: 0))
        v.addLine(to: CGPoint(x: geo.plotWidth, y: geo.bodyHeight))
        ctx.stroke(v, with: .color(color), lineWidth: 0.5)

        // vodorovná nad časovou osou
        var h = Path()
        h.move(to: CGPoint(x: 0, y: geo.bodyHeight))
        h.addLine(to: CGPoint(x: geo.size.width, y: geo.bodyHeight))
        ctx.stroke(h, with: .color(color), lineWidth: 0.5)

        // oddělení objemu a případného panelu oscilátorů
        if geo.volumeRatio > 0 {
            var vol = Path()
            vol.move(to: CGPoint(x: 0, y: geo.volumeRect.minY))
            vol.addLine(to: CGPoint(x: geo.plotWidth, y: geo.volumeRect.minY))
            ctx.stroke(vol, with: .color(ChartTheme.grid.opacity(0.6)), lineWidth: 0.5)
        }

        for pane in geo.oscRanges.indices {
            var osc = Path()
            osc.move(to: CGPoint(x: 0, y: geo.oscRect(pane).minY))
            osc.addLine(to: CGPoint(x: geo.plotWidth, y: geo.oscRect(pane).minY))
            ctx.stroke(osc, with: .color(color), lineWidth: 0.5)
        }
    }

    static func drawGrid(_ ctx: inout GraphicsContext, geo: ChartGeometry, levels: [Double]) {
        for price in levels {
            let y = geo.y(for: price)
            guard y >= 0, y <= geo.candleRect.maxY else { continue }
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: geo.plotWidth, y: y))
            ctx.stroke(p, with: .color(ChartTheme.grid), lineWidth: 1)
        }
    }

    static func drawPriceAxis(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                              levels: [Double], decimals: Int) {
        for price in levels {
            let y = geo.y(for: price)
            guard y >= 8, y <= geo.candleRect.maxY else { continue }
            let text = Text(format(price, decimals: decimals))
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(ChartTheme.axis)
            ctx.draw(text, at: CGPoint(x: geo.plotWidth + 6, y: y), anchor: .leading)
        }
    }

    static func drawTimeAxis(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                             bars: [Bar], resolution: String) {
        guard !bars.isEmpty else { return }
        let y = geo.bodyHeight + ChartGeometry.timeAxisHeight / 2
        let from = max(0, Int(geo.viewport.leftIndex))
        let to = min(bars.count - 1, Int(geo.viewport.rightIndex))
        guard from < to else { return }

        // Popisky se kladou na hranice období (nový měsíc, nový den…), ne po
        // pevném kroku — jinak vyjde pětkrát stejný měsíc jako dřív.
        //
        // Rozsah bereme z celého výřezu, ne jen z viditelných barů: u pravého
        // okraje je půlka plochy prázdná a podle barů by rozsah vyšel malý,
        // takže by osa najednou přeskočila z měsíců na dny.
        let span = geo.time(forX: geo.plotWidth) - geo.time(forX: 0)
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "cs_CZ")

        let unit: Calendar.Component
        let format: String
        if span < 2 * 86400        { unit = .hour;  format = "HH:mm" }
        else if span < 90 * 86400  { unit = .day;   format = "d.M." }
        else if span < 800 * 86400 { unit = .month; format = "LLL" }
        else                       { unit = .year;  format = "yyyy" }

        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = format
        let yearFormatter = DateFormatter()
        yearFormatter.locale = Locale(identifier: "cs_CZ")
        yearFormatter.dateFormat = unit == .month ? "LLL yy" : format

        var lastLabelX: CGFloat = -.greatestFiniteMagnitude
        var previous = Date(timeIntervalSince1970: bars[from].time)

        for i in (from + 1)...to {
            let date = Date(timeIntervalSince1970: bars[i].time)
            guard !cal.isDate(date, equalTo: previous, toGranularity: unit) else { continue }
            previous = date

            let x = geo.x(for: Double(i))
            guard x > 16, x < geo.plotWidth - 16 else { continue }
            guard x - lastLabelX > 52 else { continue }   // ať se popisky nelepí
            lastLabelX = x

            // na přelomu roku připoj i rok, ať je jasné, kde jsme
            let isYearBreak = unit == .month
                && cal.component(.month, from: date) == 1
            let text = isYearBreak ? yearFormatter.string(from: date)
                                   : f.string(from: date)

            ctx.draw(Text(text).font(.system(size: 10))
                        .foregroundColor(ChartTheme.axis),
                     at: CGPoint(x: x, y: y), anchor: .center)
        }
    }

    /// Štítek pod křížem — den, datum, měsíc i rok, ať je jasné, kde stojíš.
    static func drawTimeBadge(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                              x: CGFloat, time: Double) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = "EEE d. MMM yyyy"
        let text = f.string(from: Date(timeIntervalSince1970: time))

        let resolved = ctx.resolve(Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(ChartTheme.ink))
        let size = resolved.measure(in: CGSize(width: 260, height: 30))

        // ať štítek nevyleze z grafu ven
        let half = size.width / 2 + 6
        let cx = x.clamped(to: half...max(half, geo.plotWidth - half))
        let rect = CGRect(x: cx - size.width / 2 - 6,
                          y: geo.bodyHeight + 1,
                          width: size.width + 12,
                          height: ChartGeometry.timeAxisHeight - 2)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(ChartTheme.panel))
        ctx.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    // MARK: Svíčky a objem

    static func drawCandles(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                            bars: [Bar], kind: String) {
        // Bez ořezu se svíčky při ručním svislém měřítku daly stáhnout
        // dolů přes objem až do panelů indikátorů.
        var ctx = ctx
        ctx.clip(to: Path(CGRect(x: 0, y: 0,
                                 width: geo.plotWidth, height: geo.candleRect.maxY)))
        let range = visibleRange(geo: geo, count: bars.count)
        guard !range.isEmpty else { return }

        switch kind {
        case "Line", "Area":
            var path = Path()
            var first = true
            for i in range {
                let pt = CGPoint(x: geo.x(for: Double(i)), y: geo.y(for: bars[i].close))
                if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
            }
            if kind == "Area", let firstIdx = range.first, let lastIdx = range.last {
                var fill = path
                fill.addLine(to: CGPoint(x: geo.x(for: Double(lastIdx)), y: geo.candleRect.maxY))
                fill.addLine(to: CGPoint(x: geo.x(for: Double(firstIdx)), y: geo.candleRect.maxY))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [Color(hex: "#e0a83c").opacity(0.28), .clear]),
                    startPoint: CGPoint(x: 0, y: geo.candleRect.minY),
                    endPoint: CGPoint(x: 0, y: geo.candleRect.maxY)))
            }
            ctx.stroke(path, with: .color(Color(hex: "#e0a83c")), lineWidth: 2)

        default:
            let bodyWidth = max(1, geo.barWidth * 0.68)
            for i in range {
                let b = bars[i]
                let x = geo.x(for: Double(i))
                let up = b.close >= b.open
                let color = up ? ChartTheme.up : ChartTheme.down

                // knot
                var wick = Path()
                wick.move(to: CGPoint(x: x, y: geo.y(for: b.high)))
                wick.addLine(to: CGPoint(x: x, y: geo.y(for: b.low)))
                ctx.stroke(wick, with: .color(color), lineWidth: max(1, geo.barWidth * 0.1))

                // tělo
                let yOpen = geo.y(for: b.open), yClose = geo.y(for: b.close)
                let top = min(yOpen, yClose)
                let height = max(1, abs(yClose - yOpen))
                ctx.fill(Path(CGRect(x: x - bodyWidth / 2, y: top,
                                     width: bodyWidth, height: height)),
                         with: .color(color))
            }
        }
    }

    static func drawVolume(_ ctx: inout GraphicsContext, geo: ChartGeometry, bars: [Bar]) {
        guard geo.volumeRatio > 0 else { return }
        var ctx = ctx
        ctx.clip(to: Path(geo.volumeRect))
        let range = visibleRange(geo: geo, count: bars.count)
        let w = max(1, geo.barWidth * 0.68)
        for i in range {
            let b = bars[i]
            guard let v = b.volume, v > 0 else { continue }
            let x = geo.x(for: Double(i))
            let y = geo.volumeY(for: v)
            let color = (b.close >= b.open ? ChartTheme.up : ChartTheme.down).opacity(0.32)
            ctx.fill(Path(CGRect(x: x - w / 2, y: y,
                                 width: w, height: geo.volumeRect.maxY - y)),
                     with: .color(color))
        }
    }

    // MARK: Indikátory

    /// Objem překrytý přes spodek cenové části — bez vlastního pásu.
    static func drawVolumeOverlay(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                                  bars: [Bar]) {
        guard geo.volumeMax > 0 else { return }
        var ctx = ctx
        let area = CGRect(x: 0, y: geo.candleRect.maxY - geo.candleRect.height * 0.22,
                          width: geo.plotWidth, height: geo.candleRect.height * 0.22)
        ctx.clip(to: Path(area))

        let range = visibleRange(geo: geo, count: bars.count)
        let w = max(1, geo.barWidth * 0.68)
        for i in range {
            let b = bars[i]
            guard let v = b.volume, v > 0 else { continue }
            let h = area.height * CGFloat(v / geo.volumeMax)
            let x = geo.x(for: Double(i))
            let color = (b.close >= b.open ? ChartTheme.up : ChartTheme.down).opacity(0.28)
            ctx.fill(Path(CGRect(x: x - w / 2, y: area.maxY - h, width: w, height: h)),
                     with: .color(color))
        }
    }

    /// Objem na ose: maximum viditelného pásu a poslední hodnota.
    static func drawVolumeAxis(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                               bars: [Bar]) {
        guard geo.volumeMax > 0 else { return }
        guard geo.volumeRatio > 0 else {
            // v překryvném režimu stačí štítek poslední hodnoty
            if let last = bars.last, let v = last.volume, v > 0 {
                ctx.draw(Text(VolumeProfile.format(v))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(ChartTheme.axis),
                         at: CGPoint(x: geo.plotWidth + 5, y: geo.candleRect.maxY - 8),
                         anchor: .leading)
            }
            return
        }

        ctx.draw(Text(VolumeProfile.format(geo.volumeMax))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(ChartTheme.axis),
                 at: CGPoint(x: geo.plotWidth + 5, y: geo.volumeRect.minY + 6),
                 anchor: .leading)

        guard let last = bars.last, let v = last.volume, v > 0 else { return }
        let color = (last.close >= last.open ? ChartTheme.up : ChartTheme.down)
        let y = geo.volumeY(for: v)
        let rect = CGRect(x: geo.plotWidth + 2, y: max(geo.volumeRect.minY, y - 7),
                          width: ChartGeometry.axisWidth - 4, height: 14)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.85)))
        ctx.draw(Text(VolumeProfile.format(v))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundColor(.black),
                 at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    /// Volume profil přes viditelný rozsah — vodorovné sloupce u okraje.
    static func drawVolumeProfile(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                                  bins: [VolumeBin], settings: VolumeProfileSettings) {
        guard settings.enabled, !bins.isEmpty else { return }
        let maxTotal = bins.map(\.total).max() ?? 0
        guard maxTotal > 0 else { return }

        var ctx = ctx
        ctx.clip(to: Path(CGRect(x: 0, y: 0,
                                 width: geo.plotWidth, height: geo.candleRect.maxY)))

        let maxWidth = geo.plotWidth * CGFloat(settings.widthRatio)
        let area = settings.showValueArea ? VolumeProfile.valueArea(bins) : nil
        let poc = bins.indices.max(by: { bins[$0].total < bins[$1].total })

        for (i, bin) in bins.enumerated() {
            guard bin.total > 0 else { continue }
            let yTop = geo.y(for: bin.high), yBottom = geo.y(for: bin.low)
            let h = max(1, abs(yBottom - yTop) - 1)
            let w = maxWidth * CGFloat(bin.total / maxTotal)

            // oblast 70 % objemu se podbarví přes celou šířku profilu
            if let area, area.contains(i) {
                let bg = CGRect(x: settings.onRight ? geo.plotWidth - maxWidth : 0,
                                y: min(yTop, yBottom), width: maxWidth, height: h)
                ctx.fill(Path(bg), with: .color(settings.valueAreaColor.opacity(0.08)))
            }

            func bar(_ value: Double, offset: CGFloat, color: Color) {
                guard value > 0 else { return }
                let bw = maxWidth * CGFloat(value / maxTotal)
                let x = settings.onRight ? geo.plotWidth - offset - bw : offset
                ctx.fill(Path(CGRect(x: x, y: min(yTop, yBottom), width: bw, height: h)),
                         with: .color(color))
            }

            if settings.splitBuySell {
                bar(bin.up, offset: 0, color: settings.upColor)
                bar(bin.down, offset: maxWidth * CGFloat(bin.up / maxTotal),
                    color: settings.downColor)
            } else {
                bar(bin.total, offset: 0, color: settings.singleColor)
            }

            // Point of Control — pásmo s největším objemem
            if settings.showPOC, i == poc {
                let y = (yTop + yBottom) / 2
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: geo.plotWidth, y: y))
                ctx.stroke(line, with: .color(settings.pocColor.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                _ = w
            }
        }
    }

    static func drawIndicators(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                               outputs: [IndicatorOutput]) {
        for out in outputs {
            // Každá vrstva se ořízne na svou oblast — překryvné indikátory
            // do cenové části, oscilátory do vlastního panelu.
            var clipped = ctx
            let area = out.overlay
                ? CGRect(x: 0, y: 0, width: geo.plotWidth, height: geo.candleRect.maxY)
                : geo.oscRect(out.pane ?? 0)
            clipped.clip(to: Path(area))

            for line in out.lines {
                switch line.kind {
                case .line:
                    drawPolyline(&clipped, geo: geo, line: line,
                                 overlay: out.overlay, pane: out.pane ?? 0)
                case .histogram:
                    drawHistogram(&clipped, geo: geo, line: line, pane: out.pane ?? 0)
                case .dots:
                    drawDots(&clipped, geo: geo, line: line, pane: out.pane ?? 0)
                }
            }
        }
    }

    /// Tečky na nulové ose — u Squeeze značí stav stlačení.
    private static func drawDots(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                                 line: IndicatorLine, pane: Int) {
        let r = max(1.2, min(3, geo.barWidth * 0.18))
        let y = geo.oscY(for: 0, pane: pane)
        let left = geo.viewport.leftIndex - 1, right = geo.viewport.rightIndex + 1
        for (i, p) in line.points.enumerated() {
            let idx = Double(p.index)
            guard idx >= left, idx <= right else { continue }
            let x = geo.x(for: idx)
            let color = line.pointColors?[safe: i] ?? line.color
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(color))
        }
    }

    private static func drawPolyline(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                                     line: IndicatorLine, overlay: Bool, pane: Int) {
        guard line.points.count > 1 else { return }
        let left = geo.viewport.leftIndex - 2, right = geo.viewport.rightIndex + 2

        var path = Path()
        var started = false
        for p in line.points {
            let idx = Double(p.index)
            guard idx >= left, idx <= right else {
                // mimo výřez — přeruš, ať se nekreslí přes celou obrazovku
                if started && idx > right { break }
                continue
            }
            let pt = CGPoint(x: geo.x(for: idx),
                             y: overlay ? geo.y(for: p.value)
                                        : geo.oscY(for: p.value, pane: pane))
            if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
        }
        guard started else { return }

        ctx.stroke(path, with: .color(line.color),
                   style: StrokeStyle(lineWidth: line.width,
                                      lineCap: .round, lineJoin: .round,
                                      dash: line.dash))
    }

    private static func drawHistogram(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                                      line: IndicatorLine, pane: Int) {
        let w = max(1, geo.barWidth * 0.6)
        let zero = geo.oscY(for: 0, pane: pane)
        let left = geo.viewport.leftIndex - 1, right = geo.viewport.rightIndex + 1
        for (i, p) in line.points.enumerated() {
            let idx = Double(p.index)
            guard idx >= left, idx <= right else { continue }
            let x = geo.x(for: idx)
            let y = geo.oscY(for: p.value, pane: pane)
            let color = line.pointColors?[safe: i]
                ?? (p.value >= 0
                    ? (line.positiveColor ?? line.color)
                    : (line.negativeColor ?? line.color))
            ctx.fill(Path(CGRect(x: x - w / 2, y: min(y, zero),
                                 width: w, height: max(1, abs(zero - y)))),
                     with: .color(color))
        }
    }

    /// Rozsah panelu, aktuální hodnoty a popisek indikátoru.
    static func drawOscValues(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                              outputs: [IndicatorOutput]) {
        guard !geo.oscRanges.isEmpty else { return }

        for (pane, r) in geo.oscRanges.enumerated() {
            let rect = geo.oscRect(pane)

            // krajní a střední hodnota panelu
            for value in [r.upperBound, (r.lowerBound + r.upperBound) / 2, r.lowerBound] {
                let y = geo.oscY(for: value, pane: pane)
                guard y > rect.minY + 4, y < rect.maxY - 2 || value == r.lowerBound
                else { continue }
                ctx.draw(Text(format(value, decimals: abs(value) < 10 ? 2 : 1))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(ChartTheme.axis),
                         at: CGPoint(x: geo.plotWidth + 5, y: y), anchor: .leading)
            }

            // popisek indikátoru patří ke svému panelu, ne nahoru k ceně
            if let out = outputs.first(where: { $0.pane == pane }) {
                ctx.draw(Text(out.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(out.labelColor),
                         at: CGPoint(x: 6, y: rect.minY + 8), anchor: .topLeading)
            }
        }

        // poslední hodnota každé linie ve vlastní barvě
        for out in outputs where !out.overlay {
            let pane = out.pane ?? 0
            for line in out.lines where line.kind == .line {
                guard let last = line.points.last else { continue }
                let y = geo.oscY(for: last.value, pane: pane)
                let rect = CGRect(x: geo.plotWidth + 2, y: y - 8,
                                  width: ChartGeometry.axisWidth - 4, height: 16)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(line.color))
                ctx.draw(Text(format(last.value, decimals: 2))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundColor(.black),
                         at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
    }

    // MARK: Kresby

    static func drawDrawings(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                             drawings: [Drawing], selected: UUID?) {
        var ctx = ctx
        ctx.clip(to: Path(CGRect(x: 0, y: 0,
                                 width: geo.plotWidth, height: geo.candleRect.maxY)))
        for d in drawings {
            drawOne(&ctx, geo: geo, drawing: d, selected: d.id == selected)
        }
    }

    static func drawOne(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                        drawing d: Drawing, selected: Bool) {
        let pts = d.points.map { CGPoint(x: geo.x(forTime: $0.time), y: geo.y(for: $0.price)) }
        guard !pts.isEmpty else { return }
        let stroke = StrokeStyle(lineWidth: d.width, lineCap: .round,
                                 lineJoin: .round, dash: d.dashPattern)
        let color = d.color

        // Vodorovné čáry platí přes celý graf, ty se kreslí vždy. Fibonacci
        // řeší viditelnost sám (hladiny pokračují doprava). Ostatní objekty
        // mizí, jakmile je jejich rozsah mimo viditelnou část.
        let kind = DrawToolKind(rawValue: d.tool) ?? .trend
        if kind != .hline, kind != .hray, kind != .fib {
            let minX = pts.map(\.x).min() ?? 0
            let maxX = pts.map(\.x).max() ?? 0
            if maxX < 0 || minX > geo.plotWidth { return }
        }

        switch kind {
        case .trend, .measure:
            guard pts.count > 1 else { break }
            var p = Path(); p.move(to: pts[0]); p.addLine(to: pts[1])
            ctx.stroke(p, with: .color(color), style: stroke)
            if d.tool == DrawToolKind.measure.rawValue, d.points.count > 1 {
                let from = d.points[0].price, to = d.points[1].price
                let pct = from != 0 ? (to - from) / from * 100 : 0
                let label = String(format: "%+.2f (%+.2f %%)", to - from, pct)
                drawBadge(&ctx, text: label, at: CGPoint(x: (pts[0].x + pts[1].x) / 2,
                                                         y: min(pts[0].y, pts[1].y) - 12),
                          color: color)
            }

        case .ray:
            guard pts.count > 1 else { break }
            let dir = CGPoint(x: pts[1].x - pts[0].x, y: pts[1].y - pts[0].y)
            let len = max(1, (dir.x * dir.x + dir.y * dir.y).squareRoot())
            let far = CGPoint(x: pts[0].x + dir.x / len * 4000,
                              y: pts[0].y + dir.y / len * 4000)
            var p = Path(); p.move(to: pts[0]); p.addLine(to: far)
            ctx.stroke(p, with: .color(color), style: stroke)

        case .arrow:
            guard pts.count > 1 else { break }
            var p = Path(); p.move(to: pts[0]); p.addLine(to: pts[1])
            ctx.stroke(p, with: .color(color), style: stroke)
            drawArrowHead(&ctx, from: pts[0], to: pts[1], color: color, size: 9 + d.width * 2)

        case .hline, .hray:
            let y = pts[0].y
            var p = Path()
            p.move(to: CGPoint(x: d.tool == DrawToolKind.hray.rawValue ? pts[0].x : 0, y: y))
            p.addLine(to: CGPoint(x: geo.plotWidth, y: y))
            ctx.stroke(p, with: .color(color), style: stroke)

        case .vline:
            var p = Path()
            p.move(to: CGPoint(x: pts[0].x, y: 0))
            p.addLine(to: CGPoint(x: pts[0].x, y: geo.candleRect.maxY))
            ctx.stroke(p, with: .color(color), style: stroke)

        case .rect:
            guard pts.count > 1 else { break }
            let r = CGRect(x: min(pts[0].x, pts[1].x), y: min(pts[0].y, pts[1].y),
                           width: abs(pts[1].x - pts[0].x), height: abs(pts[1].y - pts[0].y))
            ctx.fill(Path(r), with: .color(color.opacity(0.12)))
            ctx.stroke(Path(r), with: .color(color), style: stroke)

        case .ellipse:
            guard pts.count > 1 else { break }
            let r = CGRect(x: min(pts[0].x, pts[1].x), y: min(pts[0].y, pts[1].y),
                           width: abs(pts[1].x - pts[0].x), height: abs(pts[1].y - pts[0].y))
            ctx.fill(Path(ellipseIn: r), with: .color(color.opacity(0.12)))
            ctx.stroke(Path(ellipseIn: r), with: .color(color), style: stroke)

        case .fib:
            guard d.points.count > 1 else { break }
            let cfg = d.fib ?? .default
            let anchorLeft = min(pts[0].x, pts[1].x)
            let anchorRight = max(pts[0].x, pts[1].x)

            // Hladiny pokračují doprava, takže při přiblížení u pravého okraje
            // musí zůstat vidět i když kotvy zůstaly vlevo mimo obrazovku.
            // Skryje se to až když jsou kotvy celé napravo od výřezu — tam
            // objekt ještě "nezačal" a čáry by visely bez původu.
            guard anchorLeft <= geo.plotWidth else { break }
            if !cfg.extendRight, anchorRight < 0 { break }

            let p0 = d.points[0].price, p1 = d.points[1].price
            let x0 = max(0, anchorLeft)
            let x1 = cfg.extendRight ? geo.plotWidth : max(0, anchorRight)
            guard x1 > x0 else { break }

            var connector = Path()
            connector.move(to: pts[0]); connector.addLine(to: pts[1])
            ctx.stroke(connector, with: .color(ChartTheme.inkDim.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

            let shown = cfg.levels.filter(\.visible)

            if cfg.showBackground {
                for i in 0..<max(0, shown.count - 1) {
                    let a = geo.y(for: p0 + (p1 - p0) * shown[i].ratio)
                    let b = geo.y(for: p0 + (p1 - p0) * shown[i + 1].ratio)
                    let rect = CGRect(x: x0, y: min(a, b),
                                      width: x1 - x0, height: abs(b - a))
                    let fill = Color(hex: cfg.backgroundHex ?? shown[i].colorHex)
                    ctx.fill(Path(rect), with: .color(fill.opacity(cfg.backgroundOpacity)))
                }
            }

            for lv in shown {
                let price = p0 + (p1 - p0) * lv.ratio
                let y = geo.y(for: price)
                guard y > -20, y < geo.candleRect.maxY + 20 else { continue }
                let color = Color(hex: lv.colorHex).opacity(cfg.lineOpacity)
                let strong = lv.ratio == 0 || lv.ratio == 0.5 || lv.ratio == 1

                var line = Path()
                line.move(to: CGPoint(x: x0, y: y))
                line.addLine(to: CGPoint(x: x1, y: y))
                ctx.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: strong ? 1.4 : 1))

                if cfg.showLabels {
                    let dec = decimals(for: price)
                    let label = "\(lv.percentText) (\(format(price, decimals: dec)))"
                    ctx.draw(Text(label)
                                .font(.system(size: 10,
                                              weight: strong ? .semibold : .regular))
                                .foregroundColor(color),
                             at: CGPoint(x: x1 - 6, y: y - 8), anchor: .trailing)
                }
            }

        case .brush:
            var p = Path()
            p.move(to: pts[0])
            pts.dropFirst().forEach { p.addLine(to: $0) }
            ctx.stroke(p, with: .color(color), style: stroke)

        case .text:
            let label = d.text ?? ""
            if !label.isEmpty {
                ctx.draw(Text(label).font(.system(size: 12, weight: .medium))
                            .foregroundColor(color),
                         at: pts[0], anchor: .leading)
            }

        case .cursor, .cross, .erase:
            break
        }

        guard selected else { return }

        if d.locked {
            // zamčený objekt nemá úchopy, jen značku u prvního bodu
            let r = CGRect(x: pts[0].x - 6, y: pts[0].y - 6, width: 12, height: 12)
            ctx.fill(Path(ellipseIn: r), with: .color(ChartTheme.inkDim.opacity(0.85)))
            ctx.draw(Text(Image(systemName: "lock.fill"))
                        .font(.system(size: 7))
                        .foregroundColor(.black),
                     at: CGPoint(x: pts[0].x, y: pts[0].y), anchor: .center)
            return
        }

        // úchopy jednotlivých bodů — za ně se táhne začátek/konec zvlášť
        if d.hasPointHandles {
            for pt in pts {
                let outer = CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)
                ctx.fill(Path(ellipseIn: outer), with: .color(.white))
                ctx.stroke(Path(ellipseIn: outer), with: .color(color), lineWidth: 2)
            }
        } else if let first = pts.first, let last = pts.last {
            // volná kresba se posouvá jen celá — naznač to jen konci tahu
            for pt in [first, last] {
                let r = CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: r), with: .color(color))
            }
        }
    }

    private static func drawArrowHead(_ ctx: inout GraphicsContext, from: CGPoint,
                                      to: CGPoint, color: Color, size: CGFloat) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let a1 = angle + .pi * 0.85, a2 = angle - .pi * 0.85
        var p = Path()
        p.move(to: to)
        p.addLine(to: CGPoint(x: to.x + cos(a1) * size, y: to.y + sin(a1) * size))
        p.addLine(to: CGPoint(x: to.x + cos(a2) * size, y: to.y + sin(a2) * size))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }

    private static func drawBadge(_ ctx: inout GraphicsContext, text: String,
                                  at point: CGPoint, color: Color) {
        let resolved = ctx.resolve(Text(text).font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white))
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let rect = CGRect(x: point.x - size.width / 2 - 5, y: point.y - size.height / 2 - 3,
                          width: size.width + 10, height: size.height + 6)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.9)))
        ctx.draw(resolved, at: point, anchor: .center)
    }

    // MARK: Nitkový kříž

    static func drawCrosshair(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                              at point: CGPoint, price: Double, decimals: Int) {
        let dash = StrokeStyle(lineWidth: 1, dash: [3, 3])

        var v = Path()
        v.move(to: CGPoint(x: point.x, y: 0))
        v.addLine(to: CGPoint(x: point.x, y: geo.bodyHeight))
        ctx.stroke(v, with: .color(ChartTheme.cross), style: dash)

        var h = Path()
        h.move(to: CGPoint(x: 0, y: point.y))
        h.addLine(to: CGPoint(x: geo.plotWidth, y: point.y))
        ctx.stroke(h, with: .color(ChartTheme.cross), style: dash)

        // cenovka na ose
        let label = Text(format(price, decimals: decimals))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundColor(ChartTheme.ink)
        let rect = CGRect(x: geo.plotWidth + 2, y: point.y - 8,
                          width: ChartGeometry.axisWidth - 4, height: 16)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(ChartTheme.panel))
        ctx.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    /// Vodorovné čáry opční pozice: čára přes graf, popisek vlevo, cena na ose.
    static func drawPriceLines(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                               lines: [ChartPriceLine], decimals: Int) {
        for line in lines {
            let y = geo.y(for: line.price)
            guard y >= 0, y <= geo.candleRect.maxY else { continue }
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: geo.plotWidth, y: y))
            ctx.stroke(p, with: .color(line.color.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.2, dash: line.dashed ? [5, 4] : []))

            let text = Text(line.label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.black)
            let resolved = ctx.resolve(text)
            let size = resolved.measure(in: CGSize(width: 200, height: 20))
            let tag = CGRect(x: 6, y: y - size.height / 2 - 2,
                             width: size.width + 8, height: size.height + 4)
            ctx.fill(Path(roundedRect: tag, cornerRadius: 3), with: .color(line.color))
            ctx.draw(resolved, at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)

            let rect = CGRect(x: geo.plotWidth + 2, y: y - 8,
                              width: ChartGeometry.axisWidth - 4, height: 16)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(line.color))
            ctx.draw(Text(format(line.price, decimals: decimals))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(.black),
                     at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        }
    }

    /// Čára poslední ceny včetně štítku vpravo.
    static func drawLastPrice(_ ctx: inout GraphicsContext, geo: ChartGeometry,
                              bar: Bar, decimals: Int, countdown: String? = nil) {
        let y = geo.y(for: bar.close)
        guard y >= 0, y <= geo.candleRect.maxY else { return }
        let color = bar.close >= bar.open ? ChartTheme.up : ChartTheme.down

        var p = Path()
        p.move(to: CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: geo.plotWidth, y: y))
        ctx.stroke(p, with: .color(color.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        let rect = CGRect(x: geo.plotWidth + 2, y: y - 8,
                          width: ChartGeometry.axisWidth - 4, height: 16)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
        ctx.draw(Text(format(bar.close, decimals: decimals))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(.black),
                 at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)

        // kolik zbývá do uzavření svíčky
        if let countdown {
            let below = CGRect(x: rect.minX, y: rect.maxY + 1,
                               width: rect.width, height: 14)
            ctx.fill(Path(roundedRect: below, cornerRadius: 3),
                     with: .color(color.opacity(0.28)))
            ctx.draw(Text(countdown)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundColor(ChartTheme.ink),
                     at: CGPoint(x: below.midX, y: below.midY), anchor: .center)
        }
    }

    // MARK: Pomocné

    static func visibleRange(geo: ChartGeometry, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let from = max(0, Int(geo.viewport.leftIndex.rounded(.down)))
        let to = min(count, Int(geo.viewport.rightIndex.rounded(.up)) + 1)
        return from < to ? from..<to : 0..<0
    }

    /// Hezké kulaté hladiny pro mřížku i osu.
    static func priceLevels(min lo: Double, max hi: Double, target: Int = 7) -> [Double] {
        guard hi > lo else { return [] }
        let raw = (hi - lo) / Double(target)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let stepMult: Double = norm < 1.5 ? 1 : (norm < 3 ? 2 : (norm < 7 ? 5 : 10))
        let step = stepMult * mag
        var out: [Double] = []
        var v = (lo / step).rounded(.up) * step
        while v <= hi {
            out.append(v)
            v += step
        }
        return out
    }

    static func format(_ v: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", v)
    }

    /// Kolik desetinných míst dává u téhle ceny smysl.
    static func decimals(for price: Double) -> Int {
        let a = abs(price)
        if a >= 1000 { return 2 }
        if a >= 1 { return 2 }
        if a >= 0.01 { return 4 }
        return 6
    }
}
