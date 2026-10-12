import Foundation
import ClaudeAgent
import MarketData
import OptionsMath
import Backtest

/// Lokální nástroje agenta nad daty a výpočty aplikace.
/// Výstupy jsou kompaktní JSON se zaokrouhlenými čísly – model z nich počítá, nic nevymýšlí.
@MainActor
enum AgentToolbox {
    static func tools(model: AppModel) -> [AgentTool] {
        [
            AgentTool(
                name: "get_quote",
                description: "Aktuální cena akcie/ETF/indexu (např. NVDA, SPY, ^VIX): cena, předchozí zavírací cena, denní změna.",
                inputSchema: Schema.object(["symbol": Schema.string("Ticker, např. AAPL")], required: ["symbol"])
            ) { input in try await quote(input, model: model) },

            AgentTool(
                name: "search_symbol",
                description: "Najde ticker podle názvu firmy nebo části tickeru.",
                inputSchema: Schema.object(["query": Schema.string("Název nebo ticker, např. 'nvidia'")], required: ["query"])
            ) { input in try await search(input, model: model) },

            AgentTool(
                name: "get_watchlist",
                description: "Sledované tickery uživatele s aktuálními cenami a denní změnou.",
                inputSchema: Schema.object([:])
            ) { _ in await watchlist(model: model) },

            AgentTool(
                name: "get_price_history",
                description: """
                Statistiky denní historie ceny (upravené o dividendy): výnosy 1M/3M/6M/YTD/1R, \
                realizovaná volatilita 20/60 dní, SMA 20/50/200, RSI 14, MACD 12/26/9, 52týdenní maximum/minimum, \
                max. drawdown za období, průměrný objem a posledních 10 zavíracích cen. Nevrací celou řadu.
                """,
                inputSchema: Schema.object([
                    "symbol": Schema.string("Ticker"),
                    "range": Schema.string("Délka historie (výchozí 1y)", enum: HistoryRange.allCases.map(\.rawValue)),
                ], required: ["symbol"])
            ) { input in try await priceHistory(input, model: model) },

            AgentTool(
                name: "get_option_expirations",
                description: "Seznam expirací opcí pro ticker (datum, dny do expirace, měsíční/týdenní) a souhrn nejbližší expirace.",
                inputSchema: Schema.object(["symbol": Schema.string("Ticker")], required: ["symbol"])
            ) { input in try await expirations(input, model: model) },

            AgentTool(
                name: "get_option_chain",
                description: """
                Opční řetězec jedné expirace kolem ATM: pro každý strike call a put s bid/ask/mid, IV (dopočtená z mid), \
                deltou, open interest a objemem. Plus ATM IV a trhem implikovaný pohyb (ATM straddle). \
                Expirace přesně jako YYYY-MM-DD z get_option_expirations, nebo min_days pro první expiraci s aspoň tolika dny.
                """,
                inputSchema: Schema.object([
                    "symbol": Schema.string("Ticker"),
                    "expiration": Schema.string("Datum expirace YYYY-MM-DD (volitelné)"),
                    "min_days": Schema.integer("Vyber první expiraci s aspoň tolika dny (volitelné)"),
                    "strikes_each_side": Schema.integer("Počet striků nad i pod ATM (výchozí 8, max 25)"),
                    "type": Schema.string("Které strany vrátit (výchozí both)", enum: ["call", "put", "both"]),
                ], required: ["symbol"])
            ) { input in try await optionChain(input, model: model) },

            AgentTool(
                name: "price_option",
                description: "Black-Scholes cena a greeks evropské opce. Spot zadej přímo, nebo ticker a vezme se aktuální cena. Sazba výchozí z ^IRX.",
                inputSchema: Schema.object([
                    "type": Schema.string("call nebo put", enum: ["call", "put"]),
                    "strike": Schema.number("Strike"),
                    "days": Schema.number("Dny do expirace"),
                    "volatility": Schema.number("Volatilita jako desetinné číslo, např. 0.25"),
                    "spot": Schema.number("Cena podkladu (volitelné, jinak symbol)"),
                    "symbol": Schema.string("Ticker pro aktuální cenu (volitelné)"),
                    "rate": Schema.number("Bezriziková sazba jako desetinné číslo (volitelné)"),
                ], required: ["type", "strike", "days", "volatility"])
            ) { input in try await priceOption(input, model: model) },

            AgentTool(
                name: "analyze_strategy",
                description: """
                Postaví opční strategii z REÁLNÝCH kontraktů (aktuální bid/ask/mid a IV) a spočítá: čistou prémii, \
                net kotaci, max. zisk/ztrátu, break-eveny, pravděpodobnost zisku, greeks pozice a P/L při expiraci \
                pro různé ceny. Strike i expirace musí v řetězci existovat. Akciová noha: type stock, quantity v kusech po 100. \
                apply_to_app: true nahraje strategii na záložku Opce – použij jen když o to uživatel požádá.
                """,
                inputSchema: Schema.object([
                    "symbol": Schema.string("Ticker podkladu"),
                    "legs": Schema.array("Nohy strategie", items: Schema.object([
                        "type": Schema.string("call, put nebo stock", enum: ["call", "put", "stock"]),
                        "side": Schema.string("long (koupit) nebo short (prodat)", enum: ["long", "short"]),
                        "strike": Schema.number("Strike (u stock se ignoruje)"),
                        "expiration": Schema.string("Expirace YYYY-MM-DD (u opcí povinná)"),
                        "quantity": Schema.integer("Počet kontraktů (výchozí 1)"),
                    ], required: ["type", "side"])),
                    "apply_to_app": Schema.boolean("Nahrát strategii do aplikace (výchozí false)"),
                ], required: ["symbol", "legs"])
            ) { input in try await analyzeStrategy(input, model: model) },

            AgentTool(
                name: "get_current_position",
                description: "Strategie, kterou má uživatel právě sestavenou na záložce Opce, včetně analýzy (P/L, break-eveny, greeks).",
                inputSchema: Schema.object([:])
            ) { _ in await currentPosition(model: model) },

            AgentTool(
                name: "run_backtest",
                description: """
                Backtest pravidla na denních datech (signál ze zavírací ceny, obchod za otevírací cenu dalšího dne, \
                ceny upravené o dividendy) a srovnání s buy & hold: výnos, CAGR, Sharpe, Sortino, max. drawdown, \
                volatilita, počet obchodů, win rate, expozice.
                """,
                inputSchema: Schema.object([
                    "symbol": Schema.string("Ticker"),
                    "strategy": Schema.string("Pravidlo", enum: ["sma_cross", "macd_cross", "rsi_reversion", "buy_and_hold"]),
                    "range": Schema.string("Období (výchozí 5y)", enum: HistoryRange.allCases.map(\.rawValue)),
                    "fast": Schema.integer("Rychlá perioda (SMA výchozí 50, MACD 12)"),
                    "slow": Schema.integer("Pomalá perioda (SMA výchozí 200, MACD 26)"),
                    "signal": Schema.integer("Signální perioda MACD (výchozí 9)"),
                    "rsi_period": Schema.integer("Perioda RSI (výchozí 14)"),
                    "rsi_lower": Schema.number("Nákup pod RSI (výchozí 30)"),
                    "rsi_upper": Schema.number("Prodej nad RSI (výchozí 70)"),
                    "allow_short": Schema.boolean("Povolit short místo hotovosti (výchozí false)"),
                    "cost_bps": Schema.number("Náklady v bazických bodech na obchod (výchozí 5)"),
                ], required: ["symbol", "strategy"])
            ) { input in try await backtest(input, model: model) },
        ]
    }

