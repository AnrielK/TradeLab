import Foundation
import Backtest

/// Export strategie do QuantConnectu (LEAN, Python): skript se vloží do webového editoru
/// na quantconnect.com a spustí na jejich datech (akcie, u opcí minutové kotace od 2012).
///
/// Signály jsou port Swift strategií z `Backtest` (ověřeno na stejných scénářích jako testy jádra).
enum QuantConnectExport {
    static let signalsLibrary = #"""
# ===== TradeLab signály (port ze Swiftu, inkrementálně po svíčkách) =====
import math


class Ema:
    """EMA, první hodnota = SMA prvních `period` hodnot (jako TradeLab)."""
    def __init__(self, period):
        self.period = period
        self.values = []
        self.value = None

    def update(self, x):
        if self.value is None:
            self.values.append(x)
            if len(self.values) == self.period:
                self.value = sum(self.values) / self.period
        else:
            alpha = 2.0 / (self.period + 1)
            self.value = alpha * x + (1 - alpha) * self.value
        return self.value


class Sma:
    def __init__(self, period):
        self.period = period
        self.values = []
        self.value = None

    def update(self, x):
        self.values.append(x)
        if len(self.values) > self.period:
            self.values.pop(0)
        self.value = sum(self.values) / self.period if len(self.values) == self.period else None
        return self.value


class Rsi:
    """RSI s Wilderovým vyhlazením."""
    def __init__(self, period):
        self.period = period
        self.prev = None
        self.count = 0
        self.gain = 0.0
        self.loss = 0.0
        self.value = None

    def update(self, x):
        if self.prev is None:
            self.prev = x
            return None
        change = x - self.prev
        self.prev = x
        self.count += 1
        if self.count <= self.period:
            self.gain += max(change, 0)
            self.loss += max(-change, 0)
            if self.count == self.period:
                self.gain /= self.period
                self.loss /= self.period
                self.value = self._rsi()
            return self.value
        self.gain = (self.gain * (self.period - 1) + max(change, 0)) / self.period
        self.loss = (self.loss * (self.period - 1) + max(-change, 0)) / self.period
        self.value = self._rsi()
        return self.value

    def _rsi(self):
        if self.loss == 0:
            return 50.0 if self.gain == 0 else 100.0
        return 100 - 100 / (1 + self.gain / self.loss)


class Bar:
    def __init__(self, o, h, l, c):
        self.open, self.high, self.low, self.close = o, h, l, c


class BuyHold:
    def update(self, bar):
        return 1


class SmaCross:
    def __init__(self, fast, slow, allow_short):
        self.f, self.s, self.flat = Sma(fast), Sma(slow), (-1 if allow_short else 0)

    def update(self, bar):
        a, b = self.f.update(bar.close), self.s.update(bar.close)
        if a is None or b is None:
            return 0
        return 1 if a > b else self.flat


class MacdCross:
    def __init__(self, fast, slow, signal, allow_short):
        self.f, self.s, self.sig = Ema(fast), Ema(slow), Ema(signal)
        self.flat = -1 if allow_short else 0

    def update(self, bar):
        a, b = self.f.update(bar.close), self.s.update(bar.close)
        if a is None or b is None:
            return 0
        line = a - b
        sig = self.sig.update(line)
        if sig is None:
            return 0
        return 1 if line > sig else self.flat


class RsiReversion:
    def __init__(self, period, lower, upper, allow_short):
        self.r, self.lower, self.upper, self.allow_short = Rsi(period), lower, upper, allow_short
        self.position = 0

    def update(self, bar):
        value = self.r.update(bar.close)
        if value is None:
            return 0
        if value < self.lower:
            self.position = 1
        elif value > self.upper:
            self.position = -1 if self.allow_short else 0
        return self.position


class BreakRetest:
    def __init__(self, lookback, retest_bars, tolerance, allow_short):
        self.lookback, self.retest_bars, self.tol, self.allow_short = lookback, retest_bars, tolerance, allow_short
        self.bars, self.position, self.stop, self.armed = [], 0, 0.0, None

