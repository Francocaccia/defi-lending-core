# parameter_sweep

Same price history, same borrower, different protocol parameters: how much does the safety margin between max LTV and the liquidation threshold, the liquidation bonus and the close factor change liquidation frequency and bad debt? Every variant is a valid deployment (the config loader applies the contracts' own validation).

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

## Results, 90-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) | episodes |
|---|---|---|---|---|---|---|---|---|---|
| conservative | 65% / 75% / 5% | 65.0% | 0 h | 2111 | 61.6% [59.5%, 63.7%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 26 |
| conservative | 65% / 75% / 5% | 65.0% | 6 h | 2111 | 58.2% [56.1%, 60.3%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 27 |
| conservative | 65% / 75% / 5% | 65.0% | 24 h | 2111 | 54.6% [52.5%, 56.7%] | 6 (0.28%) | 0.010% / 0.00% / 6.3% | 0 (0) | 27 |
| conservative | 65% / 75% / 5% | 65.0% | 72 h | 2111 | 49.3% [47.1%, 51.4%] | 105 (4.97%) | 0.184% / 6.65% / 16.0% | 0 (0) | 22 |
| default | 75% / 80% / 5% | 75.0% | 0 h | 2111 | 78.9% [77.1%, 80.6%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 19 |
| default | 75% / 80% / 5% | 75.0% | 6 h | 2111 | 76.7% [74.8%, 78.4%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 22 |
| default | 75% / 80% / 5% | 75.0% | 24 h | 2111 | 73.9% [72.0%, 75.8%] | 121 (5.73%) | 0.074% / 2.33% / 11.7% | 0 (0) | 25 |
| default | 75% / 80% / 5% | 75.0% | 72 h | 2111 | 65.9% [63.9%, 67.9%] | 254 (12.03%) | 0.517% / 10.91% / 19.6% | 0 (0) | 29 |
| tight-gap | 78% / 80% / 5% | 78.0% | 0 h | 2111 | 89.1% [87.7%, 90.4%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 8 |
| tight-gap | 78% / 80% / 5% | 78.0% | 6 h | 2111 | 85.3% [83.7%, 86.8%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 14 |
| tight-gap | 78% / 80% / 5% | 78.0% | 24 h | 2111 | 81.9% [80.2%, 83.4%] | 109 (5.16%) | 0.057% / 1.48% / 11.2% | 0 (0) | 19 |
| tight-gap | 78% / 80% / 5% | 78.0% | 72 h | 2111 | 77.1% [75.3%, 78.9%] | 282 (13.36%) | 0.546% / 11.25% / 29.4% | 0 (0) | 26 |
| aggressive | 80% / 85% / 5% | 80.0% | 0 h | 2111 | 79.4% [77.7%, 81.1%] | 14 (0.66%) | 0.001% / 0.00% / 0.4% | 0 (0) | 19 |
| aggressive | 80% / 85% / 5% | 80.0% | 6 h | 2111 | 77.5% [75.7%, 79.3%] | 157 (7.44%) | 0.031% / 0.92% / 2.5% | 0 (0) | 20 |
| aggressive | 80% / 85% / 5% | 80.0% | 24 h | 2111 | 74.8% [72.9%, 76.6%] | 368 (17.43%) | 0.323% / 6.25% / 16.5% | 0 (0) | 25 |
| aggressive | 80% / 85% / 5% | 80.0% | 72 h | 2111 | 67.1% [65.1%, 69.1%] | 638 (30.22%) | 1.264% / 17.14% / 24.8% | 0 (0) | 30 |
| high-bonus | 75% / 80% / 10% | 75.0% | 0 h | 2111 | 78.9% [77.1%, 80.6%] | 2 (0.09%) | 0.000% / 0.00% / 0.5% | 0 (0) | 19 |
| high-bonus | 75% / 80% / 10% | 75.0% | 6 h | 2111 | 76.7% [74.8%, 78.4%] | 61 (2.89%) | 0.008% / 0.26% / 1.4% | 0 (0) | 22 |
| high-bonus | 75% / 80% / 10% | 75.0% | 24 h | 2111 | 73.9% [72.0%, 75.8%] | 314 (14.87%) | 0.227% / 5.42% / 15.5% | 0 (0) | 25 |
| high-bonus | 75% / 80% / 10% | 75.0% | 72 h | 2111 | 65.9% [63.9%, 67.9%] | 510 (24.16%) | 1.034% / 15.86% / 23.4% | 0 (0) | 29 |
| full-close | 75% / 80% / 5% | 75.0% | 0 h | 2111 | 78.9% [77.1%, 80.6%] | 3 (0.14%) | 0.001% / 0.00% / 1.5% | 0 (0) | 19 |
| full-close | 75% / 80% / 5% | 75.0% | 6 h | 2111 | 76.7% [74.8%, 78.4%] | 1 (0.05%) | 0.002% / 0.00% / 4.4% | 0 (0) | 22 |
| full-close | 75% / 80% / 5% | 75.0% | 24 h | 2111 | 73.9% [72.0%, 75.8%] | 27 (1.28%) | 0.061% / 1.10% / 16.3% | 0 (0) | 25 |
| full-close | 75% / 80% / 5% | 75.0% | 72 h | 2111 | 65.9% [63.9%, 67.9%] | 123 (5.83%) | 0.262% / 10.52% / 17.7% | 0 (0) | 29 |

*Windows overlap heavily, so they are NOT independent: the confidence interval assumes independence and is therefore too narrow. `episodes` counts distinct crash episodes (liquidated windows starting more than 7 days apart), which is the honest sample size behind the liquidation rate.*

## Results, 365-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) | episodes |
|---|---|---|---|---|---|---|---|---|---|
| conservative | 65% / 75% / 5% | 65.0% | 0 h | 1836 | 75.4% [73.4%, 77.4%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 12 |
| conservative | 65% / 75% / 5% | 65.0% | 6 h | 1836 | 73.6% [71.6%, 75.6%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 14 |
| conservative | 65% / 75% / 5% | 65.0% | 24 h | 1836 | 72.5% [70.4%, 74.5%] | 6 (0.33%) | 0.012% / 0.00% / 6.3% | 0 (0) | 15 |
| conservative | 65% / 75% / 5% | 65.0% | 72 h | 1836 | 68.5% [66.4%, 70.6%] | 380 (20.70%) | 0.446% / 11.65% / 16.5% | 0 (0) | 11 |
| default | 75% / 80% / 5% | 75.0% | 0 h | 1836 | 86.5% [84.9%, 88.0%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 12 |
| default | 75% / 80% / 5% | 75.0% | 6 h | 1836 | 83.6% [81.8%, 85.2%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 15 |
| default | 75% / 80% / 5% | 75.0% | 24 h | 1836 | 82.2% [80.4%, 83.9%] | 369 (20.10%) | 0.108% / 3.05% / 11.7% | 0 (0) | 16 |
| default | 75% / 80% / 5% | 75.0% | 72 h | 1836 | 78.6% [76.7%, 80.5%] | 467 (25.44%) | 0.611% / 14.80% / 21.3% | 0 (0) | 18 |
| tight-gap | 78% / 80% / 5% | 78.0% | 0 h | 1836 | 93.4% [92.1%, 94.4%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 4 |
| tight-gap | 78% / 80% / 5% | 78.0% | 6 h | 1836 | 90.6% [89.2%, 91.8%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) | 7 |
| tight-gap | 78% / 80% / 5% | 78.0% | 24 h | 1836 | 87.9% [86.3%, 89.3%] | 363 (19.77%) | 0.080% / 2.04% / 11.2% | 0 (0) | 10 |
| tight-gap | 78% / 80% / 5% | 78.0% | 72 h | 1836 | 85.4% [83.7%, 86.9%] | 514 (28.00%) | 0.623% / 12.48% / 29.4% | 0 (0) | 14 |
| aggressive | 80% / 85% / 5% | 80.0% | 0 h | 1836 | 87.1% [85.5%, 88.5%] | 14 (0.76%) | 0.002% / 0.00% / 0.4% | 0 (0) | 11 |
| aggressive | 80% / 85% / 5% | 80.0% | 6 h | 1836 | 84.5% [82.8%, 86.1%] | 413 (22.49%) | 0.055% / 1.68% / 2.9% | 0 (0) | 13 |
| aggressive | 80% / 85% / 5% | 80.0% | 24 h | 1836 | 82.6% [80.8%, 84.3%] | 652 (35.51%) | 0.487% / 7.46% / 16.5% | 0 (0) | 17 |
| aggressive | 80% / 85% / 5% | 80.0% | 72 h | 1836 | 79.1% [77.2%, 80.9%] | 865 (47.11%) | 1.380% / 20.03% / 24.8% | 0 (0) | 18 |
| high-bonus | 75% / 80% / 10% | 75.0% | 0 h | 1836 | 86.5% [84.9%, 88.0%] | 2 (0.11%) | 0.000% / 0.00% / 0.5% | 0 (0) | 12 |
| high-bonus | 75% / 80% / 10% | 75.0% | 6 h | 1836 | 83.6% [81.8%, 85.2%] | 149 (8.12%) | 0.015% / 0.49% / 2.2% | 0 (0) | 15 |
| high-bonus | 75% / 80% / 10% | 75.0% | 24 h | 1836 | 82.2% [80.4%, 83.9%] | 613 (33.39%) | 0.341% / 6.17% / 15.5% | 0 (0) | 16 |
| high-bonus | 75% / 80% / 10% | 75.0% | 72 h | 1836 | 78.6% [76.7%, 80.5%] | 703 (38.29%) | 1.116% / 18.64% / 24.6% | 0 (0) | 18 |
| full-close | 75% / 80% / 5% | 75.0% | 0 h | 1836 | 86.5% [84.9%, 88.0%] | 3 (0.16%) | 0.001% / 0.00% / 1.5% | 0 (0) | 12 |
| full-close | 75% / 80% / 5% | 75.0% | 6 h | 1836 | 83.6% [81.8%, 85.2%] | 1 (0.05%) | 0.002% / 0.00% / 4.4% | 0 (0) | 15 |
| full-close | 75% / 80% / 5% | 75.0% | 24 h | 1836 | 82.2% [80.4%, 83.9%] | 29 (1.58%) | 0.072% / 2.25% / 16.3% | 0 (0) | 16 |
| full-close | 75% / 80% / 5% | 75.0% | 72 h | 1836 | 78.6% [76.7%, 80.5%] | 103 (5.61%) | 0.299% / 11.77% / 17.7% | 0 (0) | 18 |

*Windows overlap heavily, so they are NOT independent: the confidence interval assumes independence and is therefore too narrow. `episodes` counts distinct crash episodes (liquidated windows starting more than 7 days apart), which is the honest sample size behind the liquidation rate.*

## Liquidated windows by start year (latency 0 h, highest leverage)

**90-day horizon** (liquidated / windows starting that year)

| variant | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|---|
| conservative (65%) | 3/87 | 256/365 | 284/365 | 129/365 | 221/366 | 277/365 | 131/198 |
| default (75%) | 27/87 | 304/365 | 327/365 | 257/365 | 287/366 | 301/365 | 163/198 |
| tight-gap (78%) | 56/87 | 327/365 | 349/365 | 310/365 | 330/366 | 329/365 | 180/198 |
| aggressive (80%) | 28/87 | 305/365 | 327/365 | 262/365 | 289/366 | 302/365 | 164/198 |
| high-bonus (75%) | 27/87 | 304/365 | 327/365 | 257/365 | 287/366 | 301/365 | 163/198 |
| full-close (75%) | 27/87 | 304/365 | 327/365 | 257/365 | 287/366 | 301/365 | 163/198 |

**365-day horizon** (liquidated / windows starting that year)

| variant | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|---|
| conservative (65%) | 3/87 | 314/365 | 296/365 | 178/365 | 338/366 | 256/288 | - |
| default (75%) | 27/87 | 340/365 | 332/365 | 271/365 | 359/366 | 259/288 | - |
| tight-gap (78%) | 56/87 | 348/365 | 351/365 | 315/365 | 366/366 | 278/288 | - |
| aggressive (80%) | 28/87 | 341/365 | 332/365 | 277/365 | 361/366 | 260/288 | - |
| high-bonus (75%) | 27/87 | 340/365 | 332/365 | 271/365 | 359/366 | 259/288 | - |
| full-close (75%) | 27/87 | 340/365 | 332/365 | 271/365 | 359/366 | 259/288 | - |

