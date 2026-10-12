import SwiftUI

// MARK: - Liquid Glass

/// Sklo z iOS 26. Používá se jen tam, kde je k dispozici — na starším SDK
/// nebo systému se sáhne po materiálu, takže se to přeloží i starším Xcodem.
///
/// Zvýraznění se nedělá tintem skla: obarvené sklo je na tmavém podkladu
/// nečitelné a překryje ikonu. Aktivní stav řeší obrys a barva obsahu.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var tint: Color? = nil
    var interactive = false

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(
                glass(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func glass() -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
    #endif

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

extension View {
    /// Skleněné pozadí prvku.
    func glassCard(cornerRadius: CGFloat = 14,
                   tint: Color? = nil,
                   interactive: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Sklo pro spodní lištu — na starším systému zůstane materiál.
    @ViewBuilder
    func glassBar() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.background(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 0))
        } else {
            self.background(.ultraThinMaterial)
        }
        #else
        self.background(.ultraThinMaterial)
        #endif
    }
}

// MARK: - Barvy

extension Color {
    /// Převod zpět na "#rrggbb" — potřeba, když barvu vybere systémový picker.
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#ffffff" }
        return String(format: "#%02x%02x%02x",
                      Int((r * 255).rounded()),
                      Int((g * 255).rounded()),
                      Int((b * 255).rounded()))
    }
}

/// Čtyři přednastavené barvy plus systémový výběr pro cokoliv dalšího.
struct ColorSwatchPicker: View {
    let label: String
    let hex: String
    var presets: [String] = ColorSwatchPicker.defaultPresets
    let onChange: (String) -> Void

    static let defaultPresets = ["#e0a83c", "#4aa8ff", "#2ea98c", "#e0566b"]

    /// Vybraná barva neodpovídá žádnému presetu — je vlastní.
    private var isCustom: Bool { !presets.contains(hex) }

    var body: some View {
        HStack(spacing: 10) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 13))
                    .frame(width: 92, alignment: .leading)
            }

            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { c in
                    Button { onChange(c) } label: {
                        Circle()
                            .fill(Color(hex: c))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().stroke(.white, lineWidth: hex == c ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // systémový picker — kolečko ukazuje aktuální vlastní barvu
                ColorPicker("",
                            selection: Binding(
                                get: { Color(hex: hex) },
                                set: { onChange($0.hexString) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 28)
                    .overlay(
                        Circle()
                            .stroke(.white, lineWidth: isCustom ? 2 : 0)
                            .frame(width: 26, height: 26)
                            .allowsHitTesting(false)
                    )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
