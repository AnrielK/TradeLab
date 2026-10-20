# Změny

## 0.26.0 – 2026-10-20

- **OI úrovně v grafu**: call wall (zelená), put wall (červená), gamma flip (žlutá) a max pain (modrá) se kreslí
  jako čáry do grafu z Opce → Graf, do grafu v detailu tickeru i do jeho zvětšené verze – vždy jen pro ticker,
  pro který je profil načtený v Opce → OI, a podle zvoleného vážení. Čáry nemění svislé měřítko, takže
  vzdálené úrovně graf nezmačkají. Zapíná / vypíná se přepínačem „Úrovně v grafu“ v režimu OI.
- Režim OI má sekci „Jak to použít“ (kladné / záporné GEX, walls jako support a odpor, max pain).
- TVChart: `ChartPriceLine.fitsInScale` a parametr `priceLines` v `TVChartScreen`.

## 0.25.0 – 2026-10-20

- **Opce → OI**: nový režim vedle Tabulky a Payoffu. Sečte open interest všech expirací do 30 / 60 / 100 dní
  (načítá se po 3 expiracích najednou, cache 15 minut, stažením dolů znovu) a ukáže:
  **call wall** (největší call OI nad cenou), **put wall** (největší put OI pod cenou), **gamma flip**
  (cena, kde celkové GEX mění znaménko) a **max pain** nejbližší měsíční expirace; graf po strikech
  (cally doprava, puty doleva) v pásmu ±10 / 15 / 25 % kolem ceny, 8 největších úrovní a put/call poměr.
- Vážení: prosté OI, OI/√DTE (bližší expirace mají větší váhu) nebo GEX – gamma exposure v USD na 1% pohyb
  (předpokládá dealery long cally a short puty).
- Agent: nový nástroj `get_open_interest_levels`; v Opčním desku ho používá analytik směru.
- Jádro: `OpenInterestProfile`, `OptionChain.maxPain` a `YahooFinanceClient.optionChains(symbol:maxDays:)` v `MarketData` s testy.

## 0.24.1 – 2026-10-14

- Demo účet: oprava – otevřené pozice se zobrazovaly jako jeden řádek a swipe ukázal tlačítka „Zavřít“
  vedle sebe pro všechny pozice najednou. Teď má každá pozice vlastní řádek a vlastní swipe.
- Klepnutí na pozici otevře její detail: zisk / ztráta, graf s čarami vstupu, stopu a cíle, vstup, aktuální
  cena, hodnota, riziko, R:R, úprava stopu a cíle, zavření za aktuální cenu a odkaz na detail tickeru.

## 0.24.0 – 2026-10-14

- **Demo účet** (nová záložka Demo): virtuálních 10 000 USD pro živé testování strategií.
  Při otevření záložky, návratu do aplikace (nejvýš jednou za 15 minut) nebo stažením dolů se pozice
  přecení aktuální cenou a zavřou na stopu / cíli strategie; pak se projdou tickery skeneru a čerstvé vstupy
  Breakoutu, Odrazu od KP a Trendlinie (z uzavřených denních svíček, nejvýš 2 svíčky staré) se otevřou za
  aktuální cenu se stopem a cílem strategie. Velikost pozice podle rizika ke stopu (1 % účtu, nejvýš 20 %
  účtu na pozici, nejvýš 8 pozic), long i short, každý signál jen jednou. Ručně: swipe „Demo“ u řádku
  watchlistu setupů, zavření swipem u pozice. Přehled účtu, otevřené pozice, události a historie; reset účtu.
- Obchody z backtestu se kreslí jen do grafu backtestu (vlastní úložiště) – už nejsou vidět v detailu
  tickeru ani v běžném grafu; staré kresby se při dalším backtestu uklidí.
- Backtest převezme vybraný ticker: otevřený detail na Trhu nebo ticker z Opcí. Když není vybraný žádný,
  pole tickeru je prázdné.

## 0.23.1 – 2026-10-14

