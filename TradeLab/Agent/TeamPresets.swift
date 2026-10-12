import Foundation
import ClaudeAgent

/// Přednastavené týmy agentů (inspirované „swarm“ presety z Vibe-Trading).
enum TeamPresets {
    static let all: [TeamPreset] = [committee, optionsDesk, positionReview, watchlistScan]

    static func preset(_ id: String) -> TeamPreset? { all.first { $0.id == id } }

    // MARK: - Investiční výbor

    static let committee = TeamPreset(
        id: "committee",
        name: "Investiční výbor",
        icon: "building.columns.fill",
        summary: "Technik, analytik opcí a kvant posoudí akcii, risk manažer jejich teze zpochybní a předseda vynese verdikt.",
        needsSymbol: true,
        notePlaceholder: "Horizont, otázka nebo kontext (volitelné)",
        stages: [
            TeamStage([
                TeamRole(
                    id: "technical", name: "Technický analytik", icon: "chart.line.uptrend.xyaxis",
                    instructions: """
                    Posuď trend a momentum: cena vůči SMA 20/50/200, RSI, MACD, výnosy 1M–1R, 52týdenní maximum a minimum \
                    jako orientační hladiny, realizovaná volatilita. Silné supporty, rezistence a trendové linie zjisti \
                    přes find_levels (1W a 1D). Závěr: býčí / neutrální / medvědí technický obraz a proč.
                    """,
                    tools: ["get_quote", "get_price_history", "find_levels"]),
                TeamRole(
                    id: "options", name: "Analytik opčního trhu", icon: "waveform.path.ecg",
                    instructions: """
                    Co říká opční trh: ATM IV nejbližší a ~30denní expirace vs. realizovaná volatilita, trhem implikovaný \
                    pohyb (straddle), sklon IV putů vs. callů při podobné deltě, kde je největší open interest. \
                    Závěr: je opční prémie drahá nebo levná a co trh očekává.
                    """,
                    tools: ["get_quote", "get_price_history", "get_option_expirations", "get_option_chain"]),
                TeamRole(
                    id: "quant", name: "Kvant", icon: "function",
                    instructions: """
                    Spusť 2–3 backtesty za 5 let (SMA 50/200, MACD 12/26/9, RSI 14 30/70) a porovnej s buy & hold \
                    (CAGR, Sharpe, max. drawdown). Pro nejlepší pravidlo spusť i run_options_backtest (selection auto) \
                    a porovnej s akciemi. Závěr: jaký režim (trend vs. mean reversion) u tohoto titulu fungoval.
                    """,
                    tools: ["run_backtest", "run_options_backtest", "get_price_history"]),
            ]),
            TeamStage([
                TeamRole(
                    id: "risk", name: "Risk manažer", icon: "exclamationmark.shield.fill",
                    instructions: """
                    Zpochybni závěry analytiků: kde si odporují, co by tezi vyvrátilo, historický drawdown a volatilita, \
                    jak velký pohyb je realistický. Vyjmenuj 3 hlavní rizika s čísly.
                    """,
                    tools: ["get_quote", "get_price_history"], maxTurns: 6),
            ]),
            TeamStage([
                TeamRole(
                    id: "chair", name: "Předseda výboru", icon: "person.crop.circle.badge.checkmark",
                    instructions: """
                    Shrň práci týmu do závěrečného verdiktu (nástroje nepoužíváš). Struktura v markdownu: \
                    **Verdikt** (Býčí / Neutrální / Medvědí) a jistota 1–5; nejsilnější argumenty pro a proti; \
                    klíčové cenové hladiny; jak by šlo tezi vyjádřit opcemi (bez konkrétních kontraktů); \
                    co sledovat a kdy verdikt přehodnotit. Tento report je pro uživatele, ne pro tým – může být delší (až 400 slov).
                    """,
                    tools: [], maxTurns: 2),
            ]),
        ])

    // MARK: - Opční desk

