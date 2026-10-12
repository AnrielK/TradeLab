import SwiftUI
import UIKit

/// Co se právě vybírá kolečkem. Drží to ContentView, protože seznam se
/// kreslí uprostřed obrazovky, ne u tlačítka.
struct WheelSelection: Equatable {
    var items: [String]
    /// Může přesáhnout meze — seznam se protáčí dokola.
    var preview: Int

    /// Index zabalený do rozsahu pole (funguje i pro záporné).
    static func wrap(_ index: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    func item(offsetBy delta: Int) -> String {
        guard !items.isEmpty else { return "" }
        return items[Self.wrap(preview + delta, items.count)]
    }
}

/// Graf z projektu TVChart-iOS (real-time data TradingView, indikátory, kreslení),
/// v TradeLabu otevíraný na celou obrazovku pro vybraný ticker.
struct TVChartScreen: View {
    /// Ticker z TradeLabu (např. „NVDA“); burzu doplní `SymbolResolver`.
    var initialSymbol: String? = nil

    @State private var vm = ChartViewModel()
    @State private var wheel: WheelSelection?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                NativeChartView(vm: vm)
                    .frame(maxHeight: .infinity)

                BottomBar(vm: vm, wheel: $wheel)
            }

            // seznam hodnot uprostřed obrazovky, přes graf
            if let wheel {
                WheelList(selection: wheel)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.trailing, 12)
            .padding(.top, 4)
        }
        .onAppear {
            if let initialSymbol, !initialSymbol.isEmpty {
                let current = vm.symbol.split(separator: ":").last.map(String.init) ?? vm.symbol
                if current.uppercased() != initialSymbol.uppercased() {
                    vm.symbol = initialSymbol.uppercased()
                }
            }
            vm.connect()
        }
        .onDisappear {
            vm.saveDrawings()
            vm.disconnect()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                vm.saveDrawings()
                vm.disconnect()
            case .active:
                if !vm.isConnected { vm.connect() }
            default: break
            }
        }
        .sheet(item: $vm.sheet) { which in
            Group {
                switch which {
                case .symbol:    SymbolSheet(vm: vm)
                case .timeframe: TimeframeSheet(vm: vm)
                case .drawings:  DrawingsSheet(vm: vm)
                case .objects:   ObjectsSheet(vm: vm)
                case .indicators: IndicatorsSheet(vm: vm)
                case .volumeProfile: VolumeProfileSheet(vm: vm)
                case .more:      MoreSheet(vm: vm)
                }
            }
            .presentationDetents(
                which == .symbol || which == .timeframe
                    ? [.medium, .large] : [.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.bar)
            // V na šířku by se panel jinak ukázal jako kartička uprostřed
            .presentationCompactAdaptation(.sheet)
        }
    }
}

// MARK: - Spodní lišta

private struct BottomBar: View {
    @Bindable var vm: ChartViewModel
    @Binding var wheel: WheelSelection?
    /// Na šířku je místa dost, ale výšky málo — lišta se proto ztenčí.
    @Environment(\.verticalSizeClass) private var vSize
    private var compact: Bool { vSize == .compact }

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            // Symbol a interval zůstávají vždy vidět, zbytek se scrolluje.
            // Klepnutí otevře výběr, tažení nahoru a dolů listuje
            // v naposledy otevřených symbolech.
            WheelButton(items: vm.symbolWheel,
                        currentIndex: vm.symbolIndex,
                        wheel: $wheel,
                        onTap: { vm.sheet = .symbol },
                        onSelect: { vm.selectSymbol(at: $0) })

            // Totéž pro interval, ale mezi oblíbenými.
            WheelButton(items: vm.resolutionWheel,
                        currentIndex: vm.resolutionIndex,
                        wheel: $wheel,
                        onTap: { vm.sheet = .timeframe },
                        onSelect: { vm.selectResolution(at: $0) })

            Divider().frame(height: 18).overlay(Theme.line)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    BarIcon(system: "pencil.tip.crop.circle",
                            active: vm.activeTool != "cursor") { vm.sheet = .drawings }

                    BarIcon(system: "chart.xyaxis.line",
                            active: !vm.indicators.isEmpty) { vm.sheet = .indicators }

                    BarIcon(system: "square.stack.3d.up",
                            active: !vm.drawings.isEmpty) { vm.sheet = .objects }

