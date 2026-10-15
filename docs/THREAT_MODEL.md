# THREAT MODEL

Educational project. **Not audited. Never use with real funds.** This document lists what the
protocol defends against, how that is evidenced (test names), and, just as important, what it
does NOT defend against. "Evidence" refers to tests in `test/`; "Slither" refers to
`docs/SLITHER_TRIAGE.md`; formulas are in `docs/DESIGN.md`; rounding in `docs/ROUNDING_REVIEW.md`.

## 1. System, trust and assumptions

- **One market**: one collateral token, one borrow/supply token, two Chainlink-backed oracles,
  immutable parameters, **no owner, no admin, no pause, no upgrade, no fee switch**. Nobody can
  move user funds except through the user-facing functions.
- **Trusted**: the two Chainlink feeds (and the Chainlink network behind them), and the
  correctness of the oracle/feed addresses and parameters chosen at deployment. Both are
  immutable: a wrong address or a bad parameter set cannot be fixed, only redeployed.
- **Assumed**: both tokens are plain ERC-20s (see T12). Block timestamps are accurate to ~seconds.
- **Actors**: suppliers, borrowers, liquidators (permissionless), and an adversary who can be any
  of them, can deploy contracts, can sandwich transactions, and may control a token's behaviour
  only where noted.

## 2. Threats

Legend for status: **Mitigated** (code + tests), **Partially**, **Not mitigated** (accepted gap).

### Oracle

| ID | Threat | Mechanism / defence | Evidence | Status |
|---|---|---|---|---|
| T1 | **Stale price** used to borrow, withdraw collateral or liquidate | Per-feed `heartbeat`; `now - updatedAt > heartbeat` reverts. Staleness freezes only price-dependent actions | `ChainlinkOracleTest.test_price_revertsOneSecondPastHeartbeat`, `testFuzz_price_stalenessBoundary`, `ScenariosTest.test_scenario_staleOracle_*`, `MainnetForkTest.test_fork_realFeedGoesStaleWithoutUpdates` | Mitigated |
| T2 | **Invalid round data**: zero/negative answer, incomplete round, future timestamp, `answeredInRound < roundId`, scaling overflow, reverting feed | Each check reverts with a custom error; fails closed | `ChainlinkOracleTest` (30 tests), `testFuzz_price_revertsOnNonPositiveAnswer`, `Scenarios.*Price*`, `*brokenFeed*`, `*incompleteRound*` | Mitigated |
| T3 | **Price manipulation** (flash-loan spot manipulation) | No DEX spot price is used anywhere; only Chainlink's aggregated feeds | design (no spot-price code path) | Mitigated by design |
| T4 | **Feed compromise / wrong feed** (bug, malicious deployer) | NOT detectable on-chain. Constants in `script/Addresses.sol` are verified from the Chainlink registry and in `MainnetForkTest.test_fork_addressesAreWhatTheyClaimToBe` | fork test | **Not mitigated** (trusted) |
| T5 | **Bad but fresh price** (flash crash, wick, depeg within deviation) | No circuit breaker, no min/max bounds, no TWAP, no deviation check between rounds. A real wick can liquidate healthy-looking positions | none | **Not mitigated** |
| T6 | **Stablecoin depeg** | The borrow asset is priced by its own feed, never hardcoded at $1. A depeg changes debt value and can make positions liquidatable | `Liquidation.test_liquidate_becomesPossibleWhenBorrowAssetAppreciates`, `Borrow.test_borrow_usesBorrowAssetPrice_*`, fork test uses real USDC ≈ $0.9998 | Mitigated (correct valuation), but depeg risk itself remains |
| T7 | **Oracle outage freezes the market**: while stale, nobody can borrow, withdraw debt-backed collateral or liquidate. A crash during an outage lets underwater positions accumulate | Repay, deposit, supplier exit and debt-free collateral exit keep working | `Scenarios.test_scenario_staleOracle_freezesPriceDependentActionsOnly` | Partially (bounded blast radius; liquidation stall is inherent) |
| T8 | **L2 sequencer down / grace period** | Not applicable on L1; no sequencer-uptime feed check is implemented | none | **Not mitigated** (documented gap for L2 deployments) |
| T9 | **Heartbeat misconfiguration** (too tight: a healthy feed looks stale and the market freezes; too loose: old prices accepted) | Bounded `1s..7 days`; the configured bound is heartbeat + a deliberate margin and the numbers were verified against the feeds' real update gaps (ETH/USD max observed gap 3,744 s vs bound 4,200 s; USDC/USD 86,472 s vs 90,000 s; see DESIGN 2.3 and `script/Addresses.sol`). The Sepolia USDC/USD feed goes silent for days, so a Sepolia market can freeze (fail-closed) | `testFuzz_constructor_rejectsInvalidHeartbeat`, `MainnetFork.t.sol` | Partially (bounds enforced on-chain; correctness of the chosen value is a deployment decision) |

