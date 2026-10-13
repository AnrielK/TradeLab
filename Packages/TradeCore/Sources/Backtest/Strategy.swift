import Foundation

/// Obchodní pravidla backtestu. Každé vrací cílovou pozici po zavření baru:
/// 1 = long, 0 = bez pozice, −1 = short.
public enum BacktestStrategy: Hashable, Codable, Sendable {
    /// Srovnání: koupit a držet.
    case buyAndHold
    /// Breakout nad rezistenci / breakdown pod support z konsolidace.
    case breakout(BreakoutSettings)
    /// Odraz od klouzavých průměrů 20/50/100/200 s reverzním svíčkovým patternem.
    case maBounce(MABounceSettings)

    public var name: String {
        switch self {
        case .buyAndHold: return "Buy & hold"
        case .breakout(let s):
            var entries: [String] = []
            if s.preBreakout { entries.append("před") }
            if s.breakout { entries.append("průraz") }
            if s.pullback { entries.append("PNR") }
            return "Breakout/Breakdown (\(entries.joined(separator: ", ")))"
        case .maBounce(let s):
            return "Odraz od KP \(s.enabledPeriods.map(String.init).joined(separator: "/"))"
        }
    }

    /// Cílová pozice po zavření každého baru.
    public func targets(bars: [BacktestBar], allowShort: Bool) -> [Int] {
        switch self {
        case .buyAndHold:
            return bars.map { _ in 1 }
        case .breakout(let settings):
            return BreakoutStrategy.evaluate(bars, settings: settings, allowShort: allowShort).targets
        case .maBounce(let settings):
            return MABounceStrategy.evaluate(bars, settings: settings, allowShort: allowShort).targets
        }
    }
}
