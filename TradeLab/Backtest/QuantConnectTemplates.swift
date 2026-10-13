import Foundation
import Backtest

/// Export strategie do QuantConnectu (LEAN, Python): skript se vloží do webového editoru
/// na quantconnect.com a spustí na jejich datech (akcie, u opcí minutové kotace od 2012).
///
/// Strategie Breakout/Breakdown je port `BreakoutStrategy` z `Backtest` (stejné výsledky jako testy jádra).
enum QuantConnectExport {
    static let signalsLibrary = #"""
# ===== TradeLab: Breakout / Breakdown (port ze Swiftu, inkrementálně po denních svíčkách) =====
import math


class Bar:
    def __init__(self, o, h, l, c, week):
        """week: libovolný klíč týdne (rok, ISO týden) – svíčky téhož týdne mají stejný klíč."""
        self.open, self.high, self.low, self.close, self.week = o, h, l, c, week


class Psar:
    """Parabolic SAR (0,02 / 0,02 / 0,2). up = True / False / None (málo dat)."""
    def __init__(self, step=0.02, maximum=0.2):
        self.step, self.maximum = step, maximum
        self.bars = []
        self.up = None
        self.sar = self.ep = self.af = 0.0

    def update(self, h, l, c):
        self.bars.append((h, l, c))
        n = len(self.bars)
        if n == 1:
            return None
        if n == 2:
            (h0, l0, c0) = self.bars[0]
            self.up = c > c0
            self.af = self.step
            if self.up:
                self.sar, self.ep = l0, max(h, h0)
            else:
                self.sar, self.ep = h0, min(l, l0)
            return self.up
        ph, pl, _ = self.bars[-2]
        pph, ppl, _ = self.bars[-3]
        sar = self.sar + self.af * (self.ep - self.sar)
        if self.up:
            sar = min(sar, pl, ppl)
            if l < sar:
                self.up, sar, self.ep, self.af = False, self.ep, l, self.step
            elif h > self.ep:
                self.ep, self.af = h, min(self.af + self.step, self.maximum)
        else:
            sar = max(sar, ph, pph)
            if h > sar:
                self.up, sar, self.ep, self.af = True, self.ep, h, self.step
            elif l < self.ep:
                self.ep, self.af = l, min(self.af + self.step, self.maximum)
        self.sar = sar
        return self.up


def sma_last(values, period):
    if len(values) < period:
        return None
    return sum(values[-period:]) / period


class Breakout:
    """Breakout nad rezistenci / breakdown pod support z konsolidace.

    Vstupy: 1) těsně před průrazem absolutního vrcholu, 2) po čistém průrazu (celá svíčka nad hladinou,
    případně druhý den), 3) první pullback k prorazené hladině (PNR). Stop 1× ATR nebo pod předchozí
    svíčku (vzdálenější), cíl Fibonacciho extenze konsolidace (min. 1,5× ATR).
    update() vrací cílovou pozici po zavření svíčky: 1 long, -1 short, 0 bez pozice.
    """
    K = 3
    ATR_N = 14

    def __init__(self, lookback=120, min_touches=2, tolerance=0.01, pre=True, breakout=True, pullback=True,
                 weekly=True, daily=True, ma_cross=True, headroom=2.0, stop_atr=1.0, target_fib=1.272,
                 pullback_bars=20, allow_short=True):
        self.lookback, self.min_touches, self.tol = lookback, min_touches, tolerance
        self.use_pre, self.use_breakout, self.use_pullback = pre, breakout, pullback
        self.use_weekly, self.use_daily, self.use_cross = weekly, daily, ma_cross
        self.headroom, self.stop_atr, self.target_fib = headroom, stop_atr, target_fib
        self.pullback_bars, self.allow_short = pullback_bars, allow_short
        self.bars = []
        self.closes = []
        self.trs = []
        self.atr = []
        self.ma_diff = []          # znaménko SMA20 − SMA50 (None, 1, -1)
        self.sma = {20: [], 50: [], 100: []}
        self.psar = Psar()
        self.psar_up = []
        self.pivot_hi = []         # indexy potvrzených swingových maxim
        self.pivot_lo = []
        # týdenní graf
        self.week_key = None
        self.week = None           # [o, h, l, c] rozpracovaného týdne
        self.w_closes = []
        self.w_psar = Psar()
        self.w_up = None           # True / False / None podle posledního uzavřeného týdne
        self.w_trend = 0           # 1 KP seřazeny na long, -1 na short
        # stav
        self.position = 0
        self.stop = self.target = 0.0
        self.events = {1: None, -1: None}   # prorazená hladina: dict(level, low, index, extended)
        self.pending = {1: None, -1: None}  # nečistý průraz – čeká se na druhý den
        self.used = set()
        self.signals = []                   # (index, kind, direction, level, stop, target)

