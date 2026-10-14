import Foundation
import Backtest

/// Export strategie do QuantConnectu (LEAN, Python): skript se vloží do webového editoru
/// na quantconnect.com a spustí na jejich datech (akcie, u opcí minutové kotace od 2012).
///
/// Strategie Breakout/Breakdown, Odraz od KP a Trendlinie jsou porty `BreakoutStrategy`, `MABounceStrategy`
/// a `TrendlineStrategy` z `Backtest`
/// (stejné výsledky jako testy jádra).
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


class MaBounce:
    """Odraz od klouzavých průměrů (SMA 20/50/100/200), long i short.

    Reverzní svíčka (předposlední) má tělo nad průměrem a spodní stín skrz něj, potvrzující svíčka (poslední)
    je býčí, má vyšší dno a zavře nad reverzní svíčkou. Reverzní svíčka je buď níž než předchozí dvě
    (2svíčkový pattern), nebo pinbar (1svíčkový). Podmínky podle průměru: 20 a 50 – KP 20 > 50 > 100 > 200,
    100 – 50 > 100 > 200, 200 – 100 > 200; průměr byl testovaný už dřív; u 20 týdenní cena nad 10 MA a týdenní
    KP rostou; u 50 stochastic pod 30. Stop pod reverzní svíčku, aspoň 1× ATR; cíl Fibonacciho extenze
    pullbacku v rozmezí 1,5–3 R; mezi swingem a cílem žádná rezistence. Short zrcadlově.
    """
    K = 3
    ATR_N = 14
    PERIODS = (20, 50, 100, 200)

    def __init__(self, ma20=True, ma50=True, ma100=True, ma200=True, two_candle=True, one_candle=True,
                 prior_test=True, prior_bars=60, weekly=True, stochastic=True, headroom=True,
                 stop_atr=1.0, target_fib=1.618, min_rr=1.5, max_rr=3.0, swing_bars=20, allow_short=True):
        self.enabled = {20: ma20, 50: ma50, 100: ma100, 200: ma200}
        self.two_candle, self.one_candle = two_candle, one_candle
        self.prior_test, self.prior_bars = prior_test, prior_bars
        self.use_weekly, self.use_stoch, self.use_headroom = weekly, stochastic, headroom
        self.stop_atr, self.target_fib = stop_atr, target_fib
        self.min_rr, self.max_rr, self.swing_bars = min_rr, max_rr, swing_bars
        self.allow_short = allow_short
        self.bars, self.closes, self.trs, self.atr = [], [], [], []
        self.ma = {p: [] for p in self.PERIODS}
        self.raw_k, self.slow_k = [], []
        self.pivot_hi, self.pivot_lo = [], []
        self.week_key, self.week_close = None, None
        self.w_closes = []
        self.w_state = 0          # 1 cena nad 10 MA a týdenní KP rostou, -1 zrcadlově
        self.position = 0
        self.stop = self.target = 0.0
        self.signals = []         # (index, period, direction, stop, target)

    def _weekly(self, bar):
        if self.week_key is not None and bar.week != self.week_key:
            self.w_closes.append(self.week_close)
            self.w_state = 0
            if len(self.w_closes) >= 41:
                now = [sma_last(self.w_closes, n) for n in (10, 20, 40)]
                prev = [sma_last(self.w_closes[:-1], n) for n in (10, 20, 40)]
                c = self.w_closes[-1]
                if c > now[0] and all(a > b for a, b in zip(now, prev)):
                    self.w_state = 1
                elif c < now[0] and all(a < b for a, b in zip(now, prev)):
                    self.w_state = -1
        self.week_key = bar.week
        self.week_close = bar.close

    def _indicators(self, bar):
        i = len(self.bars) - 1
        self.closes.append(bar.close)
        if i == 0:
            self.trs.append(bar.high - bar.low)
        else:
            pc = self.closes[-2]
            self.trs.append(max(bar.high - bar.low, abs(bar.high - pc), abs(bar.low - pc)))
        self.atr.append(sum(self.trs[-self.ATR_N:]) / self.ATR_N if i >= self.ATR_N else None)
        for p in self.PERIODS:
            self.ma[p].append(sma_last(self.closes, p))
        if i >= 20:
            window = self.bars[i - 20:i + 1]
            hh = max(b.high for b in window)
            ll = min(b.low for b in window)
            self.raw_k.append(100.0 * (bar.close - ll) / (hh - ll) if hh > ll else 50.0)
        else:
            self.raw_k.append(None)
        last3 = self.raw_k[-3:]
        self.slow_k.append(sum(last3) / 3 if len(last3) == 3 and None not in last3 else None)
        p = i - self.K
        if p >= self.K:
            hp, lp = self.bars[p].high, self.bars[p].low
            left = self.bars[p - self.K:p]
            right = self.bars[p + 1:i + 1]
            if all(x.high < hp for x in left) and all(x.high <= hp for x in right):
                self.pivot_hi.append(p)
            if all(x.low > lp for x in left) and all(x.low >= lp for x in right):
                self.pivot_lo.append(p)

    def _aligned(self, period, i, d):
        m = self.ma
        need = {20: (20, 50, 100, 200), 50: (20, 50, 100, 200), 100: (50, 100, 200), 200: (100, 200)}[period]
        values = [m[p][i] for p in need]
        if None in values:
            return False
        return all((values[k] - values[k + 1]) * d > 0 for k in range(len(values) - 1))

    def _tested_before(self, period, r, d):
        start = max(0, r - self.prior_bars)
        for j in range(start, r - 4):
            v = self.ma[period][j]
            if v is None:
                continue
            b = self.bars[j]
            if d == 1 and b.low <= v and b.close > v:
                return True
            if d == -1 and b.high >= v and b.close < v:
                return True
        return False

    def _pattern(self, period, i, d):
        r = i - 1
        R, C = self.bars[r], self.bars[i]
        v = self.ma[period][r]
        if v is None or r < 2:
            return False
        body_lo, body_hi = min(R.open, R.close), max(R.open, R.close)
        body = body_hi - body_lo
        rng = R.high - R.low
        if d == 1:
            if not (body_lo > v and R.low < v):
                return False
            two = R.low < min(self.bars[r - 1].low, self.bars[r - 2].low)
            wick = body_lo - R.low
            pin = rng > 0 and wick >= 2 * body and wick >= 0.5 * rng
            if not ((self.two_candle and two) or (self.one_candle and pin)):
                return False
            return C.close > C.open and C.low > R.low and C.close > R.high
        if not (body_hi < v and R.high > v):
            return False
        two = R.high > max(self.bars[r - 1].high, self.bars[r - 2].high)
        wick = R.high - body_hi
        pin = rng > 0 and wick >= 2 * body and wick >= 0.5 * rng
        if not ((self.two_candle and two) or (self.one_candle and pin)):
            return False
        return C.close < C.open and C.high < R.high and C.close < R.low

    def _filters(self, period, i, d):
        if not self._aligned(period, i, d):
            return False
        if self.prior_test and not self._tested_before(period, i - 1, d):
            return False
        if period == 20 and self.use_weekly and self.w_state != d:
            return False
        if period == 50 and self.use_stoch:
            ks = [k for k in self.slow_k[max(0, i - 3):i + 1] if k is not None]
            if not ks:
                return False
            if d == 1 and min(ks) >= 30:
                return False
            if d == -1 and max(ks) <= 70:
                return False
        return True

    def _plan(self, i, d, atr):
        r = i - 1
        R = self.bars[r]
        entry = self.bars[i].close
        start = max(0, r - self.swing_bars + 1)
        if d == 1:
            stop = min(R.low, entry - self.stop_atr * atr)
            risk = entry - stop
            swing = max(b.high for b in self.bars[start:r + 1])
            fib = R.low + (swing - R.low) * self.target_fib
            target = min(max(fib, entry + self.min_rr * risk), entry + self.max_rr * risk)
            if self.use_headroom:
                for p in self.pivot_hi:
                    h = self.bars[p].high
                    if swing < h < target:
                        return None
        else:
            stop = max(R.high, entry + self.stop_atr * atr)
            risk = stop - entry
            swing = min(b.low for b in self.bars[start:r + 1])
            fib = R.high - (R.high - swing) * self.target_fib
            target = max(min(fib, entry - self.min_rr * risk), entry - self.max_rr * risk)
            if self.use_headroom:
                for p in self.pivot_lo:
                    lo = self.bars[p].low
                    if target < lo < swing:
                        return None
        return stop, target

    def update(self, bar):
        self.bars.append(bar)
        self._weekly(bar)
        self._indicators(bar)
        i = len(self.bars) - 1
        atr = self.atr[i]
        if atr is None or i < 3:
            return self.position
        exited = False
        if self.position == 1 and (bar.close <= self.stop or bar.close >= self.target):
            self.position, exited = 0, True
        elif self.position == -1 and (bar.close >= self.stop or bar.close <= self.target):
            self.position, exited = 0, True
        if self.position == 0 and not exited:
            for d in ((1, -1) if self.allow_short else (1,)):
                done = False
                for period in self.PERIODS:
                    if not self.enabled[period]:
                        continue
                    if self._pattern(period, i, d) and self._filters(period, i, d):
                        plan = self._plan(i, d, atr)
                        if plan is not None:
                            self.position, (self.stop, self.target) = d, plan
                            self.signals.append((i, period, d, self.stop, self.target))
                            done = True
                        break
                if done:
                    break
        return self.position

    def watch(self):
        """Cena se v trendu vrací k průměru (do 1× ATR nad ním / pod ním): (směr, perioda, hladina, vzdálenost v ATR)."""
        i = len(self.bars) - 1
        if i < 3 or self.atr[i] is None or self.position != 0:
            return None
        atr, bar, prev = self.atr[i], self.bars[i], self.bars[i - 1]
        for d in ((1, -1) if self.allow_short else (1,)):
            for period in self.PERIODS:
                v = self.ma[period][i]
                if not self.enabled[period] or v is None:
                    continue
                if not self._aligned(period, i, d):
                    continue
                if period == 20 and self.use_weekly and self.w_state != d:
                    continue
                distance = (bar.close - v) * d / atr
                if 0 <= distance <= 1 and (bar.close - prev.close) * d < 0:
                    return d, period, v, distance
        return None