                    BarIcon(system: "ellipsis", active: false) { vm.sheet = .more }

                    Divider().frame(height: 18).overlay(Theme.line).padding(.horizontal, 2)

                    BarIcon(system: "arrow.uturn.backward", active: false) { vm.undo() }
                    BarIcon(system: "arrow.uturn.forward", active: false) { vm.redo() }
                    BarIcon(system: "arrow.down.right.and.arrow.up.left",
                            active: false) { vm.fitContent() }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, compact ? 16 : 12)
        .padding(.vertical, compact ? 4 : 8)
        .background(Theme.bar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }
}

/// Tlačítko s kolečkem hodnot. Tažením nahoru a dolů se vybírá; samotný
/// seznam se kreslí uprostřed obrazovky (viz `WheelList` v ContentView).
private struct WheelButton: View {
    let items: [String]
    let currentIndex: Int
    @Binding var wheel: WheelSelection?
    let onTap: () -> Void
    let onSelect: (Int) -> Void

    /// O kolik bodů se táhne, než se přeskočí na další položku.
    private let stepHeight: CGFloat = 30

    @State private var preview: Int?
    private let haptics = UISelectionFeedbackGenerator()

    @Environment(\.verticalSizeClass) private var vSize
    private var compact: Bool { vSize == .compact }

    /// Během tažení ukazuje tlačítko rozpracovaný výběr, takže se točí
    /// zároveň se seznamem. Po zvednutí prstu na něm zůstane vybraná hodnota.
    private var label: String {
        guard !items.isEmpty else { return "—" }
        let index = WheelSelection.wrap(preview ?? currentIndex, items.count)
        return items[index]
    }

    var body: some View {
        Text(label)
            .font(.system(size: compact ? 14 : 15, weight: .semibold))
            .foregroundStyle(preview == nil ? .white : Theme.accent)
            .lineLimit(1)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.12), value: label)
            .padding(.horizontal, 14)
            .padding(.vertical, compact ? 6 : 9)
            .glassCard(cornerRadius: 16, interactive: true)
            .contentShape(Rectangle())
            .fixedSize()
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard items.count > 1 else { return }
                        if preview == nil {
                            preview = currentIndex
                            haptics.prepare()
                        }
                        // Bez ořezu na okraje — seznam se protáčí dokola,
                        // takže má pořád stejnou velikost a nedojde na konci.
                        let steps = Int((-value.translation.height / stepHeight).rounded())
                        let next = currentIndex + steps
                        if next != preview {
                            preview = next
                            haptics.selectionChanged()   // cvaknutí u každé položky
                        }
                        withAnimation(.easeOut(duration: 0.12)) {
                            wheel = WheelSelection(items: items, preview: next)
                        }
                    }
                    .onEnded { value in
                        let moved = abs(value.translation.height)
                        if moved < 8 {
                            onTap()
                        } else if let preview, preview != currentIndex {
                            onSelect(WheelSelection.wrap(preview, items.count))
                        }
                        // `preview` necháme až po vybrání — jinak by tlačítko
                        // na okamžik ukázalo starou hodnotu, než dorazí nová.
                        withAnimation(.easeOut(duration: 0.15)) { wheel = nil }
                        preview = nil
                    }
            )
    }
}

/// Seznam hodnot uprostřed obrazovky. Vybraná je velká, okolní se směrem
/// od ní zmenšují a blednou.
private struct WheelList: View {
    let selection: WheelSelection

    @Environment(\.verticalSizeClass) private var vSize
    private var window: Int { vSize == .compact ? 2 : 3 }

