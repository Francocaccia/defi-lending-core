# DESIGN

This document is the **specification** of the protocol math. The C++ reference model (M8) is
implemented from this file alone, so every formula here is exact: integer arithmetic only,
explicit units, explicit rounding direction.

Status legend: **[implemented]** = in `src/` and tested. **[planned]** = specified so the spec
does not drift; implemented in the named milestone, and the text is updated if the
implementation reveals a flaw.

## 0. Conventions

### 0.1 Integers and overflow
- All values are `uint256` unless stated. There is no floating point anywhere in protocol math.
- `a * b / c` is always computed as `mulDiv(a, b, c)` with a **512-bit intermediate product**:
  `floor(a*b/c)`; it reverts if `c == 0` or if the final quotient does not fit in 256 bits.
  `mulDivUp(a, b, c) = floor(a*b/c) + (1 if a*b mod c != 0 else 0)`; same revert conditions
  (and it also reverts if the `+1` overflows).
- Any other `+`, `-`, `*` overflowing 256 bits (or `-` underflowing) reverts. Note this includes
  plain products that appear as `mulDiv` OPERANDS or DENOMINATORS (e.g. `repay * (WAD + bonus)`,
  `collPrice * 10**debtDecimals * WAD` in section 7): those are ordinary checked multiplications
  evaluated BEFORE the 512-bit division, and revert on overflow.
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
  **down**, because the interest suppliers earn is by construction exactly the increase in the
  borrowers' derived total debt (section 5.2), so rounding the rate cannot create a deficit.

## 1. Asset model [implemented]
- Collateral asset: 18 decimals (WETH in the illustrative setup). Borrow/supply asset: 6
  decimals (USDC-like). The code is generic in token decimals `0..18`; `10**decimals` appears in
  the valuation and liquidation formulas.
- All on-chain balances are in token base units. USD values are WAD-scaled (section 2).
- Tokens are assumed to be plain ERC-20s (no fee-on-transfer, no rebasing, no hooks).
- Idle cash is the ACCOUNTING figure `liquidity = max(0, totalSupplyAssets - totalBorrowAssets)`,
  never `balanceOf`, so a direct token donation to the contract changes no price or ratio.

## 2. Oracle [implemented]

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

### 2.4 Valuation (consumers of the price) [implemented]
```
collateralValueUsd(amount, priceWad, dec) = mulDiv  (amount, priceWad, 10**dec)   // floor
debtValueUsd      (amount, priceWad, dec) = mulDivUp(amount, priceWad, 10**dec)   // ceil
```
Both results are WAD-scaled USD; `dec` is the token's decimals.

## 3. Interest rate model [implemented]

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

## 4. Supplier share accounting [implemented]

Supplier shares use **virtual shares/assets** to defeat the first-depositor inflation attack
(an attacker mints 1 wei of shares then donates assets to make later deposits round to zero).

```
VIRTUAL_SHARES = 1e6
VIRTUAL_ASSETS = 1

toSharesDown(a, A, S) = mulDiv  (a, S + VIRTUAL_SHARES, A + VIRTUAL_ASSETS)
toSharesUp  (a, A, S) = mulDivUp(a, S + VIRTUAL_SHARES, A + VIRTUAL_ASSETS)
toAssetsDown(s, A, S) = mulDiv  (s, A + VIRTUAL_ASSETS, S + VIRTUAL_SHARES)
toAssetsUp  (s, A, S) = mulDivUp(s, A + VIRTUAL_ASSETS, S + VIRTUAL_SHARES)
```
`A` = `totalSupplyAssets`, `S` = `totalSupplyShares` (interest already accrued).

| Operation | Conversion | Direction (against the user) |
|---|---|---|
| `supply(assets)` | `shares = toSharesDown(assets, A, S)`; reverts if `shares == 0` | user gets fewer shares |
| `withdraw(assets)` | `shares = toSharesUp(assets, A, S)` | user burns more shares |
| `redeem(shares)` | `assets = toAssetsDown(shares, A, S)`; reverts if `assets == 0` | user gets less |

