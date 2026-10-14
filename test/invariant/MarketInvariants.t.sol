// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {MarketBase} from "../utils/MarketBase.sol";
import {MarketHandler} from "./MarketHandler.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {WAD} from "../../src/libraries/Units.sol";

/// @notice Stateful fuzzing of the whole market. After every random action sequence the
///         following must hold (see docs/DESIGN.md for the formal statements):
///
///   (a) Solvency            : supplier claims <= cash + borrows; exact token conservation.
///   (b) Debt accounting     : sum(user debts) - totalBorrowAssets in [0, N-1] wei.
///   (c) Collateral safety   : every SUCCESSFUL collateral withdrawal left the position within
///                             max LTV (ghost counter == 0); nobody holds debt without collateral.
///   (d) Share price         : never decreases except through recorded bad debt (ghost == 0).
///   plus bookkeeping identities (sums of per-user balances equal the totals), index monotonicity
///   and donation immunity.
contract MarketInvariants is MarketBase {
    uint256 internal constant NUM_ACTORS = 5;

    MarketHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new MarketHandler(
            market,
            weth,
            usdc,
            ethFeed,
            usdcFeed,
            IOracle(address(ethOracle)),
            IOracle(address(usdcOracle)),
            NUM_ACTORS
        );

        handler.seedMarket(200_000e6, 20e18); // 5 x (200k USDC supplied, 20 WETH posted)

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = MarketHandler.supply.selector;
        selectors[1] = MarketHandler.withdraw.selector;
        selectors[2] = MarketHandler.redeem.selector;
        selectors[3] = MarketHandler.donate.selector;
        selectors[4] = MarketHandler.depositCollateral.selector;
        selectors[5] = MarketHandler.withdrawCollateral.selector;
        selectors[6] = MarketHandler.borrow.selector;
        selectors[7] = MarketHandler.repay.selector;
        selectors[8] = MarketHandler.liquidate.selector;
        selectors[9] = MarketHandler.setEthPrice.selector;
        selectors[10] = MarketHandler.warp.selector;
        selectors[11] = MarketHandler.setUsdcPrice.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                              (a) SOLVENCY
    //////////////////////////////////////////////////////////////*/

    /// Every supplier's claim, summed, is covered by cash plus what borrowers owe.
    function invariant_a_supplierClaimsAreCovered() public view {
        uint256 claims;
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            claims += market.supplyBalance(handler.actors(i));
        }
        assertLe(claims, usdc.balanceOf(address(market)) + market.totalBorrowAssets());
    }

    /// The accounting total is itself covered by cash + borrows (the core identity), even after
    /// bad debt was written off.
    function invariant_a_totalSupplyAssetsCoveredByCashPlusBorrows() public view {
        assertLe(
            market.totalSupplyAssets(), usdc.balanceOf(address(market)) + market.totalBorrowAssets()
        );
    }

    /// Exact conservation: the market's USDC balance is precisely what flowed in minus out, plus
    /// whatever was donated directly. Nothing is created or lost by any action.
    function invariant_a_borrowTokenConservation() public view {
        assertEq(
            usdc.balanceOf(address(market)),
            handler.ghostUsdcIn() - handler.ghostUsdcOut() + handler.ghostUsdcDonated()
        );
    }

    /// Collateral is conserved too: held WETH == recorded collateral + donations.
    function invariant_a_collateralConservation() public view {
        assertEq(
            weth.balanceOf(address(market)), market.totalCollateral() + handler.ghostWethDonated()
        );
    }

    /*//////////////////////////////////////////////////////////////
                         (b) DEBT ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function invariant_b_sumOfUserDebtsMatchesTotalWithinNMinusOne() public view {
        uint256 sum;
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            sum += market.borrowBalance(handler.actors(i));
        }
        uint256 total = market.totalBorrowAssets();
        assertGe(sum, total, "per-user rounding is upward");
        assertLe(sum - total, NUM_ACTORS - 1, "more than N-1 wei apart");
    }

    function invariant_b_scaledDebtSumsMatch() public view {
        uint256 sum;
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            sum += market.scaledDebt(handler.actors(i));
        }
        assertEq(sum, market.totalScaledDebt());
    }

    /*//////////////////////////////////////////////////////////////
                        (c) COLLATERAL SAFETY
    //////////////////////////////////////////////////////////////*/

    function invariant_c_noSuccessfulWithdrawalBrokeMaxLtv() public view {
        assertEq(handler.ghostLtvViolations(), 0);
    }

    /// Nobody keeps debt with zero collateral: that state is bad debt and is written off at once.
    function invariant_c_noDebtWithoutCollateral() public view {
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address a = handler.actors(i);
            if (market.scaledDebt(a) != 0) assertGt(market.collateralOf(a), 0);
        }
    }

    function invariant_c_collateralSumMatches() public view {
        uint256 sum;
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            sum += market.collateralOf(handler.actors(i));
        }
        assertEq(sum, market.totalCollateral());
    }

    /*//////////////////////////////////////////////////////////////
                           (d) SHARE PRICE
    //////////////////////////////////////////////////////////////*/

    function invariant_d_sharePriceOnlyFallsThroughBadDebt() public view {
        assertEq(handler.ghostSharePriceViolations(), 0);
    }

    function invariant_d_shareSumsMatch() public view {
        uint256 sum;
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            sum += market.supplyShares(handler.actors(i));
        }
        assertEq(sum, market.totalSupplyShares());
    }

    /*//////////////////////////////////////////////////////////////
                              EXTRAS
    //////////////////////////////////////////////////////////////*/

    function invariant_borrowIndexNeverDecreases() public view {
        assertEq(handler.ghostIndexViolations(), 0);
        assertGe(market.borrowIndex(), 1e27);
    }

    /// Totals reflect a freshly-accrued state when the invariants run (handler accrues last).
    function invariant_stateIsAccrued() public view {
        assertEq(market.lastAccrual(), vm.getBlockTimestamp());
    }

    /// Aggregates how often the interesting paths were reached ACROSS ALL RUNS (via process env
    /// vars) and prints the running total when INVARIANT_STATS=true (use -vv; the last printed
    /// block is the final total). Proves the campaign is not vacuous.
    function afterInvariant() public {
        if (!vm.envOr("INVARIANT_STATS", false)) return;
        _acc("INV_RUNS", 1);
        _acc("INV_LIQ", handler.nLiquidations());
        _acc("INV_BAD", handler.nBadDebtEvents());
        _acc("INV_BORROW", handler.nBorrows());
        _acc("INV_WD", handler.nCollateralWithdrawals());
        _acc("INV_WD_DEBT", handler.nCollateralWithdrawalsWithDebt());
        _acc("INV_WD_REJ", handler.nWithdrawRejectedByLtv());
        console.log(
            string.concat(
                "runs=",
                vm.toString(vm.envUint("INV_RUNS")),
                " liquidations=",
                vm.toString(vm.envUint("INV_LIQ")),
                " badDebtEvents=",
                vm.toString(vm.envUint("INV_BAD")),
                " borrows=",
                vm.toString(vm.envUint("INV_BORROW")),
                " collateralWithdrawals=",
                vm.toString(vm.envUint("INV_WD")),
                " (withDebt=",
                vm.toString(vm.envUint("INV_WD_DEBT")),
                ", rejectedByLtv=",
                vm.toString(vm.envUint("INV_WD_REJ")),
                ")"
            )
        );
    }

    function _acc(string memory key, uint256 delta) private {
        vm.setEnv(key, vm.toString(vm.envOr(key, uint256(0)) + delta));
    }
}
