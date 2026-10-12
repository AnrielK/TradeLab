import XCTest
import OptionsMath
@testable import MarketData

final class YahooParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testChartSkipsNullBarsAndBuildsQuote() throws {
        let chart = try YahooParser.parseChart(try fixture("chart"))
        XCTAssertEqual(chart.bars.count, 3)
        XCTAssertEqual(chart.quote.symbol, "AAPL")
        XCTAssertEqual(chart.quote.name, "Apple Inc.")
        XCTAssertEqual(chart.quote.exchange, "NasdaqGS")
        XCTAssertEqual(chart.quote.price, 231.5, accuracy: 1e-9)
        // Předchozí close = předposlední platný bar, ne chartPreviousClose.
        XCTAssertEqual(try XCTUnwrap(chart.quote.previousClose), 229.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(chart.quote.changePercent), (231.5 - 229.9) / 229.9, accuracy: 1e-12)
    }

    func testChartErrorIsSurfaced() throws {
        XCTAssertThrowsError(try YahooParser.parseChart(try fixture("chart_error"))) { error in
            XCTAssertEqual(error as? MarketDataError, .api("No data found, symbol may be delisted"))
        }
    }

    func testOptionChain() throws {
        let chain = try YahooParser.parseOptionChain(try fixture("options"))
        XCTAssertEqual(chain.symbol, "AAPL")
        XCTAssertEqual(chain.underlyingPrice, 231.5)
        XCTAssertEqual(chain.expirationDates.count, 3)
        XCTAssertEqual(chain.calls.map(\.strike), [220, 240], "řetězec má být seřazený podle striku")
        XCTAssertEqual(chain.puts.count, 1)

        let call = try XCTUnwrap(chain.calls.last)
        XCTAssertEqual(call.type, .call)
        XCTAssertEqual(call.volume, 1500)
        XCTAssertEqual(call.openInterest, 12000)
        XCTAssertEqual(try XCTUnwrap(call.mid), 1.20, accuracy: 1e-9)
        XCTAssertNil(chain.calls.first?.volume)
    }

    func testEstimatedVolatilityFromMid() throws {
        let chain = try YahooParser.parseOptionChain(try fixture("options"))
        let call = try XCTUnwrap(chain.calls.last)
        let now = call.expiration.addingTimeInterval(-10 * 86_400)
        let iv = try XCTUnwrap(call.estimatedVolatility(spot: 231.5, rate: 0.04, now: now))
        // Zpětné ocenění musí sedět na mid cenu.
        let params = OptionParameters(spot: 231.5, strike: 240, days: call.daysToExpiry(from: now), rate: 0.04, volatility: iv)
        XCTAssertEqual(BlackScholes.price(.call, params), 1.20, accuracy: 1e-5)
    }

    func testSearchFiltersOptions() throws {
        let matches = try YahooParser.parseSearch(try fixture("search"))
        XCTAssertEqual(matches.map(\.symbol), ["AAPL", "SPY"])
    }

    func testPathEncoding() {
        XCTAssertEqual(YahooFinanceClient.encodePath("^irx"), "%5EIRX")
        XCTAssertEqual(YahooFinanceClient.encodePath("brk-b"), "BRK-B")
    }
}