State updates: `supply`: `A += assets; S += shares`. `withdraw`/`redeem`: `A -= assets; S -= shares`,
and require `assets <= liquidity` and `shares <= userShares`.

Worked examples (independent Python): `toSharesDown(1000e6, 0, 0) = 1e15`;
`toSharesDown(100e6, 1050e6, 1e15) = 95238095242630`, `toSharesUp(...) = 95238095242631`;
`toAssetsDown(1e14, 1050e6, 1e15) = 104999999`, `toAssetsUp(...) = 105000000`.

Properties (tested): deposit-then-redeem never returns more than deposited; burning
`toSharesUp(a)` always covers a withdrawal of `a`; the share price
`(A + VA) / (S + VS)` never decreases through supply, withdraw or redeem.

## 5. Borrow index and scaled debt [implemented]

### 5.1 State
```
borrowIndex      : RAY, initial value RAY (= 1.0), only grows
totalScaledDebt  : sum of every borrower's scaledDebt (exact)
scaledDebt[u]    : borrower u's index-normalized debt
debtFromScaled(s, idx) = mulDivUp(s, idx, RAY)                        // ceil
debt(u)                = debtFromScaled(scaledDebt[u], borrowIndex)
totalBorrowAssets      = debtFromScaled(totalScaledDebt, borrowIndex) // DERIVED, never stored
```

### 5.2 Accrual
With `elapsed = now - lastAccrual` (if 0, nothing happens), using the state BEFORE the accrual:
```
oldDebt   = totalBorrowAssets
u         = utilization(totalSupplyAssets, oldDebt)
r         = borrowRatePerSecond(u)                                    // RAY, section 3
newIndex  = borrowIndex + mulDivUp(borrowIndex, r * elapsed, RAY)     // ceil
interest  = debtFromScaled(totalScaledDebt, newIndex) - oldDebt
borrowIndex = newIndex;  totalSupplyAssets += interest;  lastAccrual = now
```
The rate is the one in force at the START of the interval. Growth is linear within an interval and
compounds across intervals (each accrual multiplies the previous index). Suppliers are credited
EXACTLY the increase in derived total debt, so the identity of 5.5 cannot be broken by rounding
of the rate. Every state-changing function accrues first.

Worked example (independent Python): supply 100,000 USDC, debt 50,000 USDC (u = 0.5, annual rate
0.025e18, per-second `792744799594114662`), one accrual of 365 days:
`newIndex = 1024999999999999999980832000`, `interest = 1250000000` (1,250 USDC). Two accruals of
100 days each from the same start give `index = 1013769079868900432720487744`, total debt
`50688453994`, supplier assets `100688453994`.

### 5.3 Borrow and repay
```
borrow(assets):   scaledAdded = mulDivUp(assets, RAY, borrowIndex)            // ceil: more debt
                  scaledDebt[u] += scaledAdded; totalScaledDebt += scaledAdded
repay(assets, u): debt = debt(u)
                  if assets >= debt:  repaid = debt;   burned = scaledDebt[u]
                  else:               repaid = assets; burned = mulDiv(assets, RAY, borrowIndex)   // floor
                                      revert if burned == 0
                  scaledDebt[u] -= burned; totalScaledDebt -= burned
```
Passing `assets = type(uint256).max` therefore means "repay the whole debt". Anyone may repay for
anyone. Repay uses no oracle.

### 5.4 Per-user vs total rounding
Each user's debt is rounded up independently while the total is rounded up once, so for N
borrowers: `0 <= sum(debt(u_i)) - totalBorrowAssets <= N - 1` wei (tested).