    # ---- indikátory ----
    def _indicators(self, bar):
        i = len(self.bars) - 1
        self.closes.append(bar.close)
        if i == 0:
            self.trs.append(bar.high - bar.low)
        else:
            pc = self.closes[-2]
            self.trs.append(max(bar.high - bar.low, abs(bar.high - pc), abs(bar.low - pc)))
        self.atr.append(sum(self.trs[-self.ATR_N:]) / self.ATR_N if i >= self.ATR_N else None)
        for p in self.sma:
            self.sma[p].append(sma_last(self.closes, p))
        a, b = self.sma[20][-1], self.sma[50][-1]
        self.ma_diff.append(None if a is None or b is None else (1 if a > b else -1))
        self.psar_up.append(self.psar.update(bar.high, bar.low, bar.close))
        # pivot potvrzený na svíčce i: p = i − K
        p = i - self.K
        if p >= self.K:
            hp, lp = self.bars[p].high, self.bars[p].low
            left = self.bars[p - self.K:p]
            right = self.bars[p + 1:i + 1]
            if all(x.high < hp for x in left) and all(x.high <= hp for x in right):
                self.pivot_hi.append(p)
            if all(x.low > lp for x in left) and all(x.low >= lp for x in right):
                self.pivot_lo.append(p)

    def _weekly(self, bar):
        if self.week_key is not None and bar.week != self.week_key:
            o, h, l, c = self.week
            self.w_closes.append(c)
            self.w_up = self.w_psar.update(h, l, c)
            s10, s20, s40 = (sma_last(self.w_closes, n) for n in (10, 20, 40))
            if s40 is None:
                self.w_trend = 0
            elif s10 > s20 > s40:
                self.w_trend = 1
            elif s10 < s20 < s40:
                self.w_trend = -1
            else:
                self.w_trend = 0
            self.week = None
        self.week_key = bar.week
        if self.week is None:
            self.week = [bar.open, bar.high, bar.low, bar.close]
        else:
            self.week[1] = max(self.week[1], bar.high)
            self.week[2] = min(self.week[2], bar.low)
            self.week[3] = bar.close

    # ---- pomocné ----
    def _filters(self, d):
        i = len(self.bars) - 1
        if d == -1 and not self.allow_short:
            return False
        if self.use_weekly and not (self.w_trend == d and self.w_up == (d == 1)):
            return False
        if self.use_daily:
            s20, s50, s100 = self.sma[20][i], self.sma[50][i], self.sma[100][i]
            if s100 is None or self.psar_up[i] != (d == 1):
                return False
            if d == 1 and not (s20 > s50 > s100):
                return False
            if d == -1 and not (s20 < s50 < s100):
                return False
        return True

    def _zone(self, d):
        """Konsolidace z předchozích `lookback` svíček: (hladina, protější kraj) nebo None."""
        i = len(self.bars) - 1
        start = i - self.lookback
        if start < 0:
            return None
        window = self.bars[start:i]
        if d == 1:
            level = max(b.high for b in window)
            other = min(b.low for b in window)
            touches = sum(1 for p in self.pivot_hi if start <= p <= i - 1 - self.K
                          and self.bars[p].high >= level * (1 - self.tol))
        else:
            level = min(b.low for b in window)
            other = max(b.high for b in window)
            touches = sum(1 for p in self.pivot_lo if start <= p <= i - 1 - self.K
                          and self.bars[p].low <= level * (1 + self.tol))
        if touches < self.min_touches:
            return None
        if self.use_cross:
            signs = [s for s in self.ma_diff[start:i] if s is not None]
            if not any(signs[j] != signs[j - 1] for j in range(1, len(signs))):
                return None
        return level, other

