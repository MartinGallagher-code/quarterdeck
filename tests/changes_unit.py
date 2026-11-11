# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Martin J. Gallagher
"""quarterdeck.changes, the statistic alone: tests/test_changes.sh's unit.

    changes_unit.py QD_DIR CASE

Each CASE prints "ok" or raises.  Standard library only, Python 3.6 on;
nothing printed is outside ASCII, so LANG=C on 3.6 cannot mangle it.

The pinned values are signal-processing-algorithms 2.1.6's (Apache-2.0,
MongoDB): the figures its own tests assert, in
tests/test_energy_statistics.py (get_energy_statistics(x, y).t, to three
places: the t of e-divisive's split of x+y at len(x)) and
tests/test_e_divisive.py (test_absolute_certainty_univariate).  Read from
https://github.com/mongodb/signal-processing-algorithms, 2026-11-11.
"""

import random
import sys
import time

sys.path.insert(0, sys.argv[1])
from quarterdeck import changes as ch  # noqa: E402


def t_at(x, y):
    return ch.t_stats([float(v) for v in x + y])[len(x)]


def near(a, b, places=3):
    # numpy.testing.assert_almost_equal(decimal=places), as their tests
    assert abs(a - b) < 1.5 * 10 ** -places, "%r != %r" % (a, b)


def noise(sd, n=30, level=100.0, sigma=1.0):
    r = random.Random(sd)
    return [level + r.gauss(0, sigma) for _ in range(n)]


def case_pinned():
    # test_energy_statistics_similar_distributions
    near(t_at(list(range(1, 100)), list(range(1, 105))), 8.136)
    # ..._different_distributions
    near(t_at(list(range(1, 100)), list(range(10000, 13000, 14))),
         1481794.709)
    # ..._univariate_ndarray
    near(t_at(list(range(1, 300)), list(range(1000, 5000, 10))), 728381.015)
    # ..._univariate_list
    near(t_at(list(range(300, 500)), list(range(400, 900, 11))), 10035.943)
    # ..._same_distribution
    assert t_at(list(range(10, 70)), list(range(10, 70))) == 0
    # test_e_divisive.py: test_absolute_certainty_univariate
    assert ch.e_divisive([0.0] * 1000 + [1.0] * 1000) == [1000]


def case_brute():
    """The O(n log n) t against the reference's own definition, written
    out the slow way: every ordered pair."""
    xs = noise(3, 25)
    xs[7] = xs[3]                   # a tie
    fast = ch.t_stats(xs)
    for tau in range(len(xs)):
        X, Y = xs[:tau], xs[tau:]
        n, m = len(X), len(Y)
        x2 = sum(abs(a - b) for a in X for b in X)
        y2 = sum(abs(a - b) for a in Y for b in Y)
        xy = sum(abs(a - b) for a in X for b in Y)
        slow = ch._t(x2, y2, xy, n, m)
        assert abs(slow - fast[tau]) <= 1e-9 * max(1.0, abs(slow)), tau


def case_step():
    """A step of 5 % in noise of 1 %, at run 14 of 30: found there, every
    seed, and it is the biggest change found."""
    for sd in range(40):
        xs = noise(sd, 14) + noise(10000 + sd, 16, 95.0)
        s = ch.analyse(ch.Series(("h",), xs))
        assert s.status() == "changed", sd
        firsts = [x.first for x in s.changes()]
        assert 14 in firsts, (sd, firsts)
        big = max(s.changes(), key=lambda x: abs(x.pct))
        assert big.first == 14 and big.word == "fell", sd
        assert -6.5 < big.pct < -3.5 and big.mads < -3, (sd, big.pct)


def case_false_positives():
    """No step: over 300 seeds, the share with any change point is close
    to p (100 permutations: a p of 0.05 is at most 5 of 101, about 0.06).
    And which seeds they are is pinned: the shuffles are the same on
    every Python."""
    hit = [sd for sd in range(300) if ch.e_divisive(noise(1000 + sd))]
    rate = len(hit) / 300.0
    assert 0.02 <= rate <= 0.10, rate
    assert hit == PINNED_FALSE, hit


