import SwiftUI

extension Double {
    /// 1 234,56 $ podle locale, vždy v USD.
    var usd: String {
        formatted(.currency(code: "USD"))
    }

    /// Celé dolary pro P/L pozic.
    var usdWhole: String {
        formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    var signedUSD: String {
        (self > 0 ? "+" : "") + usd
    }

    var signedUSDWhole: String {
        (self > 0 ? "+" : "") + usdWhole
    }

    /// Vstup je zlomek (0.253 → 25,3 %).
    var percent: String {
        formatted(.percent.precision(.fractionLength(1)))
    }

    var signedPercent: String {
        (self > 0 ? "+" : "") + percent
    }

    func fixed(_ digits: Int) -> String {
        formatted(.number.precision(.fractionLength(digits)))
    }
}

extension Color {
    static func pnl(_ value: Double) -> Color {
        if value > 0 { return .green }
        if value < 0 { return .red }
        return .secondary
    }
}

/// Textové pole pro desetinné číslo.
struct DecimalField: View {
    let title: String
    @Binding var value: Double
    var digits: Int = 2

    var body: some View {
        TextField(title, value: $value, format: .number.precision(.fractionLength(0...digits)))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
    }
}

/// Řádek popisek – hodnota.
struct StatRow: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
