# historical_baseline

The protocol's default parameters (the ones in the demo and the Sepolia script) replayed over EVERY rolling window of the real Chainlink ETH/USD + USDC/USD history. Question: how often does a passive borrower who opens at a given leverage get liquidated, and does any liquidation leave bad debt?

## Setup

- **Path source:** historical replay of EVERY rolling window
  (a window starts every 1 day(s) across the whole loaded history; no period inside it is selected or excluded)
- **Oracle history:** Chainlink ETH/USD from 2020-10-06 to 2026-10-15, observed every 3600 s with carry-forward of the last round (52822 observations).
  The history starts on 2020-10-06 (`data.from`): earlier rounds of this proxy are not market data (pre-launch rounds with constant answers and gaps of days to weeks) and are excluded on purpose.
- **USDC/USD:** real Chainlink USDC/USD from 2021-02-17; before that date USDC is ASSUMED to be exactly $1.00.
- **Position:** 10.0000 ETH collateral, opened at a stated fraction of the max-LTV limit; passive borrower (no top-ups, no repayments).
- **Market:** utilization held at 80% to price interest (a single position does not move the market).
- **Liquidator:** acts after the stated latency, repays up to the close factor, then re-acts on later observations; no slippage, gas or capital limits.
- **Protocol math:** every decision uses the integer functions of the independent reference model (verified against the Solidity). Floating point is used only to skip obviously healthy steps.