    def _headroom_ok(self, d, price, atr):
        i = len(self.bars) - 1
        if d == 1:
            above = [self.bars[p].high for p in self.pivot_hi if self.bars[p].high > price]
            return not above or min(above) - price >= self.headroom * atr
        below = [self.bars[p].low for p in self.pivot_lo if self.bars[p].low < price]
        return not below or price - max(below) >= self.headroom * atr

    def _levels(self, d, level, other, atr):
        i = len(self.bars) - 1
        close = self.bars[i].close
        prev = self.bars[i - 1]
        if d == 1:
            stop = min(prev.low, close - self.stop_atr * atr)
            target = max(other + (level - other) * self.target_fib, close + 1.5 * atr)
        else:
            stop = max(prev.high, close + self.stop_atr * atr)
            target = min(other - (other - level) * self.target_fib, close - 1.5 * atr)
        return stop, target

    def _enter(self, kind, d, level, other, atr):
        stop, target = self._levels(d, level, other, atr)
        self.position, self.stop, self.target = d, stop, target
        self.signals.append((len(self.bars) - 1, kind, d, level, stop, target))

    @staticmethod
    def _reversal(d, bar, prev):
        body = abs(bar.close - bar.open)
        if d == 1:
            if bar.close > bar.open:
                return True
            wick = min(bar.open, bar.close) - bar.low
            return wick >= 2 * body and wick > 0
        if bar.close < bar.open:
            return True
        wick = bar.high - max(bar.open, bar.close)
        return wick >= 2 * body and wick > 0

    # ---- hlavní krok ----
    def update(self, bar):
        self.bars.append(bar)
        self._weekly(bar)
        self._indicators(bar)
        i = len(self.bars) - 1
        atr = self.atr[i]
        if atr is None or i < 2:
            return self.position
        prev = self.bars[i - 1]

        # 1) výstup na zavírací ceně
        exited = False
        if self.position == 1 and (bar.close <= self.stop or bar.close >= self.target):
            self.position, exited = 0, True
        elif self.position == -1 and (bar.close >= self.stop or bar.close <= self.target):
            self.position, exited = 0, True

        entries = []   # (priorita, kind, d, level, other)
        for d in (1, -1):
            s = d  # 1: nad hladinou je „ve směru“
            zone = self._zone(d)
            clean = lambda lv: (bar.open - lv) * s > 0 and (bar.close - lv) * s > 0 and (bar.close - bar.open) * s > 0

            # 2) čekající nečistý průraz z minulé svíčky
            pend = self.pending[d]
            self.pending[d] = None
            if pend is not None and clean(pend[0]):
                entries.append((0, "breakout", d, pend[0], pend[1]))

            # 3) nový průraz
            if zone is not None:
                level, other = zone
                if (bar.close - level) * s > 0:
                    self.events[d] = dict(level=level, other=other, index=i, extended=False)
                    if clean(level):
                        entries.append((0, "breakout", d, level, other))
                    else:
                        self.pending[d] = (level, other)
                elif self.use_pre and (level - bar.close) * s <= atr and (level - bar.close) * s >= 0:
                    # těsně pod absolutním vrcholem (nad absolutním dnem u breakdownu)
                    extreme = max(b.high for b in self.bars[:i]) if d == 1 else min(b.low for b in self.bars[:i])
                    if level == extreme and (d, level) not in self.used:
                        entries.append((2, "pre", d, level, other))

