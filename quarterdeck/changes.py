# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""Change points: where in a series of runs a host's level moved.

    qd changes iperf -c mbps                 every run of it so far
    qd changes iperf -c mbps --last 60 --peers sku --higher-is-better

`qd compare` holds runs against a fixed reference: the first run, or a
qualified baseline.  A node whose bandwidth slips 2 % a month never
crosses a 5 % drift from last week's run, and a baseline set last quarter
shows the gap but not when it opened.  This finds *where* each host's
series changed level -- "between run 14 and run 15" -- and splits it into
stable stretches, so the change can be lined up with whatever else
changed then (a firmware update, a facts run).

Each run is reduced the way compare reduces one (`compare.compare`): a
key's rows to one number (the median), a peer group to the median of its
keys.  So a host, or a peer group, has one value per run, oldest first.
A run where it was not measured is left out of its series (blank is not
measured, never zero) and named as a gap.

The statistic is e-divisive means (Matteson and James, "A Nonparametric
Approach for Multiple Change Point Analysis of Multivariate Data", JASA
109(505), 2014) with alpha 1, as MongoDB runs it (Daly et al., "The Use
of Change Point Detection to Identify Software Performance Regressions
in a Continuous Integration System", ICPE 2020; signal-processing-
algorithms 2.1.6, `energy_statistics.e_divisive`, Apache-2.0), ported
here line for line in the standard library:

  * every split of a stretch into X (before tau) and Y (from tau on) is
    scored t = n*m/(n+m) * (2*mean|X-Y| - mean|X-X'| - mean|Y-Y'|),
    the means over every ordered pair, as theirs are;
  * the best split of any stretch is a candidate; it is significant when
    no more than p of `permutations` shuffles (each stretch shuffled
    within itself) score as high: count / (permutations + 1) <= p;
  * a significant split is kept and the stretches are searched again,
    until a candidate is not significant.

Defaults are MongoDB's: p 0.05, 100 permutations.  The shuffles come from
the standard library's `random`, seeded afresh for every series with
SEED, so the same runs give the same answer every time, on every Python
from 3.6.  (Not the same shuffles as numpy's: the statistic matches the
reference to the last digit or so; the permutation test matches it in
distribution, not draw for draw.)

Then three rules of qd's own, each from a tool that found it needed it:

  * an outlier is not a step (Conbench): a stretch of one run between two
    others -- a jump that reverses at once -- or one run alone at either
    end is not a stretch, and its change points are dropped.  So the
    latest run can never be a change point by itself: a change shows a
    run or two after it happens, as MongoDB says of theirs;
  * a floor (--min-change, as Otava's -M): a step smaller than PCT % of
    the level before it is listed as a step but not reported as a change;
  * asv's best-to-latest rule (asv 0.6.6, `step_detect.detect_regressions`):
    the gap between the best stretch and the latest, with every step that
    explains it, so a slide made of many small steps is reported even
    when no one step passes the floor.

Each stretch carries its median, MAD and count; each step its size in
percent of the level before it and in MADs (of the noisier stretch either
side).  Fewer than MIN_RUNS measured runs is "too few runs", never "no
change".
"""

import bisect
import random

from .baseline import mad, median, pct

SEED = 20261110
MIN_RUNS = 5
DIRECTIONS = (None, "higher", "lower")


class Series(object):
    """One host's (or peer group's) values, run by run, and what was found
    in them."""

    def __init__(self, key, values):
        self.key = key              # a tuple: the key's values, or (peer,)
        self.idx = [i for i, v in enumerate(values) if v is not None]
        self.xs = [values[i] for i in self.idx]
        self.missing = [i for i, v in enumerate(values) if v is None]
        self.too_few = len(self.xs) < MIN_RUNS
        self.found = []             # change points e-divisive kept
        self.outliers = []          # run indices dropped as outliers
        self.stretches = []         # [Stretch]
        self.gap = None             # best-to-latest: (best, latest, pct, steps)

    def changes(self):
        """Steps that pass the floor."""
        return [s for s in self.stretches[1:] if s.reported]

    def status(self):
        if self.too_few:
            return "too few runs"
        if self.changes():
            return "changed"
        if self.gap is not None:
            return "slid"
        return "no change"


class Stretch(object):
    def __init__(self, first, last, xs):
        self.first, self.last = first, last     # run indices, inclusive
        self.n = len(xs)
        self.median = median(xs)
        self.mad = mad(xs)
        # the step into this stretch from the one before (None for the first)
        self.pct = None
        self.mads = None
        self.word = ""
        self.reported = False


# ---------------------------------------------------------------------------
# the statistic
# ---------------------------------------------------------------------------

def _t(x2, y2, xy, n, m):
    """The reference's _calculate_stats, its t: x2 and y2 are the sums of
    the distances within X and within Y over ordered pairs, xy across."""
    xy_avg = xy / (n * m) if n > 0 and m > 0 else 0
    x_avg = x2 / (n ** 2) if n > 0 else 0
    y_avg = y2 / (m ** 2) if m > 0 else 0
    e = 2 * xy_avg - x_avg - y_avg
    return (n * m / float(n + m)) * e


class _Tree(object):
    """A Fenwick tree of counts and sums by rank: the sum of |v - x| over
    the values put in so far, in log time."""

    def __init__(self, size):
        self.size = size
        self.cnt = [0] * (size + 1)
        self.sum = [0.0] * (size + 1)
        self.all_n, self.all_s = 0, 0.0

    def add(self, rank, v):
        self.all_n += 1
        self.all_s += v
        i = rank + 1
        while i <= self.size:
            self.cnt[i] += 1
            self.sum[i] += v
            i += i & -i

    def dist(self, rank, v):
        """sum |v - x| over every x put in."""
        c, s = 0, 0.0
        i = rank + 1
        while i > 0:
            c += self.cnt[i]
            s += self.sum[i]
            i -= i & -i
        return (c * v - s) + ((self.all_s - s) - (self.all_n - c) * v)


def _totals(xs):
    """Each value's summed distance to every value of xs (order free)."""
    srt = sorted(xs)
    pre = [0.0]
    for v in srt:
        pre.append(pre[-1] + v)
    n, total = len(srt), pre[-1]
    out = []
    for v in xs:
        k = bisect.bisect_right(srt, v)
        out.append((k * v - pre[k]) + ((total - pre[k]) - (n - k) * v))
    return out