## Results, 30-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) | episodes |
|---|---|---|---|---|---|---|---|---|---|
| default | 75% / 80% / 5% | 37.5% | 0 h | 2171 | 0.5% [0.3%, 0.9%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 2 |
| default | 75% / 80% / 5% | 37.5% | 1 h | 2171 | 0.4% [0.2%, 0.8%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 2 |
| default | 75% / 80% / 5% | 37.5% | 6 h | 2171 | 0.0% [0.0%, 0.3%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 1 |
| default | 75% / 80% / 5% | 37.5% | 24 h | 2171 | 0.0% [0.0%, 0.2%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 0 |
| default | 75% / 80% / 5% | 37.5% | 72 h | 2171 | 0.0% [0.0%, 0.2%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 0 |
| default | 75% / 80% / 5% | 60.0% | 0 h | 2171 | 17.0% [15.5%, 18.6%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 21 |
| default | 75% / 80% / 5% | 60.0% | 1 h | 2171 | 15.9% [14.4%, 17.5%] | 1 (0.05%) | 0.000% / 0.00% / 0.6% | 0 (0) | 18 |
| default | 75% / 80% / 5% | 60.0% | 6 h | 2171 | 14.7% [13.3%, 16.2%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 18 |
| default | 75% / 80% / 5% | 60.0% | 24 h | 2171 | 11.4% [10.1%, 12.8%] | 13 (0.60%) | 0.010% / 0.00% / 6.1% | 0 (0) | 17 |
| default | 75% / 80% / 5% | 60.0% | 72 h | 2171 | 9.0% [7.9%, 10.3%] | 16 (0.74%) | 0.028% / 0.00% / 8.4% | 0 (0) | 13 |
| default | 75% / 80% / 5% | 67.5% | 0 h | 2171 | 33.9% [31.9%, 35.9%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 31 |
| default | 75% / 80% / 5% | 67.5% | 1 h | 2171 | 32.2% [30.2%, 34.1%] | 3 (0.14%) | 0.001% / 0.00% / 0.8% | 0 (0) | 33 |
| default | 75% / 80% / 5% | 67.5% | 6 h | 2171 | 29.7% [27.8%, 31.7%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 32 |
| default | 75% / 80% / 5% | 67.5% | 24 h | 2171 | 25.6% [23.8%, 27.4%] | 28 (1.29%) | 0.051% / 0.63% / 11.6% | 0 (0) | 29 |
| default | 75% / 80% / 5% | 67.5% | 72 h | 2171 | 21.6% [20.0%, 23.4%] | 44 (2.03%) | 0.178% / 8.54% / 19.0% | 0 (0) | 22 |
| default | 75% / 80% / 5% | 75.0% | 0 h | 2171 | 65.3% [63.2%, 67.2%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 31 |
| default | 75% / 80% / 5% | 75.0% | 1 h | 2171 | 63.8% [61.8%, 65.8%] | 1 (0.05%) | 0.000% / 0.00% / 0.2% | 0 (0) | 31 |
| default | 75% / 80% / 5% | 75.0% | 6 h | 2171 | 61.1% [59.0%, 63.1%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 35 |
| default | 75% / 80% / 5% | 75.0% | 24 h | 2171 | 55.6% [53.5%, 57.6%] | 47 (2.16%) | 0.067% / 2.28% / 11.7% | 0 (0) | 41 |
| default | 75% / 80% / 5% | 75.0% | 72 h | 2171 | 46.6% [44.5%, 48.7%] | 85 (3.92%) | 0.292% / 10.78% / 19.6% | 0 (0) | 46 |

*Windows overlap heavily, so they are NOT independent: the confidence interval assumes independence and is therefore too narrow. `episodes` counts distinct crash episodes (liquidated windows starting more than 7 days apart), which is the honest sample size behind the liquidation rate.*

## Results, 90-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) | episodes |
|---|---|---|---|---|---|---|---|---|---|
| default | 75% / 80% / 5% | 37.5% | 0 h | 2111 | 5.8% [4.9%, 6.9%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 6 |
| default | 75% / 80% / 5% | 37.5% | 1 h | 2111 | 5.6% [4.7%, 6.7%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 6 |
| default | 75% / 80% / 5% | 37.5% | 6 h | 2111 | 4.9% [4.0%, 5.9%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 5 |
| default | 75% / 80% / 5% | 37.5% | 24 h | 2111 | 4.1% [3.3%, 5.0%] | 27 (1.28%) | 0.027% / 0.77% / 5.1% | 0 (0) | 4 |
| default | 75% / 80% / 5% | 37.5% | 72 h | 2111 | 2.9% [2.3%, 3.7%] | 39 (1.85%) | 0.144% / 6.51% / 16.1% | 0 (0) | 4 |
| default | 75% / 80% / 5% | 60.0% | 0 h | 2111 | 39.9% [37.8%, 42.0%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 15 |
| default | 75% / 80% / 5% | 60.0% | 1 h | 2111 | 38.6% [36.6%, 40.7%] | 1 (0.05%) | 0.000% / 0.00% / 0.6% | 0 (0) | 14 |
| default | 75% / 80% / 5% | 60.0% | 6 h | 2111 | 37.3% [35.3%, 39.4%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 13 |
| default | 75% / 80% / 5% | 60.0% | 24 h | 2111 | 35.2% [33.2%, 37.3%] | 92 (4.36%) | 0.046% / 1.61% / 6.1% | 0 (0) | 13 |
| default | 75% / 80% / 5% | 60.0% | 72 h | 2111 | 32.4% [30.4%, 34.4%] | 105 (4.97%) | 0.190% / 6.11% / 17.7% | 0 (0) | 13 |
| default | 75% / 80% / 5% | 67.5% | 0 h | 2111 | 55.8% [53.7%, 57.9%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 24 |
| default | 75% / 80% / 5% | 67.5% | 1 h | 2111 | 54.5% [52.3%, 56.6%] | 3 (0.14%) | 0.001% / 0.00% / 0.8% | 0 (0) | 27 |
| default | 75% / 80% / 5% | 67.5% | 6 h | 2111 | 52.3% [50.2%, 54.4%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 25 |
| default | 75% / 80% / 5% | 67.5% | 24 h | 2111 | 49.6% [47.5%, 51.8%] | 96 (4.55%) | 0.063% / 1.52% / 11.6% | 0 (0) | 27 |
| default | 75% / 80% / 5% | 67.5% | 72 h | 2111 | 45.4% [43.3%, 47.5%] | 174 (8.24%) | 0.375% / 10.73% / 20.6% | 0 (0) | 18 |
| default | 75% / 80% / 5% | 75.0% | 0 h | 2111 | 78.9% [77.1%, 80.6%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 19 |
| default | 75% / 80% / 5% | 75.0% | 1 h | 2111 | 78.2% [76.4%, 79.9%] | 1 (0.05%) | 0.000% / 0.00% / 0.2% | 0 (0) | 19 |
| default | 75% / 80% / 5% | 75.0% | 6 h | 2111 | 76.7% [74.8%, 78.4%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 22 |
| default | 75% / 80% / 5% | 75.0% | 24 h | 2111 | 73.9% [72.0%, 75.8%] | 121 (5.73%) | 0.074% / 2.33% / 11.7% | 0 (0) | 25 |
| default | 75% / 80% / 5% | 75.0% | 72 h | 2111 | 65.9% [63.9%, 67.9%] | 254 (12.03%) | 0.517% / 10.91% / 19.6% | 0 (0) | 29 |

*Windows overlap heavily, so they are NOT independent: the confidence interval assumes independence and is therefore too narrow. `episodes` counts distinct crash episodes (liquidated windows starting more than 7 days apart), which is the honest sample size behind the liquidation rate.*

## Results, 365-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) | episodes |
|---|---|---|---|---|---|---|---|---|---|
| default | 75% / 80% / 5% | 37.5% | 0 h | 1836 | 35.5% [33.4%, 37.7%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 6 |
| default | 75% / 80% / 5% | 37.5% | 1 h | 1836 | 35.2% [33.1%, 37.5%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 6 |
| default | 75% / 80% / 5% | 37.5% | 6 h | 1836 | 33.4% [31.3%, 35.6%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 6 |
| default | 75% / 80% / 5% | 37.5% | 24 h | 1836 | 31.4% [29.3%, 33.6%] | 200 (10.89%) | 0.134% / 2.98% / 5.2% | 0 (0) | 10 |
| default | 75% / 80% / 5% | 37.5% | 72 h | 1836 | 28.5% [26.5%, 30.6%] | 239 (13.02%) | 1.062% / 16.05% / 20.9% | 0 (0) | 12 |
| default | 75% / 80% / 5% | 60.0% | 0 h | 1836 | 58.9% [56.6%, 61.1%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 9 |
| default | 75% / 80% / 5% | 60.0% | 1 h | 1836 | 58.3% [56.0%, 60.5%] | 1 (0.05%) | 0.000% / 0.00% / 0.6% | 0 (0) | 8 |
| default | 75% / 80% / 5% | 60.0% | 6 h | 1836 | 57.5% [55.2%, 59.8%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 8 |
| default | 75% / 80% / 5% | 60.0% | 24 h | 1836 | 56.5% [54.3%, 58.8%] | 333 (18.14%) | 0.116% / 3.41% / 6.1% | 0 (0) | 8 |
| default | 75% / 80% / 5% | 60.0% | 72 h | 1836 | 54.9% [52.6%, 57.2%] | 437 (23.80%) | 0.821% / 15.87% / 21.5% | 0 (0) | 7 |
| default | 75% / 80% / 5% | 67.5% | 0 h | 1836 | 73.0% [71.0%, 75.0%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 14 |
| default | 75% / 80% / 5% | 67.5% | 1 h | 1836 | 72.3% [70.2%, 74.3%] | 3 (0.16%) | 0.001% / 0.00% / 0.8% | 0 (0) | 15 |
| default | 75% / 80% / 5% | 67.5% | 6 h | 1836 | 70.3% [68.2%, 72.4%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 15 |
| default | 75% / 80% / 5% | 67.5% | 24 h | 1836 | 68.8% [66.6%, 70.9%] | 355 (19.34%) | 0.119% / 3.39% / 11.6% | 0 (0) | 14 |
| default | 75% / 80% / 5% | 67.5% | 72 h | 1836 | 65.4% [63.2%, 67.5%] | 448 (24.40%) | 0.740% / 16.52% / 21.4% | 0 (0) | 9 |
| default | 75% / 80% / 5% | 75.0% | 0 h | 1836 | 86.5% [84.9%, 88.0%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 12 |
| default | 75% / 80% / 5% | 75.0% | 1 h | 1836 | 85.5% [83.8%, 87.0%] | 1 (0.05%) | 0.000% / 0.00% / 0.2% | 0 (0) | 12 |
| default | 75% / 80% / 5% | 75.0% | 6 h | 1836 | 83.6% [81.8%, 85.2%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 15 |
| default | 75% / 80% / 5% | 75.0% | 24 h | 1836 | 82.2% [80.4%, 83.9%] | 369 (20.10%) | 0.108% / 3.05% / 11.7% | 0 (0) | 16 |
| default | 75% / 80% / 5% | 75.0% | 72 h | 1836 | 78.6% [76.7%, 80.5%] | 467 (25.44%) | 0.611% / 14.80% / 21.3% | 0 (0) | 18 |

*Windows overlap heavily, so they are NOT independent: the confidence interval assumes independence and is therefore too narrow. `episodes` counts distinct crash episodes (liquidated windows starting more than 7 days apart), which is the honest sample size behind the liquidation rate.*

## Liquidated windows by start year (latency 0 h, highest leverage)

**30-day horizon** (liquidated / windows starting that year)

| variant | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|---|
| default (75%) | 27/87 | 263/365 | 301/365 | 176/365 | 256/366 | 261/365 | 133/258 |

**90-day horizon** (liquidated / windows starting that year)

| variant | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|---|
| default (75%) | 27/87 | 304/365 | 327/365 | 257/365 | 287/366 | 301/365 | 163/198 |

**365-day horizon** (liquidated / windows starting that year)

| variant | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|---|
| default (75%) | 27/87 | 340/365 | 332/365 | 271/365 | 359/366 | 259/288 | - |

