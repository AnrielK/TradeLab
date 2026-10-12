import SwiftUI
import OptionsMath

/// „Koupit k otevření 1 Vertical DB @ 2,07“
func ticketTitle(_ strategy: OptionStrategy, quote: NetQuote?) -> String {
    let count = strategy.spreadCount
    guard let quote else { return "\(count)× \(strategy.name)" }
    let action = quote.isDebit ? "Koupit" : "Prodat"
    let unit = quote.isDebit ? "DB" : "CR"
    return "\(action) k otevření \(count) \(strategy.name) \(unit) @ \(abs(quote.mid).fixed(2))"
}

/// Tiket dole v tabulce: název objednávky, bid/mid/ask a nohy (BTO/STO).
struct TicketBar: View {
    @Environment(AppModel.self) private var model
    let onAnalyze: () -> Void
    @State private var collapsed = false

    var body: some View {
        let strategy = model.strategy
        let quote = strategy.netQuote
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { collapsed.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .foregroundStyle(ChainTheme.itm)
                    Text(ticketTitle(strategy, quote: quote))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                HStack(alignment: .center, spacing: 12) {
                    Button(role: .destructive) {
                        model.clearStrategy()
                    } label: {
                        Image(systemName: "trash")
                            .font(.body)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    if let quote {
                        NetQuoteBar(quote: quote)
                    } else {
                        Text("Bez kotací bid/ask")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                VStack(spacing: 0) {
                    ForEach(strategy.legs) { leg in
                        TicketLegRow(leg: leg)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 10)

                Button(action: onAnalyze) {
                    Label("Payoff a úpravy", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.glassProminent)
                .tint(ChainTheme.action)
                .padding(10)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// Bid —•— Mid —•— Ask s jednotkou db/cr.
struct NetQuoteBar: View {
    let quote: NetQuote

    var body: some View {
        let unit = quote.isDebit ? "db" : "cr"
        VStack(spacing: 4) {
            HStack {
                Text("Bid")
                Spacer()
                Text("Mid")
                Spacer()
                Text("Ask")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

            ZStack {
                Capsule().fill(Color.secondary.opacity(0.5)).frame(height: 2)
                HStack {
                    dot
                    Spacer()
                    dot
                    Spacer()
                    dot
                }
            }

            HStack {
                Text("\(quote.low.fixed(2)) \(unit)")
                Spacer()
                Text("\(abs(quote.mid).fixed(2)) \(unit)").fontWeight(.bold)
                Spacer()
                Text("\(quote.high.fixed(2)) \(unit)")
            }
            .font(.system(size: 15))
            .monospacedDigit()
        }
        .foregroundStyle(.primary)
    }

    private var dot: some View {
        Circle().fill(Color.primary).frame(width: 6, height: 6)
    }
}

/// Řádek nohy: BTO/STO blok, počet, expirace, strike, typ.
struct TicketLegRow: View {
    let leg: StrategyLeg

    var body: some View {
        HStack(spacing: 0) {
            Text(leg.side == .long ? "BTO" : "STO")
                .font(.system(size: 15, weight: .semibold))
                .underline()
                .foregroundStyle(Color(white: 0.1))
                .frame(width: 60)
                .frame(maxHeight: .infinity)
                .background(leg.side == .long ? ChainTheme.long : ChainTheme.short)
            column("Počet", leg.side == .long ? "\(leg.quantity)" : "-\(leg.quantity)")
            column("Exp", leg.expiration?.shortExpiryLabel ?? "\(Int(leg.daysToExpiry.rounded())) d")
            column("Strike", leg.instrument == .stock ? leg.strike.fixed(2) : leg.strike.strikeLabel)
            column("Typ", typeLabel)
        }
        .frame(height: 42)
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ChainTheme.separator).frame(height: 1)
        }
    }

    private var typeLabel: String {
        switch leg.instrument {
        case .call: return "Call"
        case .put: return "Put"
        case .stock: return "Akcie"
        }
    }

    private func column(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.6))
            Text(value)
                .font(.system(size: 16, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