- **Graf obchodů v Backtestu** má vlastní období: historie o 10 % delší než backtest (celé období je vidět
  hned) a přepínač svíček 1D / 1W přímo nad grafem (u období do ~2 let i 4H), bez otevírání velkého grafu.
  Na víc než 3 roky se otevře na týdenních svíčkách.
- Ke každému obchodu se kreslí, co se obchoduje: u Breakoutu obě hladiny konsolidace (rezistence i support),
  u Trendlinie trendline nebo obě linie trojúhelníku, u Odrazu od KP průměr. Hladiny a linie pokračují až
  do výstupu z obchodu.

## 0.23.0 – 2026-10-14

- **Opce: každý signál jen jednou.** Po zavření opční pozice (výstup strategie, 7 dní před expirací,
  u vlastního výstupu i cíl nebo stop na prémii) se do trvajícího signálu znovu nevstupuje – další obchod
  až při novém vstupu strategie. Přerolování před expirací je volitelné (výchozí vypnuto).
- **Graf obchodů v Backtestu**: pod výsledky je graf TVChart s obchody – zelená zóna vstup → cíl,
  červená vstup → stop, čárkovaná cesta k výstupu, ▲/▼ otevření s typem vstupu a ✕ zavření s výsledkem;
  ke každému vstupu linie strategie (hladina konsolidace, trendline / trojúhelník, průměr). Funguje pro akcie
  i opce, kresby jsou i ve velkém grafu a další backtest je nahradí (ruční kresby zůstanou). Ceny upravené
  o dividendy se pro graf přepočtou, aby seděly na svíčky. Přepínač „Zakreslit obchody do grafu“.

## 0.22.1 – 2026-10-14

- **Opční backtest kopíruje obchody strategie.** Dřív měl jiný počet obchodů než akciový:
  signál se počítal vždy i se shorty (short obsadil strategii a zablokoval další long, i když byly medvědí
  strategie vypnuté), po vlastním cíli nebo stopu na prémii se pozice znovu otevřela, dokud signál trval,
  a opce měly vlastní cíl a stop místo stopu a cíle strategie.
- Nově (výchozí „Výstup podle strategie“): opce se otevře při vstupu strategie a zavře při jejím výstupu,
  stejně jako akcie; když se blíží expirace a obchod trvá, pozice se přeroluje (v seznamu označeno).
  Pod výsledkem je počet obchodů strategie a přerolování. Původní výstup na prémii jde zapnout,
  ani pak se ale znovu nevstupuje bez nového signálu.
- Výnos opcí se od akcií dál liší: opční obchod riskuje jen 5 % kapitálu, akcie obchodují celým kapitálem,
  a spready mají omezený zisk a časový rozpad.
- Totéž v historickém opčním backtestu, u agenta (`follow_strategy`) i v exportu do QuantConnectu.

## 0.22.0 – 2026-10-14

- **Strategie v grafu**: detail tickeru sám zakreslí do grafu, co strategie vidí – u Breakoutu rezistenci
  a support konsolidace, u Trendlinie trojúhelník (obě linie) nebo rostoucí supportní / klesající
  rezistenční trendline, u Odrazu od KP průměr, od kterého se cena odráží. U otevřeného vstupu přidá
  čáry vstupu, stopu a cíle a pod grafem ukáže vstup, stop, cíl a R:R.
- Volba „Zakreslit“ pod grafem: Automaticky (strategie z watchlistu setupů, jinak trendlinie), Breakout,
  Odraz od KP, Trendlinie nebo Nezakreslovat. Kresby jsou vidět i ve velkém grafu na všech intervalech
  a při změně se nahradí; nastavení strategií se bere ze skeneru.

## 0.21.0 – 2026-10-14

