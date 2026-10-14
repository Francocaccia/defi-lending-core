# DESIGN

This document is the **specification** of the protocol math. The C++ reference model (M8) is
implemented from this file alone, so every formula here is exact: integer arithmetic only,
explicit units, explicit rounding direction.

Status legend: **[implemented]** = in `src/` and tested. **[planned]** = specified now so the
spec does not drift, implemented in the named milestone; the text is updated if the
implementation reveals a flaw.

## 0. Conventions

### 0.1 Integers and overflow
- All values are `uint256` unless stated. There is no floating point anywhere in protocol math.
- `a * b / c` is always computed as `mulDiv(a, b, c)` with a **512-bit intermediate product**:
  `floor(a*b/c)`; it reverts if `c == 0` or if the final quotient does not fit in 256 bits.
  `mulDivUp(a, b, c) = floor(a*b/c) + (1 if a*b mod c != 0 else 0)`; same revert conditions
  (and it also reverts if the `+1` overflows).
- Any other `+`, `-`, `*` overflowing 256 bits (or `-` underflowing) reverts.
- "Floor" = round toward zero (all values are non-negative).

### 0.2 Fixed-point scales
| Name | Value | Used for |
|---|---|---|
| `WAD` | `1e18` | prices, ratios, percentages, annual rates (`0.75e18` = 75%) |
| `RAY` | `1e27` | per-second rates, borrow index |
| `WAD_TO_RAY` | `1e9` | `RAY / WAD` |
| `SECONDS_PER_YEAR` | `31_536_000` | `365 * 86_400`; no leap years |

### 0.3 Rounding policy (global)
Always round **in favour of the protocol** (solvency), i.e. against the user:
- amounts a user **owes** (debt) round **up**;
- amounts a user **receives or may withdraw** round **down**;
- rates and ratios used only as inputs (utilization, annual and per-second rates) round
  **down**, because the interest suppliers earn is by construction exactly the interest
  borrowers are charged (section 5.2), so rounding the rate cannot create a deficit.

## 1. Asset model [planned: M3]
- Collateral asset: 18 decimals (WETH). Borrow/supply asset: 6 decimals (USDC-like).
- All on-chain balances are in token base units. USD values are WAD-scaled (section 2.1).

## 2. Oracle [implemented: M1]

One oracle instance per asset: `price()` returns the USD price of **one whole token**
(`10**tokenDecimals` base units) scaled to 18 decimals.

### 2.1 Normalization
Given the feed's `answer` (int256) and its `decimals` d:

```
require d <= 18                      (constructor)
scale      = 10 ** (18 - d)
priceWad   = answer * scale          (exact, no rounding; reverts on uint256 overflow)
```
Example: ETH/USD feed, d = 8, answer = 2_000_50_000_000 ($2,000.50) -> `2000.5e18`.
Feeds with d > 18 are rejected so that normalization never rounds.

### 2.2 Validity checks (all revert; evaluated in this order)
Let `now = block.timestamp`, and `(roundId, answer, startedAt, updatedAt, answeredInRound)` the
result of `latestRoundData()`.
1. the call itself succeeds (else `FeedCallFailed`);
2. `answer > 0` (else `InvalidPrice`);
3. `updatedAt != 0` (else `IncompleteRound`);
4. `updatedAt <= now` (else `FutureTimestamp`);
5. `answeredInRound >= roundId` (else `StaleRound`);
6. `now - updatedAt <= heartbeat` (else `StalePrice`): a price exactly `heartbeat` seconds old is
   still valid;
7. `answer * scale` does not overflow (else `PriceOverflow`).

### 2.3 Configuration (immutable)
`heartbeat` must satisfy `1 <= heartbeat <= 7 days` (sanity guard against unit mistakes). The
configured value should be the feed's documented heartbeat plus a small margin. Mainnet
feeds used (see `script/Addresses.sol` for addresses and sources): ETH/USD heartbeat 3600 s,
USDC/USD heartbeat 82 800 s.

### 2.4 Valuation (consumers of the price) [planned: M4]
```
collateralValueUsd = mulDiv(collateralAmount, collateralPriceWad, 10**18)   // floor (collateral)
debtValueUsd       = mulDivUp(debtAmount, borrowPriceWad, 10**6)            // up    (debt)
```
(both WAD-scaled USD; 10^18 and 10^6 are the token decimals).

## 3. Interest rate model [implemented: M2]

Parameters (all annual, WAD-scaled): `baseRate`, `slope1`, `slope2`, `optimalUtilization = K`.

### 3.1 Parameter validation (deployment)
```
0 < K < WAD            (strict: K and WAD-K are divisors)
baseRate, slope1, slope2 <= MAX_ANNUAL_RATE = 10 * WAD      (1000% APR sanity cap)
```
`slope2 >= slope1` is not required.

### 3.2 Utilization
```
utilization(totalSupplyAssets, totalBorrowAssets):
  if totalSupplyAssets == 0                       -> 0
  if totalBorrowAssets >= totalSupplyAssets       -> WAD        (cap)
  else                                            -> mulDiv(totalBorrowAssets, WAD, totalSupplyAssets)   // floor
```
`totalSupplyAssets` is everything owed to suppliers (idle cash + outstanding borrows, interest
included).

