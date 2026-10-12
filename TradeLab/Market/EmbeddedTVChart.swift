import SwiftUI

/// Graf z TVChart vložený do detailu tickeru:
/// bez indikátorů, volba svíčky / linka a interval, čáry opční pozice.
/// Tlačítko vpravo otevře plný graf s indikátory (už bez čar pozice).
struct EmbeddedTVChart: View {
    let symbol: String
    var priceLines: [ChartPriceLine] = []

    @State private var vm = EmbeddedTVChart.makeViewModel()
    @State private var showFullScreen = false
    @AppStorage("detail.chartKind") private var chartKind = "Candlestick"
    @AppStorage("detail.resolution") private var resolution = "1D"

    private static let resolutions: [(value: String, label: String)] = [
        ("15", "15m"), ("60", "1H"), ("240", "4H"), ("1D", "1D"), ("1W", "1W"),
    ]

    private static func makeViewModel() -> ChartViewModel {
        let vm = ChartViewModel()
        vm.indicatorsEnabled = false
        vm.persistsSession = false
        return vm
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Typ grafu", selection: $chartKind) {
                    Image(systemName: "chart.bar.xaxis").tag("Candlestick")
                    Image(systemName: "chart.xyaxis.line").tag("Line")
                }
                .pickerStyle(.segmented)
                .frame(width: 110)

                Menu {
                    Picker("Interval", selection: $resolution) {
                        ForEach(Self.resolutions, id: \.value) { item in
                            Text(item.label).tag(item.value)
                        }
                    }
                } label: {
                    Text(Self.resolutions.first { $0.value == resolution }?.label ?? resolution)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .frame(minWidth: 34)
                }
                .buttonStyle(.glass)

                Spacer()

                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Zvětšit graf")
            }

            NativeChartView(vm: vm)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .onAppear {
            vm.chartKind = chartKind
            vm.resolution = resolution
            vm.priceLines = priceLines
            vm.symbol = symbol.uppercased()
            vm.connect()
        }
        .onDisappear {
            vm.disconnect()
        }
        .onChange(of: priceLines) { _, lines in vm.priceLines = lines }
        .onChange(of: chartKind) { _, kind in vm.setChartKind(kind) }
        .onChange(of: resolution) { _, value in vm.changeResolution(value) }
        .onChange(of: showFullScreen) { _, shown in
            // Plný graf má vlastní spojení – vložený mezitím odpojíme.
            if shown { vm.disconnect() } else { vm.connect() }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            TVChartScreen(initialSymbol: symbol)
        }
    }
}