    static let optionsDesk = TeamPreset(
        id: "options-desk",
        name: "Opční desk",
        icon: "square.stack.3d.up.fill",
        summary: "Stratég volatility a analytik směru určí situaci, strukturér navrhne strategie z reálného řetězce, risk je otestuje a head trader vybere.",
        needsSymbol: true,
        notePlaceholder: "Tvůj názor, např. „mírně býčí do 45 dní, max. riziko 500 $“",
        stages: [
            TeamStage([
                TeamRole(
                    id: "vol", name: "Stratég volatility", icon: "waveform.path.ecg",
                    instructions: """
                    Porovnej ATM IV 2–3 expirací (term structure, ~7, ~30 a ~60 dní) s realizovanou volatilitou 20/60 dní. \
                    Závěr: být spíš prodávající (kredit) nebo kupující (debet) prémie a ve kterém horizontu.
                    """,
                    tools: ["get_quote", "get_price_history", "get_option_expirations", "get_option_chain"]),
                TeamRole(
                    id: "direction", name: "Analytik směru", icon: "arrow.up.right",
                    instructions: """
                    Urči směrový sklon a klíčové hladiny (SMA, 52týdenní extrémy, RSI, MACD) a jak velký pohyb je \
                    realistický do 30–45 dní. Zohledni názor uživatele, pokud ho uvedl.
                    """,
                    tools: ["get_quote", "get_price_history", "find_levels"], maxTurns: 6),
            ]),
            TeamStage([
                TeamRole(
                    id: "structurer", name: "Strukturér", icon: "hammer.fill",
                    instructions: """
                    Navrhni 2–3 konkrétní strategie, které odpovídají závěrům o volatilitě a směru a riziku uživatele. \
                    Striky a expirace vyber z reálného řetězce (likvidní, rozumný spread bid/ask, open interest) a KAŽDOU \
                    přepočítej přes analyze_strategy. U každé uveď nohy, kredit/debet, max. zisk a ztrátu, break-even a PoP.
                    """,
                    tools: ["get_option_expirations", "get_option_chain", "analyze_strategy"], maxTurns: 12),
            ]),
            TeamStage([
                TeamRole(
                    id: "risk", name: "Risk manažer", icon: "exclamationmark.shield.fill",
                    instructions: """
                    Otestuj návrhy strukturéra: poměr max. ztráty ke kreditu, scénáře P/L při ±5/10 %, likvidita, \
                    riziko předčasného přiřazení u short nohou ITM, gamma před expirací. Pokud je návrh slabý, \
                    přepočítej lepší variantu přes analyze_strategy. Seřaď návrhy od nejlepšího.
                    """,
                    tools: ["get_option_chain", "analyze_strategy"], maxTurns: 8),
            ]),
            TeamStage([
                TeamRole(
                    id: "head", name: "Head trader", icon: "person.crop.circle.badge.checkmark",
                    instructions: """
                    Vyber jednu strategii (nástroje nepoužíváš) a napiš obchodní plán pro uživatele v markdownu: \
                    **Volba** a proč; nohy (strike, expirace, kredit/debet); max. riziko a velikost pozice jako % účtu; \
                    vstup (limitní cena kolem mid); výstup – cíl zisku, stop, kdy rolovat nebo zavřít; co sledovat. \
                    Tento report je pro uživatele – může být delší (až 400 slov).
                    """,
                    tools: [], maxTurns: 2),
            ]),
        ])

    // MARK: - Kontrola pozice