### Lending logic

| ID | Threat | Mechanism / defence | Evidence | Status |
|---|---|---|---|---|
| T10 | **Under-collateralized borrow** or collateral withdrawal | Post-state `debtValue <= collateralValue * maxLtv` (collateral value rounded down, debt value up); withdrawal also checked against `maxLtv` so a user cannot withdraw into liquidatability | `testFuzz_borrowLimitIsExact`, `Collateral.*`, invariant (c) `invariant_c_noSuccessfulWithdrawalBrokeMaxLtv` | Mitigated |
| T11 | **Liquidation cascades**: a price drop liquidates many positions at once; liquidators dump seized collateral; supply of liquidators may be limited | 50% close factor, 5% bonus, permissionless liquidation. No auctions, no circuit breakers, no protection against correlated crashes | `Scenarios.test_scenario_cascade_*`, invariants under wide random price swings | **Partially** (mechanics tested; market-level cascade dynamics are out of scope) |
| T12 | **Bad debt** (collateral worth less than debt after liquidation) | Detected at liquidation, written off, **socialized to suppliers** by lowering the share price; recorded in `totalBadDebt` + `BadDebtRecorded`. Saturates (never reverts) so a position can always be cleaned | `Liquidation.test_badDebt_*`, `test_badDebt_totalLossSaturatesSupplyAtZero`, `test_liquidate_zeroBurnIsAllowedWhenItSeizesAllCollateral`, `testFuzz_badDebtOnlyWhenCollateralExhausted` | Partially: **no insurance fund / reserve; suppliers bear 100% of the loss** |
| T13 | **Liquidation liveness**: a position that cannot be liquidated keeps accruing debt | Dust and zero-burn cases analysed; found and fixed a real hole by fuzzing (zero-burn liquidation allowed iff it seizes all collateral) | `Liquidation.test_liquidate_dust*`, `test_liquidate_zeroBurnIsAllowedWhenItSeizesAllCollateral` | Mitigated |
| T14 | **Borrower front-runs liquidation** by repaying/topping up | Allowed and intended: it restores health | `Scenarios.test_scenario_borrowerCanSaveThemselves*` | Accepted (feature) |
| T15 | **Liquidator sandwich / MEV**: bots race to liquidate; priority-fee wars | Anyone can liquidate; bonus is fixed; no keeper incentives beyond the bonus | none | Accepted |
| T16 | **Liquidity run**: utilization → 100% locks supplier withdrawals until borrowers repay | Slope2 raises the rate steeply above 80%; withdrawals limited to idle liquidity | `Scenarios.test_scenario_highUtilizationBlocksWithdrawalsUntilRepayment` | Partially (incentive, not a guarantee) |
| T17 | **Interest-rate manipulation** | Utilization uses accounting totals, not `balanceOf`: a donation moves nothing. A whale can still raise utilization by really borrowing | `Supply.test_donationDoesNotChangeSharePrice`, invariant `invariant_a_borrowTokenConservation` (donate action) | Mitigated for donations; whale effect accepted |
| T18 | **Self-liquidation / own-bonus extraction** | A borrower can liquidate themselves; they pay `repaid` and get `repaid*(1+bonus)` of their own collateral (net effect is just a debt-for-collateral swap with bonus returned to themselves) | not specifically tested | Accepted: no value extracted from others |