class Trendline:
    """Trendlinie a trojúhelník: průraz trojúhelníku, odraz od trendline, průraz trendline (long i short).

    Linie vedou přes potvrzené swingy (pivot ±3 svíčky) posledních `lookback` svíček; zavírací ceny je od první
    kotvy nesmí překročit o víc než toleranci, aspoň `min_touches` swingů leží na linii.
    Trojúhelník: klesající / plochá rezistence a rostoucí / plochý support, které se sbíhají (šířka teď nejvýš
    60 % šířky na začátku). Průraz: zavření za linií (předtím před ní), čistá svíčka hned nebo druhý den;
    cíl u trojúhelníku výška trojúhelníku od linie, u trendline Fibonacciho extenze od první kotvy; stop jako
    u breakoutu. Odraz: reverzní pattern na rostoucí (klesající) trendline jako u odrazu od KP.
    Filtry: týdenní KP 10/20/40 + PSAR ve směru, denní SMA 50 > 100 > 200 ve směru.
    """
    K = 3
    ATR_N = 14
    MAX_PIVOTS = 8

    def __init__(self, triangle=True, bounce=True, breakout=True, lookback=120, min_touches=2, tolerance=0.01,
                 flat=0.0003, weekly=True, daily=True, headroom=True, stop_atr=1.0, target_fib=1.618,
                 min_rr=1.5, max_rr=3.0, swing_bars=20, two_candle=True, one_candle=True, allow_short=True):
        self.use_triangle, self.use_bounce, self.use_breakout = triangle, bounce, breakout
        self.lookback, self.min_touches, self.tol, self.flat = lookback, min_touches, tolerance, flat
        self.use_weekly, self.use_daily, self.use_headroom = weekly, daily, headroom
        self.stop_atr, self.target_fib = stop_atr, target_fib
        self.min_rr, self.max_rr, self.swing_bars = min_rr, max_rr, swing_bars
        self.two_candle, self.one_candle = two_candle, one_candle
        self.allow_short = allow_short
        self.bars, self.closes, self.trs, self.atr = [], [], [], []
        self.sma = {50: [], 100: [], 200: []}
        self.pivot_hi, self.pivot_lo = [], []
        self.week_key, self.week = None, None
        self.w_closes = []
        self.w_psar = Psar()
        self.w_up = None
        self.w_trend = 0
        self.position = 0
        self.stop = self.target = 0.0
        self.pending = {1: None, -1: None}   # (kind, line, height_or_top, other)
        self.signals = []                    # (index, kind, direction, level, stop, target)

    # ---- data ----
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
        p = i - self.K
        if p >= self.K:
            hp, lp = self.bars[p].high, self.bars[p].low
            left = self.bars[p - self.K:p]
            right = self.bars[p + 1:i + 1]
            if all(x.high < hp for x in left) and all(x.high <= hp for x in right):
                self.pivot_hi.append(p)
            if all(x.low > lp for x in left) and all(x.low >= lp for x in right):
                self.pivot_lo.append(p)

    # ---- linie ----
    @staticmethod
    def value(line, x):
        p1, y1, slope = line[0], line[1], line[4]
        return y1 + slope * (x - p1)

    def _lines(self, hi, i):
        """Nejlepší linie do svíčky i−1 podle sklonu: {-1: klesající, 0: plochá, 1: rostoucí}.
        Linie = (p1, y1, p2, y2, slope, touches)."""
        source = self.pivot_hi if hi else self.pivot_lo
        piv = [p for p in source if i - self.lookback <= p <= i - 1 - self.K][-self.MAX_PIVOTS:]
        best = {}
        for a in range(len(piv)):
            for b in range(a + 1, len(piv)):
                p1, p2 = piv[a], piv[b]
                if p2 - p1 < 5:
                    continue
                y1 = self.bars[p1].high if hi else self.bars[p1].low
                y2 = self.bars[p2].high if hi else self.bars[p2].low
                slope = (y2 - y1) / (p2 - p1)
                ok = True
                for j in range(p1, i):
                    v = y1 + slope * (j - p1)
                    c = self.bars[j].close
                    if (hi and c > v * (1 + self.tol)) or (not hi and c < v * (1 - self.tol)):
                        ok = False
                        break
                if not ok:
                    continue
                touches = 0
                for q in piv:
                    if q < p1:
                        continue
                    v = y1 + slope * (q - p1)
                    y = self.bars[q].high if hi else self.bars[q].low
                    if abs(y - v) <= self.tol * v:
                        touches += 1
                if touches < self.min_touches:
                    continue
                ref = self.closes[i - 1]
                cls = 0 if abs(slope) <= self.flat * ref else (1 if slope > 0 else -1)
                key = (touches, p2, p2 - p1)
                if cls not in best or key > best[cls][0]:
                    best[cls] = (key, (p1, y1, p2, y2, slope, touches))
        return {k: v[1] for k, v in best.items()}

    @staticmethod
    def _pick(lines, classes):
        chosen = None
        for c in classes:
            if c in lines:
                ln = lines[c]
                key = (ln[5], ln[2], ln[2] - ln[0])
                if chosen is None or key > chosen[0]:
                    chosen = (key, ln)
        return chosen[1] if chosen else None

    def _triangle(self, i, highs, lows):
        res = self._pick(highs, (-1, 0))
        sup = self._pick(lows, (0, 1))
        if res is None or sup is None:
            return None
        if res[4] - sup[4] >= -self.flat * self.closes[i - 1]:
            return None
        start = min(res[0], sup[0])
        if max(res[0], sup[0]) >= min(res[2], sup[2]):
            return None
        w0 = self.value(res, start) - self.value(sup, start)
        w1 = self.value(res, i) - self.value(sup, i)
        if w0 <= 0 or w1 <= 0 or w1 > 0.6 * w0:
            return None
        c = self.closes[i - 1]
        if not (self.value(sup, i - 1) <= c <= self.value(res, i - 1)):
            return None
        return res, sup, w0

    # ---- filtry a pomocné ----
    def _filters(self, d):
        i = len(self.bars) - 1
        if d == -1 and not self.allow_short:
            return False
        if self.use_weekly and not (self.w_trend == d and self.w_up == (d == 1)):
            return False
        if self.use_daily:
            a, b, c = self.sma[50][i], self.sma[100][i], self.sma[200][i]
            if c is None or not ((a - b) * d > 0 and (b - c) * d > 0):
                return False
        return True

    def _clean(self, d, level):
        bar = self.bars[-1]
        return (bar.open - level) * d > 0 and (bar.close - level) * d > 0 and (bar.close - bar.open) * d > 0

    def _breakout_plan(self, kind, d, line, extra, atr):
        """extra: u trojúhelníku výška, u trendline (top, other)."""
        i = len(self.bars) - 1
        bar, prev = self.bars[i], self.bars[i - 1]
        close = bar.close
        lv = self.value(line, i)
        if d == 1:
            stop = min(prev.low, close - self.stop_atr * atr)
        else:
            stop = max(prev.high, close + self.stop_atr * atr)
        risk = (close - stop) * d
        if kind == "triangle":
            target = lv + d * extra
            target = max(target, close + 1.5 * atr) if d == 1 else min(target, close - 1.5 * atr)
        else:
            top, other = extra
            target = other + (top - other) * self.target_fib
            target = max(target, close + 1.5 * atr) if d == 1 else min(target, close - 1.5 * atr)
            if (target - close) * d < self.min_rr * risk:
                return None
        return stop, target

    def _bounce(self, d, line, atr):
        i = len(self.bars) - 1
        r = i - 1
        if r < 2:
            return None
        R, C = self.bars[r], self.bars[i]
        v = self.value(line, r)
        body_lo, body_hi = min(R.open, R.close), max(R.open, R.close)
        body = body_hi - body_lo
        rng = R.high - R.low
        if d == 1:
            if not (body_lo > v and R.low <= v * (1 + self.tol)):
                return None
            two = R.low < min(self.bars[r - 1].low, self.bars[r - 2].low)
            wick = body_lo - R.low
            pin = rng > 0 and wick >= 2 * body and wick >= 0.5 * rng
            if not ((self.two_candle and two) or (self.one_candle and pin)):
                return None
            if not (C.close > C.open and C.low > R.low and C.close > R.high):
                return None
        else:
            if not (body_hi < v and R.high >= v * (1 - self.tol)):
                return None
            two = R.high > max(self.bars[r - 1].high, self.bars[r - 2].high)
            wick = R.high - body_hi
            pin = rng > 0 and wick >= 2 * body and wick >= 0.5 * rng
            if not ((self.two_candle and two) or (self.one_candle and pin)):
                return None
            if not (C.close < C.open and C.high < R.high and C.close < R.low):
                return None
        entry = C.close
        start = max(0, r - self.swing_bars + 1)
        if d == 1:
            stop = min(R.low, entry - self.stop_atr * atr)
            risk = entry - stop
            swing = max(b.high for b in self.bars[start:r + 1])
            fib = R.low + (swing - R.low) * self.target_fib
            target = min(max(fib, entry + self.min_rr * risk), entry + self.max_rr * risk)
            if self.use_headroom:
                for p in self.pivot_hi:
                    h = self.bars[p].high
                    if swing < h < target:
                        return None
        else:
            stop = max(R.high, entry + self.stop_atr * atr)
            risk = stop - entry
            swing = min(b.low for b in self.bars[start:r + 1])
            fib = R.high - (R.high - swing) * self.target_fib
            target = max(min(fib, entry - self.min_rr * risk), entry - self.max_rr * risk)
            if self.use_headroom:
                for p in self.pivot_lo:
                    lo = self.bars[p].low
                    if target < lo < swing:
                        return None
        return stop, target

    # ---- hlavní krok ----
    def update(self, bar):
        self.bars.append(bar)
        self._weekly(bar)
        self._indicators(bar)
        i = len(self.bars) - 1
        atr = self.atr[i]
        if atr is None or i < 3:
            return self.position

        exited = False
        if self.position == 1 and (bar.close <= self.stop or bar.close >= self.target):
            self.position, exited = 0, True
        elif self.position == -1 and (bar.close >= self.stop or bar.close <= self.target):
            self.position, exited = 0, True

        highs = self._lines(True, i)
        lows = self._lines(False, i)
        tri = self._triangle(i, highs, lows) if self.use_triangle else None
        cands = []   # (priority, kind, d, line, extra)
        for d in (1, -1):
            pend = self.pending[d]
            self.pending[d] = None
            if pend is not None and self._clean(d, self.value(pend[1], i)):
                cands.append((0 if pend[0] == "triangle" else 1, pend[0], d, pend[1], pend[2]))
            # průraz trojúhelníku
            if tri is not None:
                res, sup, height = tri
                line = res if d == 1 else sup
                if (bar.close - self.value(line, i)) * d > 0:
                    if self._clean(d, self.value(line, i)):
                        cands.append((0, "triangle", d, line, height))
                    else:
                        self.pending[d] = ("triangle", line, height)
            # průraz trendline (klesající rezistence nahoru, rostoucí support dolů)
            if self.use_breakout:
                line = highs.get(-1) if d == 1 else lows.get(1)
                if line is not None and (bar.close - self.value(line, i)) * d > 0 \
                        and (self.closes[i - 1] - self.value(line, i - 1)) * d <= 0:
                    seg = self.bars[line[0]:i]
                    other = min(b.low for b in seg) if d == 1 else max(b.high for b in seg)
                    extra = (line[1], other)
                    if self._clean(d, self.value(line, i)):
                        cands.append((1, "breakout", d, line, extra))
                    elif self.pending[d] is None:
                        self.pending[d] = ("breakout", line, extra)
            # odraz od trendline (rostoucí support u longu, klesající rezistence u shortu)
            if self.use_bounce:
                line = lows.get(1) if d == 1 else highs.get(-1)
                if line is not None:
                    cands.append((2, "bounce", d, line, None))

        if self.position == 0 and not exited:
            for _, kind, d, line, extra in sorted(cands, key=lambda c: c[0]):
                if not self._filters(d):
                    continue
                if kind == "bounce":
                    plan = self._bounce(d, line, atr)
                else:
                    plan = self._breakout_plan(kind, d, line, extra, atr)
                if plan is None:
                    continue
                self.position, (self.stop, self.target) = d, plan
                self.signals.append((i, kind, d, self.value(line, i), self.stop, self.target))
                self.pending = {1: None, -1: None}
                break
        return self.position

    def watch(self):
        """Kandidát na poslední svíčce: cena uvnitř trojúhelníku, nebo u trendline (do 1× ATR).
        Vrací (druh, směr, hladina, vzdálenost v ATR)."""
        i = len(self.bars) - 1
        if i < 3 or self.atr[i] is None or self.position != 0:
            return None
        atr, close = self.atr[i], self.bars[i].close
        highs = self._lines(True, i)
        lows = self._lines(False, i)
        if self.use_triangle:
            tri = self._triangle(i, highs, lows)
            if tri is not None:
                res, sup, _ = tri
                for d in (1, -1):
                    if self._filters(d):
                        line = res if d == 1 else sup
                        lv = self.value(line, i)
                        distance = (lv - close) * d / atr
                        if distance >= 0:
                            return "triangle", d, lv, distance
        if self.use_bounce:
            for d in (1, -1):
                line = lows.get(1) if d == 1 else highs.get(-1)
                if line is None or not self._filters(d):
                    continue
                lv = self.value(line, i)
                distance = (close - lv) * d / atr
                if 0 <= distance <= 1:
                    return "bounce", d, lv, distance
        return None


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
        # Výstup podle strategie: opce kopírují akciové obchody, před expirací se přerolují.
        self.follow = {{FOLLOW}}
        self.roll = {{ROLL}}
        self.entry_signal = None   # nový vstup strategie, na který se čeká
        self.roll_signal = None

        self.position = None
        self.blocked = None

    # ----- signál a volatilita z denních svíček -----

    def on_daily(self, bar):
        week = tuple(bar.time.isocalendar()[:2])
        new_target = self.signal.update(Bar(bar.open, bar.high, bar.low, bar.close, week))
        if new_target != self.target:
            self.entry_signal = new_target
        self.target = new_target
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
            if self.entry_signal is not None and self.entry_signal != self.target:
                self.entry_signal = None
            wanted = self.entry_signal is not None or self.roll_signal == self.target
            rank = self.vol_rank()
            if wanted and rank is not None and chain is not None:
                play = self.choose(self.target, rank)
                if play:
                    self.open(play, chain, rank)
                    self.entry_signal = None
            self.roll_signal = None

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
        if self.target != p["signal"]:
            reason = "signal"
        elif self.follow:
            if days_left <= self.exit_dte:
                reason = "roll" if self.roll else "cas"
        elif p["credit"]:
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
        if reason:
            for sym, side in p["legs"]:
                self.liquidate(sym, tag=reason)
            self.roll_signal = p["signal"] if reason == "roll" else None
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
