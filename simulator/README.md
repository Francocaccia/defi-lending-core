# Risk simulator (M9)

A C++ tool that asks one question of the lending protocol: **with these parameters, how often does a
borrower get liquidated, how late can a liquidator be, and does a liquidation ever leave bad debt?**

It does not re-implement the protocol. It links the independent reference model
(`../reference-model`, library only), so every decision (interest accrual, health factor, liquidation
amounts, bad-debt write-off) runs on the same exact 256-bit integer math that the differential tests
check against the Solidity. Floating point is used only for statistics and to skip steps where a
position is obviously healthy; it never decides anything.

The protocol does not depend on this tool: `forge build` and `forge test` work without a C++ toolchain.

## Build and run

Requirements: CMake 3.16+ and a C++17 compiler (tested with MSVC 19.41 on Windows; CI also builds GCC).

```bash
cmake -S simulator -B simulator/build -DCMAKE_BUILD_TYPE=Release
cmake --build simulator/build
ctest --test-dir simulator/build --output-on-failure      # unit tests
simulator/build/defi_sim run simulator/configs/historical_baseline.json --out results
```

`--out <dir>` writes `<name>.md` (the report) and `<name>.csv` (the same rows, machine readable).
`--threads N` overrides the worker count; results do not depend on it.

## What is simulated

One passive borrower position on one market, replayed over a price path:

1. **Open.** Deposit `collateralEth` ETH and borrow a stated fraction of the max-LTV limit (checked with the
   same rounding as the contract's `borrow`).
2. **Evolve.** Debt grows with the protocol's own borrow rate and index. Utilization is held fixed (a single
   position does not move a whole market).
3. **Inspect** every observation: health factor `< 1` makes the position liquidatable.
4. **Liquidate** after a configurable **latency** (the liquidator re-checks when it acts, so a price that
   recovered in the meantime cancels the liquidation). It repays up to the close factor and seizes
   collateral plus bonus, repeating on later observations. If collateral runs out with debt left, the rest is
   written off as **bad debt** (the supplier loss).
5. Optional **minimum debt** a liquidator bothers with (a stand-in for gas): positions below it stay
   unhealthy and are counted as `stuck` (threat T22). The report also shows how many of those were
   **insolvent** (debt worth more than the collateral): a loss nobody has recognised.

The position is sized either as `collateralEth` (a fixed amount of ETH) or as `collateralUsd` (dollars of ETH
at the opening price, so its size does not depend on where the price was when the window started).

## Price sources

| source | what it is |
|---|---|
| `historical` | Every rolling window of the real Chainlink history, one start per day (configurable). No period is selected or excluded. |
| `bootstrap` | Stationary block bootstrap (mean block length in days) of the historical hourly log-returns; ETH and USDC are resampled jointly. Deterministic: same seed, same paths, any thread count. |

Data are the on-chain round histories of the Chainlink proxies the protocol's oracle wrapper reads
(`data/eth_usd_chainlink.csv`, `data/usdc_usd_chainlink.csv`, each with a `.meta.json` recording the
aggregator phases, fetch time and SHA-256). They are public blockchain state, fetched read-only with
`tools/fetch_chainlink_history.py` (Python standard library only; `eth_call` against free public RPCs):

```bash
python simulator/tools/fetch_chainlink_history.py 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 simulator/data/eth_usd_chainlink.csv
python simulator/tools/fetch_chainlink_history.py 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6 simulator/data/usdc_usd_chainlink.csv
```

The history is replayed on an hourly grid with carry-forward of the last round, which is what a contract reading
the feed at that moment would see. Where USDC/USD has no data yet, USDC is assumed to be exactly $1.00 and the report says so.

## Config

JSON; protocol parameters use the contracts' own names (`maxLtv`, `liquidationThreshold`,
`liquidationBonus`, `closeFactor`, and the rate model's `baseRate`, `slope1`, `slope2`,
`optimalUtilization`). Text with a `.` is a decimal fraction (`"0.75"`), plain digits are a raw WAD integer
exactly as passed to the contract. Every variant goes through the contracts' deployment validation, so an
invalid parameter set is rejected by name instead of simulated. See `configs/`.

| config | question |
|---|---|
| `historical_baseline.json` | Default parameters over every rolling window; leverage x liquidator latency. |
| `bootstrap_baseline.json` | Same, on synthetic paths (probes crashes the sample does not contain). |
| `parameter_sweep.json` | Six parameter sets on the same history: LTV / threshold gap, bonus, close factor. |
| `dust_positions.json` | A 40 USD position and a liquidator that ignores debts under 25 USD: how often do positions get stuck, and how often are they also insolvent? (T22) |

## Cross-checking the engine

`tools/crosscheck.py` re-runs a historical experiment with a second implementation of the engine, written from
`docs/DESIGN.md` section 9 in plain Python (arbitrary-precision integers), and compares the per-combination
counts with the simulator's CSV. It shares no code with the C++ engine or the reference model, inspects every
hour exactly (the C++ engine skips obviously healthy hours with a floating-point screen) and accrues interest
every hour (the C++ engine accrues lazily; `--lazy` adopts the C++ policy).

It is a second implementation written in the same project from the same specification, **not an independent
audit**: it can catch arithmetic slips and policy differences, but not a misunderstanding that both
implementations share.

```bash
simulator/build/defi_sim run simulator/configs/historical_baseline.json --out out --quiet
python simulator/tools/crosscheck.py simulator/configs/historical_baseline.json out/historical_baseline.csv 30 1.0:0 1.0:24
```

Results and their interpretation: [`../docs/RISK_SIMULATION.md`](../docs/RISK_SIMULATION.md).

## Limits (read before quoting a number)

- One position, passive borrower, no top-ups, no repayments. It measures the *mechanism*, not a whole market.
- Fixed utilization (default 80%), so a rate spike at high utilization is not modelled.
- The liquidator is idealised: no slippage, gas or capital limit, except the optional minimum-debt filter.
- Historical windows overlap heavily; the confidence interval assumes independence and is therefore too narrow.
  The `episodes` column (distinct crash episodes) is the honest sample size.
- The usable ETH/USD history starts in October 2020, so the March 2020 "Black Thursday" crash is not in the sample.
- The sample is a few years of one asset's history. "No bad debt observed" is not "bad debt impossible".
- Late bad-debt recognition and the bank-run dynamic (threat T32) need a multi-account market model and are
  not simulated.