- Nová strategie **Trendlinie a trojúhelník** (long i short) se třemi vstupy:
  - **průraz trojúhelníku** – klesající / plochá rezistence a rostoucí / plochý support přes potvrzené swingy
    (aspoň 2 dotyky, zavírací ceny je nepřekročí) se sbíhají; čistá svíčka za linií hned nebo druhý den,
    cíl výška trojúhelníku od linie (aspoň 1,5× ATR), stop 1× ATR nebo za předchozí svíčku;
  - **průraz trendline** – zavření nad klesající rezistenční linií (pod rostoucí supportní), cíl Fibonacciho
    extenze od první kotvy linie, aspoň 1,5 R;
  - **odraz od trendline** – reverzní pattern (2svíčkový nebo pinbar) na rostoucí (klesající) linii jako u odrazu
    od KP, stop za reverzní svíčku aspoň 1× ATR, cíl Fibonacci v 1,5–3 R, žádná rezistence před cílem.
  - Filtry jako u předchozích strategií: týdenní KP 10/20/40 + PSAR ve směru, denní SMA 50 > 100 > 200.
- **Skener** hledá i trojúhelníky: ticker uvnitř sbíhajícího se trojúhelníku je kandidát „Trojúhelník“
  (s hladinou průrazu a vzdáleností v ATR), cena u trendline „Test trendline“, čerstvé vstupy s typem vstupu.
- Strategie je v Backtestu (akcie i opce), u agenta (`trendline`) i v exportu do QuantConnectu.

## 0.20.0 – 2026-10-14

- Nová strategie **Odraz od klouzavých průměrů** (SMA 20/50/100/200, long i short) podle prezentace:
  - reverzní svíčka má tělo nad průměrem a spodní stín skrz něj; je buď níž než předchozí dvě svíčky
    (2svíčkový pattern), nebo pinbar (1svíčkový); potvrzující svíčka je býčí, má vyšší dno a zavře nad
    reverzní svíčkou – vstup na jejím zavření;
  - 20 a 50 MA: KP 20 > 50 > 100 > 200, 100 MA: 50 > 100 > 200, 200 MA: 100 > 200;
  - průměr testovaný už dřív (60 svíček), u 20 MA týdenní cena nad 10 MA a týdenní KP rostou,
    u 50 MA stochastic (21, 3) pod 30, žádná rezistence mezi swingem pullbacku a cílem;
  - stop pod reverzní svíčku, aspoň 1× ATR; cíl Fibonacciho extenze pullbacku 161,8 % (nebo 127,2 %),
    omezená na 1,5–3 R. Short zrcadlově.
- Strategie je v Backtestu (akcie i opce), ve skeneru na Trhu (vstupy „Odraz od KP 50“ i kandidáti „Test KP 50“,
  kteří se v trendu vrací k průměru), u agenta (`ma_bounce`) i v exportu do QuantConnectu.
- Skener hledá obě strategie (dají se vypnout) a u každého tickeru ukáže lepší setup.

## 0.19.1 – 2026-10-13

- Breakout / Breakdown: odstraněna podmínka trhu (SPY nad / pod SMA 200) – v backtestu, skeneru, agentovi
  i v exportu do QuantConnectu.

## 0.19.0 – 2026-10-13

- **Strategie od začátku**: všechny dosavadní strategie (SMA, MACD, RSI, break & retest, reversal, odrazy
  a průrazy S/R a trendlinií, swing pullback, Fibonacciho výstup) jsou pryč. Zůstává buy & hold jako srovnání
  a nová **Breakout / Breakdown** podle prezentace:
  - konsolidace (boční trend): hladina z posledních 120 svíček s aspoň 2 swingovými dotyky, KP 20 × 50 se v ní kříží;
  - týdenní graf v trendu (KP 10/20/40 seřazeny, PSAR ve směru), denní KP 20/50/100 seřazeny a PSAR ve směru,
    daleko od další hladiny (aspoň 2× ATR, nebo nový vrchol);
  - 3 vstupy: **těsně před breakoutem** (jen u absolutního vrcholu, do 1× ATR pod ním), **po breakoutu**
    (celá svíčka otevřela i zavřela nad hladinou, případně druhý den), **první pullback PNR** (návrat k prorazené
    hladině do 20 svíček, zavření nad ní býčí / obratovou svíčkou);
  - stop 1× ATR nebo pod předchozí svíčku (vzdálenější), cíl Fibonacciho extenze konsolidace 127,2 / 161,8 %
    (aspoň 1,5× ATR). Breakdown je zrcadlově.
