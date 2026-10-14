# Slither triage

Tool: Slither 0.11.6 (installed with `pip` into a throwaway virtual environment on Windows; no
WSL needed). Scope: `src/` only (`slither.config.json` filters `lib/`, `test/`, `script/`).
Compiler: solc 0.8.28 via Foundry (`forge build --build-info`).

Run it yourself:

```bash
python -m venv .venv-slither && . .venv-slither/bin/activate   # Windows: .venv-slither\Scripts\activate
pip install slither-analyzer
slither . --config-file slither.config.json
```

## Result

Re-run after the M7 refactor (accrual / repay / liquidation / bad-debt kernels moved into the pure
`MarketMath` library): still **0** findings with the same configuration.

| Stage | Findings |
|---|---|
| First run, default config | **41** (0 High, 10 Medium, 13 Low, 18 Informational) |
| After documented triage (9 inline suppression blocks covering the 10 Medium findings, 2 detectors excluded in config) | **0** |

Every finding below was read and judged individually. No finding was a vulnerability. Nothing
was "fixed" by changing logic; the contract code was left unchanged except for comments.

## Medium: `incorrect-equality` (9) — suppressed inline, justified

Slither warns on `==` comparisons because strict equality on an *ether or token balance* is
dangerous (an attacker can force-send value to break it). None of the nine compares a balance:

| Site | Expression | Why it is safe |
|---|---|---|
| `_accrue`, `_currentIndex` | `elapsed == 0` | `elapsed = block.timestamp - lastAccrual`; "no time passed" fast path. Both branches are correct; nothing an attacker controls |
| `supply` | `shares == 0` | Guard that refuses a deposit minting zero shares (derived from accounting totals, not `balanceOf`) |
| `redeem` | `assets == 0` | Guard that refuses redeeming dust worth zero assets |
| `repay` | `burned == 0` | Guard against a repayment that burns no debt |
| `liquidate` | `seized == collateralOf[borrower]` | `seized` was *assigned* `collateral` a few lines earlier when capped; the equality is intentional and set by the contract itself |
| `liquidate` | `repaid == 0 \|\| seized == 0 \|\| (burned == 0 && !takesAll)` | Zero checks of values computed in the same call |
| `liquidate` | `collateralOf[borrower] == 0 && scaledDebt[borrower] != 0` | Defines "bad debt"; internal accounting only |
| `healthFactor` | `scaled == 0` | "No debt" shortcut |

All use `// slither-disable-start/next-line incorrect-equality` with a pointer to this file.
Donating tokens cannot change any of these values (idle liquidity is an accounting number, see
`invariant_a_borrowTokenConservation` and `test_donationDoesNotChangeSharePrice`).

## Medium: `unused-return` (1) — suppressed inline, justified

`ChainlinkOracle._latestRound`: the `startedAt` element of `latestRoundData()` is not read.
Only `roundId`, `answer`, `updatedAt` and `answeredInRound` matter for the checks; `startedAt`
adds no safety (documented in the function's NatSpec). Suppressed with
`// slither-disable-next-line unused-return`.

## Low: `timestamp` (13) — detector excluded in config, justified

Slither flags any comparison whose operands are *tainted* by `block.timestamp`. The contract's
genuine uses of time are exactly two, both intended:

1. **Interest accrual** (`elapsed = now - lastAccrual`). Interest is a function of time; a
   proposer can skew the timestamp by seconds, which changes interest by a negligible amount.
2. **Oracle staleness** (`now - updatedAt > heartbeat`). Heartbeats are minutes to days.

The other 11 hits are taint propagation: functions like `borrow`, `_withdraw`, `repay` and
`liquidate` call `_accrue()` first, so *later* comparisons on accounting values (e.g.
`assets > available`) are reported as "timestamp-dependent". The comparisons themselves do not
depend on the clock. The `block-timestamp` lint in Foundry is silenced with a comment at the two
real sites. Excluded via `"detectors_to_exclude": "naming-convention,timestamp"`.

## Informational: `naming-convention` (18) — detector excluded in config

`UPPER_CASE` `immutable`s (`MAX_LTV`, `COLLATERAL_TOKEN`, `FEED`, ...) are reported as "not in
mixedCase". This is the common convention for immutables/constants (also used by OpenZeppelin
and `forge fmt`'s own lint profile). Style only; no change.

## Things Slither could NOT tell us

Static analysis does not understand the economics. The checks that matter most are in the
invariant, fork, scenario and reentrancy tests; see `docs/THREAT_MODEL.md`.
