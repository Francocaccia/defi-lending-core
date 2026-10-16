# bootstrap_baseline

The protocol's default parameters (the ones in the demo and the Sepolia script) run on synthetic price paths (stationary block bootstrap of the real hourly Chainlink returns), which can probe crashes the historical sample did not contain. Question: how often does a passive borrower who opens at a given leverage get liquidated, and does any liquidation leave bad debt?

## Setup

- **Path source:** stationary block bootstrap of historical returns
  (20000 synthetic paths per horizon, mean block length 7.0 days, seed 20260101)
- **Oracle history:** Chainlink ETH/USD from 2020-10-06 to 2026-10-15, observed every 3600 s with carry-forward of the last round (52822 observations).
  The history starts on 2020-10-06 (`data.from`): earlier rounds of this proxy are not market data (pre-launch rounds with constant answers and gaps of days to weeks) and are excluded on purpose.
- **USDC/USD:** real Chainlink USDC/USD from 2021-02-17; before that date USDC is ASSUMED to be exactly $1.00.
- **Position:** 10.0000 ETH collateral, opened at a stated fraction of the max-LTV limit; passive borrower (no top-ups, no repayments).
- **Market:** utilization held at 80% to price interest (a single position does not move the market).
- **Liquidator:** acts after the stated latency, repays up to the close factor, then re-acts on later observations; no slippage, gas or capital limits.
- **Protocol math:** every decision uses the integer functions of the independent reference model (verified against the Solidity). Floating point is used only to skip obviously healthy steps.

