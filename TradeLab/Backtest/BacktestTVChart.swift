import SwiftUI

/// Graf TVChart pro výsledky backtestu: historie o něco delší než období backtestu,
/// přepínač denních / týdenních (u kratších období i 4H) svíček přímo pod grafem.
struct BacktestTVChart: View {
    let symbol: String
    /// Začátek backtestu – graf ukáže o 10 % delší historii.
    let start: Date

    enum Candles: String, CaseIterable, Identifiable {
        case fourHours = "4H"
        case day = "1D"
        case week = "1W"

        var id: String { rawValue }
        var resolution: String { self == .fourHours ? "240" : rawValue }
        var barsPerYear: Double {
            switch self {
            case .fourHours: return 252 * 2
            case .day: return 252
            case .week: return 52
            }
        }
    }

    @State private var vm = BacktestTVChart.makeViewModel()
    @State private var showFullScreen = false
    @State private var candles: Candles = .day
    @AppStorage("detail.chartKind") private var chartKind = "Candlestick"

    private var years: Double { max(Date().timeIntervalSince(start) / (365.25 * 86_400), 0.1) * 1.1 }

    /// Na víc než ~2 roky jsou 4H svíčky zbytečně husté (a nad limit historie).
    private var available: [Candles] { years > 2.2 ? [.day, .week] : Candles.allCases }

    private static func makeViewModel() -> ChartViewModel {
        let vm = ChartViewModel()
        vm.indicatorsEnabled = false
        vm.persistsSession = false
        vm.showsLegend = false
        vm.drawingsNamespace = BacktestTradeChart.namespace
        return vm
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("Typ grafu", selection: $chartKind) {
                    Image(systemName: "chart.bar.xaxis").tag("Candlestick")
                    Image(systemName: "chart.xyaxis.line").tag("Line")
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                Spacer()
                Picker("Svíčky", selection: $candles) {
                    ForEach(available) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: CGFloat(available.count) * 52)
                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zvětšit graf")
            }

            NativeChartView(vm: vm)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .onAppear {
            if years > 3 { candles = .week }
            vm.chartKind = chartKind
            vm.symbol = symbol.uppercased()
            apply(reconnect: false)
            vm.connect()
        }
        .onDisappear { vm.disconnect() }
        .onChange(of: candles) { _, _ in apply(reconnect: true) }
        .onChange(of: chartKind) { _, kind in vm.setChartKind(kind) }
        .onReceive(NotificationCenter.default.publisher(for: .chartDrawingsChanged)) { _ in
            vm.reloadDrawingsFromStorage()
        }
        .onChange(of: showFullScreen) { _, shown in
            if shown { vm.disconnect() } else { vm.connect() }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            TVChartScreen(initialSymbol: symbol, initialResolution: candles.resolution,
                          drawingsNamespace: BacktestTradeChart.namespace)
        }
    }

    private func apply(reconnect: Bool) {
        let bars = Int((years * candles.barsPerYear).rounded(.up)) + 20
        vm.historyBars = min(max(bars, 60), 5_000)
        vm.resolution = candles.resolution
        vm.preferredSpan = .seconds(years * 365.25 * 86_400)
        if reconnect { vm.connect() }
    }
}
