# TradeLab

Osobní iOS aplikace (SwiftUI, iOS 26+, Liquid Glass) pro průzkum US akcií a opcí. Inspirováno projektem
[Vibe-Trading](https://github.com/HKUDS/Vibe-Trading) – tahle verze běží čistě na iPhonu, bez serveru.

## Co umí (v0.1)

- **Trh** – sledované tickery, vyhledávání, graf ceny (1M–5R), výnos, max. propad, historická volatilita 20D/60D.
- **Opce** – opční řetězec z Yahoo (expirace, cally/puty, bid/ask, IV a delta dopočtené z mid ceny, OI).
  Klepnutím na kontrakt se přidá do strategie jako long/short noha.
- **Strategie** (v záložce Opce) – šablony (spready, straddle, strangle, iron condor, butterfly, covered call…) postavené z reálného řetězce,
  graf P/L při expiraci i „dnes / za N dní“ s posunem IV, max. zisk/ztráta, break-even,
  pravděpodobnost zisku, Greeks celé pozice.
- **Graf TradingView** – převzatý TVChart (real-time data, indikátory, kreslení) na celou obrazovku.
- **Backtest** – SMA/MACD/RSI/buy & hold na denních datech, metriky, křivka kapitálu vs. SPY, drawdown, obchody.
- **Agent** – chat s Claude (vlastní Anthropic API klíč v Keychainu), který si sám volá nástroje aplikace:
  ceny, statistiky historie, opční řetězce, ocenění, analýzu strategií z reálných kontraktů a backtest.
- **Kalkulačka** – Black-Scholes cena + Greeks, výpočet implikované volatility z tržní ceny.
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

Lokálně:

```bash
brew install xcodegen
xcodegen generate
open TradeLab.xcodeproj
```

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
4. Multi-agentní týmy (investiční výbor, opční desk) jako konfigurovatelné presety
5. Volitelně: Mac server s Vibe-Trading (Alpha Zoo, Shadow Account)