    def update(self, bar):
        self.bars.append(bar)
        i = len(self.bars) - 1
        if self.lookback < 2 or i < self.lookback:
            return 0
        window = self.bars[i - self.lookback:i]
        resistance = max(b.high for b in window)
        support = min(b.low for b in window)
        exit_window = max(self.lookback // 2, 3)
        recent = self.bars[max(i - exit_window, 0):i]
        trail_low = min(b.low for b in recent)
        trail_high = max(b.high for b in recent)
        c = bar.close
        if self.position == 1 and (c < self.stop or c < trail_low):
            self.position = 0
        elif self.position == -1 and (c > self.stop or c > trail_high):
            self.position = 0
        if self.position == 0 and self.armed:
            side, level, index = self.armed
            t = level * self.tol
            if i - index > self.retest_bars:
                self.armed = None
            elif side == 1:
                if c < level - t:
                    self.armed = None
                elif i > index and bar.low <= level + t and c > level:
                    self.position, self.stop, self.armed = 1, level - t, None
            else:
                if c > level + t:
                    self.armed = None
                elif i > index and bar.high >= level - t and c < level:
                    self.position, self.stop, self.armed = -1, level + t, None
        if self.position == 0 and self.armed is None:
            if c > resistance:
                self.armed = (1, resistance, i)
            elif self.allow_short and c < support:
                self.armed = (-1, support, i)
        return self.position


class Reversal:
    def __init__(self, period, lower, upper, allow_short):
        self.r, self.lower, self.upper, self.allow_short = Rsi(period), lower, upper, allow_short
        self.bars, self.rsi, self.position, self.stop = [], [], 0, 0.0

    def update(self, bar):
        self.bars.append(bar)
        self.rsi.append(self.r.update(bar.close))
        i = len(self.bars) - 1
        r = self.rsi[i]
        if i < 1 or r is None:
            return self.position if i >= 1 else 0
        prev = self.bars[i - 1]
        recent = [x for x in self.rsi[max(i - 3, 0):i + 1] if x is not None]
        oversold = any(x < self.lower for x in recent)
        overbought = any(x > self.upper for x in recent)
        bullish = bar.close > bar.open and bar.close > prev.high
        bearish = bar.close < bar.open and bar.close < prev.low
        swing = self.bars[max(i - 3, 0):i + 1]
        if self.position == 1 and (bar.close < self.stop or r > self.upper or bearish):
            self.position = 0
        elif self.position == -1 and (bar.close > self.stop or r < self.lower or bullish):
            self.position = 0
        if self.position == 0:
            if oversold and bullish:
                self.position, self.stop = 1, min(b.low for b in swing)
            elif self.allow_short and overbought and bearish:
                self.position, self.stop = -1, max(b.high for b in swing)
        return self.position


class MaBounce:
    def __init__(self, period, trend_period, tolerance, exponential, allow_short):
        self.ma = Ema(period) if exponential else Sma(period)
        self.trend = Sma(trend_period)
        self.tol, self.allow_short = tolerance, allow_short
        self.history, self.position = [], 0

    def update(self, bar):
        m = self.ma.update(bar.close)
        t = self.trend.update(bar.close)
        self.history.append(m)
        if len(self.history) <= 5 or m is None or t is None or self.history[-6] is None:
            return self.position
        past = self.history[-6]
        d = m * self.tol
        c = bar.close
        if self.position == 1 and c < m - d:
            self.position = 0
        if self.position == -1 and c > m + d:
            self.position = 0
        if self.position == 0:
            up = c > t and m > past
            down = c < t and m < past
            if up and bar.low <= m + d and c > m and c > bar.open:
                self.position = 1
            elif self.allow_short and down and bar.high >= m - d and c < m and c < bar.open:
                self.position = -1
        return self.position


# ----- Struktura: pivoty, hladiny, trendlinie (jen potvrzené pivoty) -----

PIVOT_K = 3


class Structure:
    def __init__(self, lookback, tolerance, reward_risk, allow_short):
        self.lookback, self.tol, self.rr, self.allow_short = lookback, tolerance, reward_risk, allow_short
        self.bars, self.pivots, self.position = [], [], 0

    def _confirm_pivot(self):
        k = PIVOT_K
        p = len(self.bars) - 1 - k
        if p < k:
            return
        b = self.bars
        h, l = b[p].high, b[p].low
        if all(j == p or b[j].high < h or (j > p and b[j].high <= h) for j in range(p - k, p + k + 1)):
            self.pivots.append((p, h, True))
        if all(j == p or b[j].low > l or (j > p and b[j].low >= l) for j in range(p - k, p + k + 1)):
            self.pivots.append((p, l, False))

    def window(self, i):
        return [x for x in self.pivots if i - self.lookback <= x[0] <= i - PIVOT_K]

    @staticmethod
    def levels(pivots, tol):
        clusters = []
        for price in sorted(x[1] for x in pivots):
            if clusters and abs(price - sum(clusters[-1]) / len(clusters[-1])) <= tol:
                clusters[-1].append(price)
            else:
                clusters.append([price])
        return [sum(c) / len(c) for c in clusters if len(c) >= 2]

    def trendline(self, pivots, kind, i, tol):
        """Nejlepší neproražená linie (platná do i−1): (start_index, start_price, slope)."""
        side = [x for x in pivots if x[2] == (kind == 'r')][-12:]
        last = i - 1
        best = None
        for a_i in range(len(side) - 1):
            for b_i in range(a_i + 1, len(side)):
                a, b = side[a_i], side[b_i]
                if b[0] - a[0] < 3:
                    continue
                slope = (b[1] - a[1]) / (b[0] - a[0])
                value = lambda x: a[1] + slope * (x - a[0])
                broken = False
                for k in range(a[0], last + 1):
                    c = self.bars[k].close
                    if (c < value(k) - tol) if kind == 's' else (c > value(k) + tol):
                        broken = True
                        break
                if broken:
                    continue
                touches = len([p for p in side[a_i:] if abs(p[1] - value(p[0])) <= tol])
                if touches < 2:
                    continue
                score = touches + (last - a[0]) / max(last + 1, 1) + side[b_i][0] / max(last, 1)
                if value(last) <= 0:
                    continue
                if best is None or score > best[0]:
                    best = (score, a[0], a[1], slope)
        return None if best is None else best[1:]

    def update(self, bar):
        self.bars.append(bar)
        self._confirm_pivot()
        return self.step(len(self.bars) - 1, bar)


class LevelBounce(Structure):
    def step(self, i, bar):
        c = bar.close
        if self.position == 1 and (c < self.level * (1 - self.tol) or c >= self.target):
            self.position = 0
        if self.position == -1 and (c > self.level * (1 + self.tol) or c <= self.target):
            self.position = 0
        if self.position == 0 and i > 2 * PIVOT_K:
            t = c * self.tol
            levels = self.levels(self.window(i), t)
            supports = [x for x in levels if x < c]
            resistances = [x for x in levels if x > c]
            s = max(supports) if supports else None
            r = min(resistances) if resistances else None
            if s is not None and bar.low <= s + t and c > bar.open:
                self.position, self.level = 1, s
                self.target = r if r is not None else c + self.rr * (c - s * (1 - self.tol))
            elif self.allow_short and r is not None and bar.high >= r - t and c < bar.open:
                self.position, self.level = -1, r
                self.target = s if s is not None else c - self.rr * (r * (1 + self.tol) - c)
        return self.position


class LevelBreakout(Structure):
    def step(self, i, bar):
        c = bar.close
        if i < 1:
            return 0
        prev = self.bars[i - 1].close
        if self.position == 1 and (c < self.level * (1 - self.tol) or c >= self.target):
            self.position = 0
        if self.position == -1 and (c > self.level * (1 + self.tol) or c <= self.target):
            self.position = 0
        if self.position == 0 and i > 2 * PIVOT_K:
            t = c * self.tol
            levels = self.levels(self.window(i), t)
            up = [x for x in levels if prev <= x and c > x + t]
            down = [x for x in levels if prev >= x and c < x - t]
            if up:
                r = max(up)
                above = [x for x in levels if x > c + t]
                self.position, self.level = 1, r
                self.target = min(above) if above else c + self.rr * (c - r * (1 - self.tol))
            elif self.allow_short and down:
                s = min(down)
                below = [x for x in levels if x < c - t]
                self.position, self.level = -1, s
                self.target = max(below) if below else c - self.rr * (s * (1 + self.tol) - c)
        return self.position


class TrendlineBounce(Structure):
    def step(self, i, bar):
        c = bar.close
        if self.position != 0:
            v = self.line[1] + self.line[2] * (i - self.line[0])
            if self.position == 1 and (c < v * (1 - self.tol) or c >= self.target):
                self.position = 0
            if self.position == -1 and (c > v * (1 + self.tol) or c <= self.target):
                self.position = 0
        if self.position == 0 and i > 2 * PIVOT_K + 3:
            t = c * self.tol
            w = self.window(i)
            s = self.trendline(w, 's', i, t)
            if s:
                v = s[1] + s[2] * (i - s[0])
                if v > 0 and bar.low <= v + t and c > v and c > bar.open:
                    self.position, self.line = 1, s
                    self.target = c + self.rr * (c - v * (1 - self.tol))
            if self.position == 0 and self.allow_short:
                r = self.trendline(w, 'r', i, t)
                if r:
                    v = r[1] + r[2] * (i - r[0])
                    if v > 0 and bar.high >= v - t and c < v and c < bar.open:
                        self.position, self.line = -1, r
                        self.target = c - self.rr * (v * (1 + self.tol) - c)
        return self.position


class TrendlineBreakout(Structure):
    def step(self, i, bar):
        c = bar.close
        if self.position != 0:
            v = self.line[1] + self.line[2] * (i - self.line[0])
            if self.position == 1 and (c < v * (1 - self.tol) or c >= self.target):
                self.position = 0
            if self.position == -1 and (c > v * (1 + self.tol) or c <= self.target):
                self.position = 0
        if self.position == 0 and i > 2 * PIVOT_K + 3:
            t = c * self.tol
            w = self.window(i)
            r = self.trendline(w, 'r', i, t)
            if r:
                v = r[1] + r[2] * (i - r[0])
                if v > 0 and c > v + t:
                    self.position, self.line = 1, r
                    self.target = c + self.rr * (c - v * (1 - self.tol))
            if self.position == 0 and self.allow_short:
                s = self.trendline(w, 's', i, t)
                if s:
                    v = s[1] + s[2] * (i - s[0])
                    if v > 0 and c < v - t:
                        self.position, self.line = -1, s
                        self.target = c - self.rr * (v * (1 + self.tol) - c)
        return self.position


class SwingPullback:
    def __init__(self, trend_period, swing_lookback, allow_short):
        self.e20, self.e50, self.trend, self.r = Ema(20), Ema(50), Sma(trend_period), Rsi(14)
        self.swing, self.allow_short = swing_lookback, allow_short
        self.bars, self.e50s, self.rsis = [], [], []
        self.position, self.stop, self.target = 0, 0.0, 0.0

    def update(self, bar):
        self.bars.append(bar)
        fast, mid = self.e20.update(bar.close), self.e50.update(bar.close)
        t, r = self.trend.update(bar.close), self.r.update(bar.close)
        self.e50s.append(mid)
        self.rsis.append(r)
        i = len(self.bars) - 1
        if i < max(self.swing, 5):
            return 0
        mid_past, r_prev = self.e50s[i - 5], self.rsis[i - 1]
        if None in (fast, mid, mid_past, t, r, r_prev):
            return self.position
        c = bar.close
        if self.position == 1 and (c <= self.stop or c >= self.target or c < mid):
            self.position = 0
        if self.position == -1 and (c >= self.stop or c <= self.target or c > mid):
            self.position = 0
        if self.position == 0:
            recent = self.bars[i - 4:i + 1]
            recent_low, recent_high = min(b.low for b in recent), max(b.high for b in recent)
            sw = self.bars[i - self.swing:i + 1]
            high, low = max(b.high for b in sw), min(b.low for b in sw)
            rng = high - low
            rr = [x for x in self.rsis[i - 4:i + 1] if x is not None]
            if rng <= 0:
                return self.position
            up = c > t and mid > t and mid > mid_past
            long_zone = (high - 0.786 * rng <= recent_low <= high - 0.382 * rng) or recent_low <= fast * 1.005
            long_mom = (min(rr) if rr else 50) < 45 and r > r_prev
            long_trig = c > bar.open and c > self.bars[i - 1].high
            down = c < t and mid < t and mid < mid_past
            short_zone = (low + 0.382 * rng <= recent_high <= low + 0.786 * rng) or recent_high >= fast * 0.995
            short_mom = (max(rr) if rr else 50) > 55 and r < r_prev
            short_trig = c < bar.open and c < self.bars[i - 1].low
            if up and long_zone and long_mom and long_trig and recent_low < c:
                self.position, self.stop, self.target = 1, recent_low, low + 1.272 * rng
                if self.target <= c:
                    self.target = c + 2 * (c - self.stop)
            elif self.allow_short and down and short_zone and short_mom and short_trig and recent_high > c:
                self.position, self.stop, self.target = -1, recent_high, high - 1.272 * rng
                if self.target >= c:
                    self.target = c - 2 * (self.stop - c)
        return self.position


class FibExit:
    """Fibonacciho výstup nad signálem strategie (cíl extenze, stop retracement swingu)."""
    def __init__(self, inner, lookback, target, stop):
        self.inner, self.lookback, self.target_ratio, self.stop_ratio = inner, lookback, target, stop
        self.bars, self.position, self.tp, self.sl, self.blocked = [], 0, 0.0, 0.0, 0

    def update(self, bar):
        self.bars.append(bar)
        signal = self.inner.update(bar)
        i, c = len(self.bars) - 1, bar.close
        if self.blocked != 0 and signal != self.blocked:
            self.blocked = 0
        if self.position != 0:
            hit_t = c >= self.tp if self.position == 1 else c <= self.tp
            hit_s = c <= self.sl if self.position == 1 else c >= self.sl
            if hit_t or hit_s:
                self.blocked = self.position if signal == self.position else 0
                self.position = 0
            elif signal != self.position:
                self.position = 0
        if self.position == 0 and signal != 0 and signal != self.blocked:
            w = self.bars[max(0, i - self.lookback):i + 1]
            high, low = max(b.high for b in w), min(b.low for b in w)
            rng = high - low
            if rng > 0:
                ext = self.target_ratio - 1 if self.target_ratio - 1 > 0 else 0.272
                if signal == 1:
                    self.tp, self.sl = low + rng * self.target_ratio, high - rng * self.stop_ratio
                    if self.sl >= c:
                        self.sl = low
                    if self.tp <= c:
                        self.tp = c + rng * ext
                else:
                    self.tp, self.sl = high - rng * self.target_ratio, low + rng * self.stop_ratio
                    if self.sl <= c:
                        self.sl = high
                    if self.tp >= c:
                        self.tp = c - rng * ext
                self.position = signal
        return self.position
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

    def on_data(self, data: Slice):
        bar = data.bars.get(self.symbol)
        if bar is None:
            return
        target = self.signal.update(Bar(bar.open, bar.high, bar.low, bar.close))
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
        self.target = self.signal.update(Bar(bar.open, bar.high, bar.low, bar.close))
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