### 5.5 Solvency identity
`totalSupplyAssets <= idleCash + totalBorrowAssets` where `idleCash` = token balance (held by the
market, up to unrecorded donations). Every operation preserves it: borrow lowers cash by `a` and
raises derived debt by `>= a`; repay raises cash by `p` and lowers derived debt by `<= p`;
accrual raises both sides by `interest`.

## 6. Risk parameters, health factor and borrow limits [implemented]

Illustrative defaults (immutable): `maxLtv = 0.75e18`, `liquidationThreshold = LT = 0.80e18`,
`liquidationBonus = 0.05e18`, `closeFactor = 0.50e18`.

### 6.1 Deployment checks (all must hold, else revert)
```
0 < maxLtv < LT < WAD
0 < liquidationBonus <= MAX_LIQUIDATION_BONUS = 0.25e18
LT * (WAD + liquidationBonus) < WAD * WAD            // LT*(1+bonus) < 1, STRICT
0 < closeFactor <= WAD
```
`LT*(1+bonus) < 1` guarantees that a liquidation of a position that has just crossed the
threshold seizes collateral worth less than the position holds (otherwise every liquidation
would already create bad debt). `maxLtv < LT` leaves a buffer between "cannot borrow more" and
"can be liquidated".

### 6.2 Health factor
```
healthFactor(collValue, debtValue, LT) = (debtValue == 0) ? 2**256-1
                                         : mulDiv(collValue, LT, debtValue)       // floor, WAD
liquidatable  <=>  healthFactor < WAD
```
Despite the floor, the decision is exact: `floor(c*LT/d) < WAD  <=>  c*LT < d*WAD`.
`collValue`/`debtValue` come from section 2.4 with the current oracle prices.

### 6.3 Borrow and collateral-withdrawal limit
```
maxDebtValue(collValue, maxLtv) = mulDiv(collValue, maxLtv, WAD)                  // floor
withinMaxLtv  <=>  debtValue <= maxDebtValue(collValue, maxLtv)
```
Applied to the POST-action state: after `borrow`, and after `withdrawCollateral` when the user has
debt (a user with no debt skips the oracle entirely). Using `maxLtv` (not `LT`) for withdrawals
prevents withdrawing into a position that any price tick makes liquidatable. Within the limit
implies `HF >= 1` because `maxLtv < LT`.

## 7. Liquidation and bad debt [implemented]

### 7.1 Eligibility and the repay cap
A borrower with debt `D` (after accrual) is liquidatable iff `healthFactor < WAD` (6.2) using
current prices. Let `requested` be the liquidator's cap (`type(uint256).max` = no cap; 0 reverts).
```
maxRepayable(D, closeFactor) = mulDivUp(D, closeFactor, WAD)          // ceil, <= D
repaid = min(requested, maxRepayable(D, closeFactor))
```
Rounded UP so a 1-wei debt (floor would give 0) stays liquidatable.

### 7.2 Collateral seized
Let `pb, db` = borrow-asset price (WAD) and decimals, `pc, dc` = collateral price and decimals,
`b` = liquidationBonus:
```
seizeForRepay(r) = mulDiv( r * (WAD + b),  pb * 10**dc,  pc * 10**db * WAD )          // floor
repayForSeize(s) = mulDivUp( s,  pc * 10**db * WAD,  pb * (WAD + b) * 10**dc )        // ceil
```
`repayForSeize` is the inverse. Properties (tested): `repayForSeize(seizeForRepay(r)) <= r` and
`seizeForRepay(repayForSeize(s)) >= s`; the seized value never exceeds `repaid * (1 + b)`.
Worked example (independent): repay 5000e6 USDC, ETH = $1,200, b = 5% ->
`seizeForRepay = 4.375e18`; `repayForSeize(10e18)` at ETH = $500 -> `4761904762`.