            # 4) PNR – první pullback k prorazené hladině
            ev = self.events[d]
            if ev is not None and ev["index"] < i:
                lv = ev["level"]
                if i - ev["index"] > self.pullback_bars or (lv - bar.close) * s > 0.5 * atr:
                    self.events[d] = None
                elif ev["extended"]:
                    touched = (bar.low - lv <= 0.5 * atr) if d == 1 else (lv - bar.high <= 0.5 * atr)
                    if touched and (bar.close - lv) * s > 0 and self._reversal(d, bar, prev):
                        entries.append((1, "pullback", d, lv, ev["other"]))
                if self.events[d] is not None and ((bar.high - lv >= atr) if d == 1 else (lv - bar.low >= atr)):
                    self.events[d]["extended"] = True

        if self.position == 0 and not exited:
            for _, kind, d, level, other in sorted(entries, key=lambda e: e[0]):
                if not self.use_breakout and kind == "breakout":
                    continue
                if not self.use_pullback and kind == "pullback":
                    continue
                if not self._filters(d) or not self._headroom_ok(d, bar.close, atr):
                    continue
                self._enter(kind, d, level, other, atr)
                self.used.add((d, level))
                if kind != "pre":
                    self.events[d] = None
                    self.pending[d] = None
                break
        return self.position

    def watch(self):
        """Konsolidace těsně pod rezistencí / nad supportem na poslední svíčce: (směr, hladina, vzdálenost v ATR)."""
        i = len(self.bars) - 1
        if i < 2 or self.atr[i] is None or self.position != 0:
            return None
        atr, close = self.atr[i], self.bars[i].close
        best = None
        for d in (1, -1):
            zone = self._zone(d)
            if zone is None or not self._filters(d):
                continue
            distance = (zone[0] - close) * d / atr
            if 0 <= distance <= 1.5 and (best is None or distance < best[2]):
                best = (d, zone[0], distance)
        return best


class BuyHold:
    def update(self, bar):
        return 1

"""#

    static let stockTemplate = #"""
class TradeLabAlgorithm(QCAlgorithm):
    """Akciový backtest: signál ze zavírací ceny, obchod na otevření dalšího dne."""

    def initialize(self):
        self.set_start_date({{START}})
        self.set_end_date({{END}})
        self.set_cash({{CASH}})
        equity = self.add_equity("{{TICKER}}", Resolution.DAILY)
        equity.set_fee_model(ConstantFeeModel(0))
        equity.set_slippage_model(ConstantSlippageModel({{SLIPPAGE}}))
        self.symbol = equity.symbol
        self.set_benchmark(self.symbol)
        self.signal = {{SIGNAL}}
        self.target = 0
        self.set_warm_up(timedelta(days={{WARMUP_DAYS}}))

    def on_data(self, data: Slice):
        bar = data.bars.get(self.symbol)
        if bar is None:
            return
        week = tuple(bar.time.isocalendar()[:2])
        target = self.signal.update(Bar(bar.open, bar.high, bar.low, bar.close, week))
        if self.is_warming_up:
            return
        if target != self.target:
            self.target = target
            self.set_holdings(self.symbol, float(target))
"""#

    static let optionsTemplate = #"""
class TradeLabOptionsAlgorithm(QCAlgorithm):
    """Opční backtest: signál strategie dává směr, spread se vybírá podle volatility."""

    def initialize(self):
        self.set_start_date({{START}})
        self.set_end_date({{END}})
        self.set_cash({{CASH}})
        equity = self.add_equity("{{TICKER}}", Resolution.MINUTE)
        self.symbol = equity.symbol
        option = self.add_option("{{TICKER}}", Resolution.MINUTE)
        option.set_filter(lambda u: u.include_weeklys().strikes(-60, 60).expiration({{MIN_DTE}}, {{MAX_DTE}}))
        option.price_model = OptionPriceModels.black_scholes()
        self.option_symbol = option.symbol
        self.set_benchmark(self.symbol)

        self.signal = {{SIGNAL}}
        self.target = 0
        self.closes = []
        self.hv = []
        self.consolidate(self.symbol, Resolution.DAILY, self.on_daily)
        self.set_warm_up(timedelta(days={{WARMUP_DAYS}}))
        self.schedule.on(self.date_rules.every_day(self.symbol),
                         self.time_rules.after_market_open(self.symbol, 30), self.trade)

