# TradeLab – konvence pro Claude

- Osobní iOS aplikace pro průzkum US akcií a opcí, inspirovaná HKUDS/Vibe-Trading. Běží čistě na iPhonu.
- Komunikace, UI, README a `ZMENY.md` česky. Každá verze dostane záznam v `ZMENY.md`.
- iOS 26+ (Liquid Glass: `glassEffect`, `.glass`/`.glassProminent` – jen na ovládací vrstvě, data neprůhledná), SwiftUI, `@Observable`, Swift Charts, `SWIFT_VERSION 5.0`. Projekt generuje XcodeGen z `project.yml`.
- Logika a síť patří do `Packages/TradeCore` (`OptionsMath`, `MarketData`, `Backtest`, `ClaudeAgent`), musí jít otestovat přes `swift test`.
- Data: neoficiální Yahoo Finance (chart, search, options s crumbem). Zdroj dat držet za rozhraním, ať jde vyměnit.
- CI: `.github/workflows/build.yml` → testy jádra, pak unsigned IPA artefakt. Chyby jdou do anotací; Claude po pushi kontroluje běh sám přes GitHub REST API (`/actions/runs`, `/check-runs/<job>/annotations`).
- `TradeLab/TVChart/` je kopie zdrojů z projektu TVChart-iOS (bez `TVChartApp.swift`, `ContentView` → `TVChartScreen(initialSymbol:)`). Při úpravách grafu držet kompatibilitu s původním projektem (přidáno: `indicatorsEnabled`, `priceLines`, `persistsSession` ve `ChartViewModel`, `drawPriceLines` v rendereru); data jdou přes neoficiální websocket TradingView.
- Agent: `ClaudeAgent` – kanonický formát je Claude Messages API (`anthropic-version: 2023-06-01`, `tool_choice` jen `auto`); `OpenAITransport` (Responses API, `store: false`) a `GeminiTransport` (generateContent v1beta) převádějí tam a zpět, surová data poskytovatele drží skrytý blok `_provider`, nástroje v `TradeLab/Agent/AgentTools.swift`. API klíč jen v Keychainu, nikdy v repu (repo je veřejné).
- Plán: ~~backtester~~ → ~~agent nad Claude API~~ → multi-agentní presety → volitelný Mac server s Vibe-Trading.
