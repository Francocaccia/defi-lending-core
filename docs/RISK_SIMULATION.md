# Risk simulation (M9)

The protocol is tested for *correctness* (unit, fuzz, invariant, fork and differential tests). This document
asks a different question: **with the parameters it ships with, how often would a borrower have been
liquidated, and when would liquidations have left bad debt for suppliers?** It is answered by replaying the
protocol's own math over the real Chainlink price history and over synthetic paths built from it.

Everything below is produced by [`simulator/`](../simulator/README.md) (C++17, links the independent reference
model, so every decision uses the same exact integer math that was verified against the Solidity). Every
number in the tables is read from the CSV files in [`simulator/results/`](../simulator/results/); the exact
commands are at the end. **Read the [limits](#limits-read-before-quoting-a-number) before quoting anything.**

## What was simulated

One borrower position on one market (WETH collateral, USDC debt), passive (no top-ups, no repayments), opened at
a stated fraction of the max-LTV limit, then followed for 30, 90 or 365 days. Interest accrues with the
protocol's rate model at a fixed 80% utilization. When the health factor drops below 1, a liquidator acts after a
configurable **latency** (0 h = on the very next hourly observation, 72 h = three days later). It repays up to the
close factor and seizes collateral plus the bonus; if the collateral runs out first, the remainder is written off
as **bad debt** (the loss suppliers absorb; the protocol has no first-loss buffer).

Two kinds of price paths:

- **Historical:** *every* rolling window of the real history, one start per day, no period chosen or excluded
  (2,171 windows of 30 days, 2,111 of 90 days, 1,836 of 365 days).
- **Bootstrap:** 20,000 synthetic paths per horizon built by resampling the real hourly returns in blocks (mean block
  7 days, ETH and USDC jointly), which probes crashes the sample did not contain. Fixed seed.

## Data

On-chain round histories of the two Chainlink proxies the protocol's oracle wrapper reads, fetched read-only from
Ethereum mainnet (`simulator/tools/fetch_chainlink_history.py`): ETH/USD `0x5f4eC3Df...8419` (134,222 rounds,
2020-08-06 to 2026-10-15, SHA-256 `e609e72b521a499e...`) and USDC/USD `0x8fFfFfd4...18f6` (3,310 rounds from
2021-02-17, SHA-256 `27709eb2cf8a491e...`). The prices are replayed on an hourly grid with carry-forward of the last
round, which is what a contract reading the feed at that moment would see. Before the first USDC/USD round the
simulator assumes exactly $1.00 (stated in every report).

**The ETH/USD history used starts on 2020-10-06, not 2020-08-06.** The first rounds of that proxy are not live
market data: the answer stays at $379.04 and then $443.49 for days to weeks, with gaps of 88, 167 and 1,081
hours (45 days). From
2020-10-05 the longest gap is 3 hours. Keeping the earlier rounds would freeze the price for up to 45 days in the
grid, so every config sets `data.from` and every report states the exclusion. The raw download is committed
unchanged.

## How the engine was checked

- 61 unit tests (2,407 checks, MSVC 19.41), including a hand-computed crash scenario, exact-boundary cases, the
  dust filter, determinism across thread counts and a BOM-tolerant config loader.
- **Independent cross-check** (`simulator/tools/crosscheck.py`, output in
  [`simulator/results/crosscheck.txt`](../simulator/results/crosscheck.txt)): a second implementation written from
  `docs/DESIGN.md` section 9 in plain Python (arbitrary-precision integers, no shared code with the C++), re-run on
  the committed data for 17 combinations of leverage, latency, horizon and protocol variant (30, 90 and 365 days;
  default, `full-close` and `tight-gap` parameters; the dust experiment). It compares the number of windows that
  became unhealthy, were liquidated, ended with bad debt, got stuck and got stuck while insolvent, plus the mean
  bad-debt fraction. **13 of 17 agree exactly.** The other 4 are all 365-day runs: in three of them the counts differ
  by 1 to 2 windows out of 1,836, and in the fourth the counts agree and only the mean bad-debt fraction differs
  (0.0008077 against 0.0008037). The cause is the accrual *policy*, not the arithmetic: the Python version accrues interest
  every hour while the C++ engine accrues only when it inspects the position, and over a year at 4% the hourly
  compounding is about 0.08% larger (arithmetic: 4% squared, over 2), which flips a window whose health factor is within ~1e-3 of 1. With
  `--lazy` (the C++ policy, same screening rule, all arithmetic still exact and independent) **7 of 7** 365-day
  combinations agree exactly. Which accrual policy is "right" depends on how often the market is touched by
  others; the effect on any reported count is at most 2 windows in 1,836.
- Not cross-checked: the bootstrap path generator (it uses floating-point `log`/`exp`, so the exact paths can
  differ in the last bits between compilers and platforms; the reported numbers come from MSVC on Windows). It is
  covered by unit tests of determinism and statistics only.

## Results

In every table a cell is **share of windows liquidated / share of windows that ended with bad debt**. "Start LTV" is
the absolute loan-to-value at opening (max LTV is 75%, liquidation threshold 80%, bonus 5%, close factor 50%).
Rows are how aggressively the borrower leveraged; columns are the liquidator's latency.

### 1. Default parameters, real history

**90-day windows (N = 2111):**

| start LTV | 0 h | 1 h | 6 h | 24 h | 72 h |
|---|---|---|---|---|---|
| 37.5% | 5.8% / 0.00% | 5.6% / 0.00% | 4.9% / 0.00% | 4.1% / 1.28% | 2.9% / 1.85% |
| 60.0% | 39.9% / 0.00% | 38.6% / 0.05% | 37.3% / 0.00% | 35.2% / 4.36% | 32.4% / 4.97% |
| 67.5% | 55.8% / 0.00% | 54.5% / 0.14% | 52.3% / 0.00% | 49.6% / 4.55% | 45.4% / 8.24% |
| 75.0% | 78.9% / 0.00% | 78.2% / 0.05% | 76.7% / 0.00% | 73.9% / 5.73% | 65.9% / 12.03% |

**365-day windows (N = 1836):**

| start LTV | 0 h | 1 h | 6 h | 24 h | 72 h |
|---|---|---|---|---|---|
| 37.5% | 35.5% / 0.00% | 35.2% / 0.00% | 33.4% / 0.00% | 31.4% / 10.89% | 28.5% / 13.02% |
| 60.0% | 58.9% / 0.00% | 58.3% / 0.05% | 57.5% / 0.00% | 56.5% / 18.14% | 54.9% / 23.80% |
| 67.5% | 73.0% / 0.00% | 72.3% / 0.16% | 70.3% / 0.00% | 68.8% / 19.34% | 65.4% / 24.40% |
| 75.0% | 86.5% / 0.00% | 85.5% / 0.05% | 83.6% / 0.00% | 82.2% / 20.10% | 78.6% / 25.44% |

(30-day windows, N = 2171: see the CSV.) Windows overlap, so the real sample is far smaller than N: the `episodes` column
of the full reports counts distinct crash episodes, and the confidence intervals there assume independence and are
too narrow.

### 2. Default parameters, bootstrap (N = 20,000 paths per horizon)

**90-day paths:**

| start LTV | 0 h | 1 h | 6 h | 24 h | 72 h |
|---|---|---|---|---|---|
| 37.5% | 4.4% / 0.00% | 4.0% / 0.02% | 3.5% / 0.01% | 2.9% / 0.11% | 2.3% / 0.22% |
| 60.0% | 38.6% / 0.01% | 37.2% / 0.17% | 35.4% / 0.03% | 31.9% / 2.10% | 28.7% / 4.04% |
| 67.5% | 58.6% / 0.01% | 56.8% / 0.21% | 54.5% / 0.06% | 50.5% / 3.48% | 46.2% / 7.03% |
| 75.0% | 81.0% / 0.01% | 79.4% / 0.23% | 77.2% / 0.08% | 72.9% / 4.71% | 67.6% / 10.19% |

**365-day paths:**

| start LTV | 0 h | 1 h | 6 h | 24 h | 72 h |
|---|---|---|---|---|---|
| 37.5% | 22.5% / 0.00% | 21.8% / 0.11% | 21.0% / 0.02% | 19.6% / 1.97% | 18.4% / 4.00% |
| 60.0% | 61.0% / 0.03% | 59.8% / 0.43% | 58.3% / 0.09% | 55.4% / 6.31% | 52.8% / 13.45% |
| 67.5% | 74.8% / 0.02% | 73.6% / 0.43% | 72.1% / 0.11% | 69.2% / 8.21% | 66.3% / 17.48% |
| 75.0% | 88.9% / 0.01% | 87.9% / 0.45% | 86.5% / 0.14% | 83.7% / 9.55% | 80.4% / 20.97% |

### 3. Other protocol parameters, same history

All rows open at the max-LTV limit. A *valid deployment* is required (the loader applies the contracts' own
validation); `tight-gap` narrows max LTV to LT, `aggressive` raises both, `high-bonus` doubles the bonus,
`full-close` lets one liquidation repay everything.

**90-day windows (N = 2111):**

| variant (max LTV / LT / bonus / close factor) | 0 h | 6 h | 24 h | 72 h |
|---|---|---|---|---|
| conservative (65% / 75% / 5% / 50%) | 61.6% / 0.00% | 58.2% / 0.00% | 54.6% / 0.28% | 49.3% / 4.97% |
| default (75% / 80% / 5% / 50%) | 78.9% / 0.00% | 76.7% / 0.00% | 73.9% / 5.73% | 65.9% / 12.03% |
| tight-gap (78% / 80% / 5% / 50%) | 89.1% / 0.00% | 85.3% / 0.00% | 81.9% / 5.16% | 77.1% / 13.36% |
| aggressive (80% / 85% / 5% / 50%) | 79.4% / 0.66% | 77.5% / 7.44% | 74.8% / 17.43% | 67.1% / 30.22% |
| high-bonus (75% / 80% / 10% / 50%) | 78.9% / 0.09% | 76.7% / 2.89% | 73.9% / 14.87% | 65.9% / 24.16% |
| full-close (75% / 80% / 5% / 100%) | 78.9% / 0.14% | 76.7% / 0.05% | 73.9% / 1.28% | 65.9% / 5.83% |

**365-day windows (N = 1836):**

| variant (max LTV / LT / bonus / close factor) | 0 h | 6 h | 24 h | 72 h |
|---|---|---|---|---|
| conservative (65% / 75% / 5% / 50%) | 75.4% / 0.00% | 73.6% / 0.00% | 72.5% / 0.33% | 68.5% / 20.70% |
| default (75% / 80% / 5% / 50%) | 86.5% / 0.00% | 83.6% / 0.00% | 82.2% / 20.10% | 78.6% / 25.44% |
| tight-gap (78% / 80% / 5% / 50%) | 93.4% / 0.00% | 90.6% / 0.00% | 87.9% / 19.77% | 85.4% / 28.00% |
| aggressive (80% / 85% / 5% / 50%) | 87.1% / 0.76% | 84.5% / 22.49% | 82.6% / 35.51% | 79.1% / 47.11% |
| high-bonus (75% / 80% / 10% / 50%) | 86.5% / 0.11% | 83.6% / 8.12% | 82.2% / 33.39% | 78.6% / 38.29% |
| full-close (75% / 80% / 5% / 100%) | 86.5% / 0.16% | 83.6% / 0.05% | 82.2% / 1.58% | 78.6% / 5.61% |

### 4. Dust positions (threat T22)

A 40 USD position opened at the max-LTV limit (30 USD of debt) and a liquidator that ignores debts under 25 USD, a
stand-in for the gas cost of a liquidation. The protocol has no minimum borrow size in v1.

| horizon | windows | unhealthy at some point | liquidated | stuck (never liquidated at that moment) | stuck AND insolvent |
|---|---|---|---|---|---|
| 90 days | 2111 | 1666 (78.9%) | 1666 (78.9%) | 1037 (49.1%) | 544 (25.8%) |
| 365 days | 1836 | 1588 (86.5%) | 1588 (86.5%) | 1234 (67.2%) | 935 (50.9%) |

"stuck" means the position was unhealthy at least once at a moment when nobody would liquidate it (the first
liquidation can itself leave a residual debt under the threshold); "insolvent" means that at such a moment its debt
was worth more than its collateral, a loss nobody has recognised.

## What this says

1. **Liquidation frequency is a function of leverage and horizon, not of the protocol.** Opened at the limit
   (75% LTV), a position was liquidated in 78.9% of 90-day windows and in
   86.5% of 365-day windows; opened at half the limit (37.5% LTV), in
   5.8% and 35.5%. ETH moves enough that a borrower who wants to
   stay out of liquidation has to keep a wide margin or manage the position.
2. **Bad debt is decided first by how fast liquidators act, then by the margin parameters.** With the default
   parameters, a liquidator acting on the next observation (0 h) left bad debt in 0 of 2111 90-day
   windows. At 1 h latency there was 1 window (0.05%): the one starting
   2021-05-09, whose 90 days contain the 19 May 2021 crash (identified by re-running the windows). At 6 h: 0. At 24 h: 121 windows (5.73%); at 72 h:
   254 (12.03%), with the worst single window losing 19.6% of the
   position's debt. The protocol is safe against these crashes **if liquidators act within hours**; if they do not, there is
   nothing behind suppliers (no first-loss buffer, see `docs/THREAT_MODEL.md`).
3. **The safety margin between the liquidation threshold and the point where a liquidation stops being
   profitable matters.** Raising the threshold to 85% (`aggressive`) produced bad debt at 0 h latency in
   14 windows (0.66%) and at 6 h in 157 (7.44%), against
   0 for the default parameters at 6 h. Doubling the bonus to 10% did the same at 6 h:
   61 windows (2.89%). A larger bonus shrinks the headroom because a liquidation
   stops covering its own debt once the position's LTV exceeds 1/(1+bonus) (95.2% for 5%, 90.9% for 10%); that
   explanation is arithmetic, not something the simulation measured.
4. **A larger close factor reduces bad debt in slow-liquidator scenarios.** `full-close` (100%) cut the 24 h
   bad-debt share from 5.73% to 1.28%; the mechanism is that a single liquidation
   repays the whole debt, so no risk is left between liquidations (an explanation, not separately measured). It is not strictly better: it also leaves a few windows with bad debt at 0 h (3 of 2111) where the
   default has none; the simulation does not isolate why.
5. **A conservative set (65% / 75%) delays but does not remove the problem:** 0 windows with bad
   debt at 6 h latency, but 105 (4.97%) at 72 h.
6. **Dust positions are a real, quantified gap.** In 1037 of 2111 90-day windows
   (49.1%) the small position became unhealthy and could not be liquidated at that
   moment, and in 544 (25.8%) it was also insolvent. Under the assumption that nobody liquidates debts below 25 USD,
   this is a loss that is never written off or even recorded. A minimum borrow size would address
   it; v1 does not have one.
7. **The synthetic paths agree with the history where they should.** At the limit with 0 h latency, 81.0%
   of bootstrap paths were liquidated against 78.9% of historical windows (90 days); at half the limit,
   4.4% against 5.8%. The bootstrap finds bad debt at 0 h latency where the history found none
   (1 of 20,000 paths) and more often at 1 h (0.23% of paths against
   0.05% of historical windows), which is what it is for; it recombines the same hourly returns, so
   it adds no larger single-hour move than the sample has (it can, however, chain bad stretches in new orders).

## Limits (read before quoting a number)

- **One position, passive borrower, no top-ups or repayments.** It measures the *mechanism*, not a market. A real
  borrower who watches the position is liquidated less often than these tables say.
- **Fixed utilization (80%).** Rate spikes at high utilization, and the feedback between liquidations and
  utilization, are not modelled. At 80% utilization the borrow rate is 4% a year, so interest adds at most about 4%
  to the debt over the longest horizon.
- **The liquidator is idealised except for latency:** no slippage, gas, capital limit, competition or MEV, no
  failed transaction. Latency stands in for all of those and for oracle delay. Real latency during a crash is
  not uniform: the worst moments are when gas is highest.
- **The oracle is replayed as published.** A Chainlink outage, a stale feed that the oracle wrapper would reject (which
  would block liquidations), or a fresh-but-wrong price are not simulated.
- **Sample size.** About six years of one asset's history, with only a small number of distinct crash episodes behind each rate (the `episodes` column). "No bad
  debt observed" is not "bad debt impossible", and the bootstrap only recombines what happened.
- **Overlapping windows are not independent**, so confidence intervals in the reports are too narrow; use `episodes`.
- **Not simulated:** late recognition of bad debt and the bank-run dynamic among suppliers (threat T32, needs a
  multi-account market model), flash-crash prices, multiple collateral assets (the protocol has one).
- **Reproducibility:** the numbers here come from MSVC 19.41 on Windows. Historical results use only exact
  integers plus a conservative floating-point screen, and the cross-check reproduces them with a second
  implementation. The bootstrap uses `log`/`exp` and may differ in rare paths on another platform.

## Reproduce

```bash
cmake -S simulator -B simulator/build -DCMAKE_BUILD_TYPE=Release
cmake --build simulator/build
ctest --test-dir simulator/build --output-on-failure
for c in historical_baseline bootstrap_baseline parameter_sweep dust_positions; do
  simulator/build/defi_sim run simulator/configs/$c.json --out simulator/results --quiet > /dev/null
done
python simulator/tools/crosscheck.py simulator/configs/historical_baseline.json simulator/results/historical_baseline.csv 90 1.0:24
```

Run times on a 16-core machine, measured with PowerShell's `Measure-Command`: historical_baseline 5 s,
parameter_sweep 6 s, dust_positions 27 s, bootstrap_baseline 44 s.
