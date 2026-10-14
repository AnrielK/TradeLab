# TradeLab

Osobní iOS aplikace (SwiftUI, iOS 26+, Liquid Glass) pro průzkum US akcií a opcí. Inspirováno projektem
[Vibe-Trading](https://github.com/HKUDS/Vibe-Trading) – tahle verze běží čistě na iPhonu, bez serveru.

## Co umí (v0.1)

- **Trh** – sledované tickery, vyhledávání, graf ceny (1M–5R), výnos, max. propad, historická volatilita 20D/60D.
- **Opce** – opční řetězec z Yahoo (expirace, cally/puty, bid/ask, IV a delta dopočtené z mid ceny, OI).
  Klepnutím na kontrakt se přidá do strategie jako long/short noha.
- **Strategie** (v záložce Opce) – šablony (spready, straddle, strangle, iron condor, butterfly, covered call…) postavené z reálného řetězce,
  graf P/L při expiraci i „dnes / za N dní“ s posunem IV, max. zisk/ztráta, break-even,
  pravděpodobnost zisku, Greeks celé pozice; panel „Hodnoty v bodě“ (teoretická hodnota a P/L nohou, greeks pro vybranou cenu, den a IV).
- **Graf TradingView** – převzatý TVChart (real-time data, indikátory, kreslení) na celou obrazovku.
- **Watchlist setupů** – skener strategií Breakout/Breakdown, Odraz od KP a Trendlinie (včetně hledání trojúhelníků) na likvidních akciích: čerstvé vstupy i kandidáti v konsolidaci těsně u hladiny, s hladinou, stopem, cílem a návrhem spreadu podle volatility a likvidity opcí.
- **Demo účet** – virtuálních 10 000 USD, strategie obchodují naživo na denních svíčkách (vstupy ze skeneru, stop a cíl strategie, velikost podle rizika).
- **Backtest** – strategie Trendlinie a trojúhelník (průraz trojúhelníku, odraz od / průraz trendline), Odraz od klouzavých průměrů 20/50/100/200 (reverzní svíčkový pattern, ATR stop, Fibonacci cíl 1,5–3 R) a Breakout/Breakdown (3 vstupy: těsně před průrazem, po průrazu, pullback PNR; filtr týdenního grafu, denních KP a PSAR; stop ATR, cíl Fibonacci) a buy & hold na datech z Yahoo nebo TradingView (1D–1H), metriky, křivka kapitálu vs. SPY, drawdown, obchody. Export strategie jako Python skript pro QuantConnect (free plán, copy & paste).
- **Agent** – chat s Claude, ChatGPT nebo Gemini (vlastní API klíč v Keychainu), který si sám volá nástroje aplikace:
  ceny, statistiky historie, opční řetězce, ocenění, analýzu strategií z reálných kontraktů a backtest.
- **Týmy agentů** – investiční výbor, opční desk, kontrola pozice a přehled watchlistu: role ve fázích, závěrečný verdikt.
- Bezriziková sazba se načítá z 13týdenních T-bills (`^IRX`).

## Struktura

```
project.yml                 XcodeGen definice projektu
TradeLab/                   SwiftUI aplikace
  App/                      vstupní bod, AppModel (stav aplikace)
  Market/  Options/  Strategy/  Calculator/  Shared/
Packages/TradeCore/         Swift package (testovatelný bez simulátoru)
  Sources/OptionsMath/      Black-Scholes, Greeks, IV solver, strategie, šablony, volatilita
  Sources/MarketData/       Yahoo Finance klient (chart, search, options + crumb), parser, modely
  Tests/                    unit testy + JSON fixtures
.github/workflows/build.yml CI: swift test → xcodebuild → unsigned IPA artefakt
CLAUDE.md                   konvence projektu pro další sezení
```

## Build

`TradeLab.xcodeproj` je v repu – stačí naklonovat a otevřít v Xcode:

```bash
open TradeLab.xcodeproj
```

Projekt se generuje z `project.yml` (XcodeGen). Po pushi na `main` ho CI přegeneruje a změny commitne samo.
Při úpravě `project.yml` nebo přidání souborů lokálně: `brew install xcodegen && xcodegen generate`.

Testy jádra: `swift test --package-path Packages/TradeCore`

GitHub Actions při každém pushi na `main` spustí testy a sestaví `TradeLab-unsigned.ipa`
(artefakt `TradeLab-unsigned-ipa`) pro sideload (AltStore / Sideloadly / vlastní podpis).

## Známá omezení

- Yahoo Finance je **neoficiální** API. Opční řetězce vyžadují cookie + crumb, klient je získává automaticky
  (`fc.yahoo.com` → `getcrumb`). Pokud Yahoo v EU vynutí souhlas s cookies, načítání opcí selže s hláškou o crumbu.
  Zdroj dat je oddělený v `MarketData`, takže jde později doplnit Tradier / Polygon apod.
- Mimo obchodní hodiny bývá bid/ask 0 – pak se použije poslední cena a IV od Yahoo.
- Model je evropský Black-Scholes (americké puty a dividendy jen přibližně).
- Pouze pro výzkum a učení, ne investiční doporučení.

## Plán

1. ~~Datová vrstva + opční modul~~
2. ~~Backtester~~ (vektorový engine, SMA/MACD/RSI, Sharpe, drawdown, porovnání se SPY)
3. ~~Agent nad Claude API~~ (tool use nad moduly výše)
4. ~~Multi-agentní týmy~~ (investiční výbor, opční desk, kontrola pozice, přehled watchlistu)
5. Volitelně: Mac server s Vibe-Trading (Alpha Zoo, Shadow Account)
