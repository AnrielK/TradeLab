import SwiftUI
import OptionsMath

struct LegEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var leg: StrategyLeg

    init(leg: StrategyLeg) {
        _leg = State(initialValue: leg)
    }

    private var exists: Bool {
        model.strategy.legs.contains { $0.id == leg.id }
    }

    private var ivPercent: Binding<Double> {
        Binding(
            get: { leg.impliedVolatility * 100 },
            set: { leg.impliedVolatility = max($0, 0.01) / 100 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Instrument", selection: $leg.instrument) {
                        Text("Call").tag(LegInstrument.call)
                        Text("Put").tag(LegInstrument.put)
                        Text("Akcie").tag(LegInstrument.stock)
                    }
                    .pickerStyle(.segmented)
                    Picker("Směr", selection: $leg.side) {
                        Text("Long (koupit)").tag(PositionSide.long)
                        Text("Short (prodat)").tag(PositionSide.short)
                    }
                    .pickerStyle(.segmented)
                    Stepper(leg.instrument == .stock ? "Počet lotů (×100): \(leg.quantity)" : "Kontraktů: \(leg.quantity)",
                            value: $leg.quantity, in: 1...100)
                }

                Section {
                    LabeledContent(leg.instrument == .stock ? "Vstupní cena" : "Strike") {
                        DecimalField(title: "0", value: $leg.strike)
                    }
                    if leg.instrument != .stock {
                        LabeledContent("Prémie / akcie") {
                            DecimalField(title: "0", value: $leg.premium)
                        }
                        LabeledContent("Dny do expirace") {
                            DecimalField(title: "30", value: $leg.daysToExpiry, digits: 1)
                        }
                        LabeledContent("IV (%)") {
                            DecimalField(title: "30", value: ivPercent, digits: 1)
                        }
                    }
                } footer: {
                    if let symbol = leg.contractSymbol {
                        Text(symbol)
                    }
                }

                if leg.instrument != .stock {
                    Section {
                        Button {
                            leg.premium = model.theoreticalPremium(for: leg)
                        } label: {
                            Label("Prémie z Black-Scholes", systemImage: "function")
                        }
                        .disabled(model.strategySpot <= 0)
                    } footer: {
                        Text("Spočítá teoretickou prémii ze spotu \(model.strategySpot.usd), IV a sazby.")
                    }
                }

                if exists {
                    Section {
                        Button("Smazat nohu", role: .destructive) {
                            model.deleteLeg(id: leg.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(exists ? "Upravit nohu" : "Nová noha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zrušit") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Uložit") {
                        model.upsertLeg(leg)
                        dismiss()
                    }
                    .disabled(leg.strike <= 0)
                }
            }
        }
    }
}
