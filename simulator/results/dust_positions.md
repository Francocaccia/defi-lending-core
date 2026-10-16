# dust_positions

Threat T22 (dust positions) made quantitative. A small position (40 USD of ETH collateral, so 30 USD of debt at the max-LTV limit) and a liquidator that only acts when the debt is worth at least 25 USD (a stand-in for the gas cost of a liquidation call). The first liquidation repays up to the close factor and can leave a residual debt below the threshold that nobody will ever liquidate. How often does that happen, and how often is such a stuck position also insolvent (debt worth more than its collateral)? The protocol has no minimum borrow size in v1, which is why this is documented as not mitigated.

## Setup

- **Path source:** historical replay of EVERY rolling window
  (a window starts every 1 day(s) across the whole loaded history; no period inside it is selected or excluded)
- **Oracle history:** Chainlink ETH/USD from 2020-10-06 to 2026-10-15, observed every 3600 s with carry-forward of the last round (52822 observations).
  The history starts on 2020-10-06 (`data.from`): earlier rounds of this proxy are not market data (pre-launch rounds with constant answers and gaps of days to weeks) and are excluded on purpose.
- **USDC/USD:** real Chainlink USDC/USD from 2021-02-17; before that date USDC is ASSUMED to be exactly $1.00.
- **Position:** $40.00 worth of ETH (at the opening price) collateral, opened at a stated fraction of the max-LTV limit; passive borrower (no top-ups, no repayments).
- **Market:** utilization held at 80% to price interest (a single position does not move the market).
- **Liquidator:** acts after the stated latency, repays up to the close factor, then re-acts on later observations; no slippage, gas or capital limits.
- **Protocol math:** every decision uses the integer functions of the independent reference model (verified against the Solidity). Floating point is used only to skip obviously healthy steps.

## Results, 90-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) | episodes |
|---|---|---|---|---|---|---|---|---|---|
| default | 75% / 80% / 5% | 75.0% | 0 h | 2111 | 78.9% [77.1%, 80.6%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 1037 (544) | 19 |

*Windows overlap heavily, so they are NOT independent: the confidence interval assumes independence and is therefore too narrow. `episodes` counts distinct crash episodes (liquidated windows starting more than 7 days apart), which is the honest sample size behind the liquidation rate.*

## Results, 365-day horizon

`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; `latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. `stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at that moment: a loss nobody has recognised.

| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) | episodes |
|---|---|---|---|---|---|---|---|---|---|
| default | 75% / 80% / 5% | 75.0% | 0 h | 1836 | 86.5% [84.9%, 88.0%] | 0 (0.00%) | 0.000% / 0.00% / 0.0% | 1234 (935) | 12 |

*Windows overlap heavily, so they are NOT independent: the confidence interval assumes independence and is therefore too narrow. `episodes` counts distinct crash episodes (liquidated windows starting more than 7 days apart), which is the honest sample size behind the liquidation rate.*

## Liquidated windows by start year (latency 0 h, highest leverage)

**90-day horizon** (liquidated / windows starting that year)

| variant | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|---|
| default (75%) | 27/87 | 304/365 | 327/365 | 257/365 | 287/366 | 301/365 | 163/198 |

**365-day horizon** (liquidated / windows starting that year)

| variant | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 | 2026 |
|---|---|---|---|---|---|---|---|
| default (75%) | 27/87 | 340/365 | 332/365 | 271/365 | 359/366 | 259/288 | - |

