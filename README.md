# defi-lending-core

A minimal over-collateralized lending protocol (Solidity + Foundry + Chainlink) with an
independent C++ reference model that verifies the on-chain math.

> **Status: M0 (setup).** Nothing is implemented yet. This README is a skeleton and will be
> filled in milestone by milestone. This is a portfolio/educational project, **not** a
> production protocol: never use it with real funds.

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

None yet. Every number here will come from real command output (`forge test`,
`forge coverage`, `forge snapshot`).

## What I learned

TODO (author).

## License

MIT. See `LICENSE`. Educational project, not audited, never use with real funds.
