# Změny

## 0.4.0 – 2026-10-12

- Liquid Glass (iOS 26+, minimální verze zvýšena z iOS 17): tiket, přepínač Tabulka/Payoff, tlačítko Strategie
  a nastavení, panely a tlačítka payoffu, štítky striků v grafu, tlačítka v detailu a kalkulačce.
- Tab bar se při scrollování dolů zmenší, měkký okraj scrollu pod hlavičkou tabulky.
- Datové tabulky zůstávají neprůhledné kvůli čitelnosti.

## 0.3.2 – 2026-10-12

- Tažení nohy v tabulce jako v tastytrade: noha se přesouvá živě (rámeček, tiket i ceny sledují prst),
  přes střed na call ↔ put, vytažením ven ze strany tabulky se noha smaže.
- ITM u putů pod čarou, kapka spotu špičkou na stupnici.

## 0.3.1 – 2026-10-12

- Vybranou nohu v tabulce jde táhnout za barevný blok: nahoru/dolů na jiný strike, do strany přes střed na call ↔ put
  (během tažení ukazuje cílový kontrakt).
- Menší žluté popisky ITM se šipkami, aktuální cena jako kapka na stupnici striků.
- Menší písmo v tabulce i v payoffu.
- Vyhledávání tickeru na záložce Opce nahrazeno tlačítkem „Strategie ▾“ (ticker se vybírá na záložce Trh).

## 0.3.0 – 2026-10-12

- Záložka Strategie zrušena, šablony jsou v Opcích (tlačítko „Strategie ▾“). Staví se z reálného řetězce
  rozbalené expirace (jinak ~30 dní): striky existujících kontraktů, ceny bid/ask/mid a IV z trhu.
- Staré uložené nohy bez expirace se při spuštění zahodí.
- Otevření tickeru na záložce Trh ho rovnou nastaví i pro Opce.
- Expirace s vybranými nohami jsou v přehledu zvýrazněné (žlutý proužek a počet nohou).
- Nižší řádky expirací, stupnice ve sloupci striků a značka aktuální ceny na čáře ITM.
- V payoffu jde nohu odebrat křížkem.

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
