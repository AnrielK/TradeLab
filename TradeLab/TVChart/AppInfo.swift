import Foundation

/// Označení sestavení. Slouží k ověření, že v telefonu běží opravdu ta verze,
/// kterou čekáš — zobrazuje se dole v panelu „…“.
enum AppInfo {
    /// Zvyš při každé změně chování, ať jde build rozpoznat na první pohled.
    static let revision = "r40"

    static let notes = "přiblížení zvlášť pro výšku a šířku"

    /// Přeložil se projekt s podporou Liquid Glass? Sklo se do binárky
    /// dostane jen s Xcode 26 (Swift 6.2+); na starším SDK se ta větev
    /// vůbec nepřekládá, takže by se to jinak hledalo těžko.
    static var glassStatus: String {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return "Liquid Glass · aktivní"
        } else {
            return "Liquid Glass · v buildu, systém starší než iOS 26"
        }
        #else
        return "Liquid Glass · nepřeloženo (build starším Xcode)"
        #endif
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b)) · \(revision)"
    }
}
