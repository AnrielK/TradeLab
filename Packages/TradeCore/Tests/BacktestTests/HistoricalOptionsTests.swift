import XCTest
import OptionsMath
@testable import Backtest

/// Maketa zdroje: kotace z Black-Scholes nad cenami podkladu, týdenní expirace, striky po 5.
final class MockOptionsSource: HistoricalOptionsSource, @unchecked Sendable {
    let closes: [String: Double]
    let days: [String]
    init(bars: [BacktestBar]) {
        closes = Dictionary(uniqueKeysWithValues: bars.map { (HistoricalDay.string($0.date), $0.close) })
        days = bars.map { HistoricalDay.string($0.date) }
    }

    func quotes(day: String, expiration: String, strikes: [Double]) -> [HistoricalOptionQuote] {
        guard let spot = closes[day] else { return [] }
        let t = max(HistoricalDay.days(from: day, to: expiration), 0.5)
        return strikes.flatMap { k in
            [OptionType.call, .put].map { type in
                let p = OptionParameters(spot: spot, strike: k, days: t, rate: 0.04, volatility: 0.3)
                let price = BlackScholes.price(type, p)
                return HistoricalOptionQuote(date: day, expiration: expiration, strike: k, type: type,
                                             bid: max(price - 0.05, 0), ask: price + 0.05, iv: 0.3,
                                             delta: BlackScholes.greeks(type, p).delta)
            }
        }
    }

    func expirations(symbol: String, candidates: [String], minDays: Int, maxDays: Int) async throws
        -> (date: String, expirations: [String])? {
        guard let date = candidates.first(where: { closes[$0] != nil }) else { return nil }
        let list = stride(from: 7, through: 70, by: 7).filter { $0 >= minDays && $0 <= maxDays }
            .map { HistoricalDay.adding($0, to: date) }
        return (date, list)
    }

    func chain(symbol: String, date: String, expiration: String, minStrike: Double, maxStrike: Double) async throws
        -> [HistoricalOptionQuote] {
        let strikes = stride(from: (minStrike / 5).rounded(.up) * 5, through: maxStrike, by: 5).map { $0 }
        return quotes(day: date, expiration: expiration, strikes: strikes)
    }

    func history(symbol: String, expiration: String, strikes: [Double], days requested: [String]) async throws
        -> [HistoricalOptionQuote] {
        requested.flatMap { quotes(day: $0, expiration: expiration, strikes: strikes) }
    }

    func ivRank(symbol: String, days requested: [String]) async throws -> [String: Double] {
        let index = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, $0.offset) })
        return Dictionary(uniqueKeysWithValues: requested.compactMap { day in
            index[day].map { (day, Double(($0 / 40) % 2) * 80 + 10) }
        })
    }
}

final class HistoricalOptionsTests: XCTestCase {
    func testParseDoltHubRows() throws {
        let json = """
        {"query_execution_status":"Success","query_execution_message":"","rows":[
          {"date":"2024-03-06","act_symbol":"SPY","expiration":"2024-04-19","strike":"510.00","call_put":"Call",
           "bid":"12.10","ask":"12.30","vol":"0.1450","delta":"0.5210","gamma":"0.0100","theta":"-0.1200","vega":"0.6000","rho":"0.3000"},
          {"date":"2024-03-06","act_symbol":"SPY","expiration":"2024-04-19","strike":"500.00","call_put":"Put",
           "bid":"5.00","ask":null,"vol":null,"delta":null}
        ]}
        """.data(using: .utf8)!
        let rows = try DoltHubOptionsSource.parseRows(json)
        XCTAssertEqual(rows.count, 2)
        let quotes = rows.compactMap(DoltHubOptionsSource.parseQuote)
        XCTAssertEqual(quotes.count, 1)                 // bez ask se kotace zahodí
        XCTAssertEqual(quotes[0].type, .call)
        XCTAssertEqual(quotes[0].strike, 510)
        XCTAssertEqual(quotes[0].mid, 12.2, accuracy: 1e-9)
        XCTAssertEqual(quotes[0].delta, 0.521)

        let error = #"{"query_execution_status":"Error","query_execution_message":"syntax error"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try DoltHubOptionsSource.parseRows(error))
    }

    func testHistoricalRunWithMockSource() async throws {
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        var price = 100.0
        var seed: UInt64 = 3
        let bars: [BacktestBar] = (0..<260).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(seed >> 33) / Double(UInt64(1) << 31) - 0.5
            let open = price
            price *= 1 + 0.001 + noise * 0.03
            return BacktestBar(date: start.addingTimeInterval(Double(i) * 86_400), open: open,
                               high: max(open, price) * 1.002, low: min(open, price) * 0.998, close: price)
        }
        let config = OptionsBacktestConfig(signal: .smaCross(fast: 10, slow: 30), selection: .auto(neutralCondor: false))
        let result = try await OptionsBacktest.runHistorical(bars: bars, symbol: "TEST", config: config,
                                                             source: MockOptionsSource(bars: bars))
        XCTAssertEqual(result.equity.count, bars.count)
        XCTAssertFalse(result.trades.isEmpty)
        XCTAssertTrue(result.pricing.contains("Historické"))
        // Striky z řetězce (po 5) a obě volby podle IV ranku se vyskytnou.
        XCTAssertTrue(result.trades.allSatisfy { $0.legs.allSatisfy { $0.strike.truncatingRemainder(dividingBy: 5) == 0 } })
        let plays = Set(result.trades.map(\.play))
        XCTAssertTrue(plays.isSubset(of: [.bullPutSpread, .bullCallSpread, .bearCallSpread, .bearPutSpread]))
        for trade in result.trades where trade.exitDate != nil {
            XCTAssertGreaterThan(trade.pnl, -trade.maxLoss * 1.3 - 50)
        }
    }
}
