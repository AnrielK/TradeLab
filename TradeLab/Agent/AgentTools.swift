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
                name: "get_option_setups",
                description: """
                Výsledky skeneru Breakout/Breakdown (watchlist na záložce Trh): tickery s čerstvým vstupem \
                (těsně před breakoutem, po breakoutu, pullback PNR) nebo kandidáti v konsolidaci těsně u hladiny; \
                směr, hladina, stop, cíl, stáří vstupu, percentil HV, IV/HV, likvidita ATM opcí a navržený spread. \
                rescan=true spustí nový sken (trvá desítky sekund).
                """,
                inputSchema: Schema.object(["rescan": Schema.boolean("Spustit nový sken (výchozí false = poslední výsledky)")])
            ) { input in await optionSetups(input, model: model) },

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
                name: "find_levels",
                description: """
                Najde silné horizontální supporty a rezistence (shluky swingových maxim a minim, síla podle počtu dotyků \
                a čerstvosti) a trendové linie (přes swingová minima/maxima, které zavírací cena neprorazila) na \
                svíčkách 1W, 1D nebo 4H stejných jako v grafu aplikace (TradingView). Časy jsou v UTC. \
                Vrací i Fibonacciho swing (nejvyšší high a nejnižší low za poslední období) s retracementy \
                0,236–0,786 a extenzemi 1,272 a 1,618. \
                draw: true rovnou zakreslí všechny nalezené (nahradí dřívější kresby agenta v tomto timeframu); \
                pro výběr jen těch nejdůležitějších použij místo toho draw_on_chart.
                """,
                inputSchema: Schema.object([
                    "symbol": Schema.string("Ticker"),
                    "timeframe": Schema.string("Časový rámec", enum: LevelTimeframe.allCases.map(\.rawValue)),
                    "max_levels": Schema.integer("Max. počet horizontálních hladin (výchozí 6)"),
                    "draw": Schema.boolean("Zakreslit vše nalezené do grafu (výchozí false)"),
                ], required: ["symbol", "timeframe"])
            ) { input in try await findLevels(input, model: model) },

            AgentTool(
                name: "draw_on_chart",
                description: """
                Zakreslí do grafu tickeru (TradingView graf v aplikaci) vybrané hladiny, trendové linie a Fibonacciho \
                retracementy (z find_levels → fibonacci). \
                Hladina = vodorovná čára (zelená support, červená rezistence), trendová linie = paprsek přes dva body \
                (start a end, čas „YYYY-MM-DD HH:mm“ v UTC nebo „YYYY-MM-DD“). Tloušťka podle timeframe (1W nejsilnější, \
                4H čárkovaně). replace: true (výchozí) nejdřív smaže všechny dřívější kresby agenta u tickeru; \
                prázdné seznamy s replace: true kresby agenta jen smažou. Uživatelovy vlastní kresby zůstanou.
                """,
                inputSchema: Schema.object([
                    "symbol": Schema.string("Ticker"),
                    "levels": Schema.array("Horizontální hladiny", items: Schema.object([
                        "price": Schema.number("Cena"),
                        "kind": Schema.string("support nebo resistance", enum: ["support", "resistance"]),
                        "timeframe": Schema.string("Odkud hladina je", enum: LevelTimeframe.allCases.map(\.rawValue)),
                        "label": Schema.string("Krátká poznámka (volitelné), např. „3 dotyky“"),
                    ], required: ["price", "kind", "timeframe"])),
                    "trendlines": Schema.array("Trendové linie", items: Schema.object([
                        "kind": Schema.string("support nebo resistance", enum: ["support", "resistance"]),
                        "timeframe": Schema.string("Odkud linie je", enum: LevelTimeframe.allCases.map(\.rawValue)),
                        "start_time": Schema.string("Čas prvního bodu"),
                        "start_price": Schema.number("Cena prvního bodu"),
                        "end_time": Schema.string("Čas druhého bodu"),
                        "end_price": Schema.number("Cena druhého bodu"),
                        "label": Schema.string("Krátká poznámka (volitelné)"),
                    ], required: ["kind", "timeframe", "start_time", "start_price", "end_time", "end_price"])),
                    "fibonacci": Schema.array("Fibonacciho retracementy", items: Schema.object([
                        "timeframe": Schema.string("Odkud swing je", enum: LevelTimeframe.allCases.map(\.rawValue)),
                        "start_time": Schema.string("Počátek swingu (low u růstu, high u poklesu)"),
                        "start_price": Schema.number("Cena počátku"),
                        "end_time": Schema.string("Extrém swingu (high u růstu, low u poklesu)"),
                        "end_price": Schema.number("Cena extrému"),
                        "label": Schema.string("Krátká poznámka (volitelné)"),
                    ], required: ["timeframe", "start_time", "start_price", "end_time", "end_price"])),
                    "replace": Schema.boolean("Smazat dřívější kresby agenta (výchozí true)"),
                ], required: ["symbol"])
            ) { input in try await drawOnChart(input, model: model) },

            AgentTool(
                name: "run_options_backtest",
                description: """
                Simulovaný backtest opčních strategií: pravidlo (stejná jako v run_backtest, stejné parametry) dává směr \
                a podle situace se otevře opční strategie. selection auto: býčí signál + vysoká volatilita → bull put spread, \
                nízká → bull call spread; medvědí → bear call / bear put spread; bez signálu volitelně iron condor. \
                selection fixed: bullish_play / bearish_play. Ceny opcí z Black-Scholes (IV = HV 20 × iv_multiplier), \
                skluz a poplatky, velikost podle rizika na obchod. Vrací metriky vs. buy & hold, rozpad podle strategií a poslední obchody. \
                pricing historical použije skutečné historické kotace konce dne (od 2019); jinak jde o simulaci – uveď, která varianta běžela.
                """,
                inputSchema: Schema.object(breakoutSchema.merging([
                    "symbol": Schema.string("Ticker"),
                    "strategy": Schema.string("Pravidlo pro směr (viz run_backtest)", enum: ["breakout", "buy_and_hold"]),
                    "range": Schema.string("Období (výchozí 5y)", enum: HistoryRange.allCases.map(\.rawValue)),
                    "selection": Schema.string("auto (podle situace) nebo fixed", enum: ["auto", "fixed"]),
                    "bullish_play": Schema.string("fixed: strategie pro býčí signál", enum: OptionPlay.allCases.filter { $0.direction == 1 }.map(\.rawValue)),
                    "bearish_play": Schema.string("fixed: strategie pro medvědí signál", enum: OptionPlay.allCases.filter { $0.direction == -1 }.map(\.rawValue)),
                    "allow_bearish": Schema.boolean("Obchodovat i medvědí signály (výchozí true)"),
                    "neutral_condor": Schema.boolean("auto: iron condor bez signálu při vysoké volatilitě (výchozí false)"),
                    "days_to_expiry": Schema.integer("DTE při otevření (výchozí 35)"),
                    "short_delta": Schema.number("Delta prodávané nohy (výchozí 0.30)"),
                    "width_pct": Schema.number("Šířka spreadu v % ceny (výchozí 5)"),
                    "risk_pct": Schema.number("Max. ztráta obchodu v % kapitálu (výchozí 5)"),
                    "high_vol_rank": Schema.number("Percentil HV pro „vysokou“ volatilitu (výchozí 50)"),
                    "iv_multiplier": Schema.number("simulated: IV = HV × násobek (výchozí 1.1)"),
                    "pricing": Schema.string("simulated (Black-Scholes, rychlé) nebo historical (skutečné EOD kotace z DoltHubu od 2019, pomalejší)",
                                             enum: ["simulated", "historical"]),
                ]) { a, _ in a }, required: ["symbol", "strategy"])
            ) { input in try await optionsBacktest(input, model: model) },

            AgentTool(
                name: "run_backtest",
                description: """
                Backtest pravidla (signál ze zavírací ceny svíčky, obchod za otevírací cenu další svíčky) a srovnání \
                s buy & hold: výnos, CAGR, Sharpe, Sortino, max. drawdown, volatilita, počet obchodů, win rate, expozice. \
                Zdroj dat a interval (Yahoo 1D, nebo TradingView 1D/1W/4H/1H) určuje nastavení backtestu v aplikaci. \
                Pravidla: breakout (Breakout nad rezistenci / Breakdown pod support z konsolidace – denní graf, \
                filtr týdenního grafu; vstupy 1) těsně před průrazem absolutního vrcholu, 2) po čistém průrazu, \
                3) první pullback PNR; stop 1× ATR nebo pod předchozí svíčku, cíl Fibonacciho extenze konsolidace) \
                a buy_and_hold. Vše se v každé svíčce počítá jen z minulých dat.
                """,
                inputSchema: Schema.object(breakoutSchema.merging([
                    "symbol": Schema.string("Ticker"),
                    "strategy": Schema.string("Pravidlo", enum: ["breakout", "buy_and_hold"]),
                    "range": Schema.string("Období (výchozí 5y)", enum: HistoryRange.allCases.map(\.rawValue)),
                    "allow_short": Schema.boolean("Povolit short (breakdown) místo hotovosti (výchozí false)"),
                    "cost_bps": Schema.number("Náklady v bazických bodech na obchod (výchozí 5)"),
                ]) { a, _ in a }, required: ["symbol", "strategy"])
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

    static func optionSetups(_ input: JSONValue, model: AppModel) async -> String {
        let scanner = model.scanner
        if input["rescan"]?.boolValue == true || scanner.lastScan == nil {
            await scanner.scan(watchlist: model.watchlist, rate: model.riskFreeRate)
        }
        return output(.object([
            "scanned_at": scanner.lastScan.map { .string(day($0)) } ?? .null,
            "tickers_scanned": .number(Double(scanner.scannedCount)),
            "setups": .array(scanner.results.map { r in
                let h = r.hit
                return [
                    "symbol": .string(h.symbol),
                    "direction": .string(h.direction > 0 ? "bullish" : "bearish"),
                    "setup": .string(h.title),
                    "is_entry": .bool(h.entry != nil),
                    "bars_ago": .number(Double(h.barsAgo)),
                    "level": num(h.level),
                    "stop": num(h.stop),
                    "target": num(h.target),
                    "distance_atr": num(h.distanceATR),
                    "atr": num(h.atr),
                    "close": num(h.close),
                    "hv20": pct(h.historicalVolatility),
                    "hv_rank": num(h.volatilityRank, 0),
                    "atm_iv": pct(r.liquidity?.impliedVolatility),
                    "iv_to_hv": num(r.ivToHv),
                    "atm_open_interest": r.liquidity.map { .number(Double($0.atmOpenInterest)) } ?? .null,
                    "atm_spread_pct": pct(r.liquidity?.atmSpread),
                    "liquid": .bool(r.liquidity?.isLiquid == true),
                    "suggested_play": .string(h.suggestedPlay.name),
                ]
            }),
        ]))
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

    // MARK: - Hladiny a graf

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func parseTime(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let normalized = text.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        if let date = timeFormatter.date(from: String(normalized.prefix(16))) { return date }
        return dayFormatter.date(from: String(normalized.prefix(10)))
    }

    static func findLevels(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        guard let timeframe = input["timeframe"]?.stringValue.flatMap(LevelTimeframe.init(rawValue:)) else {
            throw ToolError("timeframe musí být 1W, 1D nebo 4H.")
        }
        let series = try await ChartAnnotations.bars(symbol: s, timeframe: timeframe, client: model.client)
        guard series.bars.count > 30 else { throw ToolError("Málo svíček (\(series.bars.count)).") }
        let maxLevels = min(max(input["max_levels"]?.intValue ?? 6, 1), 12)
        let analysis = LevelFinder.analyze(series.bars, window: timeframe.pivotWindow, maxLevels: maxLevels)
        let close = analysis.lastClose

        let levels: [JSONValue] = analysis.levels.map { level in
            [
                "price": num(level.price),
                "kind": .string(level.kind.rawValue),
                "touches": .number(Double(level.touches)),
                "strength": num(level.strength),
                "first_touch": .string(timeFormatter.string(from: level.firstTouch)),
                "last_touch": .string(timeFormatter.string(from: level.lastTouch)),
                "distance_pct": pct(level.price / close - 1),
            ]
        }
        let lines: [JSONValue] = analysis.trendLines.map { line in
            [
                "kind": .string(line.kind.rawValue),
                "direction": .string(line.isRising ? "rising" : "falling"),
                "start_time": .string(timeFormatter.string(from: line.startDate)),
                "start_price": num(line.startPrice),
                "end_time": .string(timeFormatter.string(from: line.endDate)),
                "end_price": num(line.endPrice),
                "price_now": num(line.priceNow),
                "touches": .number(Double(line.touches)),
                "strength": num(line.strength),
                "distance_pct": pct(line.priceNow / close - 1),
            ]
        }

        let swing = Fibonacci.lastSwing(series.bars, lookback: timeframe.fibLookback)
        var fib: JSONValue = .null
        if let swing {
            var retracements: [String: JSONValue] = [:]
            for r in FibonacciSwing.retracementRatios { retracements[String(r)] = num(swing.retracement(r)) }
            var extensions: [String: JSONValue] = [:]
            for e in FibonacciSwing.extensionRatios { extensions[String(e)] = num(swing.extensionLevel(e)) }
            fib = [
                "direction": .string(swing.direction.rawValue),
                "start_time": .string(timeFormatter.string(from: swing.startDate)),
                "start_price": num(swing.startPrice),
                "end_time": .string(timeFormatter.string(from: swing.endDate)),
                "end_price": num(swing.endPrice),
                "retracements": .object(retracements),
                "extensions": .object(extensions),
                "current_retracement": num((swing.endPrice - close) / (swing.endPrice - swing.startPrice), 3),
            ]
        }

        var drawn = 0
        if input["draw"]?.boolValue == true {
            var drawings: [Drawing] = analysis.levels.map {
                ChartAnnotations.level(price: $0.price, kind: $0.kind, timeframe: timeframe, note: "\($0.touches)×")
            }
            drawings += analysis.trendLines.map {
                ChartAnnotations.trendLine(kind: $0.kind, timeframe: timeframe, start: ($0.startDate, $0.startPrice),
                                           end: ($0.endDate, $0.endPrice), note: "\($0.touches)×")
            }
            if let swing { drawings.append(ChartAnnotations.fibonacci(swing, timeframe: timeframe, note: nil)) }
            ChartAnnotations.write(series.tvSymbol, adding: drawings) {
                ChartAnnotations.timeframe(of: $0) == timeframe.rawValue
            }
            drawn = drawings.count
        }

        let result: [String: JSONValue] = [
            "symbol": .string(series.tvSymbol),
            "timeframe": .string(timeframe.rawValue),
            "source": .string(series.source),
            "bars": .number(Double(series.bars.count)),
            "from": .string(timeFormatter.string(from: series.bars[0].date)),
            "to": .string(timeFormatter.string(from: series.bars[series.bars.count - 1].date)),
            "last_close": num(close),
            "atr": num(analysis.atr),
            "levels": .array(levels),
            "trendlines": .array(lines),
            "fibonacci": fib,
            "drawn": .number(Double(drawn)),
        ]
        return output(.object(result))
    }

    static func drawOnChart(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        guard let tvSymbol = await SymbolResolver.shared.resolve(s) else { throw ToolError("Ticker \(s) na TradingView nenalezen.") }
        var drawings: [Drawing] = []
        var timeframes = Set<String>()

        for (i, level) in (input["levels"]?.arrayValue ?? []).enumerated() {
            guard let price = level["price"]?.doubleValue, price > 0 else { throw ToolError("Hladina \(i + 1): chybí price.") }
            let kind: PriceLevel.Kind = level["kind"]?.stringValue == "resistance" ? .resistance : .support
            let tf = level["timeframe"]?.stringValue.flatMap(LevelTimeframe.init(rawValue:)) ?? .day
            timeframes.insert(tf.rawValue)
            drawings.append(ChartAnnotations.level(price: price, kind: kind, timeframe: tf, note: level["label"]?.stringValue))
        }
        for (i, line) in (input["trendlines"]?.arrayValue ?? []).enumerated() {
            guard let start = parseTime(line["start_time"]?.stringValue), let startPrice = line["start_price"]?.doubleValue,
                  let end = parseTime(line["end_time"]?.stringValue), let endPrice = line["end_price"]?.doubleValue else {
                throw ToolError("Trendlinie \(i + 1): chybí nebo je neplatný start/end (čas YYYY-MM-DD HH:mm).")
            }
            guard end > start else { throw ToolError("Trendlinie \(i + 1): end_time musí být po start_time.") }
            let kind: PriceLevel.Kind = line["kind"]?.stringValue == "resistance" ? .resistance : .support
            let tf = line["timeframe"]?.stringValue.flatMap(LevelTimeframe.init(rawValue:)) ?? .day
            timeframes.insert(tf.rawValue)
            drawings.append(ChartAnnotations.trendLine(kind: kind, timeframe: tf, start: (start, startPrice),
                                                       end: (end, endPrice), note: line["label"]?.stringValue))
        }

        var fibCount = 0
        for (i, f) in (input["fibonacci"]?.arrayValue ?? []).enumerated() {
            guard let start = parseTime(f["start_time"]?.stringValue), let startPrice = f["start_price"]?.doubleValue,
                  let end = parseTime(f["end_time"]?.stringValue), let endPrice = f["end_price"]?.doubleValue,
                  startPrice != endPrice else {
                throw ToolError("Fibonacci \(i + 1): chybí nebo je neplatný start/end.")
            }
            let tf = f["timeframe"]?.stringValue.flatMap(LevelTimeframe.init(rawValue:)) ?? .day
            timeframes.insert(tf.rawValue)
            let swing = FibonacciSwing(direction: endPrice > startPrice ? .up : .down, startDate: start,
                                       startPrice: startPrice, endDate: end, endPrice: endPrice)
            drawings.append(ChartAnnotations.fibonacci(swing, timeframe: tf, note: f["label"]?.stringValue))
            fibCount += 1
        }

        let replace = input["replace"]?.boolValue ?? true
        ChartAnnotations.write(tvSymbol, adding: drawings) { _ in replace }
        let result: [String: JSONValue] = [
            "symbol": .string(tvSymbol),
            "drawn_levels": .number(Double(input["levels"]?.arrayValue?.count ?? 0)),
            "drawn_trendlines": .number(Double(input["trendlines"]?.arrayValue?.count ?? 0)),
            "drawn_fibonacci": .number(Double(fibCount)),
            "timeframes": .array(timeframes.sorted().map { .string($0) }),
            "replaced_previous": .bool(replace),
            "note": "Kresby jsou v grafu tickeru (detail na záložce Trh i plný graf), uživatel je vidí v seznamu objektů.",
        ]
        return output(.object(result))
    }

    // MARK: - Backtest

    static func optionsBacktest(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        let range = input["range"]?.stringValue.flatMap(HistoryRange.init(rawValue:)) ?? .fiveYears
        let signal = try parseStrategy(input)
        let allowBearish = input["allow_bearish"]?.boolValue ?? true
        let selection: OptionSelection
        if input["selection"]?.stringValue == "fixed" {
            let bullish = input["bullish_play"]?.stringValue.flatMap(OptionPlay.init(rawValue:)) ?? .bullCallSpread
            let bearish = input["bearish_play"]?.stringValue.flatMap(OptionPlay.init(rawValue:)) ?? .bearPutSpread
            selection = .fixed(bullish: bullish, bearish: bearish)
        } else {
            selection = .auto(neutralCondor: input["neutral_condor"]?.boolValue ?? false)
        }
        let config = OptionsBacktestConfig(
            signal: signal, selection: selection, allowBearish: allowBearish,
            daysToExpiry: input["days_to_expiry"]?.intValue ?? 35,
            shortDelta: input["short_delta"]?.doubleValue ?? 0.30,
            widthPct: (input["width_pct"]?.doubleValue ?? 5) / 100,
            ivMultiplier: input["iv_multiplier"]?.doubleValue ?? 1.1,
            highVolRank: input["high_vol_rank"]?.doubleValue ?? 50,
            riskPerTrade: (input["risk_pct"]?.doubleValue ?? 5) / 100,
            riskFreeRate: model.riskFreeRate)

        let historical = input["pricing"]?.stringValue == "historical"
        let series = try await BacktestData.load(symbol: s, range: range,
                                                 source: historical ? .yahoo : .current,
                                                 interval: historical ? .day : .current, client: model.client)
        let bars = historical ? series.bars.filter { $0.date >= HistoricalOptionsData.firstDay } : series.bars
        guard bars.count > 60 else { throw ToolError("Málo dat (\(bars.count) svíček).") }
        let result: OptionsBacktestResult
        let market = await marketUp(input, strategy: signal, bars: bars, range: range, model: model)
        if historical {
            result = try await OptionsBacktest.runHistorical(bars: bars, symbol: s, config: config,
                                                             source: HistoricalOptionsData.shared, marketUp: market)
        } else {
            result = await Task.detached(priority: .userInitiated) {
                OptionsBacktest.run(bars: bars, config: config, marketUp: market)
            }.value
        }

        func metrics(_ m: BacktestMetrics) -> JSONValue {
            [
                "total_return_pct": pct(m.totalReturn), "cagr_pct": pct(m.cagr), "sharpe": num(m.sharpe),
                "max_drawdown_pct": pct(m.maxDrawdown), "trades": .number(Double(m.tradeCount)),
                "win_rate_pct": pct(m.winRate), "avg_return_on_risk_pct": pct(m.averageTrade),
                "exposure_pct": pct(m.exposure),
            ]
        }
        let plays: [JSONValue] = result.playCounts.map {
            ["play": .string($0.play.rawValue), "trades": .number(Double($0.count)), "pnl_usd": num($0.pnl, 0)]
        }
        let lastTrades: [JSONValue] = result.trades.suffix(6).map { t in
            [
                "play": .string(t.play.rawValue),
                "legs": .string(t.legsText),
                "entry": .string(day(t.entryDate)),
                "exit": t.exitDate.map { JSONValue.string(day($0)) } ?? "otevřený",
                "reason": .string(t.exitReason),
                "premium": num(t.entryPremium),
                "pnl_usd": num(t.pnl, 0),
                "return_on_risk_pct": pct(t.returnOnRisk),
                "iv_pct": pct(t.impliedVol),
                "hv_rank": num(t.volRank, 0),
            ]
        }
        let summary: [String: JSONValue] = [
            "symbol": .string(s),
            "signal_rule": .string(signal.name),
            "data": .string(series.label),
            "from": .string(day(bars[0].date)),
            "to": .string(day(bars[bars.count - 1].date)),
            "options": metrics(result.metrics),
            "buy_and_hold_underlying": metrics(result.buyAndHoldMetrics),
            "plays": .array(plays),
            "last_trades": .array(lastTrades),
            "pricing": .string(result.pricing),
            "skipped_entries": .number(Double(result.skippedEntries)),
        ]
        return output(.object(summary))
    }

    /// Parametry strategie Breakout pro schéma nástrojů.
    static let breakoutSchema: [String: JSONValue] = [
        "pre_breakout": Schema.boolean("breakout: vstup 1 – těsně před průrazem absolutního vrcholu (výchozí true)"),
        "breakout_entry": Schema.boolean("breakout: vstup 2 – po čistém průrazu (výchozí true)"),
        "pullback": Schema.boolean("breakout: vstup 3 – první pullback PNR (výchozí true)"),
        "lookback": Schema.integer("breakout: konsolidace z N svíček (výchozí 120)"),
        "min_touches": Schema.integer("breakout: min. dotyků hladiny (výchozí 2)"),
        "tolerance_pct": Schema.number("breakout: tolerance dotyku v % (výchozí 1)"),
        "weekly_filter": Schema.boolean("breakout: týdenní KP 10/20/40 seřazeny + PSAR ve směru (výchozí true)"),
        "daily_filter": Schema.boolean("breakout: denní SMA 20/50/100 seřazeny + PSAR ve směru (výchozí true)"),
        "ma_cross": Schema.boolean("breakout: v konsolidaci se SMA 20 a 50 kříží (výchozí true)"),
        "market_filter": Schema.boolean("breakout: SPY nad SMA 200 pro long, pod pro short (výchozí true)"),
        "headroom_atr": Schema.number("breakout: min. volno k další hladině v ATR (výchozí 2)"),
        "stop_atr": Schema.number("breakout: stop v ATR (výchozí 1)"),
        "target_fib": Schema.number("breakout: cíl jako Fibonacciho extenze konsolidace (1.272 nebo 1.618)"),
        "pullback_bars": Schema.integer("breakout: pullback do N svíček po průrazu (výchozí 20)"),
    ]

    static func parseStrategy(_ input: JSONValue) throws -> BacktestStrategy {
        switch input["strategy"]?.stringValue {
        case "breakout", nil:
            var settings = BreakoutSettings()
            if let v = input["pre_breakout"]?.boolValue { settings.preBreakout = v }
            if let v = input["breakout_entry"]?.boolValue { settings.breakout = v }
            if let v = input["pullback"]?.boolValue { settings.pullback = v }
            if let v = input["lookback"]?.intValue { settings.lookback = max(20, v) }
            if let v = input["min_touches"]?.intValue { settings.minTouches = max(1, v) }
            if let v = input["tolerance_pct"]?.doubleValue { settings.tolerance = v / 100 }
            if let v = input["weekly_filter"]?.boolValue { settings.weeklyFilter = v }
            if let v = input["daily_filter"]?.boolValue { settings.dailyFilter = v }
            if let v = input["ma_cross"]?.boolValue { settings.requireMACross = v }
            if let v = input["headroom_atr"]?.doubleValue { settings.headroomATR = v }
            if let v = input["stop_atr"]?.doubleValue { settings.stopATR = v }
            if let v = input["target_fib"]?.doubleValue { settings.targetFib = v }
            if let v = input["pullback_bars"]?.intValue { settings.pullbackBars = max(1, v) }
            return .breakout(settings)
        case "buy_and_hold":
            return .buyAndHold
        default:
            throw ToolError("Neznámé pravidlo. Použij breakout nebo buy_and_hold.")
        }
    }

    /// Trend trhu (SPY nad / pod SMA 200) pro filtr breakoutů; `nil`, když se nepoužije.
    static func marketUp(_ input: JSONValue, strategy: BacktestStrategy, bars: [BacktestBar], range: HistoryRange,
                         model: AppModel) async -> [Bool?]? {
        guard case .breakout = strategy, input["market_filter"]?.boolValue ?? true,
              let spy = try? await BacktestData.load(symbol: "SPY", range: range, source: .yahoo, interval: .day,
                                                     client: model.client) else { return nil }
        return BreakoutStrategy.marketTrend(spy.bars, for: bars)
    }

    static func backtest(_ input: JSONValue, model: AppModel) async throws -> String {
        let s = try symbol(input)
        let range = input["range"]?.stringValue.flatMap(HistoryRange.init(rawValue:)) ?? .fiveYears
        let strategy = try parseStrategy(input)

        let series = try await BacktestData.load(symbol: s, range: range, client: model.client)
        let bars = series.bars
        guard bars.count > 30 else { throw ToolError("Málo dat pro backtest (\(bars.count) svíček).") }
        let config = BacktestConfig(strategy: strategy, allowShort: input["allow_short"]?.boolValue ?? false,
                                    costBps: input["cost_bps"]?.doubleValue ?? 5, riskFreeRate: model.riskFreeRate)
        let market = await marketUp(input, strategy: strategy, bars: bars, range: range, model: model)
        let result = await Task.detached(priority: .userInitiated) {
            BacktestEngine.run(bars: bars, config: config, marketUp: market)
        }.value

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
            "rule": .string(config.title),
            "data": .string(series.label),
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
