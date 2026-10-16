# Demo output

Real output of the local demo, produced on 2026-10-16 with:

```
forge Version: 1.8.5
Commit SHA: 51a52c59cffd940f76eddd0b4bb1791aa4b5ac7f
Build Timestamp: 2026-10-05T17:01:32.131957300Z (1791219692)
Build Profile: dist
```

```
forge script script/Demo.s.sol --sig "runWithInterest()"
```

The demo deploys the market on mock tokens and mock Chainlink feeds (the real oracle wrapper and market code),
and tells one story: supply, borrow, a year of interest, an ETH crash, a liquidation, a deeper crash and bad
debt. It runs in-process (no network, no keys). The block below is the script's standard output verbatim, after
the compiler messages (which depend on the build cache). The market address and the gas figure depend on the
deployer nonce and the compiler settings; every other number is deterministic. `test/script/Demo.t.sol` asserts
the key numbers, so the demo cannot silently rot.

```text
Script ran successfully.
Gas used: 7445945

== Return ==
0: struct Demo.Result Result({ bobHealthBefore: 1600000000000000000 [1.6e18], bobHealthAfterCrash: 955223880597014925 [9.552e17], firstRepaid: 5025000000 [5.025e9], firstSeized: 4396875000000000000 [4.396e18], bobHealthAfterLiquidation: 1070447761194029850 [1.07e18], badDebt: 3424107143 [3.424e9], aliceBalanceAtEnd: 96625892857 [9.662e10] })

== Logs ==
  == 1. DEPLOY (mock WETH / USDC / Chainlink feeds + the real oracle wrapper and market)
  market            0x0165878A594ca255338adfa4d48449f69242Eb8F
  parameters        max LTV 75% | liquidation threshold 80% | bonus 5% | close factor 50%
  rate model        0% base, +4% up to the 80% kink, +75% above it
  prices            ETH $2,000.00 | USDC $1.00
  == 2. ALICE supplies 100,000 USDC
  shares minted     100000000000000000
  alice's balance   100000.000000 USDC
  == 3. BOB deposits 10 WETH ($20,000) and borrows 10,000 USDC
  bob's debt        10000.000000 USDC
  health factor     1.600000  (liquidatable below 1.0)
  utilization       0.100000  | borrow APR 0.005000
  == 4. ONE YEAR PASSES (feeds re-published at the same prices)
  bob's debt        10050.000000 USDC  (interest accrued)
  alice's balance   100049.999999 USDC  (she earned it)
  health factor     1.592039
  == 5. ETH CRASHES from $2,000 to $1,200 (mock oracle updated)
  health factor     0.955223  <- below 1.0: liquidatable
  == 6. CAROL liquidates Bob (close factor 50%, bonus 5%)
  carol repaid      5025.000000 USDC of Bob's debt
  carol received    4.396875 WETH
    worth           $5276.250000 at $1,200/ETH (5% more than she paid)
  bob's debt left   5025.000000 USDC
  bob's collateral  5.603125 WETH
  health factor     1.070447  <- healthy again
  == 7. ETH CRASHES AGAIN to $300: Bob's collateral can no longer cover his debt
  health factor     0.267611
  position          collateral worth $1680.937500 vs debt 5025.000000 USDC
  == 8. CAROL liquidates again -> all collateral seized, the rest is BAD DEBT
  carol repaid      1600.892858 USDC
  carol received    5.603125 WETH  (everything Bob had left)
  BAD DEBT recorded 3424.107143 USDC, socialized to suppliers
  bob's debt now    0.000000 USDC  (written off)
  == 9. SUMMARY
  alice supplied    100000.000000 USDC
  alice can redeem  96625.892857 USDC
  note              the shortfall is the bad debt; a production system would let an insurance
                    fund absorb it first. In v1 the suppliers bear it (see docs/THREAT_MODEL.md).
```

How to read it: Bob borrows 10,000 USDC against 10 WETH (health factor 1.6). A year of interest adds 50 USDC
(a 0.5% APR at 10% utilization). When ETH falls to $1,200 his health factor is 0.955 and Carol repays half his
debt for 5% more collateral than she paid. When ETH falls to $300 the remaining collateral (about $1,681) no
longer covers the remaining debt (5,025 USDC): the last liquidation seizes everything and the rest, 3,424.107143
USDC, is recorded as bad debt and borne by the suppliers, because v1 has no insurance fund
(see [`THREAT_MODEL.md`](THREAT_MODEL.md)).

To see it as real transactions on a local node, use the Anvil variant in the README.