    // MARK: - Pomocníci

    static func num(_ x: Double?, _ digits: Int = 2) -> JSONValue {
        guard let x, x.isFinite else { return .null }
        let p = pow(10, Double(digits))
        return .number((x * p).rounded() / p)
    }

    static func pct(_ x: Double?) -> JSONValue { num(x.map { $0 * 100 }, 2) }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func symbol(_ input: JSONValue, key: String = "symbol") throws -> String {
        guard let s = input[key]?.stringValue?.trimmingCharacters(in: .whitespaces).uppercased(), !s.isEmpty else {
            throw ToolError("Chybí parametr \(key).")
        }
        return s
    }

    static func output(_ value: JSONValue) -> String { value.jsonString }

    // MARK: - Ceny

    static func quote(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        let q = try await model.client.quote(symbol: s)
        return output([
            "symbol": .string(q.symbol),
            "name": q.name.map(JSONValue.string) ?? .null,
            "exchange": q.exchange.map(JSONValue.string) ?? .null,
            "currency": .string(q.currency),
            "price": num(q.price),
            "previous_close": num(q.previousClose),
            "change": num(q.change),
            "change_pct": pct(q.changePercent),
        ])
    }

    static func search(_ input: JSONValue, model: AppModel) async throws -> String {
        guard let query = input["query"]?.stringValue, !query.isEmpty else { throw ToolError("Chybí query.") }
        let matches = try await model.client.search(query)
        return output(.array(matches.prefix(8).map { m in
            [
                "symbol": .string(m.symbol),
                "name": m.name.map(JSONValue.string) ?? .null,
                "exchange": m.exchange.map(JSONValue.string) ?? .null,
                "type": m.type.map(JSONValue.string) ?? .null,
            ]
        }))
    }