    var body: some View {
        // Vždy stejný počet řádků kolem výběru — seznam se protáčí dokola,
        // takže u krajních položek nezmenší.
        VStack(spacing: 2) {
            ForEach(-window...window, id: \.self) { delta in
                let distance = abs(delta)
                Text(selection.item(offsetBy: delta))
                    .font(.system(size: distance == 0 ? 30 : (distance == 1 ? 21 : 16),
                                  weight: distance == 0 ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(opacity(distance)))
                    .lineLimit(1)
                    .frame(height: distance == 0 ? 46 : 32)
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 18)
        .glassCard(cornerRadius: 26)
        .fixedSize()
    }

    /// Čím dál od výběru, tím bledší — krajní položky skoro zmizí.
    private func opacity(_ distance: Int) -> Double {
        switch distance {
        case 0:  return 1
        case 1:  return 0.5
        case 2:  return 0.26
        default: return 0.12
        }
    }
}

private struct BarIcon: View {
    let system: String
    let active: Bool
    let action: () -> Void

    @Environment(\.verticalSizeClass) private var vSize
    private var compact: Bool { vSize == .compact }

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: compact ? 16 : 18, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Color.white)
                .frame(width: compact ? 40 : 44, height: compact ? 30 : 36)
                .glassCard(cornerRadius: 11, interactive: true)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.accent, lineWidth: active ? 1.5 : 0)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panel: symbol

private struct SymbolSheet: View {
    @Bindable var vm: ChartViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private let quick = ["AAPL", "AMZN", "MSFT", "NVDA", "TSLA", "GOOGL",
                         "BTC", "ETH", "SPX", "GOLD"]

    var body: some View {
        SheetShell(title: "Symbol") {
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("AAPL nebo BURZA:SYMBOL", text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(apply)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassCard(cornerRadius: 14)

                Text("Burzu můžeš vynechat — doplní se sama.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                FlowRow(items: quick) { sym in
                    Button(sym) {
                        vm.symbol = sym
                        vm.connect()
                        dismiss()
                    }
                    .buttonStyle(ChipStyle(active: vm.shortSymbol == sym))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .onAppear { text = vm.symbol; focused = true }
    }

    private func apply() {
        vm.symbol = text
        vm.connect()
        dismiss()
    }
}

// MARK: - Panel: rozlišení

private struct TimeframeSheet: View {
    @Bindable var vm: ChartViewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        SheetShell(title: "Interval") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !vm.favoriteResolutions.isEmpty {
                        section("OBLÍBENÉ",
                                vm.favoriteResolutions.compactMap(Timeframes.timeframe))
                    }

                    ForEach(Timeframes.sections, id: \.title) { part in
                        section(part.title, part.items)
                    }

                    Text("Hvězdičkou přidáš interval mezi oblíbené. Mezi nimi se pak dá v liště listovat tažením nahoru a dolů.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func section(_ title: String, _ items: [Timeframe]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(items) { tf in
                    TimeframeCell(
                        timeframe: tf,
                        selected: vm.resolution == tf.value,
                        favorite: vm.isFavorite(tf.value),
                        onTap: {
                            vm.changeResolution(tf.value)
                            dismiss()
                        },
                        onStar: { vm.toggleFavoriteResolution(tf.value) }
                    )
                }
            }
        }
    }
}

private struct TimeframeCell: View {
    let timeframe: Timeframe
    let selected: Bool
    let favorite: Bool
    let onTap: () -> Void
    let onStar: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(timeframe.label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .glassCard(cornerRadius: 12, interactive: true)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.accent, lineWidth: selected ? 1.5 : 0)
                )
        }
        .buttonStyle(.plain)
        // hvězdička sedí v rohu dlaždice jako v TradingView
        .overlay(alignment: .topTrailing) {
            Button(action: onStar) {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(favorite ? Theme.accent : Color.white.opacity(0.35))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .offset(x: 2, y: -2)
        }
    }
}

// MARK: - Panel: kreslicí nástroje

private struct DrawingsSheet: View {
    @Bindable var vm: ChartViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var groups: [ToolGroup] {
        guard !query.isEmpty else { return DrawTools.groups }
        return DrawTools.groups.compactMap { g in
            let hits = g.tools.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return hits.isEmpty ? nil : ToolGroup(id: g.id, title: g.title, tools: hits)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 82), spacing: 8)]

    var body: some View {
        SheetShell(title: "Nástroje") {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Hledat", text: $query)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassCard(cornerRadius: 14)
                .padding(.horizontal, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title.uppercased())
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)

                                LazyVGrid(columns: columns, spacing: 10) {
                                    ForEach(group.tools) { tool in
                                        ToolCell(tool: tool, active: vm.activeTool == tool.id) {
                                            vm.selectTool(tool.id)
                                            dismiss()
                                        }
                                    }
                                }
                            }
                        }

                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

