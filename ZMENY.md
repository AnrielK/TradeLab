# Změny

## 0.1.0 – 2026-10-12

- Založení projektu (XcodeGen, SwiftUI, iOS 17) a Swift package `TradeCore`.
- `OptionsMath`: Black-Scholes s dividendovým výnosem, Greeks, IV solver (Newton + bisekce),
  realizovaná volatilita, model strategie (P/L, Greeks pozice, max. zisk/ztráta, break-even,
  pravděpodobnost zisku), 10 šablon strategií.
- `MarketData`: Yahoo Finance klient – graf, vyhledávání, opční řetězec s automatickým crumbem, sazba z ^IRX.
- UI: Trh, detail tickeru s grafem, opční řetězec, builder strategie s payoff grafem, kalkulačka.
- CI: testy jádra + unsigned IPA na GitHub Actions.