    static func watchlist(model: AppModel) async -> String {
        await model.refreshQuotes()
        return output(.array(model.watchlist.map { s in
            let q = model.quotes[s]
            return ["symbol": .string(s), "price": num(q?.price), "change_pct": pct(q?.changePercent)]
        }))
    }

    static func priceHistory(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        let range = input["range"]?.stringValue.flatMap(HistoryRange.init(rawValue:)) ?? .oneYear
        let data = try await model.client.dailyHistory(symbol: s, range: range)
        let bars = data.bars.filter { $0.close > 0 }
        guard bars.count > 2 else { throw ToolError("Málo dat pro \(s).") }
        let closes = bars.map { $0.adjustedClose ?? $0.close }
        let last = closes[closes.count - 1]

        func ret(_ n: Int) -> JSONValue {
            guard closes.count > n else { return .null }
            return pct(last / closes[closes.count - 1 - n] - 1)
        }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let calendar = Calendar(identifier: .gregorian)
        let ytdBase = bars.lastIndex { calendar.component(.year, from: $0.date) < year }.map { closes[$0] }

        var peak = closes[0]
        var maxDD = 0.0
        for c in closes {
            peak = max(peak, c)
            maxDD = min(maxDD, c / peak - 1)
        }
        let recent = bars.suffix(252)
        let macd = TA.macd(closes)
        let years = bars.last!.date.timeIntervalSince(bars[0].date) / (365.25 * 86_400)
        let cagr: JSONValue = years > 0.5 ? pct(pow(last / closes[0], 1 / years) - 1) : .null
        let avgVolume = bars.suffix(20).map(\.volume).reduce(0, +) / Double(min(20, bars.count))

        let result: [String: JSONValue] = [
            "symbol": .string(s),
            "from": .string(day(bars[0].date)),
            "to": .string(day(bars.last!.date)),
            "bars": .number(Double(bars.count)),
            "last_close": num(bars.last!.close),
            "return_total_pct": pct(last / closes[0] - 1),
            "cagr_pct": cagr,
            "return_1m_pct": ret(21),
            "return_3m_pct": ret(63),
            "return_6m_pct": ret(126),
            "return_1y_pct": ret(252),
            "return_ytd_pct": ytdBase.map { pct(last / $0 - 1) } ?? .null,
            "realized_vol_20d_pct": pct(Volatility.realized(closes: closes, window: 20)),
            "realized_vol_60d_pct": pct(Volatility.realized(closes: closes, window: 60)),
            "realized_vol_period_pct": pct(Volatility.realized(closes: closes)),
            "sma20": num(TA.sma(closes, 20).last ?? nil),
            "sma50": num(TA.sma(closes, 50).last ?? nil),
            "sma200": num(TA.sma(closes, 200).last ?? nil),
            "rsi14": num(TA.rsi(closes, 14).last ?? nil, 1),
            "macd": num(macd.macd.last ?? nil, 3),
            "macd_signal": num(macd.signal.last ?? nil, 3),
            "high_52w": num(recent.map(\.high).max()),
            "low_52w": num(recent.map(\.low).min()),
            "max_drawdown_pct": pct(maxDD),
            "avg_volume_20d": num(avgVolume, 0),
            "last_10_closes": .array(bars.suffix(10).map { ["date": .string(day($0.date)), "close": num($0.close)] }),
        ]
        return output(.object(result))
    }