private struct ToolCell: View {
    let tool: DrawTool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 16, weight: .regular))
                Text(tool.name)
                    .font(.system(size: 9.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(active ? Theme.accent : Color.white)
            .glassCard(cornerRadius: 14, interactive: true)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.accent, lineWidth: active ? 1.5 : 0)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panel: objekty (seznam kreseb)

private struct ObjectsSheet: View {
    @Bindable var vm: ChartViewModel
    @State private var editing: UUID?

    var body: some View {
        SheetShell(title: "Objekty") {
            if vm.drawings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "scribble")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Zatím žádné kresby")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                VStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button("Zobrazit vše") { vm.setAllDrawingsVisible(true) }
                                .buttonStyle(ChipStyle(active: false))
                            Button("Skrýt vše") { vm.setAllDrawingsVisible(false) }
                                .buttonStyle(ChipStyle(active: false))
                            Button("Zamknout vše") { vm.setAllDrawingsLocked(true) }
                                .buttonStyle(ChipStyle(active: false))
                            Button("Odemknout vše") { vm.setAllDrawingsLocked(false) }
                                .buttonStyle(ChipStyle(active: false))
                            Button(role: .destructive) { vm.clearDrawings() } label: {
                                Image(systemName: "trash")
                            }
                            .foregroundStyle(ChartTheme.down)
                            .padding(.horizontal, 8)
                        }
                        .padding(.horizontal, 16)
                    }

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(vm.drawings) { d in
                                ObjectRow(
                                    drawing: d,
                                    selected: vm.selectedDrawing == d.id,
                                    onSelect: {
                                        vm.selectedDrawing = d.locked ? nil : d.id
                                    },
                                    onToggle: { vm.toggleVisibility(d.id) },
                                    onLock: { vm.toggleLock(d.id) },
                                    onEdit: { editing = d.id },
                                    onDelete: { vm.removeDrawing(d.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .sheet(item: Binding(get: { editing.map(IdentifiedUUID.init) },
                             set: { editing = $0?.id })) { wrapped in
            ObjectEditor(vm: vm, drawingId: wrapped.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.bar)
                .presentationCompactAdaptation(.sheet)
        }
    }
}

/// UUID se nedá přímo použít v `.sheet(item:)`, tohle ho jen zabalí.
private struct IdentifiedUUID: Identifiable {
    let id: UUID
    init(_ id: UUID) { self.id = id }
}

private struct ObjectRow: View {
    let drawing: Drawing
    let selected: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onLock: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: DrawToolKind(rawValue: drawing.tool)?.symbolName ?? "scribble")
                .font(.system(size: 15))
                .frame(width: 22)
                .foregroundStyle(drawing.color)

            Button(action: onSelect) {
                Text(drawing.displayName)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(drawing.visible ? .white : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onToggle) {
                Image(systemName: drawing.visible ? "eye" : "eye.slash")
                    .foregroundStyle(drawing.visible ? .white : .secondary)
            }
            .buttonStyle(.plain)
            Button(action: onLock) {
                Image(systemName: drawing.locked ? "lock.fill" : "lock.open")
                    .foregroundStyle(drawing.locked ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            Button(action: onEdit) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(ChartTheme.down)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.accent, lineWidth: selected ? 1.5 : 0)
        )
    }
}

// MARK: - Editor jedné kresby

private struct ObjectEditor: View {
    @Bindable var vm: ChartViewModel
    let drawingId: UUID
    @Environment(\.dismiss) private var dismiss

    private var drawing: Drawing? { vm.drawing(drawingId) }

    var body: some View {
        SheetShell(title: drawing?.displayName ?? "Objekt") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let d = drawing {
                        colorSection(d)
                        widthSection(d)
                        dashSection(d)

                        if d.tool == DrawToolKind.text.rawValue {
                            textSection(d)
                        }

                        if d.tool == DrawToolKind.fib.rawValue, let cfg = d.fib {
                            fibSection(d, cfg)
                        }

                        Toggle("Zobrazit", isOn: Binding(
                            get: { d.visible },
                            set: { _ in vm.toggleVisibility(drawingId) }))
                        .tint(Theme.accent)
                        .foregroundStyle(.white)

                        Toggle("Zamknout", isOn: Binding(
                            get: { d.locked },
                            set: { _ in vm.toggleLock(drawingId) }))
                        .tint(Theme.accent)
                        .foregroundStyle(.white)

                        if d.locked {
                            Text("Zamčený objekt se nedá vybrat ani táhnout.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Button(role: .destructive) {
                            vm.removeDrawing(drawingId)
                            dismiss()
                        } label: {
                            Label("Smazat objekt", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 10)
                        .glassCard(cornerRadius: 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func colorSection(_ d: Drawing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BARVA").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ColorSwatchPicker(label: "", hex: d.colorHex) { hex in
                vm.updateDrawing(drawingId) { $0.colorHex = hex }
            }
        }
    }

    private func widthSection(_ d: Drawing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TLOUŠŤKA").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { w in
                    Button("\(Int(w)) px") {
                        vm.updateDrawing(drawingId) { $0.width = w }
                    }
                    .buttonStyle(ChipStyle(active: d.width == w))
                }
            }
        }
    }

    private func dashSection(_ d: Drawing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STYL ČÁRY").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(["Plná", "Tečkovaná", "Čárkovaná"].enumerated()),
                        id: \.offset) { i, name in
                    Button(name) {
                        vm.updateDrawing(drawingId) { $0.dash = i }
                    }
                    .buttonStyle(ChipStyle(active: d.dash == i))
                }
            }
        }
    }

    // MARK: Fibonacci

    @ViewBuilder
    private func fibSection(_ d: Drawing, _ cfg: FibSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HLADINY").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(cfg.levels.enumerated()), id: \.element.ratio) { i, lv in
                HStack(spacing: 10) {
                    Button {
                        vm.updateDrawing(drawingId) { $0.fib?.levels[i].visible.toggle() }
                    } label: {
                        Image(systemName: lv.visible ? "checkmark.square.fill" : "square")
                            .foregroundStyle(lv.visible ? Theme.accent : .secondary)
                    }

                    Text(lv.percentText)
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(lv.visible ? .white : .secondary)
                        .frame(width: 62, alignment: .leading)

                    // barva hladiny — čtyři presety plus systémový výběr
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: lv.colorHex) },
                        set: { c in
                            vm.updateDrawing(drawingId) {
                                $0.fib?.levels[i].colorHex = c.hexString
                            }
                        }), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 28, height: 28)
                }
            }

            Divider().overlay(Theme.line)

            Toggle("Popisky", isOn: Binding(
                get: { cfg.showLabels },
                set: { v in vm.updateDrawing(drawingId) { $0.fib?.showLabels = v } }))
            Toggle("Protáhnout doprava", isOn: Binding(
                get: { cfg.extendRight },
                set: { v in vm.updateDrawing(drawingId) { $0.fib?.extendRight = v } }))
            Toggle("Podbarvení", isOn: Binding(
                get: { cfg.showBackground },
                set: { v in vm.updateDrawing(drawingId) { $0.fib?.showBackground = v } }))

            if cfg.showBackground {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Průhlednost pozadí").font(.system(size: 13))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(Int(cfg.backgroundOpacity * 100)) %")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { cfg.backgroundOpacity },
                        set: { v in vm.updateDrawing(drawingId) { $0.fib?.backgroundOpacity = v } }
                    ), in: 0...0.5)
                    .tint(Theme.accent)

                    Text("BARVA POZADÍ").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            vm.updateDrawing(drawingId) { $0.fib?.backgroundHex = nil }
                        } label: {
                            Text("Dle hladin")
                                .font(.system(size: 12))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(cfg.backgroundHex == nil
                                                 ? Theme.accent : .white)
                                .glassCard(cornerRadius: 14)
                        }

                        ColorSwatchPicker(label: "", hex: cfg.backgroundHex ?? "#4aa8ff") { hex in
                            vm.updateDrawing(drawingId) { $0.fib?.backgroundHex = hex }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Průhlednost čar").font(.system(size: 13))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(Int(cfg.lineOpacity * 100)) %")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { cfg.lineOpacity },
                    set: { v in vm.updateDrawing(drawingId) { $0.fib?.lineOpacity = v } }
                ), in: 0.1...1)
                .tint(Theme.accent)
            }
        }
        .tint(Theme.accent)
        .foregroundStyle(.white)
    }

    private func textSection(_ d: Drawing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEXT").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Popisek", text: Binding(
                get: { d.text ?? "" },
                set: { newValue in vm.updateDrawing(drawingId) { $0.text = newValue } }))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .glassCard(cornerRadius: 14)
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Panel: indikátory