- Backtest (akcie i opce), skener, agent i export do QuantConnectu používají novou strategii; Python verze
  pro QuantConnect je ověřená proti testům jádra.
- **Watchlist breakoutů** na Trhu: čerstvé vstupy s hladinou, stopem a cílem + kandidáti v konsolidaci těsně
  u hladiny (do 1,5× ATR), kteří čekají na průraz. Text „nelikvidní“ je pod výstražným trojúhelníkem.

## 0.18.0 – 2026-10-13

- **Watchlist opčních setupů** na Trhu pod Sledovanými: skener projde Sledované + ~65 likvidních US akcií
  a ETF (nebo jen Sledované / vlastní seznam) na denních svíčkách a hledá čerstvé vzory – break & retest,
  odraz a průraz S/R i trendlinie, odraz od EMA 20, swing pullback, reversal RSI. U každého tickeru směr,
  vzory, stáří signálu, souhlas s trendem SMA 200, percentil HV, IV/HV a likvidita ATM opcí (OI, spread).
- Navržená strategie podle volatility: vysoká → kreditní spread, nízká → debetní. Swipe „Opce“ sestaví
  spread z reálných kontraktů (short ~30Δ, šířka ~5 %, striky s OI ≥ 1 000) a otevře ho v payoffu;
  swipe doleva přidá ticker do Sledovaných.
- Sken se spustí sám, když je starší než den; nastavení (vzory, stáří signálu, medvědí setupy, hranice
  volatility, expirace, skrytí nelikvidních) pod ikonou posuvníků.
- Agent má nástroj `get_option_setups` a tým „Přehled watchlistu“ ho používá.

## 0.17.0 – 2026-10-13

- **Export pro QuantConnect** v Backtestu: tlačítko vygeneruje Python skript (LEAN) s aktuálním tickerem,
  obdobím, strategií, Fib výstupem a u opcí i s nastavením výběru spreadů. Skript jde zkopírovat nebo
  sdílet jako `.py`, vloží se do `main.py` ve webovém editoru QuantConnectu (stačí free plán) a backtest
  poběží na jejich datech – u opcí skutečné minutové kotace od 2012. Výsledky zůstávají v QuantConnectu
  (free plán nemá API, takže se nevracejí do aplikace).
- Signály strategií jsou přeportované do Pythonu a ověřené proti Swift testům.
- Skóre trendových linií nezávisí na délce celé řady (stejný výsledek při výpočtu po svíčkách).

## 0.16.1 – 2026-10-13

- Tlačítko agenta i v detailu tickeru.

## 0.16.0 – 2026-10-13

- **Agent** už není záložka: kulaté tlačítko ✦ vpravo nahoře na Trhu, Opcích i v Backtestu ho otevře jako
  vysouvací okno přes aktuální obrazovku. „Otevřít v Opcích“ okno zavře a přepne na Opce.
- Trh: tlačítko Upravit je vlevo.

## 0.15.2 – 2026-10-13

- Oprava: po výběru jiného tickeru payoff ukazoval nohy předchozího tickeru. Strategie se teď pamatují
  zvlášť pro každý ticker – po přepnutí se načte strategie nového tickeru (nebo prázdná) a po návratu
  se původní vrátí.

## 0.15.1 – 2026-10-13

- Spodní lišta se při scrollování už nezmenšuje.
- Payoff: kotace bid/mid/ask, úpravy (striky, šířka, počet, expirace) a hodnoty v bodě jsou ve výsuvném panelu
  dole – stejně jako tiket v tabulce. Graf, statistiky, posuvníky a nohy zůstávají nahoře; stav panelu si aplikace pamatuje.

## 0.15.0 – 2026-10-13