    // MARK: - Opce

    static func expirations(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        let chain = try await model.client.optionChain(symbol: s)
        guard !chain.expirationDates.isEmpty else { throw ToolError("\(s) nemá opce.") }
        let summary = chain.summary(rate: model.riskFreeRate)
        return output([
            "symbol": .string(s),
            "underlying_price": num(chain.underlyingPrice),
            "expirations": .array(chain.expirationDates.map { d in
                [
                    "date": .string(day(d)),
                    "days": num(OptionChain.daysToExpiry(d), 1),
                    "monthly": .bool(ExpirationCalendar.isMonthly(d)),
                ]
            }),
            "nearest": summaryJSON(summary),
        ])
    }

    static func summaryJSON(_ s: ExpirationSummary) -> JSONValue {
        [
            "expiration": .string(day(s.expiration)),
            "days": num(s.daysToExpiry, 1),
            "atm_iv_pct": pct(s.atmVolatility),
            "expected_move_straddle": num(s.straddleMove),
            "one_sigma_move": num(s.oneSigmaMove),
        ]
    }

    /// Řetězec pro požadovanou expiraci (přesné datum, min. počet dní, nebo nejbližší).
    static func loadChain(symbol: String, expiration: String?, minDays: Int?, model: AppModel) async throws -> OptionChain {
        let first = try await model.client.optionChain(symbol: symbol)
        var target: Date? = nil
        if let expiration, !expiration.isEmpty {
            guard let match = first.expirationDates.first(where: { day($0) == expiration }) else {
                let list = first.expirationDates.prefix(15).map(day).joined(separator: ", ")
                throw ToolError("Expirace \(expiration) pro \(symbol) neexistuje. Dostupné: \(list)…")
            }
            target = match
        } else if let minDays {
            target = first.expirationDates.first { OptionChain.daysToExpiry($0) >= Double(minDays) }
                ?? first.expirationDates.last
        }
        guard let target, target != first.expiration else { return first }
        return try await model.client.optionChain(symbol: symbol, expiration: target)
    }

    static func contractJSON(_ c: OptionContract?, spot: Double, rate: Double) -> JSONValue {
        guard let c else { return .null }
        let iv = c.estimatedVolatility(spot: spot, rate: rate)
        let delta = iv.map { BlackScholes.greeks(c.type, OptionParameters(spot: spot, strike: c.strike, days: c.daysToExpiry(),
                                                                          rate: rate, volatility: $0)).delta }
        return [
            "bid": num(c.bid),
            "ask": num(c.ask),
            "mid": num(c.mid),
            "iv_pct": pct(iv),
            "delta": num(delta, 3),
            "oi": c.openInterest.map { .number(Double($0)) } ?? .null,
            "volume": c.volume.map { .number(Double($0)) } ?? .null,
        ]
    }

    static func optionChain(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        let chain = try await loadChain(symbol: s, expiration: input["expiration"]?.stringValue,
                                        minDays: input["min_days"]?.intValue, model: model)
        let spot = chain.underlyingPrice
        let rate = model.riskFreeRate
        let each = min(max(input["strikes_each_side"]?.intValue ?? 8, 1), 25)
        let side = input["type"]?.stringValue ?? "both"
        let strikes = chain.strikes
        guard let atm = StrikeLadder.nearestIndex(to: spot, in: strikes) else { throw ToolError("Prázdný řetězec.") }
        let slice = strikes[max(atm - each, 0)...min(atm + each, strikes.count - 1)]

        let rows: [JSONValue] = slice.map { k in
            var row: [String: JSONValue] = ["strike": num(k)]
            if side != "put" { row["call"] = contractJSON(chain.contract(.call, strike: k), spot: spot, rate: rate) }
            if side != "call" { row["put"] = contractJSON(chain.contract(.put, strike: k), spot: spot, rate: rate) }
            return .object(row)
        }
        return output([
            "symbol": .string(s),
            "underlying_price": num(spot),
            "rate_pct": pct(rate),
            "summary": summaryJSON(chain.summary(rate: rate)),
            "strikes": .array(rows),
            "note": "IV a delta jsou dopočtené z mid ceny (Black-Scholes). Mimo obchodní hodiny mohou být kotace zastaralé.",
        ])
    }