### 3.3 Annual borrow rate (WAD)
Precondition: `0 <= u <= WAD` (else revert `InvalidUtilization`).
```
if u <= K:  rate = baseRate + mulDiv(slope1, u, K)                          // floor
else:       rate = baseRate + slope1 + mulDiv(slope2, u - K, WAD - K)        // floor
```
Properties (tested): continuous at `K` (`rate(K) = baseRate + slope1`); non-decreasing in `u`;
`rate(0) = baseRate`; `rate(WAD) = baseRate + slope1 + slope2`.

### 3.4 Per-second borrow rate (RAY)
```
ratePerSecond = (annualRate * WAD_TO_RAY) / SECONDS_PER_YEAR       // floor
```
The `* 1e9` happens **before** the division to keep ~27 digits of precision.

### 3.5 Worked examples (verified independently in Python)
Params: `baseRate=0, slope1=0.04e18, slope2=0.75e18, K=0.8e18`.

| u (WAD) | annual rate (WAD) | per-second rate (RAY) |
|---|---|---|
| 0 | 0 | 0 |
| 0.4e18 | 0.02e18 | 634195839675291730 |
| 0.8e18 | 0.04e18 | 1268391679350583460 |
| 0.9e18 | 0.415e18 | 13159563673262303399 |
| 1.0e18 | 0.79e18 | 25050735667174023338 |

With `baseRate=0.01e18` the annual rates are `0.01, 0.03, 0.05, 0.425, 0.80` (e18) for the same u.
Floor case: `slope1=10, slope2=0, K=0.8e18, u=0.1e18` -> `10*0.1e18/0.8e18 = 1.25` -> `1`.
`utilization(3, 1) = 333333333333333333`, `utilization(3, 2) = 666666666666666666`.

## 4. Share accounting [planned: M3]

Supplier shares use **virtual shares/assets** to defeat the first-depositor inflation attack
(an attacker mints 1 wei of shares then donates assets to make later deposits round to zero).

```
VIRTUAL_SHARES = 1e6
VIRTUAL_ASSETS = 1

toSharesDown(a, A, S) = mulDiv  (a, S + VIRTUAL_SHARES, A + VIRTUAL_ASSETS)   // deposit: user gets fewer
toSharesUp  (a, A, S) = mulDivUp(a, S + VIRTUAL_SHARES, A + VIRTUAL_ASSETS)   // withdraw by assets: burns more
toAssetsDown(s, A, S) = mulDiv  (s, A + VIRTUAL_ASSETS, S + VIRTUAL_SHARES)   // redeem: user gets less
toAssetsUp  (s, A, S) = mulDivUp(s, A + VIRTUAL_ASSETS, S + VIRTUAL_SHARES)
```
`A` = `totalSupplyAssets`, `S` = `totalSupplyShares`. Operation -> function:
supply(assets) mints `toSharesDown`; withdraw(assets) burns `toSharesUp`;
redeem(shares) pays `toAssetsDown`.

## 5. Borrow index and debt [planned: M3]
### 5.1 Index accrual (RAY)
Linear within an accrual interval, compounding across intervals (each accrual multiplies the
previous index). With `dt = now - lastAccrual` and `r = borrowRatePerSecond(utilization)`
evaluated at the **start** of the interval (state before the accrual):
```
interestFactor = r * dt                                    // RAY
newIndex       = index + mulDivUp(index, interestFactor, RAY)     // up: debt grows at least as fast
interest       = mulDivUp(totalBorrowAssets, interestFactor, RAY) // up
totalBorrowAssets += interest;  totalSupplyAssets += interest     // suppliers earn exactly what is charged
```
### 5.2 Per-user debt
A borrower stores `(principal, userIndex)`. `debt = mulDivUp(principal, index, userIndex)`
(round up). Because each user's debt rounds up independently, `sum(userDebt) >= totalBorrowAssets`
up to a bounded rounding tolerance (documented in M5 with the invariant tests).

## 6. Risk parameters and constructor checks [planned: M4]
Illustrative defaults (immutable): `maxLtv = 0.75e18`, `liquidationThreshold = 0.80e18`,
`liquidationBonus = 0.05e18`, `closeFactor = 0.50e18`.

Deployment checks (all must hold, else revert):
```
0 < maxLtv < liquidationThreshold < WAD
0 < liquidationBonus <= MAX_BONUS                (MAX_BONUS to be fixed in M4)
liquidationThreshold * (WAD + liquidationBonus) < WAD * WAD      // LT*(1+bonus) < 1
0 < closeFactor <= WAD
```
The `LT*(1+bonus) < 1` rule guarantees a liquidation at the threshold seizes collateral worth
less than the position's total collateral (otherwise even a position exactly at the threshold
would already be insolvent for the liquidator's payout).

Health factor and liquidation formulas: added in M4.
