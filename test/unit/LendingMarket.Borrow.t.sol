// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketBase} from "../utils/MarketBase.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {RAY} from "../../src/libraries/Units.sol";

/// @dev Interest numbers (index, debts, payouts) were computed independently in Python integer
///      arithmetic for: supply 100,000 USDC, borrow 50,000 USDC (50% utilization => 2.5% APR).
contract LendingMarketBorrowTest is MarketBase {
    event Borrow(address indexed borrower, uint256 assets, uint256 scaledDebtAdded);
    event Repay(
        address indexed payer, address indexed borrower, uint256 assets, uint256 scaledDebtBurned
    );
    event InterestAccrued(uint256 interest, uint256 newBorrowIndex, uint256 elapsed);

    /*//////////////////////////////////////////////////////////////
                                 BORROW
    //////////////////////////////////////////////////////////////*/

    function test_borrow_transfersAndRecordsDebt() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        uint256 before = usdc.balanceOf(bob);

        vm.expectEmit(true, false, false, true, address(market));
        emit Borrow(bob, 10_000e6, 10_000e6);
        _borrow(bob, 10_000e6);

        assertEq(usdc.balanceOf(bob), before + 10_000e6);
        assertEq(market.scaledDebt(bob), 10_000e6, "index starts at 1.0 => scaled == assets");
        assertEq(market.totalScaledDebt(), 10_000e6);
        assertEq(market.borrowBalance(bob), 10_000e6);
        assertEq(market.totalBorrowAssets(), 10_000e6);
        assertEq(market.liquidity(), 90_000e6);
        assertEq(market.utilization(), 0.1e18);
        assertEq(market.healthFactor(bob), 1.6e18);
        _assertSolvencyIdentity();
    }

    function test_borrow_revertsOnZero() public {
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.borrow(0);
    }

    function test_borrow_revertsWithoutCollateral() public {
        _supply(alice, 100_000e6);
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
        market.borrow(1);
    }

    function test_borrow_atExactlyMaxLtv() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18); // $20,000 * 75% = $15,000
        _borrow(bob, 15_000e6);
        assertEq(market.borrowBalance(bob), 15_000e6);
        assertEq(market.healthFactor(bob), uint256(20_000e18) * 0.8e18 / 15_000e18);
    }

    function test_borrow_revertsOneMicroDollarOverMaxLtv() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
        market.borrow(15_000e6 + 1);
    }

    function test_borrow_secondBorrowCountsExistingDebt() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        _borrow(bob, 10_000e6);
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
        market.borrow(5000e6 + 1);
        _borrow(bob, 5000e6); // exactly to the limit
        assertEq(market.borrowBalance(bob), 15_000e6);
    }

    function test_borrow_revertsWhenNotEnoughLiquidity() public {
        _supply(alice, 1000e6);
        _depositCollateral(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingMarket.Market__InsufficientLiquidity.selector, 1001e6, 1000e6
            )
        );
        market.borrow(1001e6);
    }

    function test_borrow_usesCollateralPrice() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        _setEthPrice(1000); // $10,000 collateral => limit $7,500
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
        market.borrow(7500e6 + 1);
        _borrow(bob, 7500e6);
    }

    function test_borrow_usesBorrowAssetPrice_depegLowersLimit() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        usdcFeed.setAnswer(1.25e8); // USDC at $1.25: each borrowed USDC counts $1.25
        // limit $15,000 / 1.25 = 12,000 USDC
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
        market.borrow(12_000e6 + 1);
        _borrow(bob, 12_000e6);
    }

    function test_borrow_revertsWhenCollateralOracleStale() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        vm.prank(bob);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.borrow(1000e6);
    }

    function test_borrow_revertsWhenOnlyBorrowAssetOracleStale() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        // Keep ETH fresh, let USDC go stale.
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        ethFeed.setAnswer(2000e8);
        vm.prank(bob);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.borrow(1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                                 REPAY
    //////////////////////////////////////////////////////////////*/

    function test_repay_partial() public {
        _openStandardPosition();

        vm.expectEmit(true, true, false, true, address(market));
        emit Repay(bob, bob, 4000e6, 4000e6);
        vm.prank(bob);
        uint256 repaid = market.repay(4000e6, bob);

        assertEq(repaid, 4000e6);
        assertEq(market.borrowBalance(bob), 6000e6);
        assertEq(market.totalScaledDebt(), 6000e6);
        assertEq(usdc.balanceOf(address(market)), 100_000e6 - 10_000e6 + 4000e6);
        _assertSolvencyIdentity();
    }

    function test_repay_fullWithMaxUint() public {
        _openStandardPosition();
        uint256 balanceBefore = usdc.balanceOf(bob);

        uint256 repaid = _repayAll(bob);

        assertEq(repaid, 10_000e6);
        assertEq(usdc.balanceOf(bob), balanceBefore - 10_000e6);
        assertEq(market.scaledDebt(bob), 0);
        assertEq(market.totalScaledDebt(), 0);
        assertEq(market.healthFactor(bob), type(uint256).max);
    }

    function test_repay_capsAtDebtWhenOverpaying() public {
        _openStandardPosition();
        vm.prank(bob);
        uint256 repaid = market.repay(50_000e6, bob);
        assertEq(repaid, 10_000e6, "never pulls more than the debt");
        assertEq(market.scaledDebt(bob), 0);
    }

    function test_repay_anyoneCanRepayForABorrower() public {
        _openStandardPosition();
        vm.prank(carol);
        market.repay(10_000e6, bob);
        assertEq(market.borrowBalance(bob), 0);
    }

    function test_repay_revertsOnZero() public {
        _openStandardPosition();
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.repay(0, bob);
    }

    function test_repay_revertsWhenNoDebt() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LendingMarket.Market__NoDebt.selector, bob));
        market.repay(1, bob);
    }

    function test_repay_revertsWhenAmountTooSmallToBurnAnyDebt() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        _borrow(bob, 10_000e6);
        _skip(365 days); // index > 1.0 now
        // floor(1 * RAY / index) == 0 => paying 1 wei would burn nothing.
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__RepayTooSmall.selector);
        market.repay(1, bob);
    }

    function test_repay_worksWhenOraclesAreDown() public {
        _openStandardPosition();
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1); // both feeds stale
        uint256 repaid = _repayAll(bob);
        assertGt(repaid, 10_000e6, "interest accrued meanwhile");
        assertEq(market.scaledDebt(bob), 0);
    }

    function test_repay_thenWithdrawAllCollateral() public {
        _openStandardPosition();
        _repayAll(bob);
        vm.prank(bob);
        market.withdrawCollateral(10e18);
        assertEq(weth.balanceOf(bob), 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                           INTEREST ACCRUAL
    //////////////////////////////////////////////////////////////*/

    function _borrow50k() internal {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 100e18);
        _borrow(bob, 50_000e6);
    }

    function test_accrual_oneYearAt50PercentUtilization() public {
        _borrow50k();
        assertEq(market.currentBorrowRate(), 0.025e18, "2.5% APR at 50% utilization");

        _skip(365 days);
        // View is projected: debt already includes interest before any state change.
        assertEq(market.borrowBalance(bob), 51_250e6);

        vm.expectEmit(false, false, false, true, address(market));
        emit InterestAccrued(1250e6, 1_024_999_999_999_999_999_980_832_000, 365 days);
        market.accrueInterest();

        assertEq(market.borrowIndex(), 1_024_999_999_999_999_999_980_832_000);
        assertEq(market.totalBorrowAssets(), 51_250e6);
        assertEq(market.totalSupplyAssets(), 101_250e6);
        assertEq(market.lastAccrual(), vm.getBlockTimestamp());
        _assertSolvencyIdentity();
    }

    function test_accrual_fullLifecycleSupplyBorrowAccrueRepayWithdraw() public {
        _borrow50k();
        _skip(365 days);

        // Bob repays everything: principal + 1,250 USDC interest.
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 repaid = _repayAll(bob);
        assertEq(repaid, 51_250e6);
        assertEq(bobBefore - usdc.balanceOf(bob), 51_250e6);

        // Bob gets his collateral back.
        vm.prank(bob);
        market.withdrawCollateral(100e18);
        assertEq(market.collateralOf(bob), 0);

        // Alice redeems everything: 100,000 + 1,250 interest, minus 1 wei of rounding dust.
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 aliceShares = market.supplyShares(alice);
        vm.prank(alice);
        uint256 out = market.redeem(aliceShares);
        assertEq(out, 101_249_999_999);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 101_249_999_999);

        // Nothing is left that is owed to anyone except 1 wei of dust in the contract.
        assertEq(market.totalScaledDebt(), 0);
        assertEq(usdc.balanceOf(address(market)), 1);
        assertEq(market.totalCollateral(), 0);
    }

    function test_accrual_compoundsAcrossAccruals() public {
        _borrow50k();
        _skip(100 days);
        market.accrueInterest();
        _skip(100 days);
        market.accrueInterest();

        // Two 100-day steps (independently computed): index and debt slightly above a single
        // 200-day linear step, because the second step earns interest on the first.
        assertEq(market.borrowIndex(), 1_013_769_079_868_900_432_720_487_744);
        assertEq(market.totalBorrowAssets(), 50_688_453_994);
        assertEq(market.totalSupplyAssets(), 100_688_453_994);
    }

    function test_accrual_sameBlockIsNoOp() public {
        _borrow50k();
        uint256 indexBefore = market.borrowIndex();
        market.accrueInterest();
        market.accrueInterest();
        assertEq(market.borrowIndex(), indexBefore);
        assertEq(market.totalSupplyAssets(), 100_000e6);
    }

    function test_accrual_noBorrowsNoInterest() public {
        _supply(alice, 100_000e6);
        _skip(365 days);
        market.accrueInterest();
        assertEq(market.totalSupplyAssets(), 100_000e6);
        assertEq(market.supplyBalance(alice), 100_000e6);
    }

    function test_accrual_isTriggeredByEveryAction() public {
        _borrow50k();
        _skip(30 days);
        uint256 before = market.lastAccrual();
        _supply(dave, 1e6); // any state-changing call accrues
        assertGt(market.lastAccrual(), before);
    }

    function test_accrual_rateRisesWithUtilization() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 100e18);
        _borrow(bob, 10_000e6);
        uint256 low = market.currentBorrowRate();
        _borrow(bob, 60_000e6);
        uint256 mid = market.currentBorrowRate();
        _borrow(bob, 15_000e6); // 85% utilization: past the 80% kink
        uint256 high = market.currentBorrowRate();

        assertEq(low, 0.005e18);
        assertEq(mid, 0.035e18);
        assertGt(high, 0.04e18);
        assertEq(high, 0.04e18 + (0.75e18 * 0.05e18) / 0.2e18);
    }

    function test_accrual_twoBorrowersEachAccrueFromTheirOwnEntry() public {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 100e18);
        _depositCollateral(dave, 100e18);
        _borrow(bob, 20_000e6);
        _skip(180 days);
        _borrow(dave, 20_000e6); // dave joins half a year later at the higher index

        uint256 bobDebt = market.borrowBalance(bob);
        uint256 daveDebt = market.borrowBalance(dave);
        assertGt(bobDebt, 20_000e6, "bob accrued for 180 days");
        // Borrow rounds scaled debt UP, so right after borrowing the debt is `a` or `a + 1` wei.
        assertApproxEqAbs(daveDebt, 20_000e6, 1, "dave has accrued nothing yet");

        _skip(180 days);
        // Same time elapsed for both from here on => both grew, bob more in absolute terms.
        assertGt(market.borrowBalance(dave), 20_000e6);
        assertGt(market.borrowBalance(bob) - bobDebt, market.borrowBalance(dave) - daveDebt);
    }

    function test_accrual_sumOfUserDebtsWithinNMinusOneOfTotal() public {
        _supply(alice, 500_000e6);
        _depositCollateral(bob, 100e18);
        _depositCollateral(dave, 100e18);
        _depositCollateral(carol, 100e18);
        _borrow(bob, 12_345_678);
        _skip(33 days);
        _borrow(dave, 87_654_321);
        _skip(77 days);
        _borrow(carol, 1_000_001);
        _skip(5 days);
        market.accrueInterest();

        uint256 sum =
            market.borrowBalance(bob) + market.borrowBalance(dave) + market.borrowBalance(carol);
        uint256 total = market.totalBorrowAssets();
        assertGe(sum, total);
        assertLe(sum - total, 2, "N - 1 = 2 wei tolerance for 3 borrowers");
    }

    function test_view_supplyAndBorrowBalancesAreProjectedWithoutStateChange() public {
        _borrow50k();
        uint256 supplyStored = market.totalSupplyAssets();
        _skip(365 days);
        assertEq(market.totalSupplyAssets(), supplyStored, "storage not touched by views");
        assertEq(market.borrowBalance(bob), 51_250e6);
        assertEq(market.supplyBalance(alice), 101_249_999_999);
        assertEq(market.borrowIndex(), RAY);
    }
}