- Záložka **Kalkulačka** odebrána – výpočty jsou v payoffu v novém panelu **Hodnoty v bodě**:
  pro cenu vybranou posunem prstu po grafu (nebo ±1 %, návrat na aktuální) a zvolený posun v čase a IV
  ukáže vstupní a teoretickou hodnotu každé nohy, její P/L, P/L pozice ve scénáři i při expiraci
  a greeks pozice (Δ v akciích, Γ, Θ za den, vega za 1 p. b.).

## 0.14.2 – 2026-10-13

- Rychlejší historický opční backtest: na vstup jeden dotaz (celý řetězec tickeru pro daný den, výběr expirace
  a striků v telefonu), historie pozice jedním dotazem (po 25 dnech), IV rank souběžně (4 dotazy najednou).
  Zhruba 2 dotazy na obchod místo ~5.

## 0.14.1 – 2026-10-13

- Oprava historického opčního backtestu („context deadline exceeded“): dotazy na DoltHub jdou přes konkrétní dny
  (`date =` / `date IN`) podle primárního klíče místo rozsahů dat, historie pozice po 10 dnech, IV rank jednou týdně.
- Výpadek jednoho dotazu už neshodí celý běh – vstup se vynechá a započítá do „vynechaných vstupů“.

## 0.14.0 – 2026-10-13

- Opční backtest umí **historická data**: skutečné kotace konce dne z veřejné databáze DoltHub
  (`post-no-preference/options`, US akcie od 2019, bez klíče).
  - Expirace nejblíž zvolenému DTE, short noha podle skutečné delty, křídla z dostupných striků.
  - Vstup i výstup za mid ± polovinu spreadu, denní přecenění na mid, vypořádání v expiraci na vnitřní hodnotu.
  - „Vysoká volatilita“ podle IV ranku z databáze (jinak HV rank).
  - Dotazy se ukládají do cache v zařízení – druhý běh je rychlý. Průběh stahování je vidět na tlačítku.
- Přepínač **Ceny opcí: Simulace / Historická data** v Backtestu; agent v `run_options_backtest` má `pricing`.
- Jádro: `HistoricalOptionsSource`, `DoltHubOptionsSource`, `OptionsBacktest.runHistorical` s testy (maketa zdroje).

## 0.13.3 – 2026-10-13

- Graf v detailu tickeru se vždy otevře na YTD.
- Záložka Opce: po příchodu jsou všechny expirace zabalené (výjimkou je otevření strategie z agenta).
- Šablony strategií vybírají jen striky s open interest ≥ 1 000 (když takové v expiraci nejsou, použijí se všechny);
  agent dostal stejné pravidlo.

## 0.13.2 – 2026-10-13

- Graf v detailu tickeru je čistý: bez hlavičky s tickerem, změnou, OHLC a stavem připojení.
- Svíčky podle období: 1D → 15 min, 5D → 2H, 1M → 4H, 3M → 1D, YTD a 1Y → 1W, 5Y → 1M, Vše → 3M.

## 0.13.1 – 2026-10-13

- Čáry od agenta v grafu jsou přehlednější: tlumené barvy (support šalvějově zelená, rezistence terakotová,
  trendlinie světle modrá / levandulová), průhlednost, tloušťka podle timeframe (1W nejsilnější, 4H čárkovaně),
  krátké popisky („R 1D 233.42“) u pravého okraje; Fibonacci od agenta jemněji.
- Graf ukazuje jen čáry z aktuálního nebo vyššího timeframe – na denním grafu 1D a 1W, na týdenním jen 1W,
  na 4H a nižších všechny. Platí i pro už zakreslené čáry.

## 0.13.0 – 2026-10-13

- **Opční backtest** (Backtest → Obchodovat: Opce): zvolená strategie dává jen směr a opční strategie se vybere
  podle situace:
  - býčí signál + vysoká volatilita → bull put spread (kredit), nízká → bull call spread (debet);
  - medvědí signál → bear call / bear put spread; bez signálu volitelně iron condor;
  - nebo pevně zvolené strategie (vč. long call / long put).
