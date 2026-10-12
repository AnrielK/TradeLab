# Změny

## 0.2.3 – 2026-10-12

- Kompaktnější tabulka: nižší řádky expirací i striků, menší písmo, IV a ±1σ na jednom řádku.
- Delta pod bidem a open interest pod askem přes celou šířku pole bid–ask.
- Rámeček vybrané nohy obepíná i strike.
- Payoff se při tažení nechvěje: graf má přednost před scrollováním stránky a osa Y je během tažení zafixovaná.

## 0.2.2 – 2026-10-12

- Vzhled tabulky jako v brokerské aplikaci: záložky TABULKA / PAYOFF, šedá lišta sloupců,
  modré řádky expirací (měsíční světlejší) s dny ve středovém sloupci, ceny barevně podle denní změny,
  čára ITM a 1 SD s popisky, vybrané nohy s barevným blokem a rámečkem.
- Ozubené kolo: zapnutí/vypnutí delty a open interestu v řetězci.
- Nový tiket: „Koupit/Prodat k otevření … DB/CR @ mid“, bid–mid–ask, nohy BTO/STO, tlačítko Payoff, lze sbalit.
- Payoff: hodnota break-even v grafu i pod statistikami, průhlednější zóny, štítky blízkých striků ve dvou řadách.

## 0.2.1 – 2026-10-12

- Přehled expirací v pevných sloupcích (datum, dny, IV/±1σ), souhrn se dotahuje i pro vzdálené expirace.
- Řetězec ukazuje u každého callu a putu deltu a open interest.
- Payoff: texty už se nepřekrývají s grafem, štítky striků jsou nahoře a dají se tažením posunout
  na jiný strike (noha se přecení z řetězce). Funguje i na záložce Strategie.

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
