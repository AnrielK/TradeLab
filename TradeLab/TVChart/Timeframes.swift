import Foundation

/// Jeden interval. `value` je to, co chce TradingView v `create_series`.
struct Timeframe: Identifiable, Hashable {
    let value: String
    let label: String
    let seconds: Double

    var id: String { value }
}

enum Timeframes {

    static let seconds: [Timeframe] = [
        .init(value: "1S", label: "1s", seconds: 1),
        .init(value: "5S", label: "5s", seconds: 5),
        .init(value: "10S", label: "10s", seconds: 10),
        .init(value: "15S", label: "15s", seconds: 15),
        .init(value: "30S", label: "30s", seconds: 30),
        .init(value: "45S", label: "45s", seconds: 45)
    ]

    static let minutes: [Timeframe] = [
        .init(value: "1", label: "1m", seconds: 60),
        .init(value: "2", label: "2m", seconds: 120),
        .init(value: "3", label: "3m", seconds: 180),
        .init(value: "5", label: "5m", seconds: 300),
        .init(value: "10", label: "10m", seconds: 600),
        .init(value: "15", label: "15m", seconds: 900),
        .init(value: "30", label: "30m", seconds: 1800),
        .init(value: "45", label: "45m", seconds: 2700)
    ]

    static let hours: [Timeframe] = [
        .init(value: "60", label: "1H", seconds: 3600),
        .init(value: "120", label: "2H", seconds: 7200),
        .init(value: "180", label: "3H", seconds: 10800),
        .init(value: "240", label: "4H", seconds: 14400)
    ]

    static let days: [Timeframe] = [
        .init(value: "1D", label: "1D", seconds: 86400),
        .init(value: "1W", label: "1W", seconds: 604800),
        .init(value: "1M", label: "1M", seconds: 2592000),
        .init(value: "3M", label: "3M", seconds: 7776000),
        .init(value: "6M", label: "6M", seconds: 15552000),
        .init(value: "12M", label: "12M", seconds: 31536000)
    ]

    /// Sekce pro panel výběru, v pořadí jako v TradingView.
    static let sections: [(title: String, items: [Timeframe])] = [
        ("SEKUNDY", seconds),
        ("MINUTY", minutes),
        ("HODINY", hours),
        ("DNY", days)
    ]

    static let all: [Timeframe] = seconds + minutes + hours + days

    static func timeframe(_ value: String) -> Timeframe? {
        all.first { $0.value == value }
    }

    static func label(_ value: String) -> String {
        timeframe(value)?.label ?? value
    }

    static func seconds(_ value: String) -> Double {
        timeframe(value)?.seconds ?? 86400
    }

    /// Výchozí oblíbené — to, co člověk používá nejčastěji.
    static let defaultFavorites = ["1", "5", "15", "60", "240", "1D", "1W"]
}