def t_stats(xs, ranks=None, totals=None):
    """t for every split tau of xs (X = xs[:tau], Y = xs[tau:]), as the
    reference's _calculate_t_stats gives them: O(n log n), where the
    reference's is O(n^2).  `ranks` (each value's rank among xs) and
    `totals` (_totals) may be given when xs is a shuffle of values whose
    ranks and totals are already known."""
    n = len(xs)
    if ranks is None:
        order = sorted(range(n), key=lambda i: xs[i])
        ranks = [0] * n
        for r, i in enumerate(order):
            ranks[i] = r
    if totals is None:
        totals = _totals(xs)
    tree = _Tree(n)
    col = []                        # sum_{i<tau} |x_i - x_tau|
    for i, v in enumerate(xs):
        col.append(tree.dist(ranks[i], v))
        tree.add(ranks[i], v)
    x = xy = 0.0
    y = sum(col)                    # every pair once
    out = []
    for tau in range(n):
        out.append(_t(2 * x, 2 * y, xy, tau, n - tau))
        cd = col[tau]
        rd = totals[tau] - cd       # sum_{j>tau} |x_tau - x_j|
        xy = xy - cd + rd
        x += cd
        y -= rd
    return out


def _best(stats):
    """argmax, the first of equals, as numpy's."""
    b = 0
    for i, s in enumerate(stats):
        if s > stats[b]:
            b = i
    return b, stats[b]


def e_divisive(xs, p=0.05, permutations=100, seed=SEED):
    """The change points of xs (indices: where a new stretch starts), in
    the order found.  A port of signal-processing-algorithms'
    e_divisive (see the module's docstring)."""
    rng = random.Random(seed)
    n = len(xs)
    order = sorted(range(n), key=lambda i: xs[i])
    rank = [0] * n
    for r, i in enumerate(order):
        rank[i] = r
    memo = {}
    found = []
    while True:
        bounds = [0] + sorted(found) + [n]
        windows = list(zip(bounds, bounds[1:]))
        cands = []
        for a, b in windows:
            if (a, b) not in memo:
                i, s = _best(t_stats(xs[a:b]))
                memo[(a, b)] = (i + a, s)
            cands.append(memo[(a, b)])
        best = cands[0]
        for c in cands[1:]:
            if c[1] > best[1]:
                best = c
        prepared = []
        for a, b in windows:
            seg = xs[a:b]
            # ranks within the stretch, and totals: a shuffle keeps both
            o = sorted(range(b - a), key=lambda i: (rank[a + i]))
            rk = [0] * (b - a)
            for r, i in enumerate(o):
                rk[i] = r
            prepared.append((list(range(b - a)), seg, rk, _totals(seg)))
        better = 0
        for _ in range(permutations):
            top = None
            for perm, seg, rk, tot in prepared:
                rng.shuffle(perm)
                s = max(t_stats([seg[i] for i in perm], [rk[i] for i in perm],
                                [tot[i] for i in perm]))
                top = s if top is None or s > top else top
            if top >= best[1]:
                better += 1
        if better / float(permutations + 1) > p or not best[0]:
            return found
        found.append(best[0])


