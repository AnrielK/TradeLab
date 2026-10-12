import SwiftUI
import OptionsMath

struct LegRow: View {
    let leg: StrategyLeg

    var body: some View {
        HStack {
            Text(leg.side == .long ? "+\(leg.quantity)" : "−\(leg.quantity)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(leg.side == .long ? Color.green : Color.red)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if leg.instrument != .stock {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(leg.instrument == .stock ? leg.strike.usd : leg.premium.usd)
                .monospacedDigit()
        }
    }

    private var detail: String {
        let expiry = leg.expiration.map { $0.shortExpiryLabel + " · " } ?? ""
        return expiry + "\(Int(leg.daysToExpiry.rounded())) d · IV " + leg.impliedVolatility.percent
    }

    private var title: String {
        switch leg.instrument {
        case .call: return "Call \(leg.strike.fixed(leg.strike.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))"
        case .put: return "Put \(leg.strike.fixed(leg.strike.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 1))"
        case .stock: return "Akcie ×100"
        }
    }
}
