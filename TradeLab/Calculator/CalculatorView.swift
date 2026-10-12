import SwiftUI
import OptionsMath

struct CalculatorView: View {
    @Environment(AppModel.self) private var model

    @State private var type: OptionType = .call
    @State private var spot = 100.0
    @State private var strike = 100.0
    @State private var days = 30.0
    @State private var volatilityPercent = 25.0
    @State private var ratePercent = 4.0
    @State private var dividendPercent = 0.0
    @State private var marketPrice = 0.0
    @State private var didSyncRate = false

    private var parameters: OptionParameters {
        OptionParameters(spot: spot, strike: strike, days: days,
                         rate: ratePercent / 100, volatility: volatilityPercent / 100,
                         dividendYield: dividendPercent / 100)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Vstupy") {
                    Picker("Typ", selection: $type) {
                        Text("Call").tag(OptionType.call)
                        Text("Put").tag(OptionType.put)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Spot") { DecimalField(title: "100", value: $spot) }
                    LabeledContent("Strike") { DecimalField(title: "100", value: $strike) }
                    LabeledContent("Dny do expirace") { DecimalField(title: "30", value: $days, digits: 1) }
                    LabeledContent("Volatilita (%)") { DecimalField(title: "25", value: $volatilityPercent, digits: 1) }
                    LabeledContent("Sazba (%)") { DecimalField(title: "4", value: $ratePercent, digits: 2) }
                    LabeledContent("Dividendový výnos (%)") { DecimalField(title: "0", value: $dividendPercent, digits: 2) }
                    Button("Použít aktuální sazbu \(model.riskFreeRate.percent)") {
                        ratePercent = model.riskFreeRate * 100
                    }
                }

                resultSection
                impliedVolatilitySection
            }
            .navigationTitle("Black-Scholes")
            .onAppear {
                if !didSyncRate {
                    ratePercent = (model.riskFreeRate * 10000).rounded() / 100
                    didSyncRate = true
                }
            }
        }
    }

    private var resultSection: some View {
        let valid = spot > 0 && strike > 0
        let price = valid ? BlackScholes.price(type, parameters) : 0
        let g = valid ? BlackScholes.greeks(type, parameters) : .zero
        let intrinsic = BlackScholes.intrinsic(type, spot: spot, strike: strike)
        return Section("Výsledek") {
            StatRow(title: "Teoretická cena", value: price.usd)
            StatRow(title: "Vnitřní / časová hodnota", value: "\(intrinsic.usd) / \(max(price - intrinsic, 0).usd)")
            StatRow(title: "Kontrakt (×100)", value: (price * 100).usd)
            StatRow(title: "Delta", value: g.delta.fixed(4))
            StatRow(title: "Gamma", value: g.gamma.fixed(4))
            StatRow(title: "Theta / den", value: g.theta.fixed(4))
            StatRow(title: "Vega / 1 b.", value: g.vega.fixed(4))
            StatRow(title: "Rho / 1 b.", value: g.rho.fixed(4))
        }
    }

    private var impliedVolatilitySection: some View {
        let iv = ImpliedVolatility.solve(type, price: marketPrice, spot: spot, strike: strike,
                                         years: days / BlackScholes.daysPerYear, rate: ratePercent / 100,
                                         dividendYield: dividendPercent / 100)
        return Section {
            LabeledContent("Tržní cena opce") { DecimalField(title: "0", value: $marketPrice) }
            if marketPrice > 0 {
                if let iv {
                    StatRow(title: "Implikovaná volatilita", value: iv.percent)
                    Button("Použít jako volatilitu") {
                        volatilityPercent = (iv * 1000).rounded() / 10
                    }
                } else {
                    Text("Cena je mimo arbitrážní meze – IV nelze spočítat.")
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Implikovaná volatilita")
        }
    }
}