- Simulace: ceny opcí z Black-Scholes s IV = realizovaná volatilita 20 svíček × násobek, „vysoká“ volatilita
  podle percentilu za rok, striky na mřížce podle delty (short noha 30Δ) a šířky, skluz a poplatky za nohu,
  velikost pozice podle rizika na obchod. Výstupy: cíl (50 % kreditu / +100 % debetu), stop (2× kredit / −50 % debetu),
  7 dní před expirací, změna signálu.
- Výsledky: metriky vs. buy & hold podkladu, rozpad podle zvolených strategií, obchody s nohami, IV a HV rankem.
- Agent: nástroj `run_options_backtest`; kvant v Investičním výboru porovnává akcie a opce.
- Jádro: `OptionsBacktest`, `OptionPlay`, `OptionSelection`, `OptionsBacktestConfig` s testy.

## 0.12.0 – 2026-10-12

- Backtest: strategie nad strukturou trhu – hladiny a trendlinie se v každé svíčce skládají jen z potvrzených
  swingů (pivot je známý až 3 svíčky po vzniku), takže bez pohledu do budoucnosti:
  - **Odraz od S/R** – dotyk supportu (aspoň 2 swingy) a zelené zavření nad ním; cíl nejbližší rezistence, jinak R:R.
  - **Průraz S/R** – zavření nad rezistencí o toleranci; stop návrat pod hladinu, cíl další rezistence, jinak R:R.
  - **Odraz od trendline** – dotyk neproražené support linie a zelené zavření nad ní; stop pod linií, cíl R:R.
  - **Průraz trendline** – zavření nad rezistenční linií; stop návrat pod linii, cíl R:R.
  - Všechny zrcadlově i short, parametry: okno struktury, tolerance, R:R.
- **Swing pullback (TradeLab)** – vlastní swingová strategie: trend (nad SMA 200, rostoucí EMA 50), pullback
  do zóny 0,382–0,786 swingu nebo k EMA 20, RSI pod 45 a otáčí, zelená svíčka nad high předchozí;
  stop pod minimem pullbacku, cíl extenze 1,272, výstup i pod EMA 50.
- Výpočet backtestu běží mimo hlavní vlákno. Agent umí všech pět nových pravidel v `run_backtest`.

## 0.11.0 – 2026-10-12

- **Fibonacciho retracement v grafu**: `find_levels` vrací poslední výrazný swing s retracementy 0,236–0,786
  a extenzemi 1,272 / 1,618 (a jak hluboko je cena v pullbacku); `draw_on_chart` ho zakreslí jako Fib objekt
  (0 = extrém, 1 = počátek swingu, extenze fialově za extrémem). Popisky extenzí v grafu ukazují 127,2 % a 161,8 %.
- **Fibonacciho výstup v backtestu** pro všechny strategie: při vstupu se vezme swing z N svíček, cíl na extenzi
  (1,0 / 1,272 / 1,618 / 2,0), stop na retracementu (0,5 / 0,618 / 0,786 / 1,0); výstup na zavření, nebo dřív
  podle strategie; nový vstup až po novém signálu. Umí ho i agent v `run_backtest` (`exit: fibonacci`).
- Jádro: `Fibonacci.lastSwing`, `Fibonacci.applyExit`, `ExitRule` v `BacktestConfig` s testy.

## 0.10.0 – 2026-10-12

- Agent kreslí do grafu **supporty, rezistence a trendové linie** z 1W, 1D a 4H:
  - nástroj `find_levels` najde silné hladiny (shluky swingových maxim/minim, síla podle počtu dotyků a čerstvosti)
    a trendové linie přes swingy, které zavírací cena neprorazila – na stejných svíčkách TradingView jako graf;
  - nástroj `draw_on_chart` zakreslí vybrané: zelená support, červená rezistence, trendlinie jako paprsek,
    týdenní nejsilnější, 4H čárkovaně, s popiskem; dřívější kresby agenta nahradí, uživatelovy nechá;
  - pod odpovědí karta **Otevřít graf** (plný TVChart na timeframu kreseb). Kresby jsou i v detailu tickeru
    a v seznamu objektů grafu (zamčené, jdou skrýt nebo smazat).