### 7.3 Final amounts
```
C = collateral of the borrower
seized = seizeForRepay(repaid)
if seized > C:  seized = C;  repaid = min(repaid, repayForSeize(C))
burned = (repaid >= D) ? scaledDebt[borrower] : mulDiv(repaid, RAY, borrowIndex)          // floor
revert NothingToLiquidate if repaid == 0 or seized == 0
revert NothingToLiquidate if burned == 0 and seized != C           // see 7.4
```
Effects: `scaledDebt -= burned; totalScaledDebt -= burned; collateral[b] -= seized`. The liquidator
pays `repaid` of the borrow asset and receives `seized` collateral.

### 7.4 Zero-burn exception (liveness)
A repayment too small to burn any scaled debt is pointless and reverts, EXCEPT when it seizes ALL
remaining collateral: then the leftover debt is written off (7.5). Without the exception, an
extreme price collapse (collateral worth < ~1 unit of the borrow asset against large debt) would
make the position impossible to liquidate and its bad debt could never be cleared. (Found by
fuzzing; covered by a dedicated test.)

### 7.5 Bad debt
After the effects of 7.3, if `collateral[b] == 0` and `scaledDebt[b] != 0`:
```
debtBefore = debtFromScaled(totalScaledDebt, borrowIndex)
totalScaledDebt -= scaledDebt[b];  scaledDebt[b] = 0
loss = debtBefore - debtFromScaled(totalScaledDebt, borrowIndex)
totalSupplyAssets = (loss >= totalSupplyAssets) ? 0 : totalSupplyAssets - loss     // saturating
totalBadDebt += loss
```
The loss is the DROP in derived total debt (not the borrower's own ceil'd debt) so the solvency
identity (5.5) stays exact; it is socialized to suppliers by lowering the share price
`(A+1)/(S+1e6)`. The subtraction saturates because a revert here would make liquidation
impossible. Worked example (independent): ETH = $500, standard position (10 ETH, 10,000 USDC debt,
100,000 supplied): `seized = 10e18`, `repaid = 4761904762`, `loss = 5238095238`,
`totalSupplyAssets = 94761904762`, which equals the market's cash.

**Not implemented (documented gap):** a production system would first draw an insurance fund /
reserve and only then socialize; v1 has no admin, no reserve factor and no fund. See
docs/THREAT_MODEL.md.

## 8. Operations, ordering and oracle dependence [implemented]

Every state-changing function is `nonReentrant` and follows: (1) accrue interest, (2) checks,
(3) storage effects, (4) token transfers last.

| Function | Needs oracle? | Check applied |
|---|---|---|
| `supply`, `withdraw`, `redeem` | no | liquidity (`assets <= liquidity`) and share balance |
| `depositCollateral` | no | amount > 0 |
| `withdrawCollateral` | only if the user has debt | post-state `withinMaxLtv` |
| `borrow` | yes (both prices) | `assets <= liquidity`, post-state `withinMaxLtv` |
| `repay` | no | debt exists |
| `liquidate` | yes (both prices) | `healthFactor < WAD`, 7.x |

A stale or invalid oracle therefore freezes exactly the actions that extend credit or release
collateral against a price; deposits, repayments, supplier exits and debt-free collateral exits
keep working.

## 9. Function catalogue for the reference model [implemented]

Every function below is a PURE function of its arguments (no storage, no time, no oracle). The
reference model implements exactly these, with the same name and the same argument order, and must
behave identically: same outputs when the Solidity succeeds, a failure exactly when the Solidity
reverts. The command-line encoding is in `docs/M8_HANDOFF.md`; this section is the semantics.

### 9.1 Evaluation rules (they decide WHEN a function fails)

- **R1 Checked arithmetic.** Every `+`, `-`, `*` on 256-bit unsigned integers fails if the exact
  result is outside `[0, 2^256 - 1]`. This applies to every sub-expression that is evaluated,
  including products used as `mulDiv` operands or denominators.
