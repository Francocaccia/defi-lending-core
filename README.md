# defi-lending-core

A minimal over-collateralized lending protocol (Solidity + Foundry + Chainlink) with an
independent C++ reference model that verifies the on-chain math.

> **Status: M4 done (of M0-M8).** Implemented so far: Chainlink oracle wrapper, kinked interest
> rate model, supplier shares, borrow index, health factor, liquidation and bad-debt recording,
> all unit/fuzz/scenario tested. Invariant, fork and differential tests come in later milestones.
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

As of M4, from real command output (re-measured at the end of every milestone):

| Metric | Value | Command |
|---|---|---|
| Tests | 263 passed, 0 failed (default profile, 256 fuzz runs) | `forge test` |
| Tests, CI profile | 263 passed, 0 failed (1000 fuzz runs) | `FOUNDRY_PROFILE=ci forge test` |
| Line coverage of `src/` | 100% (290/290) | `forge coverage` |
| Branch coverage of `src/` | 100% (62/62) | `forge coverage` |

Gas snapshot, invariant results and fork-test results will be added in M5/M6.

## What I learned

TODO (author).

## License

MIT. See `LICENSE`. Educational project, not audited, never use with real funds.