### Rounding, precision, donations

| ID | Threat | Mechanism / defence | Evidence | Status |
|---|---|---|---|---|
| T19 | **First-depositor / share-inflation attack** | Virtual shares (1e6) and assets (1); idle liquidity is accounting-based so donations do nothing | `SharesMathTest.test_inflationAttack_*`, `Supply.test_firstDepositorInflationAttackFails`, invariant donation action | Mitigated |
| T20 | **Rounding leaks** (repeated tiny actions extracting dust) | Every conversion rounds against the user; the share price never falls except through bad debt; per-user debt rounding ≤ N-1 wei | `docs/ROUNDING_REVIEW.md`; `testFuzz_sharePriceNeverDecreasesOnSupplierActions`, invariants (b), (d); flipping the rounding direction of supply, withdraw, redeem, borrow or repay is caught by the tests (see ROUNDING_REVIEW) | Mitigated |
| T21 | **Overflow / underflow** | Solidity 0.8 checked math; `mulDiv` with 512-bit intermediates; unrealistic inputs revert rather than wrap | fuzz ranges documented in `test/fuzz/*` | Mitigated (reverts on absurd values) |
| T22 | **Dust positions**: there is NO minimum debt or minimum collateral, so small positions can cost more gas to liquidate than the 5% bonus pays. On Ethereum mainnet at normal gas prices a liquidation costs tens of dollars, so positions below a few hundred dollars of debt can be uneconomic for every liquidator; they then sit underwater, keep accruing interest and, if the price keeps falling, turn into bad debt that nobody liquidates (and, through T32, is not recognised). Many such positions add up. | `maxRepayable` rounds up so even a 1-wei debt CAN be liquidated by anyone willing to pay the gas, and the zero-burn rule (T13) lets a position be cleared; but there is nothing that makes it worth doing. A production market would set a minimum borrow size and/or a liquidation incentive floor | `Liquidation.test_liquidate_dustDebtIsFullyLiquidatable` (the mechanism works; economics are not tested) | **NOT mitigated in v1** (accepted limitation) |

### Accounting and economics (added in the final review)

| ID | Threat | Mechanism / consequence | Evidence | Status |
|---|---|---|---|---|
| T32 | **Late bad-debt recognition** (bank-run dynamic). Bad debt is only written off when a liquidation seizes ALL of a borrower's collateral. A deeply underwater position that still holds even a little collateral (or that nobody liquidates, see T22) is **not** written off: the debt stays in `totalBorrowAssets`, so `totalSupplyAssets` and the supplier share price stay **overstated** by the unrecognised loss. Suppliers who withdraw first are paid at the inflated price (from idle liquidity); the loss is then borne entirely by the suppliers who stay, and when the write-off finally happens the price drops. Rational suppliers therefore have an incentive to exit at the first sign of insolvency, which is a run. There is no mark-to-market haircut, no pause and no insurance fund to dampen it. | Not addressed: it would need either a solvency-aware share price (haircut for positions with HF below the bonus break-even `1 / (LT x (1 + bonus))`) or a first-loss reserve. The behaviour is visible in the tests (`Liquidation.test_badDebt_*`: the loss appears only at the final liquidation) but is not tested as a run | **NOT mitigated in v1** (documented design limitation) |

### Execution environment