- **R2 `mulDiv(a, b, d)`** = `floor(a*b/d)` using a 512-bit intermediate. Fails if `d == 0` or if the
  quotient does not fit in 256 bits. **`mulDivUp(a, b, d)`** = `mulDiv(a, b, d)` plus 1 when
  `a*b mod d != 0`; it fails in the same cases and also if that `+1` overflows.
- **R3 Powers of ten.** `10**d` (`d` = a token-decimals argument, `0..255`) is computed as a checked
  256-bit power: it fails for `d >= 78` (`10^77 < 2^256 < 10^78`).
- **R4 Eager operands, lazy branches.** All operands of an expression and all arguments of a call
  are evaluated (and may fail) before the operation runs, even if the final value would not depend
  on them. In an `if / else` or a `? :` ONLY the taken branch is evaluated. Where a function lists
  steps in order, steps are evaluated in that order; since every failure is the same failure, only
  *whether* something fails matters, never which step fails first.
- **R5 Products are left-associative**: `a * b * c` means `(a * b) * c` (matters only for whether an
  intermediate overflows).
- **R6 Constants**: `WAD = 10^18`, `RAY = 10^27`, `WAD_TO_RAY = 10^9`, `SECONDS_PER_YEAR = 31_536_000`,
  `VIRTUAL_SHARES = 10^6`, `VIRTUAL_ASSETS = 1`, `MAX_ANNUAL_RATE = 10 * WAD`,
  `MAX_LIQUIDATION_BONUS = 25 * 10^16` (0.25 WAD), `UINT_MAX = 2^256 - 1`.
- **R7 Rate-model and risk-parameter arguments are NOT validated** by the functions that use them
  (only `validateRateParams` / `validateRiskParams` validate). Invalid parameters therefore flow
  through the arithmetic and fail only where rules R1-R2 say so.

### 9.2 Interest rate model

| Function (arguments in order) | Returns | Definition |
|---|---|---|
| `utilization(supply, borrows)` | `[u]` | `supply == 0` -> 0; `borrows >= supply` -> WAD; else `mulDiv(borrows, WAD, supply)`. Never fails. |
| `validateRateParams(base, slope1, slope2, optimal)` | `[1]` | Fails if `optimal == 0` or `optimal >= WAD`; fails if any of `base`, `slope1`, `slope2` is `> MAX_ANNUAL_RATE`. Otherwise returns 1. |
| `annualBorrowRate(base, slope1, slope2, optimal, u)` | `[rate]` | Fails if `u > WAD`. If `u <= optimal`: `base + mulDiv(slope1, u, optimal)`. Else: `base + slope1 + mulDiv(slope2, u - optimal, WAD - optimal)` (the subtraction `WAD - optimal` fails if `optimal > WAD`). |
| `borrowRatePerSecond(base, slope1, slope2, optimal, u)` | `[r]` | `annual = annualBorrowRate(...)` (same failures), then `(annual * WAD_TO_RAY) / SECONDS_PER_YEAR` with plain floor division. |

### 9.3 Borrow index and scaled debt

| Function | Returns | Definition |
|---|---|---|
| `accrueIndex(index, ratePerSecond, dt)` | `[newIndex]` | `t = ratePerSecond * dt`; `index + mulDivUp(index, t, RAY)`. |
| `scaledFromAssetsUp(assets, index)` | `[s]` | `mulDivUp(assets, RAY, index)` (fails if `index == 0`). |
| `scaledFromAssetsDown(assets, index)` | `[s]` | `mulDiv(assets, RAY, index)`. |
| `debtFromScaled(scaled, index)` | `[d]` | `mulDivUp(scaled, index, RAY)`. |

### 9.4 Supplier shares

| Function | Returns | Definition |
|---|---|---|
| `toSharesDown(assets, totalAssets, totalShares)` | `[x]` | `mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS)` |
| `toSharesUp(assets, totalAssets, totalShares)` | `[x]` | `mulDivUp(` same operands `)` |
| `toAssetsDown(shares, totalAssets, totalShares)` | `[x]` | `mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES)` |
| `toAssetsUp(shares, totalAssets, totalShares)` | `[x]` | `mulDivUp(` same operands `)` |

