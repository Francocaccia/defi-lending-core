# defi-lending-core

A minimal over-collateralized lending protocol (Solidity + Foundry + Chainlink) with an
independent C++ reference model that verifies the on-chain math.

> **Status: M6 done (of M0-M8).** Implemented and tested: Chainlink oracle wrapper, kinked interest
> rate model, supplier shares, borrow index, health factor, liquidation and bad-debt recording.
> Verified by unit, fuzz, scenario, invariant, mainnet-fork and reentrancy tests plus a Slither pass.
> Demo script, final README and the C++ reference model (differential tests) come later.
> This README is filled in milestone by milestone. This is a portfolio/educational project,
> **not** a production protocol: never use it with real funds.

## What it will do (v1 scope)

One market, one collateral asset (WETH), one borrow asset (USDC-like, 6 decimals):
supply with shares, borrow against collateral with a compound-style borrow index, a
utilization-based interest rate model with a kink, Chainlink-based health factor, and
liquidations with explicit bad-debt recording.

## Architecture

TODO (M7): diagram of Solidity contracts and the Solidity / C++ verification split.

## Quick start

Requirements: [Foundry](https://book.getfoundry.sh/getting-started/installation) and git.
**No C++ toolchain is needed** to build and test the protocol.

```bash
git clone --recurse-submodules https://github.com/Francocaccia/defi-lending-core.git
cd defi-lending-core
forge build
forge test
```

### Optional: fork tests

Fork tests run against a mainnet fork using the real Chainlink ETH/USD feed. They are
skipped automatically when no RPC is configured.

```bash
cp .env.example .env     # then set MAINNET_RPC_URL to any free public RPC (read-only)
```

### Optional: differential tests vs the C++ reference model (M8)

TODO (M8): build instructions, and `FOUNDRY_PROFILE=diff forge test --match-path "test/differential/*"`.
`ffi` is enabled **only** in the `diff` profile; see `foundry.toml` for why that is safe
(one fixed, repo-built binary; numeric arguments only; no shell, no network).

## Design decisions

TODO (M7). See `docs/DESIGN.md` (spec) and `docs/THREAT_MODEL.md`.

## Reference model

TODO (M8): what it verifies (the math) and what it does not (state machine, access
control, oracle behaviour).

## Limitations

Out of scope for v1: multiple assets, cross-margin, upgradeability, governance, flash loans,
L2 sequencer-uptime checks, a frontend, and anything involving real money or mainnet
deployment. Full list will be finalized in M7.

## Measured metrics

Measured on Foundry 1.8.5 / solc 0.8.28 (full details and commands in `docs/GAS_AND_COVERAGE.md`):

| Metric | Value |
|---|---|
| Tests, default profile, no RPC (what CI runs) | 275 passed, 0 failed, 1 skipped (fork suite) |
| Tests, CI profile (1000 fuzz runs, invariant depth 128) | 275 passed, 0 failed, 1 skipped |
| Tests with a mainnet RPC configured | 282 passed, 0 failed |
| Invariant properties (random action sequences, 5 actors) | 13, all hold; one campaign reached 53 liquidations and 13 bad-debt events |
| Line / statement / branch / function coverage of `src/` | 100% (290/290), 100% (375/375), 100% (62/62), 100% (51/51) |
| Slither (scope `src/`) | 0 findings after documented triage (41 raw) |
| `LendingMarket` runtime size | 9,272 bytes |

Gas per function (median, unit/scenario tests, fresh storage): `supply` 133k, `borrow` 138k,
`repay` 64k, `withdrawCollateral` 66k, `liquidate` 131k; see the caveats in
`docs/GAS_AND_COVERAGE.md`.

## Security documentation

| Document | Contents |
|---|---|
| `docs/DESIGN.md` | exact math and rounding rules (the spec) |
| `docs/THREAT_MODEL.md` | threats, defences, evidence, and what is NOT mitigated |
| `docs/ROUNDING_REVIEW.md` | every rounding decision and the test that pins it |
| `docs/SLITHER_TRIAGE.md` | all 41 static-analysis findings, individually judged |
| `docs/GAS_AND_COVERAGE.md` | commands and raw numbers behind the metrics above |

## What I learned

TODO (author).

## License

MIT. See `LICENSE`. Educational project, not audited, never use with real funds.