    static func priceOption(_ input: JSONValue, model: AppModel) async throws -> String {
        guard let typeName = input["type"]?.stringValue, let type = OptionType(rawValue: typeName) else {
            throw ToolError("type musí být call nebo put.")
        }
        guard let strike = input["strike"]?.doubleValue, strike > 0,
              let days = input["days"]?.doubleValue, days >= 0,
              var vol = input["volatility"]?.doubleValue, vol > 0 else {
            throw ToolError("Chybí strike, days nebo volatility.")
        }
        if vol > 3 { vol /= 100 } // zadáno v procentech
        var spot = input["spot"]?.doubleValue
        if spot == nil, input["symbol"] != nil {
            spot = try await model.client.quote(symbol: try symbol(input)).price
        }
        guard let spot, spot > 0 else { throw ToolError("Zadej spot nebo symbol.") }
        let rate = input["rate"]?.doubleValue ?? model.riskFreeRate
        let p = OptionParameters(spot: spot, strike: strike, days: days, rate: rate, volatility: vol)
        let price = BlackScholes.price(type, p)
        let g = BlackScholes.greeks(type, p)
        let intrinsic = BlackScholes.intrinsic(type, spot: spot, strike: strike)
        return output([
            "spot": num(spot),
            "rate_pct": pct(rate),
            "volatility_pct": pct(vol),
            "price": num(price, 3),
            "intrinsic": num(intrinsic, 3),
            "extrinsic": num(price - intrinsic, 3),
            "delta": num(g.delta, 4),
            "gamma": num(g.gamma, 5),
            "theta_per_day": num(g.theta, 4),
            "vega_per_1pct": num(g.vega, 4),
            "rho_per_1pct": num(g.rho, 4),
            "note": "Ceny a greeks za 1 akcii; kontrakt = 100 akcií.",
        ])
    }

    static func analyzeStrategy(_ input: JSONValue, model: AppModel) async throws -> String {
        let (strategy, spot) = try await buildStrategy(input, model: model)
        var result = describe(strategy, spot: spot, rate: model.riskFreeRate)
        if input["apply_to_app"]?.boolValue == true {
            model.openAgentStrategy(strategy, spot: spot, switchTab: false)
            result["applied_to_app"] = true
        }
        return output(.object(result))
    }

    /// Strategie z reálných kontraktů podle vstupu `analyze_strategy` (aktuální kotace).
    static func buildStrategy(_ input: JSONValue, model: AppModel) async throws -> (OptionStrategy, Double) {
        let s = try symbol(input)
        guard let legInputs = input["legs"]?.arrayValue, !legInputs.isEmpty else { throw ToolError("Chybí legs.") }
        guard legInputs.count <= 8 else { throw ToolError("Maximálně 8 nohou.") }

        var chains: [String: OptionChain] = [:]
        var legs: [StrategyLeg] = []
        var spot: Double? = nil
        let rate = model.riskFreeRate

        for (i, leg) in legInputs.enumerated() {
            guard let typeName = leg["type"]?.stringValue, let instrument = LegInstrument(rawValue: typeName) else {
                throw ToolError("Noha \(i + 1): type musí být call, put nebo stock.")
            }
            guard let sideName = leg["side"]?.stringValue, let side = PositionSide(rawValue: sideName) else {
                throw ToolError("Noha \(i + 1): side musí být long nebo short.")
            }
            let quantity = max(leg["quantity"]?.intValue ?? 1, 1)

            guard let type = instrument.optionType else {
                let price: Double
                if let spot { price = spot } else {
                    price = try await model.client.quote(symbol: s).price
                    spot = price
                }
                legs.append(StrategyLeg(instrument: .stock, side: side, quantity: quantity, strike: price))
                continue
            }
            guard let expiration = leg["expiration"]?.stringValue else {
                throw ToolError("Noha \(i + 1): u opce chybí expiration (YYYY-MM-DD).")
            }
            guard let strike = leg["strike"]?.doubleValue else { throw ToolError("Noha \(i + 1): chybí strike.") }

            let chain: OptionChain
            if let cached = chains[expiration] {
                chain = cached
            } else {
                chain = try await loadChain(symbol: s, expiration: expiration, minDays: nil, model: model)
                chains[expiration] = chain
            }
            if spot == nil { spot = chain.underlyingPrice }
            guard let contract = chain.contract(type, strike: strike) else {
                let available = chain.contracts(type).map(\.strike).sorted()
                let near = available.sorted { abs($0 - strike) < abs($1 - strike) }.prefix(6).sorted()
                throw ToolError("Noha \(i + 1): \(typeName) strike \(strike) pro \(expiration) neexistuje. Nejbližší: \(near.map { String($0) }.joined(separator: ", ")).")
            }
            legs.append(chain.leg(for: contract, side: side, quantity: quantity, rate: rate))
        }

        guard let spot else { throw ToolError("Nepodařilo se zjistit cenu podkladu.") }
        let strategy = OptionStrategy(name: StrategyClassifier.name(for: OptionStrategy(underlying: s, legs: legs)),
                                      underlying: s, legs: legs)
        return (strategy, spot)
    }

