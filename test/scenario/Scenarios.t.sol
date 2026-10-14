// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketBase} from "../utils/MarketBase.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";

/// @notice End-to-end stories. Each test reads as a narrative; assertions pin the economics.
contract ScenariosTest is MarketBase {
    function setUp() public override {
        super.setUp();
        _openStandardPosition(); // alice 100k supplied; bob 10 WETH, 10,000 USDC debt
    }

    /*//////////////////////////////////////////////////////////////
                    ETH CRASH -> LIQUIDATION (happy path)
    //////////////////////////////////////////////////////////////*/

    function test_scenario_ethCrashThenLiquidationRestoresHealth() public {
        // 1. A year passes with a calm market.
        _skip(365 days);
        uint256 debt = market.borrowBalance(bob);
        assertGt(debt, 10_000e6);

        // 2. ETH falls 40%: $2,000 -> $1,200. Bob's HF drops below 1.
        _setEthPrice(1200);
        assertLt(market.healthFactor(bob), 1e18);

        // 3. A liquidator (carol) repays the maximum allowed.
        vm.prank(carol);
        (uint256 repaid, uint256 seized) = market.liquidate(bob, type(uint256).max);

        // 4. The position is healthy again, suppliers lost nothing.
        assertGe(market.healthFactor(bob), 1e18, "one 50% liquidation was enough");
        assertEq(market.totalBadDebt(), 0);
        assertGe(market.supplyBalance(alice), 100_000e6, "alice made whole plus interest");
        assertGt(seized, 0);
        assertApproxEqAbs(repaid, debt / 2, 1);
        _assertSolvencyIdentity();
    }

    function test_scenario_borrowerCanSaveThemselvesByRepayingBeforeLiquidation() public {
        _setEthPrice(1200);
        assertLt(market.healthFactor(bob), 1e18);

        // Bob repays 3,000 USDC and is healthy again: 12,000*0.8 / 7,000 = 1.371
        vm.prank(bob);
        market.repay(3000e6, bob);
        assertGt(market.healthFactor(bob), 1e18);

        vm.prank(carol);
        vm.expectPartialRevert(LendingMarket.Market__PositionHealthy.selector);
        market.liquidate(bob, type(uint256).max);
    }

    function test_scenario_borrowerCanSaveThemselvesByAddingCollateral() public {
        _setEthPrice(1200);
        _depositCollateral(bob, 5e18); // 15 ETH * 1200 * 0.8 / 10,000 = 1.44
        assertEq(market.healthFactor(bob), 1.44e18);
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDATION CASCADE
    //////////////////////////////////////////////////////////////*/

    function test_scenario_cascade_tightPositionsGoBadFirstSuppliersAbsorbOnlyTheShortfall()
        public
    {
        // Dave runs a much riskier position than bob: 10 WETH, 14,500 USDC (97% of max LTV).
        _depositCollateral(dave, 10e18);
        _borrow(dave, 14_500e6);

        // ETH crashes to $700: bob: 7,000*0.8/10,000 = 0.56 ; dave: 7,000*0.8/14,500 = 0.386
        _setEthPrice(700);

        // Liquidate bob first: repay 5,000 => 5,000*1.05/700 = 7.5 ETH out of 10: no bad debt.
        vm.prank(carol);
        (uint256 rb, uint256 sb) = market.liquidate(bob, type(uint256).max);
        assertEq(rb, 5000e6);
        assertEq(sb, 7.5e18);
        assertEq(market.totalBadDebt(), 0);

        // Dave: 50% of 14,500 = 7,250 => 7,250*1.05/700 = 10.875 ETH > 10 held => bad debt.
        vm.prank(carol);
        (uint256 rd, uint256 sd) = market.liquidate(dave, type(uint256).max);
        assertEq(sd, 10e18, "all of dave's collateral is seized");
        assertLt(rd, 7250e6, "liquidator is charged only for what it receives");
        assertGt(market.totalBadDebt(), 0);

        // The loss equals dave's unpaid remainder; bob's position was untouched by it.
        assertEq(market.totalBadDebt(), 14_500e6 - rd);
        assertGt(market.borrowBalance(bob), 0);
        assertEq(market.borrowBalance(dave), 0);
        _assertSolvencyIdentity();
    }

    function test_scenario_liquidatorProfitIsBonusMinusNothingElse() public {
        _setEthPrice(1200);
        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 wethBefore = weth.balanceOf(carol);
        vm.prank(carol);
        market.liquidate(bob, type(uint256).max);

        uint256 paidUsd = usdcBefore - usdc.balanceOf(carol); // 6 decimals, $1 each
        uint256 gotUsd = (weth.balanceOf(carol) - wethBefore) * 1200 / 1e18; // whole dollars
        assertEq(paidUsd / 1e6, 5000);
        assertEq(gotUsd, 5250);
    }

    /*//////////////////////////////////////////////////////////////
                           ORACLE FAILURES
    //////////////////////////////////////////////////////////////*/

    /// A dead oracle must freeze exactly the actions that need a price, and nothing else.
    function test_scenario_staleOracle_freezesPriceDependentActionsOnly() public {
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1); // both feeds stale

        // --- blocked: anything that extends credit or releases collateral against a price
        vm.prank(bob);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.borrow(1e6);

        vm.prank(bob);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.withdrawCollateral(1e18);

        vm.prank(carol);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.liquidate(bob, type(uint256).max);

        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.healthFactor(bob);

        // --- still allowed: moving money in, repaying, supplier exits, accrual
        _supply(dave, 1000e6);
        _depositCollateral(dave, 1e18);
        market.accrueInterest();
        vm.prank(bob);
        market.repay(1000e6, bob);
        vm.prank(alice);
        market.withdraw(1000e6);

        // --- and a debt-free user can always take their collateral out
        vm.prank(dave);
        market.withdrawCollateral(1e18);
    }

    function test_scenario_staleOracle_recoversWhenFeedUpdates() public {
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        vm.prank(bob);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.borrow(1e6);

        ethFeed.setAnswer(2000e8);
        usdcFeed.setAnswer(1e8);
        _borrow(bob, 1e6); // works again
        // 10,000 + 1 borrowed, plus ~7 days of interest at ~0.5% APR (< 1 USDC).
        assertGt(market.borrowBalance(bob), 10_001e6);
        assertLt(market.borrowBalance(bob), 10_002e6);
    }

    function test_scenario_zeroPriceFreezesExtensionsOfCredit() public {
        ethFeed.setAnswer(0);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, int256(0))
        );
        market.borrow(1e6);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, int256(0))
        );
        market.liquidate(bob, type(uint256).max);

        // Repayment is still possible (no oracle on that path).
        vm.prank(bob);
        market.repay(1e6, bob);
    }

    function test_scenario_negativePriceFreezesExtensionsOfCredit() public {
        usdcFeed.setAnswer(-5);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, int256(-5))
        );
        market.withdrawCollateral(1e18);
    }

    function test_scenario_brokenFeedFreezesExtensionsOfCredit() public {
        ethFeed.setShouldRevert(true);
        vm.prank(bob);
        vm.expectRevert(ChainlinkOracle.Oracle__FeedCallFailed.selector);
        market.borrow(1e6);
    }

    function test_scenario_incompleteRoundFreezesExtensionsOfCredit() public {
        ethFeed.setRoundData(77, 2000e8, block.timestamp, 0, 77);
        vm.prank(bob);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__IncompleteRound.selector);
        market.borrow(1e6);
    }

    /*//////////////////////////////////////////////////////////////
                              BANK RUN
    //////////////////////////////////////////////////////////////*/

    function test_scenario_highUtilizationBlocksWithdrawalsUntilRepayment() public {
        // Bob borrows nearly everything: 100,000 supplied; he already owes 10,000.
        _depositCollateral(bob, 60e18); // 70 ETH = $140k of collateral => $105k borrow limit
        _borrow(bob, 85_000e6); // 95,000 / 100,000 utilization
        assertEq(market.liquidity(), 5000e6);

        // Alice cannot get her 100,000 out.
        vm.prank(alice);
        vm.expectPartialRevert(LendingMarket.Market__InsufficientLiquidity.selector);
        market.withdraw(100_000e6);

        // The steep slope2 makes borrowing expensive, pulling bob to repay.
        assertGt(market.currentBorrowRate(), 0.04e18);

        // Once bob repays, alice exits fully.
        _repayAll(bob);
        uint256 aliceShares = market.supplyShares(alice);
        vm.prank(alice);
        uint256 out = market.redeem(aliceShares);
        assertGe(out, 100_000e6 - 1);
    }

    /*//////////////////////////////////////////////////////////////
                           FULL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_scenario_fullLifecycleEveryoneExitsSolvent() public {
        _supply(dave, 50_000e6);
        _skip(200 days);
        _depositCollateral(dave, 30e18);
        _borrow(dave, 20_000e6);
        _skip(150 days);

        // Everyone unwinds.
        _repayAll(bob);
        _repayAll(dave);
        vm.prank(bob);
        market.withdrawCollateral(10e18);
        vm.prank(dave);
        market.withdrawCollateral(30e18);

        uint256 aliceShares = market.supplyShares(alice);
        uint256 daveShares = market.supplyShares(dave);
        vm.prank(alice);
        uint256 aliceOut = market.redeem(aliceShares);
        vm.prank(dave);
        uint256 daveOut = market.redeem(daveShares);

        assertGe(aliceOut, 100_000e6, "alice never loses principal absent bad debt");
        assertGe(daveOut, 50_000e6 - 1, "dave (supplier side) never loses principal");
        assertEq(market.totalScaledDebt(), 0);
        assertEq(market.totalCollateral(), 0);
        assertEq(weth.balanceOf(address(market)), 0);
        // Only rounding dust may remain in the market.
        assertLe(usdc.balanceOf(address(market)), 3);
    }
}