- Technický analytik a analytik směru v týmech používají `find_levels`.
- Graf: paprsky zůstávají vidět i se starými kotvami, popisky čar od agenta.
- Jádro: `LevelFinder` (pivoty, ATR, shlukování hladin, trendové linie) s testy.

## 0.9.0 – 2026-10-12

- Backtest: nové price action strategie
  - **Break & retest** – průraz rezistence (max. high za N svíček), retest prolomené hladiny do M svíček
    s tolerancí a zavření nad ní; stop pod hladinou, trailing výstup pod low posledních N/2 svíček.
  - **Reversal** – po přeprodanosti RSI býčí obratová svíčka (zelená, zavření nad high předchozí);
    stop pod swing low, výstup při překoupenosti nebo medvědí obratové svíčce.
  - **Odraz od klouzavého průměru** – v trendu (nad pomalým SMA, rostoucí průměr) dotyk EMA/SMA a zavření nad ní;
    výstup při zavření pod průměrem.
  - Všechny umí i zrcadlový short. Engine teď předává strategiím celé svíčky (OHLC).
- Nastavení dat backtestu: **Yahoo** (denní, upraveno o dividendy) nebo **TradingView** s intervalem 1D / 1W / 4H / 1H
  (jednorázové stažení přes websocket TradingView, úprava o dividendy, když ji server povolí, jinak splity).
  Platí i pro srovnání se SPY a pro backtesty agenta a týmů.
- Agent: `run_backtest` umí break_retest, reversal a ma_bounce a ve výsledku uvádí zdroj dat.

## 0.8.0 – 2026-10-12

- **Týmy agentů** v záložce Agent (přepínač Chat / Tým), inspirované „swarm“ presety z Vibe-Trading.
  Role pracují ve fázích nad nástroji aplikace, každá fáze vidí závěry předchozích, poslední role shrne verdikt.
  - **Investiční výbor**: technický analytik, analytik opčního trhu a kvant (backtesty) → risk manažer → předseda
    (Býčí / Neutrální / Medvědí s jistotou, argumenty, hladiny, co sledovat).
  - **Opční desk**: stratég volatility a analytik směru → strukturér (2–3 strategie z reálného řetězce) →
    risk manažer (stress test) → head trader (obchodní plán, velikost, výstupy).
  - **Kontrola pozice**: rozbor strategie z builderu, návrh úprav a doporučení držet / upravit / zavřít.
  - **Přehled watchlistu**: skener, opční pohled na 3 nejzajímavější tickery a shrnutí trhu.
- Průběh po rolích (stav, volání nástrojů, rozbalitelné reporty), závěrečný report, karty navržených strategií
  s tlačítkem Otevřít v Opcích, historie posledních 15 běhů, zastavení a opakování běhu.
- Volba „Šetřit limity API“ pouští role postupně (bezplatné klíče); delší čekání při 429.
- Jádro: `TeamRunner`, `TeamPreset`, `TeamStage`, `TeamRole` s testy.

## 0.7.2 – 2026-10-12

- Pod odpovědí agenta s navrženou strategií je karta s nohami (strike, expirace, mid), kreditem/debetem,
  max. ztrátou a ziskem a break-evenem. Tlačítko **Otevřít v Opcích** nahraje strategii s aktuálními kotacemi
  do builderu, přepne na záložku Opce, rozbalí expiraci první nohy a posune na ni tabulku.

## 0.7.1 – 2026-10-12

- Agent umí kromě Claude i **ChatGPT** (OpenAI Responses API: GPT-6.1 Sol, GPT-6 Astra, GPT-6 Luna)
  a **Gemini** (generateContent: Gemini 3.8 Flash, 3.1 Pro preview, 3.5 Flash-Lite) se stejnými nástroji.
- Nastavení: přepínač poskytovatele, samostatný klíč pro každého (Keychain), výběr modelu a vlastní ID modelu.
- Konverzaci jde přepnout na jiný model uprostřed – historie se převádí; šifrované reasoning položky OpenAI
  a podpisy myšlení Gemini se ukládají a vrací beze změny.
