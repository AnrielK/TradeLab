import SwiftUI

/// Nastavení volume profilu. Počítá se z právě viditelných svíček, takže se
/// mění při každém posunu i zoomu.
struct VolumeProfileSettings: Codable, Hashable {
    var enabled: Bool = false
    /// Počet cenových pásem, do kterých se objem rozpočítá.
    var rows: Int = 24
    /// Šířka nejdelšího sloupce jako podíl šířky grafu.
    var widthRatio: Double = 0.28
    /// Kreslit vpravo u osy, nebo vlevo.
    var onRight: Bool = true
    /// Rozdělit na nákupní/prodejní podle směru svíčky.
    var splitBuySell: Bool = true
    var upHex: String = "#2ea98c"
    var downHex: String = "#e0566b"
    var singleHex: String = "#6a7b8c"
    var opacity: Double = 0.45
    /// Zvýraznit pásmo s největším objemem (Point of Control).
    var showPOC: Bool = true
    var pocHex: String = "#e0a83c"
    /// Vyznačit oblast, kde se odehrálo 70 % objemu.
    var showValueArea: Bool = false
    var valueAreaHex: String = "#4aa8ff"

    var upColor: Color { Color(hex: upHex).opacity(opacity) }
    var downColor: Color { Color(hex: downHex).opacity(opacity) }
    var singleColor: Color { Color(hex: singleHex).opacity(opacity) }
    var pocColor: Color { Color(hex: pocHex) }
    var valueAreaColor: Color { Color(hex: valueAreaHex) }

    static let key = "volumeProfile"

    static func load() -> VolumeProfileSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(VolumeProfileSettings.self, from: data)
        else { return VolumeProfileSettings() }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// Jedno cenové pásmo profilu.
struct VolumeBin {
    let low: Double
    let high: Double
    var up: Double = 0
    var down: Double = 0
    var total: Double { up + down }
}

enum VolumeProfile {

    /// Rozpočítá objem viditelných svíček do cenových pásem.
    /// Objem svíčky se rozdělí rovnoměrně přes její rozpětí high–low, takže
    /// dlouhá svíčka nepřidá všechno do jediného pásma.
    static func compute(bars: [Bar], range: Range<Int>,
                        priceMin: Double, priceMax: Double,
                        rows: Int) -> [VolumeBin] {
        guard rows > 0, priceMax > priceMin, !range.isEmpty else { return [] }

        let step = (priceMax - priceMin) / Double(rows)
        var bins = (0..<rows).map { i in
            VolumeBin(low: priceMin + Double(i) * step,
                      high: priceMin + Double(i + 1) * step)
        }

        for i in range where i >= 0 && i < bars.count {
            let b = bars[i]
            let volume = b.volume ?? 0
            guard volume > 0 else { continue }
            let up = b.close >= b.open

            let lo = Swift.max(b.low, priceMin)
            let hi = Swift.min(b.high, priceMax)
            guard hi >= lo else { continue }

            let first = Swift.max(0, Int((lo - priceMin) / step))
            let last = Swift.min(rows - 1, Int((hi - priceMin) / step))
            guard first <= last else { continue }

            let span = Swift.max(hi - lo, step * 0.001)
            for k in first...last {
                // kolik z rozpětí svíčky spadá do tohoto pásma
                let overlap = Swift.min(hi, bins[k].high) - Swift.max(lo, bins[k].low)
                guard overlap > 0 else { continue }
                let share = volume * (overlap / span)
                if up { bins[k].up += share } else { bins[k].down += share }
            }
        }
        return bins
    }

    /// Indexy pásem tvořících oblast 70 % objemu, od POC ven.
    static func valueArea(_ bins: [VolumeBin], share: Double = 0.7) -> ClosedRange<Int>? {
        guard !bins.isEmpty else { return nil }
        let total = bins.reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }

        guard let poc = bins.indices.max(by: { bins[$0].total < bins[$1].total })
        else { return nil }

        var lower = poc, upper = poc
        var accumulated = bins[poc].total
        while accumulated < total * share, lower > 0 || upper < bins.count - 1 {
            let below = lower > 0 ? bins[lower - 1].total : -1
            let above = upper < bins.count - 1 ? bins[upper + 1].total : -1
            if above >= below {
                upper += 1; accumulated += bins[upper].total
            } else {
                lower -= 1; accumulated += bins[lower].total
            }
        }
        return lower...upper
    }

    /// Objem ve zkratce: 1,2 M místo 1234567.
    static func format(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_000_000_000 { return String(format: "%.2f B", v / 1_000_000_000) }
        if a >= 1_000_000     { return String(format: "%.2f M", v / 1_000_000) }
        if a >= 1_000         { return String(format: "%.1f K", v / 1_000) }
        return String(format: "%.0f", v)
    }
}