    static let positionReview = TeamPreset(
        id: "position-review",
        name: "Kontrola pozice",
        icon: "stethoscope",
        summary: "Tým rozebere strategii sestavenou na záložce Opce, navrhne úpravy a doporučí držet, upravit nebo zavřít.",
        needsSymbol: false,
        notePlaceholder: "Co tě na pozici trápí (volitelné)",
        stages: [
            TeamStage([
                TeamRole(
                    id: "position", name: "Analytik pozice", icon: "chart.xyaxis.line",
                    instructions: """
                    Rozeber aktuální pozici: greeks, P/L scénáře při expiraci, vzdálenost ceny od break-evenů a striků, \
                    časový rozpad (theta), citlivost na IV (vega).
                    """,
                    tools: ["get_current_position", "get_quote", "get_option_chain"]),
                TeamRole(
                    id: "market", name: "Analytik trhu", icon: "globe.americas.fill",
                    instructions: """
                    Posuď trh podkladu pozice: trend a momentum, realizovaná vs. implikovaná volatilita, trhem \
                    implikovaný pohyb do expirace pozice vs. vzdálenost break-evenů.
                    """,
                    tools: ["get_current_position", "get_price_history", "get_option_expirations", "get_option_chain"]),
            ]),
            TeamStage([
                TeamRole(
                    id: "adjust", name: "Strukturér úprav", icon: "wrench.and.screwdriver.fill",
                    instructions: """
                    Navrhni 1–2 úpravy (posun striků, rolování expirace, zúžení nebo zajištění) a každou spočítej přes \
                    analyze_strategy jako celou novou pozici. Porovnej s ponecháním pozice beze změny.
                    """,
                    tools: ["get_current_position", "get_option_expirations", "get_option_chain", "analyze_strategy"],
                    maxTurns: 12),
            ]),
            TeamStage([
                TeamRole(
                    id: "decision", name: "Rozhodnutí", icon: "person.crop.circle.badge.checkmark",
                    instructions: """
                    Doporuč pro uživatele (nástroje nepoužíváš): **Držet / Upravit / Zavřít**, proč, a za jakých podmínek \
                    rozhodnutí změnit (cenové hladiny, dny do expirace, P/L). Markdown, až 300 slov.
                    """,
                    tools: [], maxTurns: 2),
            ]),
        ])

    // MARK: - Přehled watchlistu

    static let watchlistScan = TeamPreset(
        id: "watchlist",
        name: "Přehled watchlistu",
        icon: "list.star",
        summary: "Skener projde sledované tickery, opční analytik se podívá na ty nejzajímavější a vznikne krátký přehled trhu.",
        needsSymbol: false,
        notePlaceholder: "Na co se zaměřit (volitelné)",
        stages: [
            TeamStage([
                TeamRole(
                    id: "scanner", name: "Skener", icon: "magnifyingglass",
                    instructions: """
                    Načti watchlist a u každého tickeru historii (1y). Seřaď podle zajímavosti (silný trend, extrémní RSI, \
                    blízkost 52týdenního maxima/minima, skok volatility) a vyber 3 nejzajímavější s krátkým zdůvodněním. \
                    Přidej jednořádkovou tabulku všech tickerů (cena, změna dne, výnos 1M, RSI).
                    """,
                    tools: ["get_watchlist", "get_price_history"], maxTurns: 14),
            ]),
            TeamStage([
                TeamRole(
                    id: "options", name: "Opční analytik", icon: "waveform.path.ecg",
                    instructions: """
                    U 3 tickerů vybraných skenerem zjisti ATM IV ~30denní expirace, implikovaný pohyb a srovnání \
                    s realizovanou volatilitou. Ke každému jeden typ strategie, který by situaci odpovídal (bez výpočtu).
                    """,
                    tools: ["get_option_expirations", "get_option_chain", "get_price_history"], maxTurns: 12),
            ]),
            TeamStage([
                TeamRole(
                    id: "summary", name: "Shrnutí", icon: "doc.text.fill",
                    instructions: """
                    Napiš pro uživatele přehled (nástroje nepoužíváš): náladu trhu podle watchlistu, tabulku tickerů \
                    ze skeneru a 3 tipy na další průzkum s odkazem na zjištěná čísla. Markdown, až 350 slov.
                    """,
                    tools: [], maxTurns: 2),
            ]),
        ])
}