private struct IndicatorsSheet: View {
    @Bindable var vm: ChartViewModel
    @State private var query = ""
    @State private var editing: IndicatorInstance?

    private func filtered(_ list: [IndicatorDef]) -> [IndicatorDef] {
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        SheetShell(title: "Indikátory") {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Hledat", text: $query)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassCard(cornerRadius: 14)
                .padding(.horizontal, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !vm.indicators.isEmpty { activeSection }
                        addSection("NA GRAFU", filtered(Indicators.overlays))
                        addSection("VLASTNÍ PANEL", filtered(Indicators.oscillators))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(item: $editing) { inst in
            IndicatorEditor(vm: vm, instance: inst)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.bar)
        }
    }

    /// Co právě běží — dá se upravit i odebrat, každý řádek zvlášť.
    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ZAPNUTÉ")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Vypnout vše") { vm.clearIndicators() }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            }

            ForEach(vm.indicators) { inst in
                HStack(spacing: 10) {
                    Circle()
                        .fill(inst.style.color)
                        .frame(width: 10, height: 10)

                    Text(inst.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)

                    Spacer()

                    Button { editing = inst } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Button { vm.removeIndicator(inst.id) } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassCard(cornerRadius: 14)
            }
        }
    }

    /// Katalog — tapnutí přidá další instanci, i když už jedna běží.
    @ViewBuilder
    private func addSection(_ title: String, _ items: [IndicatorDef]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(items) { def in
                    Button { vm.addIndicator(def) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: def.symbol)
                                .font(.system(size: 17))
                                .frame(width: 26)
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(def.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white)
                                Text(def.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if vm.count(of: def.id) > 0 {
                                Text("\(vm.count(of: def.id))×")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            Image(systemName: "plus.circle")
                                .font(.system(size: 19))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .glassCard(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Editor jedné instance indikátoru

private struct IndicatorEditor: View {
    @Bindable var vm: ChartViewModel
    let instance: IndicatorInstance
    @Environment(\.dismiss) private var dismiss

    @State private var params: [String: Double] = [:]
    @State private var style = IndicatorStyle()

    private var def: IndicatorDef? { instance.def }

    var body: some View {
        SheetShell(title: def?.name ?? instance.label) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let def, !def.params.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("PARAMETRY")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(def.params) { p in
                                ParamStepper(param: p, value: binding(for: p))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("VZHLED")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        colorPicker
                        widthPicker
                        stylePicker
                        opacitySlider
                        extraColors
                    }

                    Button(role: .destructive) {
                        vm.removeIndicator(instance.id)
                        dismiss()
                    } label: {
                        Label("Odebrat indikátor", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 10)
                    .glassCard(cornerRadius: 14)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            params = instance.params
            style = instance.style
        }
    }

    private func binding(for p: IndicatorParam) -> Binding<Double> {
        Binding(
            get: { params[p.key] ?? p.def },
            set: { newValue in
                params[p.key] = newValue
                vm.updateIndicator(instance.id, params: [p.key: newValue])
            }
        )
    }

    /// Barvy složek u indikátorů, které jich mají víc (Squeeze).
    @ViewBuilder
    private var extraColors: some View {
        let labels = Indicators.extraColorLabels(for: instance.defId)
        if !labels.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("SLOŽKY").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                    ColorSwatchPicker(
                        label: label,
                        hex: i < style.extraHex.count
                            ? style.extraHex[i] : Indicators.palette[0]
                    ) { hex in
                        var all = style.extraHex
                        while all.count <= i { all.append(Indicators.palette[0]) }
                        all[i] = hex
                        style.extraHex = all
                        vm.updateIndicator(instance.id, style: style)
                    }
                }
            }
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Barva").font(.system(size: 13)).foregroundStyle(.white)
            ColorSwatchPicker(label: "", hex: style.colorHex) { hex in
                style.colorHex = hex
                vm.updateIndicator(instance.id, style: style)
            }
        }
    }

    private var widthPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tloušťka").font(.system(size: 13)).foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { w in
                    Button("\(Int(w)) px") {
                        style.width = w
                        vm.updateIndicator(instance.id, style: style)
                    }
                    .buttonStyle(ChipStyle(active: style.width == w))
                }
            }
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Styl čáry").font(.system(size: 13)).foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach(Array(IndicatorStyle.lineStyleNames.enumerated()), id: \.offset) { i, name in
                    Button(name) {
                        style.lineStyle = i
                        vm.updateIndicator(instance.id, style: style)
                    }
                    .buttonStyle(ChipStyle(active: style.lineStyle == i))
                }
            }
        }
    }

    private var opacitySlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Průhlednost").font(.system(size: 13)).foregroundStyle(.white)
                Spacer()
                Text("\(Int(style.opacity * 100)) %")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { style.opacity },
                set: { newValue in
                    style.opacity = newValue
                    vm.updateIndicator(instance.id, style: style)
                }
            ), in: 0.1...1)
            .tint(Theme.accent)
        }
    }
}