The `+ VIRTUAL_*` additions are checked (R1): `totalShares = UINT_MAX` fails.

### 9.5 Valuation, health factor, limits

| Function | Returns | Definition |
|---|---|---|
| `collateralValueUsd(amount, priceWad, decimals)` | `[v]` | `mulDiv(amount, priceWad, 10**decimals)` |
| `debtValueUsd(amount, priceWad, decimals)` | `[v]` | `mulDivUp(amount, priceWad, 10**decimals)` |
| `healthFactor(collateralValue, debtValue, liquidationThreshold)` | `[hf]` | `debtValue == 0` -> UINT_MAX; else `mulDiv(collateralValue, liquidationThreshold, debtValue)` |
| `maxDebtValue(collateralValue, maxLtv)` | `[v]` | `mulDiv(collateralValue, maxLtv, WAD)` |
| `isWithinMaxLtv(collateralValue, debtValue, maxLtv)` | `[0 or 1]` | `1` if `debtValue <= maxDebtValue(collateralValue, maxLtv)` else `0` (fails if `maxDebtValue` fails) |
| `maxRepayable(debt, closeFactor)` | `[v]` | `mulDivUp(debt, closeFactor, WAD)` |
| `validateRiskParams(maxLtv, liquidationThreshold, bonus, closeFactor)` | `[1]` | Fails if any of: `maxLtv == 0`; `maxLtv >= liquidationThreshold`; `liquidationThreshold >= WAD`; `bonus == 0`; `bonus > MAX_LIQUIDATION_BONUS`; `liquidationThreshold * (WAD + bonus) >= WAD * WAD`; `closeFactor == 0`; `closeFactor > WAD`. Otherwise returns 1. |

### 9.6 Liquidation formulas

`dd`/`cd` are the borrow-/collateral-token decimals, `dp`/`cp` the borrow-/collateral-asset prices.

| Function | Returns | Definition |
|---|---|---|
| `seizeForRepay(repay, dp, dd, cp, cd, bonus)` | `[s]` | `mulDiv(repay * (WAD + bonus), dp * 10**cd, cp * 10**dd * WAD)` |
| `repayForSeize(seize, dp, dd, cp, cd, bonus)` | `[r]` | `mulDivUp(seize, cp * 10**dd * WAD, dp * (WAD + bonus) * 10**cd)` |

Operand note (R1/R4): ALL of `WAD + bonus`, `repay * (WAD + bonus)`, `10**cd`, `dp * 10**cd`,
`10**dd`, `cp * 10**dd`, `(cp * 10**dd) * WAD` are computed before `mulDiv` runs.

### 9.7 Market kernels (composite procedures)