## Results, 30-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) |
|---|---|---|---|---|---|---|---|---|
| default | 75% / 80% / 5% | 37.5% | 0 h | 20000 | 0.5% [0.4%, 0.6%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 1 h | 20000 | 0.4% [0.3%, 0.5%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 6 h | 20000 | 0.3% [0.2%, 0.3%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 24 h | 20000 | 0.2% [0.1%, 0.2%] | 1 (0.01%) | 0.000% / 0.00% / 2.1% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 72 h | 20000 | 0.1% [0.0%, 0.1%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 0 h | 20000 | 16.2% [15.7%, 16.7%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 1 h | 20000 | 15.1% [14.6%, 15.6%] | 11 (0.06%) | 0.000% / 0.00% / 0.9% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 6 h | 20000 | 13.6% [13.1%, 14.1%] | 3 (0.01%) | 0.000% / 0.00% / 5.6% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 24 h | 20000 | 10.9% [10.4%, 11.3%] | 88 (0.44%) | 0.013% / 0.00% / 23.2% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 72 h | 20000 | 8.6% [8.2%, 9.0%] | 106 (0.53%) | 0.039% / 0.00% / 24.0% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 0 h | 20000 | 36.5% [35.8%, 37.1%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 1 h | 20000 | 34.7% [34.1%, 35.4%] | 22 (0.11%) | 0.001% / 0.00% / 8.4% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 6 h | 20000 | 32.2% [31.5%, 32.8%] | 3 (0.01%) | 0.001% / 0.00% / 8.5% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 24 h | 20000 | 27.7% [27.0%, 28.3%] | 239 (1.20%) | 0.045% / 0.70% / 14.5% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 72 h | 20000 | 22.7% [22.1%, 23.3%] | 314 (1.57%) | 0.130% / 5.61% / 32.1% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 0 h | 20000 | 69.0% [68.4%, 69.6%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 1 h | 20000 | 66.7% [66.1%, 67.4%] | 21 (0.10%) | 0.000% / 0.00% / 4.0% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 6 h | 20000 | 63.4% [62.7%, 64.0%] | 7 (0.03%) | 0.000% / 0.00% / 5.5% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 24 h | 20000 | 57.1% [56.4%, 57.8%] | 436 (2.18%) | 0.059% / 2.14% / 18.4% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 72 h | 20000 | 49.2% [48.5%, 49.9%] | 695 (3.48%) | 0.246% / 8.73% / 30.1% | 0 (0) |

## Results, 90-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) |
|---|---|---|---|---|---|---|---|---|
| default | 75% / 80% / 5% | 37.5% | 0 h | 20000 | 4.4% [4.1%, 4.7%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 1 h | 20000 | 4.0% [3.7%, 4.3%] | 4 (0.02%) | 0.000% / 0.00% / 0.5% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 6 h | 20000 | 3.5% [3.3%, 3.8%] | 1 (0.01%) | 0.001% / 0.00% / 11.3% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 24 h | 20000 | 2.9% [2.7%, 3.1%] | 23 (0.11%) | 0.005% / 0.00% / 21.3% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 72 h | 20000 | 2.3% [2.1%, 2.5%] | 44 (0.22%) | 0.014% / 0.00% / 26.2% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 0 h | 20000 | 38.6% [38.0%, 39.3%] | 3 (0.01%) | 0.000% / 0.00% / 2.8% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 1 h | 20000 | 37.2% [36.6%, 37.9%] | 34 (0.17%) | 0.001% / 0.00% / 4.7% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 6 h | 20000 | 35.4% [34.8%, 36.1%] | 7 (0.03%) | 0.001% / 0.00% / 10.8% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 24 h | 20000 | 31.9% [31.3%, 32.5%] | 419 (2.10%) | 0.049% / 1.49% / 23.2% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 72 h | 20000 | 28.7% [28.1%, 29.3%] | 809 (4.04%) | 0.212% / 7.93% / 31.1% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 0 h | 20000 | 58.6% [57.9%, 59.3%] | 3 (0.01%) | 0.000% / 0.00% / 2.4% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 1 h | 20000 | 56.8% [56.1%, 57.4%] | 43 (0.21%) | 0.002% / 0.00% / 8.4% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 6 h | 20000 | 54.5% [53.8%, 55.2%] | 11 (0.06%) | 0.001% / 0.00% / 8.5% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 24 h | 20000 | 50.5% [49.8%, 51.2%] | 697 (3.48%) | 0.091% / 3.14% / 22.2% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 72 h | 20000 | 46.2% [45.6%, 46.9%] | 1405 (7.03%) | 0.373% / 11.09% / 32.1% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 0 h | 20000 | 81.0% [80.4%, 81.5%] | 1 (0.01%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 1 h | 20000 | 79.4% [78.8%, 79.9%] | 46 (0.23%) | 0.001% / 0.00% / 5.7% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 6 h | 20000 | 77.2% [76.6%, 77.8%] | 17 (0.08%) | 0.001% / 0.00% / 8.7% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 24 h | 20000 | 72.9% [72.3%, 73.5%] | 942 (4.71%) | 0.101% / 3.62% / 29.8% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 72 h | 20000 | 67.6% [66.9%, 68.2%] | 2038 (10.19%) | 0.473% / 12.65% / 31.8% | 0 (0) |

## Results, 365-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) |
|---|---|---|---|---|---|---|---|---|
| default | 75% / 80% / 5% | 37.5% | 0 h | 20000 | 22.5% [22.0%, 23.1%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 1 h | 20000 | 21.8% [21.2%, 22.4%] | 22 (0.11%) | 0.001% / 0.00% / 8.2% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 6 h | 20000 | 21.0% [20.4%, 21.6%] | 4 (0.02%) | 0.001% / 0.00% / 11.3% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 24 h | 20000 | 19.6% [19.1%, 20.2%] | 393 (1.97%) | 0.037% / 0.81% / 21.3% | 0 (0) |
| default | 75% / 80% / 5% | 37.5% | 72 h | 20000 | 18.4% [17.9%, 18.9%] | 799 (4.00%) | 0.174% / 6.53% / 30.0% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 0 h | 20000 | 61.0% [60.3%, 61.6%] | 6 (0.03%) | 0.000% / 0.00% / 3.5% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 1 h | 20000 | 59.8% [59.1%, 60.4%] | 87 (0.43%) | 0.001% / 0.00% / 4.7% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 6 h | 20000 | 58.3% [57.6%, 59.0%] | 18 (0.09%) | 0.002% / 0.00% / 10.8% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 24 h | 20000 | 55.4% [54.7%, 56.1%] | 1263 (6.31%) | 0.096% / 3.08% / 23.2% | 0 (0) |
| default | 75% / 80% / 5% | 60.0% | 72 h | 20000 | 52.8% [52.1%, 53.4%] | 2690 (13.45%) | 0.483% / 11.83% / 31.1% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 0 h | 20000 | 74.8% [74.2%, 75.4%] | 4 (0.02%) | 0.000% / 0.00% / 2.4% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 1 h | 20000 | 73.6% [73.0%, 74.2%] | 87 (0.43%) | 0.002% / 0.00% / 8.4% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 6 h | 20000 | 72.1% [71.5%, 72.7%] | 23 (0.11%) | 0.002% / 0.00% / 8.5% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 24 h | 20000 | 69.2% [68.6%, 69.9%] | 1642 (8.21%) | 0.134% / 4.09% / 22.2% | 0 (0) |
| default | 75% / 80% / 5% | 67.5% | 72 h | 20000 | 66.3% [65.6%, 66.9%] | 3497 (17.48%) | 0.627% / 13.56% / 32.1% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 0 h | 20000 | 88.9% [88.5%, 89.3%] | 2 (0.01%) | 0.000% / 0.00% / 0.2% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 1 h | 20000 | 87.9% [87.5%, 88.4%] | 90 (0.45%) | 0.001% / 0.00% / 5.7% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 6 h | 20000 | 86.5% [86.0%, 87.0%] | 29 (0.14%) | 0.001% / 0.00% / 8.7% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 24 h | 20000 | 83.7% [83.2%, 84.2%] | 1910 (9.55%) | 0.136% / 4.07% / 29.8% | 0 (0) |
| default | 75% / 80% / 5% | 75.0% | 72 h | 20000 | 80.4% [79.8%, 80.9%] | 4194 (20.97%) | 0.667% / 13.81% / 31.8% | 0 (0) |