# the seeds of noise() (1000 + these) where e-divisive finds a change
# point that is not there: 19 of 300 (0.063), from Python 3.9 and 3.13
PINNED_FALSE = [11, 17, 54, 104, 105, 106, 114, 150, 151, 206, 211, 215,
                239, 245, 257, 264, 268, 275, 287]


def case_outlier():
    """One run far out, anywhere in the series: never a change, over many
    seeds; where e-divisive does split there, the stretch of one run is
    dropped and the run named as an outlier."""
    for sd in range(60):
        xs = noise(5000 + sd)
        at = sd % 30
        xs[at] = 130.0
        s = ch.analyse(ch.Series(("h",), xs))
        assert not s.changes(), (sd, [x.first for x in s.changes()])
        assert s.gap is None, sd
    # and the rule itself, on change points that bracket one run
    xs = [100.0] * 10 + [130.0] + [100.0] * 10
    assert ch._drop_outliers([10, 11], xs) == ([], [10])
    # a run on the way from one level to the next is not an outlier
    xs = [100.0] * 10 + [95.0] + [90.0] * 10
    assert ch._drop_outliers([10, 11], xs) == ([10], [])
    # one run alone at either end
    assert ch._drop_outliers([1, 10], [5.0] + [1.0] * 20) == ([10], [0])
    assert ch._drop_outliers([10, 20], [1.0] * 20 + [5.0]) == ([10], [20])


def case_slide():
    """Four levels 2.5 % apart, each step under a 5 % floor: no change is
    reported, and the best-to-latest gap is, with the three steps."""
    r = random.Random(3)
    xs = []
    for lvl in (100.0, 97.5, 95.0, 92.5):
        xs += [lvl + r.gauss(0, 0.2) for _ in range(15)]
    s = ch.analyse(ch.Series(("h",), xs), min_change=5.0,
                   direction="higher")
    assert not s.changes()
    assert [x.first for x in s.stretches] == [0, 15, 30, 45]
    assert all(abs(x.pct) < 5 for x in s.stretches[1:])
    best, latest, d, steps = s.gap
    assert best is s.stretches[0] and latest is s.stretches[-1]
    assert -8.5 < d < -6.5, d
    assert [x.first for x in steps] == [15, 30, 45]
    assert all(x.word == "regression" for x in steps)
    assert s.status() == "slid"
    # lower is better: the same fall is an improvement, and no gap
    s = ch.analyse(ch.Series(("h",), xs), min_change=5.0, direction="lower")
    assert s.gap is None and s.status() == "no change"
    assert all(x.word == "improvement" for x in s.stretches[1:])


def case_blanks():
    """None is not measured: left out of the series and named; never 0."""
    xs = noise(7, 12) + noise(8, 12, 80.0)
    vals = xs[:5] + [None] + xs[5:]
    s = ch.analyse(ch.Series(("h",), vals), min_change=5.0)
    assert s.missing == [5]
    assert 5 not in s.idx and len(s.xs) == 24
    assert [x.first for x in s.changes()] == [13]
    assert ch.analyse(ch.Series(("h",), [1.0, None, 2.0, 3.0, None,
                                         4.0])).status() == "too few runs"
    s = ch.analyse(ch.Series(("h",), [None] * 9))
    assert s.status() == "too few runs" and s.missing == list(range(9))


def case_deterministic():
    """The same series twice: the same answer, and a fresh seed each
    series, so one host's answer does not hang on the hosts before it."""
    a = ch.find([(("x",), noise(1, 40)), (("y",), noise(2, 40, 101.0))])
    b = ch.find([(("y",), noise(2, 40, 101.0))])
    assert a[1].found == b[0].found


def case_timing():
    """A 100-run series takes under a second (and says how long 500 do)."""
    xs = noise(9, 50) + noise(10, 50, 97.0)
    t0 = time.time()
    ch.analyse(ch.Series(("h",), xs))
    took = time.time() - t0
    assert took < 1.0, took
    xs = noise(9, 250) + noise(10, 250, 97.0)
    t0 = time.time()
    ch.analyse(ch.Series(("h",), xs))
    print("100 runs %.2fs, 500 runs %.2fs" % (took, time.time() - t0))


if __name__ == "__main__":
    globals()["case_" + sys.argv[2]]()
    print("ok")