- Jádro: `OpenAITransport`, `GeminiTransport`, `Provider`, `ModelOption`; testy převodu tam i zpět.

## 0.7.0 – 2026-10-12

- Nová záložka **Agent**: chat s Claude (Opus 5.5 výchozí, Sonnet 5.5, Haiku 5.5), který si sám volá
  nástroje aplikace – cena, hledání tickeru, watchlist, statistiky historie (výnosy, volatilita, SMA, RSI, MACD),
  expirace a opční řetězec (bid/ask, IV, delta, OI), Black-Scholes ocenění, analýza strategie z reálných
  kontraktů (s volitelným nahráním na záložku Opce), aktuální pozice a backtest.
- Odpovědi v markdownu (nadpisy, odrážky, tabulky), čipy volání nástrojů s rozbalitelným vstupem/výstupem,
  zastavení běhu, nová konverzace; konverzace se ukládá v zařízení.
- API klíč jen v Keychainu iPhonu, nastavení modelu a spotřeba tokenů v relaci.
- Jádro `ClaudeAgent` v TradeCore: klient Messages API (prompt caching, opakování při 429/529),
  smyčka tool use s limitem kroků a testy s maketou API.

## 0.6.0 – 2026-10-12

- Nová záložka **Backtest**: ticker, období 1R–Vše (denní data upravená o dividendy), strategie SMA cross,
  MACD cross, RSI mean-reversion a buy & hold, volitelný short a náklady v bp.
- Výsledky: metriky strategie vs. buy & hold (výnos, CAGR, max. drawdown, Sharpe, Sortino, volatilita, Calmar,
  expozice, obchody, win rate), křivka kapitálu se srovnáním se SPY, drawdown a seznam obchodů.
- Jádro `Backtest` v TradeCore: indikátory (SMA, EMA, RSI, MACD), strategie, engine bez look-ahead biasu
  (signál na close, obchod na open dalšího dne), metriky; testy proti referenčním hodnotám.
- `YahooFinanceClient.dailyHistory(symbol:range:)`.

## 0.5.2 – 2026-10-12

- Vložený graf v detailu má období jako aplikace TradingView: 1D (5m), 5D (15m), 1M (1H), 3M a YTD (1D),
  1Y a 5Y (1W), Vše (1M). Výřez se nastaví přesně na zvolené období; menší intervaly jsou v plném grafu.
- TVChart: `preferredSpan` (`ChartSpan`), `historyBars`, `fitPreferredSpan()`.

## 0.5.1 – 2026-10-12

- Detail tickeru: místo jednoduchého grafu je vložený TVChart (bez indikátorů) s volbou svíčky / linka
  a intervalu 15m–1W. Do grafu se kreslí striky (zeleně long, červeně short) a break-even (fialově)
  aktuální opční pozice na tomto tickeru.
- Tlačítko pro zvětšení otevře plný TVChart s vlastními indikátory a kreslením, bez čar pozice.
- Odstraněna tlačítka „Graf TradingView“ a „Opční řetězec“, volba období je u statistik.
- TVChart: `indicatorsEnabled`, `priceLines` (`ChartPriceLine`) a `persistsSession` pro vložené použití.

## 0.5.0 – 2026-10-12

- Graf z projektu TVChart-iOS (real-time TradingView, svíčky, indikátory, kreslení, volume profil)
  v `TradeLab/TVChart/`. Otevírá se na celou obrazovku z detailu tickeru (tlačítko nebo klepnutí na graf)
  a tlačítkem „Graf“ na záložce Opce, vždy pro aktuální ticker. Zavírá se křížkem, stream se odpojí.

## 0.4.1 – 2026-10-12

- Vybranou nohu v tabulce jde táhnout za celé označené pole (strana i strike), ne jen za blok s počtem.
- Tlačítko nastavení sloupců má jedno kulaté skleněné pozadí těsně kolem ikony.
- V Payoffu jsou nohy v barevných rámečcích (zelená long, červená short).

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