    static func currentPosition(model: AppModel) async -> String {
        let strategy = model.strategy
        guard !strategy.legs.isEmpty else {
            return output(["position": .null, "note": "Uživatel nemá sestavenou žádnou strategii."])
        }
        await model.refreshStrategySpot()
        let spot = model.strategySpot > 0 ? model.strategySpot : (strategy.legs.first?.strike ?? 0)
        return output(.object(describe(model.strategy, spot: spot, rate: model.riskFreeRate)))
    }

    /// Analýza strategie pro model.
    static func describe(_ strategy: OptionStrategy, spot: Double, rate: Double) -> [String: JSONValue] {
        let market = MarketContext(rate: rate)
        let analysis = strategy.analyze(spot: spot, market: market)
        let greeks = strategy.greeks(atSpot: spot, market: market)
        let netPremium = strategy.netPremium

        let legs: [JSONValue] = strategy.legs.map { leg in
            var o: [String: JSONValue] = [
                "type": .string(leg.instrument.rawValue),
                "side": .string(leg.side.rawValue),
                "quantity": .number(Double(leg.quantity)),
            ]
            if leg.instrument == .stock {
                o["entry_price"] = num(leg.strike)
            } else {
                o["strike"] = num(leg.strike)
                o["expiration"] = leg.expiration.map { JSONValue.string(day($0)) } ?? .null
                o["days"] = num(leg.daysToExpiry, 1)
                o["bid"] = num(leg.bid)
                o["ask"] = num(leg.ask)
                o["mid"] = num(leg.premium)
                o["iv_pct"] = pct(leg.impliedVolatility)
                if let type = leg.instrument.optionType {
                    let p = OptionParameters(spot: spot, strike: leg.strike, days: leg.daysToExpiry,
                                             rate: rate, volatility: leg.impliedVolatility)
                    o["delta"] = num(BlackScholes.greeks(type, p).delta, 3)
                }
                o["contract"] = leg.contractSymbol.map(JSONValue.string) ?? .null
            }
            return .object(o)
        }

        let moves = [-0.2, -0.1, -0.05, 0, 0.05, 0.1, 0.2]
        let scenarios: [JSONValue] = moves.map { m in
            let price = spot * (1 + m)
            return [
                "move_pct": num(m * 100, 0),
                "price": num(price),
                "pnl_at_expiry": num(strategy.expiryProfitLoss(atSpot: price, market: market), 0),
            ]
        }

        var result: [String: JSONValue] = [
            "name": .string(strategy.name),
            "underlying": .string(strategy.underlying),
            "spot": num(spot),
            "legs": .array(legs),
            "net_premium_usd": num(netPremium, 0),
            "premium_kind": .string(netPremium >= 0 ? "debit (zaplaceno)" : "credit (přijato)"),
            "max_profit_usd": analysis.maxProfit.map { num($0, 0) } ?? "neomezený",
            "max_loss_usd": analysis.maxLoss.map { num($0, 0) } ?? "neomezená",
            "breakevens": .array(analysis.breakevens.map { num($0) }),
            "probability_of_profit_pct": pct(analysis.probabilityOfProfit),
            "position_greeks": [
                "delta_shares": num(greeks.delta, 1),
                "gamma": num(greeks.gamma, 2),
                "theta_usd_per_day": num(greeks.theta, 2),
                "vega_usd_per_1pct": num(greeks.vega, 2),
            ],
            "pnl_scenarios_at_expiry": .array(scenarios),
        ]
        if strategy.stockCost != 0 { result["stock_cost_usd"] = num(strategy.stockCost, 0) }
        if let q = strategy.netQuote {
            result["net_quote_per_spread"] = ["natural": num(q.natural), "mid": num(q.mid), "opposite": num(q.opposite)]
        }
        return result
    }