| Function (arguments in order) | Returns | Definition |
|---|---|---|
| `accrue(totalScaledDebt, totalSupplyAssets, borrowIndex, elapsed, base, slope1, slope2, optimal)` | `[newIndex, interest]` | `oldDebt = debtFromScaled(totalScaledDebt, borrowIndex)`; `u = utilization(totalSupplyAssets, oldDebt)`; `r = borrowRatePerSecond(base, slope1, slope2, optimal, u)`; `newIndex = accrueIndex(borrowIndex, r, elapsed)`; `interest = debtFromScaled(totalScaledDebt, newIndex) - oldDebt` (checked subtraction). |
| `repayAmounts(assets, scaled, index)` | `[repaid, burned]` | `debt = debtFromScaled(scaled, index)`; if `assets >= debt`: `[debt, scaled]`; else `[assets, scaledFromAssetsDown(assets, index)]`. |
| `liquidationAmounts(scaled, index, requested, collateral, cp, dp, cd, dd, bonus, closeFactor)` | `[repaid, seized, burned]` | `debt = debtFromScaled(scaled, index)`; `repaid = maxRepayable(debt, closeFactor)`; if `requested < repaid`: `repaid = requested`; `seized = seizeForRepay(repaid, dp, dd, cp, cd, bonus)`; if `seized > collateral`: `seized = collateral` and `forSeize = repayForSeize(collateral, dp, dd, cp, cd, bonus)`, then if `forSeize < repaid`: `repaid = forSeize`; finally `burned = (repaid >= debt) ? scaled : scaledFromAssetsDown(repaid, index)`. |
| `badDebt(totalScaledDebt, borrowerScaled, index, totalSupplyAssets)` | `[debtWrittenOff, loss, newTotalSupplyAssets]` | `debtBefore = debtFromScaled(totalScaledDebt, index)`; `debtAfter = debtFromScaled(totalScaledDebt - borrowerScaled, index)` (checked subtraction); `debtWrittenOff = debtFromScaled(borrowerScaled, index)`; `loss = debtBefore - debtAfter`; `newTotalSupplyAssets = (loss >= totalSupplyAssets) ? 0 : totalSupplyAssets - loss`. |

Note the argument order of `liquidationAmounts`: collateral price `cp` comes BEFORE debt price `dp`,
and collateral decimals `cd` before debt decimals `dd` (unlike `seizeForRepay`/`repayForSeize`,
which take the debt asset first). This asymmetry is deliberate and fixed.

### 9.8 Clarifications found while implementing the reference model (M8)

The C++ model was written from sections 0-9 only. Reading them as a stranger, these points were
not stated explicitly. None of them turned out to be a disagreement with the Solidity; they are
now written down so the next reader does not have to guess (details in
`docs/DIFFERENTIAL_REPORT.md`).

- **`annualBorrowRate`, `WAD - optimal`.** The subtraction is only evaluated in the `u > optimal`
  branch. Since `u <= WAD` is checked first, that branch implies `optimal < WAD`, so
  `WAD - optimal` can never underflow in practice: the remark "fails if `optimal > WAD`" describes
  a case that is unreachable. With `optimal > WAD` the `u <= optimal` branch is always taken.
- **`validateRiskParams` and `validateRateParams` check order.** The listed conditions are a
  plain "any of these fails" disjunction. Whether a product such as
  `liquidationThreshold * (WAD + bonus)` overflows is therefore irrelevant on its own: an overflow
  is also a failure, so the result is "fails" either way. The order of the checks is unobservable.
- **`liquidationAmounts` with `requested == 0`** succeeds and returns `[0, 0, 0]` (no failure, no
  special case): `repaid = 0`, `seized = seizeForRepay(0, ...) = 0`, `burned = mulDiv(0, RAY, index)`.
  The "nothing to liquidate" revert of section 7.3 belongs to the market, not to this pure function.
- **`liquidationAmounts` with `collateral == 0`** and a positive `seized` takes the cap branch:
  `seized = 0` and `repaid = min(repaid, repayForSeize(0, ...)) = 0`.
- **`repayAmounts` with `index == 0`**: `debt = debtFromScaled(scaled, 0) = 0`, so
  `assets >= debt` holds and the result is `[0, scaled]`; `scaledFromAssetsDown` (which would divide
  by zero) is never evaluated.
- **Decimals arguments.** `decimals`, `dd`, `cd` are `uint8` in the Solidity, so the command-line
  model rejects values above 255 as a usage error (exit 2, the Solidity call could not even be
  made). `10**d` for `78 <= d <= 255` is a model failure (exit 1, R3).
- **Reachability of large decimals in the liquidation formulas.** `seizeForRepay` /
  `repayForSeize` also multiply the power of ten by `WAD` and a price, so they already fail for
  `10**d * WAD * price` at much smaller `d` than 78 (with price 1: `d >= 60`). R1 explains it; it is
  not a separate rule.
