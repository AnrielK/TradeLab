import SwiftUI

/// Barvy opční tabulky (tmavý styl podobný brokerským aplikacím).
enum ChainTheme {
    /// Týdenní expirace.
    static let weekly = Color(red: 0.118, green: 0.192, blue: 0.302)
    /// Měsíční (standardní) expirace.
    static let monthly = Color(red: 0.153, green: 0.267, blue: 0.420)
    /// Středový sloupec s dny / striky.
    static let centerColumn = Color(white: 0.17)
    static let strikeColumn = Color(white: 0.06)
    static let headerBar = Color(white: 0.16)
    static let row = Color(white: 0.10)
    static let rowInTheMoney = Color(white: 0.15)
    static let separator = Color.black.opacity(0.55)
    static let itm = Color(red: 0.95, green: 0.78, blue: 0.25)
    static let sigma = Color(red: 0.35, green: 0.55, blue: 0.95)
    static let up = Color(red: 0.42, green: 0.80, blue: 0.47)
    static let down = Color(red: 0.95, green: 0.42, blue: 0.42)
    static let long = Color(red: 0.35, green: 0.70, blue: 0.40)
    static let short = Color(red: 0.90, green: 0.38, blue: 0.40)
    static let badge = Color.black.opacity(0.75)
    static let action = Color(red: 0.86, green: 0.48, blue: 0.30)

    /// Barva ceny podle denní změny kontraktu.
    static func priceColor(change: Double?) -> Color {
        guard let change else { return Color(white: 0.75) }
        if change > 0 { return up }
        if change < 0 { return down }
        return Color(white: 0.75)
    }
}
