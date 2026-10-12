# Změny

## 0.2.0 – 2026-10-12

- Opce ve stylu brokerské tabulky: rozbalovací expirace (dny, týdenní „W“, ATM IV, ±1σ pohyb),
  řetězec cally | strike | puty, čára spotu a 1σ hranic, klepnutím na bid prodáš, na ask koupíš.
- Tiket: název strategie (vertical, iron condor, calendar…), net bid/mid/ask, nohy.
- Záložka Payoff: interaktivní graf (tažením P/L pro cenu, zelená/červená zóna, 1σ pásmo, striky),
  POP, extrinsic, max. zisk/ztráta, posun striků, šířky, počtu a expirace, posun v čase a IV.
- Jádro: `NetQuote`, `extrinsicValue`, `shiftingStrikes`, `changingWidth`, `withSpreadCount`,
  `StrategyClassifier`, `ExpirationSummary`, přecenění nohou z řetězce.

## 0.1.1 – 2026-10-12

- CI: chyby kompilátoru a testů se převádějí na GitHub anotace (`.github/scripts/annotate.sh`), `actions/checkout@v5`.
- Test implikované volatility ověřuje zpětné ocenění; σ porovnává jen u opcí s nenulovou vegou.

## 0.1.0 – 2026-10-12

- Založení projektu (XcodeGen, SwiftUI, iOS 17) a Swift package `TradeCore`.
- `OptionsMath`: Black-Scholes s dividendovým výnosem, Greeks, IV solver (Newton + bisekce),
  realizovaná volatilita, model strategie (P/L, Greeks pozice, max. zisk/ztráta, break-even,
  pravděpodobnost zisku), 10 šablon strategií.
- `MarketData`: Yahoo Finance klient – graf, vyhledávání, opční řetězec s automatickým crumbem, sazba z ^IRX.
- UI: Trh, detail tickeru s grafem, opční řetězec, builder strategie s payoff grafem, kalkulačka.
- CI: testy jádra + unsigned IPA na GitHub Actions.