| ID | Threat | Mechanism / defence | Evidence | Status |
|---|---|---|---|---|
| T23 | **Reentrancy** via token hooks (ERC-777-style) in any function | Checks-effects-interactions + `nonReentrant` on every state-changing function; events before transfers. Verified with a hostile token that calls back on every transfer; removing the guard from any of the 8 functions fails the tests | `test/security/Reentrancy.t.sol` (8 re-entry tests) | Mitigated |
| T24 | **Read-only reentrancy** (another protocol reads our views mid-callback) | State is fully updated BEFORE any transfer, so views read from a callback already show the final state | `Reentrancy.test_readOnlyReentrancy_*` | Mitigated |
| T25 | **Fee-on-transfer / rebasing / deflationary tokens** | NOT supported: the market credits the requested amount, not the received amount. With such a token the books would exceed the real balance | none | **Not mitigated** (unsupported; deploy-time choice) |
| T26 | **Token admin powers** (e.g. USDC blacklist / pause / upgrade): the market address or a user being blacklisted freezes transfers | Out of the protocol's control | none | **Not mitigated** (inherent to the chosen assets) |
| T27 | **Tokens with >18 decimals** | Rejected in the constructor; oracle also rejects feeds with >18 decimals | `Constructor.test_constructor_revertsOnTokenWithMoreThan18Decimals` | Mitigated |
| T28 | **Block-timestamp manipulation** | A proposer can skew time by seconds; heartbeat/interest horizons are minutes–years | Slither `timestamp` (documented) | Accepted |
| T29 | **Unbounded loops / gas DoS** | No loops over users or positions anywhere | design | Mitigated |
| T30 | **Admin / governance risk** | None exists | design | N/A |
| T31 | **Mis-deployment** (wrong oracle, wrong tokens, silly parameters) | Constructor validates ranges and relations but cannot know that an oracle really tracks the token | constructor tests | **Not mitigated** (verify at deploy; see `script/Addresses.sol`) |

## 3. What is NOT mitigated (summary)

1. Compromised or wrong Chainlink feeds; fresh-but-wrong prices (no circuit breaker / TWAP).
2. L2 sequencer-uptime handling.
3. Bad debt has no first-loss buffer: **suppliers absorb all of it**. A production design would add
   an insurance fund / reserve factor, or auction mechanics, and a governance-free way to top it up.
4. Market-wide liquidation dynamics (liquidator capital, MEV, gas spikes during crashes).
5. Fee-on-transfer, rebasing and hook tokens as the *market's own* assets; token blacklists/pauses.
6. Parameter/oracle mistakes at deployment (immutability cuts both ways).
7. Economic attacks that need real capital (e.g. a whale pushing utilization to 100%).
8. **Late bad-debt recognition (T32):** losses are recognised only when a liquidation exhausts a borrower's collateral, so the share price is overstated meanwhile and early withdrawers shift the loss to those who stay.
9. **Dust positions (T22):** no minimum debt; small positions can be uneconomic to liquidate once real gas costs exceed the bonus, so bad debt can accumulate unseen.

## 4. How the claims are tested

| Layer | What it shows |
|---|---|
| Unit / fuzz | exact numbers (hand-computed, independently verified in Python) and algebraic properties of every pure function |
| Scenario | oracle outages, crash → liquidation → bad debt, bank run, full lifecycle |
| Invariants (5 actors, random valid action sequences) | solvency, exact token conservation, debt/share bookkeeping, LTV safety of withdrawals, share price monotonicity |
| Fork (real feeds, WETH, USDC) | the code works with the real contracts, real decimals and the real USDC price |
| Security | hostile-token reentrancy, read-only reentrancy |
| Mutation checks (manual) | injected bugs were caught: 18/18 unit-level (market logic), 11/11 by the invariant suite alone, 8/8 reentrancy guards |
| Static analysis | Slither: 0 high/medium findings that survive triage (`docs/SLITHER_TRIAGE.md`) |

Limits of the evidence: fuzz and invariant testing are probabilistic, not proofs; the mutation
checks were run by hand on a hand-picked list; fork tests depend on live data and a public RPC.
No external audit or formal verification has been done.
