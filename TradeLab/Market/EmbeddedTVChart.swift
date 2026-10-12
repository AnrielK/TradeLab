import SwiftUI

/// Období vloženého grafu – stejná nabídka jako v aplikaci TradingView.
enum DetailChartSpan: String, CaseIterable, Identifiable {
    case day = "1D"
    case fiveDays = "5D"
    case month = "1M"
    case threeMonths = "3M"
    case yearToDate = "YTD"
    case year = "1Y"
    case fiveYears = "5Y"
    case all = "Vše"

    var id: String { rawValue }

    /// Interval svíček pro dané období.
    var resolution: String {
        switch self {
        case .day: return "15"
        case .fiveDays: return "120"
        case .month: return "240"
        case .threeMonths: return "1D"
        case .yearToDate, .year: return "1W"
        case .fiveYears: return "1M"
        case .all: return "3M"
        }
    }

    var span: ChartSpan {
        let day: TimeInterval = 86_400
        switch self {
        case .day: return .sessions(1)
        case .fiveDays: return .sessions(5)
        case .month: return .seconds(31 * day)
        case .threeMonths: return .seconds(92 * day)
        case .yearToDate: return .yearToDate
        case .year: return .seconds(366 * day)
        case .fiveYears: return .seconds(5 * 366 * day)
        case .all: return .all
        }
    }

    var historyBars: Int {
        switch self {
        case .day: return 300
        case .fiveDays, .month, .threeMonths: return 200
        case .yearToDate, .year, .fiveYears: return 150
        case .all: return 250
        }
    }
}

/// Graf z TVChart vložený do detailu tickeru:
/// bez indikátorů, svíčky / linka, období 1D–Vše, čáry opční pozice.
/// Tlačítko zvětšení otevře plný graf s indikátory a všemi intervaly (bez čar pozice).
struct EmbeddedTVChart: View {
    let symbol: String
    var priceLines: [ChartPriceLine] = []

    @State private var vm = EmbeddedTVChart.makeViewModel()
    @State private var showFullScreen = false
    @AppStorage("detail.chartKind") private var chartKind = "Candlestick"
    @AppStorage("detail.span") private var spanRaw = DetailChartSpan.year.rawValue

    private var span: DetailChartSpan { DetailChartSpan(rawValue: spanRaw) ?? .year }

    private static func makeViewModel() -> ChartViewModel {
        let vm = ChartViewModel()
        vm.indicatorsEnabled = false
        vm.persistsSession = false
        vm.showsLegend = false
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
            }

            NativeChartView(vm: vm)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 6) {
                ForEach(DetailChartSpan.allCases) { item in
                    Button {
                        spanRaw = item.rawValue
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(item == span ? Color.white.opacity(0.22) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(item == span ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }

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
        }
        .onAppear {
            vm.chartKind = chartKind
            apply(span, reconnect: false)
            vm.priceLines = priceLines
            vm.symbol = symbol.uppercased()
            vm.connect()
        }
        .onDisappear {
            vm.disconnect()
        }
        .onChange(of: priceLines) { _, lines in vm.priceLines = lines }
        .onChange(of: chartKind) { _, kind in vm.setChartKind(kind) }
        .onReceive(NotificationCenter.default.publisher(for: .chartDrawingsChanged)) { _ in
            vm.reloadDrawingsFromStorage()
        }
        .onChange(of: spanRaw) { _, _ in apply(span, reconnect: true) }
        .onChange(of: showFullScreen) { _, shown in
            // Plný graf má vlastní spojení – vložený mezitím odpojíme.
            if shown { vm.disconnect() } else { vm.connect() }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            TVChartScreen(initialSymbol: symbol)
        }
    }

    /// Nastaví interval, počet barů a výřez podle období.
    private func apply(_ span: DetailChartSpan, reconnect: Bool) {
        let resolutionChanged = vm.resolution != span.resolution || vm.historyBars != span.historyBars
        vm.preferredSpan = span.span
        vm.historyBars = span.historyBars
        vm.resolution = span.resolution
        guard reconnect else { return }
        if resolutionChanged {
            vm.connect()
        } else {
            vm.fitPreferredSpan()
        }
    }
}