        # Parametry z TradeLabu
        self.auto = {{AUTO}}
        self.neutral_condor = {{CONDOR}}
        self.bullish_play = "{{BULLISH}}"
        self.bearish_play = {{BEARISH}}
        self.allow_bearish = {{ALLOW_BEARISH}}
        self.dte = {{DTE}}
        self.short_delta = {{SHORT_DELTA}}
        self.width_pct = {{WIDTH_PCT}}
        self.high_vol_rank = {{HIGH_VOL_RANK}}
        self.risk = {{RISK}}
        self.credit_tp, self.credit_stop = {{CREDIT_TP}}, {{CREDIT_STOP}}
        self.debit_tp, self.debit_stop = {{DEBIT_TP}}, {{DEBIT_STOP}}
        self.exit_dte = {{EXIT_DTE}}

        self.position = None
        self.blocked = None

    # ----- signál a volatilita z denních svíček -----

    def on_daily(self, bar):
        week = tuple(bar.time.isocalendar()[:2])
        self.target = self.signal.update(Bar(bar.open, bar.high, bar.low, bar.close, week))
        self.closes.append(bar.close)
        if len(self.closes) > 21:
            rets = [math.log(self.closes[k] / self.closes[k - 1]) for k in range(len(self.closes) - 20, len(self.closes))]
            mean = sum(rets) / len(rets)
            var = sum((r - mean) ** 2 for r in rets) / (len(rets) - 1)
            self.hv.append(math.sqrt(var * 252))
            self.hv = self.hv[-252:]

    def vol_rank(self):
        if len(self.hv) < 10:
            return None
        current = self.hv[-1]
        return 100.0 * len([x for x in self.hv if x <= current]) / len(self.hv)

    def choose(self, signal, rank):
        high = rank >= self.high_vol_rank
        if self.auto:
            if signal == 1:
                return "bull_put" if high else "bull_call"
            if signal == -1:
                return ("bear_call" if high else "bear_put") if self.allow_bearish else None
            return "iron_condor" if (self.neutral_condor and high) else None
        if signal == 1:
            return self.bullish_play
        if signal == -1 and self.allow_bearish:
            return self.bearish_play
        return None

    # ----- obchodování (30 min po otevření) -----

    def trade(self):
        if self.is_warming_up:
            return
        chain = self.current_slice.option_chains.get(self.option_symbol)
        if self.position is not None:
            self.manage()
        if self.position is None:
            if self.blocked is not None and self.target != self.blocked:
                self.blocked = None
            rank = self.vol_rank()
            if self.blocked is None and rank is not None and chain is not None:
                play = self.choose(self.target, rank)
                if play:
                    self.open(play, chain, rank)

    def mid(self, symbol):
        sec = self.securities[symbol]
        if sec.bid_price > 0 and sec.ask_price > 0:
            return (sec.bid_price + sec.ask_price) / 2
        return sec.price

    def manage(self):
        p = self.position
        value = sum(side * self.mid(sym) for sym, side in p["legs"])
        pnl = value - p["premium"]
        days_left = (p["expiry"].date() - self.time.date()).days
        reason = None
        if p["credit"]:
            credit = -p["premium"]
            if pnl >= credit * self.credit_tp:
                reason = "cil"
            elif -pnl >= credit * self.credit_stop:
                reason = "stop"
        else:
            if pnl >= p["premium"] * self.debit_tp:
                reason = "cil"
            elif -pnl >= p["premium"] * self.debit_stop:
                reason = "stop"
        if reason is None and days_left <= self.exit_dte:
            reason = "cas"
        if reason is None and self.target != p["signal"]:
            reason = "signal"
        if reason:
            for sym, side in p["legs"]:
                self.liquidate(sym, tag=reason)
            self.blocked = p["signal"] if reason == "stop" else None
            self.position = None

    def open(self, play, chain, rank):
        spot = self.securities[self.symbol].price
        contracts = [c for c in chain if c.ask_price > 0]
        if not contracts:
            return
        expiries = sorted(set(c.expiry for c in contracts))
        expiry = min(expiries, key=lambda e: abs((e.date() - self.time.date()).days - self.dte))
        calls = sorted([c for c in contracts if c.expiry == expiry and c.right == OptionRight.CALL], key=lambda c: c.strike)
        puts = sorted([c for c in contracts if c.expiry == expiry and c.right == OptionRight.PUT], key=lambda c: c.strike)
        width = spot * self.width_pct