/// Číselný parametr se šipkami i posuvníkem — na telefonu se trefuje líp
/// než do textového pole.
private struct ParamStepper: View {
    let param: IndicatorParam
    @Binding var value: Double

    private var text: String {
        param.isInteger ? String(Int(value)) : String(format: "%.1f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(param.label).font(.system(size: 13)).foregroundStyle(.white)
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        value = max(param.min, value - param.step)
                    } label: { Image(systemName: "minus") }

                    Text(text)
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 42)

                    Button {
                        value = min(param.max, value + param.step)
                    } label: { Image(systemName: "plus") }
                }
                .foregroundStyle(Theme.accent)
            }
            Slider(value: $value, in: param.min...param.max, step: param.step)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
    }
}

// MARK: - Panel: volume profil

private struct VolumeProfileSheet: View {
    @Bindable var vm: ChartViewModel

    private var cfg: VolumeProfileSettings { vm.volumeProfile }

    var body: some View {
        SheetShell(title: "Volume profil") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Zobrazit profil", isOn: Binding(
                        get: { cfg.enabled },
                        set: { vm.volumeProfile.enabled = $0 }))

                    Text("Počítá se z právě viditelných svíček.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if cfg.enabled {
                        slider("Počet pásem", value: Binding(
                            get: { Double(cfg.rows) },
                            set: { vm.volumeProfile.rows = Int($0) }),
                            range: 8...80, step: 1, text: "\(cfg.rows)")

                        slider("Šířka", value: Binding(
                            get: { cfg.widthRatio },
                            set: { vm.volumeProfile.widthRatio = $0 }),
                            range: 0.1...0.6, step: 0.01,
                            text: "\(Int(cfg.widthRatio * 100)) %")

                        slider("Průhlednost", value: Binding(
                            get: { cfg.opacity },
                            set: { vm.volumeProfile.opacity = $0 }),
                            range: 0.1...1, step: 0.05,
                            text: "\(Int(cfg.opacity * 100)) %")

                        Picker("Umístění", selection: Binding(
                            get: { cfg.onRight },
                            set: { vm.volumeProfile.onRight = $0 })) {
                            Text("Vlevo").tag(false)
                            Text("Vpravo").tag(true)
                        }
                        .pickerStyle(.segmented)

                        Toggle("Rozdělit nákup/prodej", isOn: Binding(
                            get: { cfg.splitBuySell },
                            set: { vm.volumeProfile.splitBuySell = $0 }))

                        if cfg.splitBuySell {
                            colorRow("Nákupní", hex: cfg.upHex) { vm.volumeProfile.upHex = $0 }
                            colorRow("Prodejní", hex: cfg.downHex) { vm.volumeProfile.downHex = $0 }
                        } else {
                            colorRow("Barva", hex: cfg.singleHex) { vm.volumeProfile.singleHex = $0 }
                        }

                        Toggle("Point of Control", isOn: Binding(
                            get: { cfg.showPOC },
                            set: { vm.volumeProfile.showPOC = $0 }))
                        if cfg.showPOC {
                            colorRow("Barva POC", hex: cfg.pocHex) { vm.volumeProfile.pocHex = $0 }
                        }

                        Toggle("Oblast 70 % objemu", isOn: Binding(
                            get: { cfg.showValueArea },
                            set: { vm.volumeProfile.showValueArea = $0 }))
                        if cfg.showValueArea {
                            colorRow("Barva oblasti", hex: cfg.valueAreaHex) {
                                vm.volumeProfile.valueAreaHex = $0
                            }
                        }
                    }
                }
                .tint(Theme.accent)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double,
                        text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13))
                Spacer()
                Text(text)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
    }

    private func colorRow(_ label: String, hex: String,
                          set: @escaping (String) -> Void) -> some View {
        ColorSwatchPicker(label: label, hex: hex, onChange: set)
    }
}