# ---------------------------------------------------------------------------
# stretches, steps and the slide
# ---------------------------------------------------------------------------

def _drop_outliers(cps, xs):
    """Change points with every stretch of one run taken out.  A run alone
    at either end joins the stretch beside it, as an outlier.  A run alone
    between two stretches is an outlier when the jump to it reverses at
    once (both its change points go, and the stretches either side join);
    when it sits on the way from one level to the next, it is the first
    run of the new level (the change point after it goes).  Returns
    (change points, the positions of the runs dropped as outliers)."""
    cps = sorted(cps)
    n = len(xs)
    out = []
    while True:
        bounds = [0] + cps + [n]
        lone = [i for i in range(len(bounds) - 1)
                if bounds[i + 1] - bounds[i] == 1]
        if not lone:
            return cps, out
        i = lone[0]
        at = bounds[i]
        drop = set()
        if i == 0:
            drop.add(bounds[1])
            out.append(at)
        elif i == len(bounds) - 2:
            drop.add(at)
            out.append(at)
        else:
            before = median(xs[bounds[i - 1]:at])
            after = median(xs[bounds[i + 1]:bounds[i + 2]])
            if (xs[at] - before) * (after - xs[at]) < 0:
                drop.update((at, bounds[i + 1]))
                out.append(at)
            else:
                drop.add(bounds[i + 1])
        cps = [c for c in cps if c not in drop]


def _word(d, direction):
    if direction == "higher":
        return "improvement" if d > 0 else "regression"
    if direction == "lower":
        return "regression" if d > 0 else "improvement"
    return "rose" if d > 0 else "fell"


def analyse(s, p=0.05, permutations=100, min_change=1.0, direction=None,
            seed=SEED):
    """Fill a Series in: its change points, stretches, steps and gap."""
    if direction not in DIRECTIONS:
        raise ValueError("direction is higher, lower or None")
    if s.too_few:
        return s
    cps = e_divisive(s.xs, p, permutations, seed)
    s.found = sorted(cps)
    kept, lone = _drop_outliers(cps, s.xs)
    s.outliers = [s.idx[i] for i in lone]
    bounds = [0] + kept + [len(s.xs)]
    for a, b in zip(bounds, bounds[1:]):
        xs = [s.xs[i] for i in range(a, b) if i not in lone]
        s.stretches.append(Stretch(s.idx[a], s.idx[b - 1], xs))
    for prev, st in zip(s.stretches, s.stretches[1:]):
        d = pct(prev.median, st.median)
        st.pct = d
        spread = max(prev.mad, st.mad)
        st.mads = (st.median - prev.median) / spread if spread else None
        st.word = _word(st.median - prev.median, direction) \
            if st.median != prev.median else ""
        st.reported = d is not None and abs(d) >= min_change and \
            st.median != prev.median
    s.gap = _gap(s, min_change, direction)
    return s


def _gap(s, min_change, direction):
    """asv's rule: the best stretch against the latest, and the steps
    between them.  Without a direction, "best" is the stretch farthest
    from the latest.  (best, latest, pct, steps) when the gap is
    min_change % or more, else None; steps are the stretches stepped
    into on the way, each carrying its own step."""
    sts = s.stretches
    if len(sts) < 2:
        return None
    latest = sts[-1]
    if direction == "higher":
        best = max(sts, key=lambda x: x.median)
    elif direction == "lower":
        best = min(sts, key=lambda x: x.median)
    else:
        best = max(sts, key=lambda x: abs(x.median - latest.median))
    if best is latest:
        return None
    d = pct(best.median, latest.median)
    if d is None or abs(d) < min_change:
        return None
    return (best, latest, d, sts[sts.index(best) + 1:])


def find(keys, p=0.05, permutations=100, min_change=1.0, direction=None,
         seed=SEED):
    """[(key, [value or None per run])] -> [Series], each analysed."""
    return [analyse(Series(k, vals), p, permutations, min_change, direction,
                    seed) for k, vals in keys]