        def by_delta(items, target, otm):
            cands = [c for c in items if otm(c.strike) and c.bid_price > 0]
            if not cands:
                return None
            return min(cands, key=lambda c: abs(abs(c.greeks.delta) - target) if c.greeks.delta != 0 else abs(c.strike - spot))

        def nearest(items, strike, ok):
            cands = [c for c in items if ok(c.strike)]
            return min(cands, key=lambda c: abs(c.strike - strike)) if cands else None

        def atm(items):
            return min(items, key=lambda c: abs(c.strike - spot)) if items else None

        legs = []
        if play == "bull_put":
            s = by_delta(puts, self.short_delta, lambda k: k < spot)
            l = nearest(puts, s.strike - width, lambda k: k < s.strike) if s else None
            legs = [(s, -1), (l, 1)]
        elif play == "bear_call":
            s = by_delta(calls, self.short_delta, lambda k: k > spot)
            l = nearest(calls, s.strike + width, lambda k: k > s.strike) if s else None
            legs = [(s, -1), (l, 1)]
        elif play == "bull_call":
            l = atm(calls)
            s = nearest(calls, l.strike + width, lambda k: k > l.strike) if l else None
            legs = [(l, 1), (s, -1)]
        elif play == "bear_put":
            l = atm(puts)
            s = nearest(puts, l.strike - width, lambda k: k < l.strike) if l else None
            legs = [(l, 1), (s, -1)]
        elif play == "iron_condor":
            d = min(self.short_delta, 0.2)
            sp = by_delta(puts, d, lambda k: k < spot)
            sc = by_delta(calls, d, lambda k: k > spot)
            lp = nearest(puts, sp.strike - width, lambda k: k < sp.strike) if sp else None
            lc = nearest(calls, sc.strike + width, lambda k: k > sc.strike) if sc else None
            legs = [(lp, 1), (sp, -1), (sc, -1), (lc, 1)]
        elif play == "long_call":
            legs = [(atm(calls), 1)]
        elif play == "long_put":
            legs = [(atm(puts), 1)]
        if not legs or any(c is None for c, _ in legs):
            return

        # Odhad ceny a max. ztráty z kotací (mid), velikost podle rizika.
        premium = sum(side * (c.bid_price + c.ask_price) / 2 for c, side in legs)
        strikes_p = [c.strike for c, _ in legs if c.right == OptionRight.PUT]
        strikes_c = [c.strike for c, _ in legs if c.right == OptionRight.CALL]
        spread = max((max(strikes_p) - min(strikes_p)) if strikes_p else 0, (max(strikes_c) - min(strikes_c)) if strikes_c else 0)
        credit = play in ("bull_put", "bear_call", "iron_condor")
        max_loss = spread + premium if credit else premium
        if (credit and premium >= -0.01) or (not credit and premium <= 0.01) or max_loss <= 0:
            return
        qty = int(self.portfolio.total_portfolio_value * self.risk / (max_loss * 100))
        if qty < 1:
            return

        # Nejdřív koupené nohy, pak prodané (marže).
        fills = {}
        for c, side in sorted(legs, key=lambda x: -x[1]):
            ticket = self.market_order(c.symbol, side * qty, tag=play)
            fills[c.symbol] = ticket.average_fill_price or (c.bid_price + c.ask_price) / 2
        filled_premium = sum(side * fills[c.symbol] for c, side in legs)
        self.position = {
            "play": play, "legs": [(c.symbol, side) for c, side in legs], "premium": filled_premium,
            "credit": credit, "expiry": expiry, "signal": 0 if play == "iron_condor" else self.target,
        }
        self.debug(f"{self.time.date()} {play} {[(c.strike, side) for c, side in legs]} prémie {filled_premium:.2f} × {qty} | HV rank {rank:.0f}")
"""#
}