// MARK: - Panel: další

private struct MoreSheet: View {
    @Bindable var vm: ChartViewModel

    var body: some View {
        SheetShell(title: "Další") {
            // Bez scrollování se horní položky nevešly a byly useknuté.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TYP GRAFU")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach([("Svíčky", "Candlestick"), ("Čára", "Line"), ("Plocha", "Area")],
                                id: \.1) { label, kind in
                            Button(label) { vm.setChartKind(kind) }
                                .buttonStyle(ChipStyle(active: vm.chartKind == kind))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("OBJEM")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("Objem", selection: Binding(
                        get: { vm.volumeMode },
                        set: { vm.volumeMode = $0 })) {
                        ForEach(ChartViewModel.VolumeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Button { vm.sheet = .volumeProfile } label: {
                    HStack {
                        Label("Volume profil", systemImage: "chart.bar.xaxis")
                        Spacer()
                        Text(vm.volumeProfile.enabled ? "zapnuto" : "vypnuto")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Přichytávat k OHLC", isOn: Binding(
                    get: { vm.magnet }, set: { _ in vm.toggleMagnet() }))
                Toggle("Nechat kříž zobrazený", isOn: $vm.crosshairPinned)
                Toggle("Nechat nástroj aktivní", isOn: Binding(
                    get: { vm.keepTool }, set: { _ in vm.toggleKeepTool() }))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Odsazení od cenové osy")
                            .font(.system(size: 13))
                        Spacer()
                        Text("\(Int(vm.rightMarginBars)) svíček")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { vm.rightMarginBars },
                        set: { vm.setRightMargin($0.rounded()) }
                    ), in: 0...40, step: 1)
                    .tint(Theme.accent)
                }

                if !vm.indicators.filter({ $0.def?.overlay == false }).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Výška panelu indikátorů")
                                .font(.system(size: 13))
                            Spacer()
                            Text("\(Int(vm.oscHeightRatio * 100)) %")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { vm.oscHeightRatio },
                            set: { vm.oscHeightRatio = $0 }
                        ), in: 0.12...0.5)
                        .tint(Theme.accent)
                    }
                }

                Button { vm.resetPriceScale() } label: {
                    Label("Obnovit svislé měřítko", systemImage: "arrow.up.and.down")
                }

                Button { vm.scrollToEnd() } label: {
                    Label("Skočit na poslední svíčku", systemImage: "arrow.right.to.line")
                }

                Button(role: .destructive) {
                    vm.clearDrawings()
                } label: {
                    Label("Smazat všechny kresby", systemImage: "trash")
                }

                Divider().overlay(Theme.line)

                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.errorMessage != nil ? .red : (vm.isConnected ? .green : .gray))
                        .frame(width: 6, height: 6)
                    Text(vm.status.isEmpty ? "Připraveno" : vm.status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Button(vm.isConnected ? "Odpojit" : "Připojit") { vm.toggle() }
                    .buttonStyle(ChipStyle(active: false))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sestavení \(AppInfo.version)")
                        .font(.system(size: 11))
                    Text(AppInfo.notes)
                        .font(.system(size: 10))
                    Text(AppInfo.glassStatus)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)

                }
                .tint(Theme.accent)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
    }
}

// MARK: - Sdílené kousky

private struct SheetShell<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 18)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

private struct ChipStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(active ? Theme.accent : Color.white)
            .glassCard(cornerRadius: 12, interactive: true)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.accent, lineWidth: active ? 1.5 : 0)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Jednoduché zalamování do řádků — `Flow` layout je až od iOS 16, tohle
/// funguje kdekoliv a stačí na krátké seznamy.
private struct FlowRow<Item: Hashable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    private let perRow = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: items.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(items[start..<min(start + perRow, items.count)], id: \.self) { item in
                        cell(item)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Barvy

enum Theme {
    static let bg     = Color(red: 0.05, green: 0.07, blue: 0.09)
    static let bar    = Color(red: 0.07, green: 0.09, blue: 0.12)
    static let sheet  = Color(red: 0.09, green: 0.11, blue: 0.14)
    static let chip   = Color(red: 0.14, green: 0.17, blue: 0.21)
    static let line   = Color(red: 0.18, green: 0.22, blue: 0.27)
    static let accent = Color(red: 0.88, green: 0.66, blue: 0.24)
}


#Preview { TVChartScreen(initialSymbol: "NVDA") }