    // MARK: - Backtest

    static func backtest(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        let range = input["range"]?.stringValue.flatMap(HistoryRange.init(rawValue:)) ?? .fiveYears
        let strategy: BacktestStrategy
        switch input["strategy"]?.stringValue {
        case "sma_cross":
            strategy = .smaCross(fast: input["fast"]?.intValue ?? 50, slow: input["slow"]?.intValue ?? 200)
        case "macd_cross":
            strategy = .macdCross(fast: input["fast"]?.intValue ?? 12, slow: input["slow"]?.intValue ?? 26,
                                  signal: input["signal"]?.intValue ?? 9)
        case "rsi_reversion":
            strategy = .rsiReversion(period: input["rsi_period"]?.intValue ?? 14,
                                     lower: input["rsi_lower"]?.doubleValue ?? 30,
                                     upper: input["rsi_upper"]?.doubleValue ?? 70)
        case "buy_and_hold":
            strategy = .buyAndHold
        default:
            throw ToolError("Neznámé pravidlo. Použij sma_cross, macd_cross, rsi_reversion nebo buy_and_hold.")
        }

        let data = try await model.client.dailyHistory(symbol: s, range: range)
        let bars = BacktestModel.backtestBars(data.bars)
        guard bars.count > 30 else { throw ToolError("Málo dat pro backtest (\(bars.count) dní).") }
        let config = BacktestConfig(strategy: strategy, allowShort: input["allow_short"]?.boolValue ?? false,
                                    costBps: input["cost_bps"]?.doubleValue ?? 5, riskFreeRate: model.riskFreeRate)
        let result = BacktestEngine.run(bars: bars, config: config)

        func metrics(_ m: BacktestMetrics) -> JSONValue {
            [
                "total_return_pct": pct(m.totalReturn),
                "cagr_pct": pct(m.cagr),
                "volatility_pct": pct(m.volatility),
                "sharpe": num(m.sharpe),
                "sortino": num(m.sortino),
                "max_drawdown_pct": pct(m.maxDrawdown),
                "calmar": num(m.calmar),
                "trades": .number(Double(m.tradeCount)),
                "win_rate_pct": pct(m.winRate),
                "avg_trade_pct": pct(m.averageTrade),
                "exposure_pct": pct(m.exposure),
            ]
        }

        let lastTrades: [JSONValue] = result.trades.suffix(5).map { t in
            [
                "side": .string(t.side > 0 ? "long" : "short"),
                "entry": .string(day(t.entryDate)),
                "exit": t.exitDate.map { JSONValue.string(day($0)) } ?? "otevřený",
                "return_pct": pct(t.returnPct),
            ]
        }
        let summary: [String: JSONValue] = [
            "symbol": .string(s),
            "rule": .string(strategy.name),
            "from": .string(day(bars[0].date)),
            "to": .string(day(bars[bars.count - 1].date)),
            "strategy": metrics(result.metrics),
            "buy_and_hold": metrics(result.buyAndHoldMetrics),
            "last_trades": .array(lastTrades),
            "note": "Historický backtest bez daní a skluzu nad rámec cost_bps; nezaručuje budoucí výsledky.",
        ]
        return output(.object(summary))
    }
}
