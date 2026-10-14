// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketBase} from "../utils/MarketBase.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";

contract LendingMarketCollateralTest is MarketBase {
    event CollateralDeposited(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);

    function test_deposit_recordsAndPullsTokens() public {
        uint256 before = weth.balanceOf(bob);

        vm.expectEmit(true, false, false, true, address(market));
        emit CollateralDeposited(bob, 10e18);
        _depositCollateral(bob, 10e18);

        assertEq(market.collateralOf(bob), 10e18);
        assertEq(market.totalCollateral(), 10e18);
        assertEq(weth.balanceOf(address(market)), 10e18);
        assertEq(weth.balanceOf(bob), before - 10e18);
    }

    function test_deposit_accumulates() public {
        _depositCollateral(bob, 1e18);
        _depositCollateral(bob, 2e18);
        assertEq(market.collateralOf(bob), 3e18);
    }

    function test_deposit_revertsOnZero() public {
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.depositCollateral(0);
    }

    function test_deposit_worksEvenWhenOracleIsDown() public {
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1); // both feeds now stale
        _depositCollateral(bob, 1e18);
        assertEq(market.collateralOf(bob), 1e18);
    }

    function test_withdraw_noDebtReturnsEverything() public {
        _depositCollateral(bob, 10e18);

        vm.expectEmit(true, false, false, true, address(market));
        emit CollateralWithdrawn(bob, 10e18);
        vm.prank(bob);
        market.withdrawCollateral(10e18);

        assertEq(market.collateralOf(bob), 0);
        assertEq(market.totalCollateral(), 0);
        assertEq(weth.balanceOf(bob), 1000e18);
    }

    function test_withdraw_revertsOnZero() public {
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.withdrawCollateral(0);
    }

    function test_withdraw_revertsWhenMoreThanDeposited() public {
        _depositCollateral(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingMarket.Market__InsufficientCollateral.selector, 2e18, 1e18
            )
        );
        market.withdrawCollateral(2e18);
    }

    function test_withdraw_cannotTouchOthersCollateral() public {
        _depositCollateral(bob, 1e18);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(LendingMarket.Market__InsufficientCollateral.selector, 1e18, 0)
        );
        market.withdrawCollateral(1e18);
    }

    function test_withdraw_withDebt_allowedDownToMaxLtv() public {
        _openStandardPosition(); // 10 WETH, 10,000 USDC debt
        // Debt $10,000 needs collateral >= 10,000 / 0.75 = $13,333.34 => 6.66666667 ETH at $2,000.
        // Withdrawing 3 ETH leaves 7 ETH ($14,000): fine.
        vm.prank(bob);
        market.withdrawCollateral(3e18);
        assertEq(market.collateralOf(bob), 7e18);
    }

    function test_withdraw_withDebt_revertsBeyondMaxLtv() public {
        _openStandardPosition();
        // Leaving 6 ETH ($12,000): 10,000 > 12,000 * 0.75 = 9,000 -> reverts.
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
        market.withdrawCollateral(4e18);
        // State unchanged after the revert.
        assertEq(market.collateralOf(bob), 10e18);
    }

    function test_withdraw_withDebt_exactBoundary() public {
        _depositCollateral(bob, 10e18);
        _supply(alice, 100_000e6);
        _borrow(bob, 7500e6); // 7,500 = 10,000 * 0.75 for 5 ETH
        // 5 ETH ($10,000 value) supports exactly $7,500 of debt.
        vm.prank(bob);
        market.withdrawCollateral(5e18);
        // One more wei of collateral removed breaks the limit.
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
        market.withdrawCollateral(1);
    }

    function test_withdraw_withDebt_revertsWhenEthPriceDropped() public {
        _openStandardPosition();
        _setEthPrice(1500); // 10 ETH = $15,000; limit = $11,250; debt $10,000 ok
        vm.prank(bob);
        market.withdrawCollateral(1e18); // 9 ETH = $13,500 -> limit $10,125 ok
        vm.prank(bob);
        vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
        market.withdrawCollateral(1e18); // 8 ETH = $12,000 -> limit $9,000 < $10,000
    }

    function test_withdraw_withDebt_revertsWhenOracleStale() public {
        _openStandardPosition();
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        vm.prank(bob);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.withdrawCollateral(1e18);
    }

    function test_withdraw_noDebt_worksEvenWhenOracleIsDown() public {
        _depositCollateral(bob, 5e18);
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        vm.prank(bob);
        market.withdrawCollateral(5e18); // no debt => no oracle needed => can always exit
        assertEq(market.collateralOf(bob), 0);
    }

    function test_withdraw_afterFullRepayReleasesAll() public {
        _openStandardPosition();
        _repayAll(bob);
        vm.prank(bob);
        market.withdrawCollateral(10e18);
        assertEq(market.collateralOf(bob), 0);
    }
}
