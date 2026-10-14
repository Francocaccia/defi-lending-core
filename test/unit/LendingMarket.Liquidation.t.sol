// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketBase} from "../utils/MarketBase.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";

/// @dev Standard position: alice supplies 100,000 USDC; bob has 10 WETH and owes 10,000 USDC.
///      Expected values are hand-computed in the comments next to each assertion.
contract LendingMarketLiquidationTest is MarketBase {
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event BadDebtRecorded(address indexed borrower, uint256 debtWrittenOff, uint256 supplierLoss);

    function setUp() public override {
        super.setUp();
        _openStandardPosition();
    }

    function _liquidate(uint256 maxRepay) internal returns (uint256 repaid, uint256 seized) {
        vm.prank(carol);
        return market.liquidate(bob, maxRepay);
    }

    /*//////////////////////////////////////////////////////////////
                            ELIGIBILITY
    //////////////////////////////////////////////////////////////*/

    function test_healthFactor_reflectsPriceMoves() public {
        assertEq(market.healthFactor(bob), 1.6e18);
        _setEthPrice(1200); // 12,000 * 0.8 / 10,000
        assertEq(market.healthFactor(bob), 0.96e18);
        assertEq(market.healthFactor(alice), type(uint256).max, "no debt => max");
    }

    function test_liquidate_revertsOnHealthyPosition() public {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(LendingMarket.Market__PositionHealthy.selector, 1.6e18)
        );
        market.liquidate(bob, type(uint256).max);
    }

    function test_liquidate_revertsAtExactlyHealthFactorOne() public {
        // 10 ETH * $1,250 * 0.8 = $10,000 = debt  =>  HF == 1.0 exactly: NOT liquidatable.
        _setEthPrice(1250);
        assertEq(market.healthFactor(bob), 1e18);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(LendingMarket.Market__PositionHealthy.selector, 1e18)
        );
        market.liquidate(bob, type(uint256).max);
    }

    function test_liquidate_worksOneDollarBelowHealthFactorOne() public {
        _setEthPrice(1249);
        assertLt(market.healthFactor(bob), 1e18);
        (uint256 repaid,) = _liquidate(type(uint256).max);
        assertEq(repaid, 5000e6);
    }

    function test_liquidate_revertsOnZeroMaxRepay() public {
        _setEthPrice(1200);
        vm.prank(carol);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.liquidate(bob, 0);
    }

    function test_liquidate_revertsWhenBorrowerHasNoDebt() public {
        _setEthPrice(1200);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(LendingMarket.Market__NoDebt.selector, dave));
        market.liquidate(dave, 1e6);
    }

    function test_liquidate_becomesPossibleWhenBorrowAssetAppreciates() public {
        // USDC at $1.70: debt is worth $17,000 vs $20,000 * 0.8 = $16,000  =>  HF 0.941
        usdcFeed.setAnswer(1.7e8);
        assertLt(market.healthFactor(bob), 1e18);
        (uint256 repaid, uint256 seized) = _liquidate(type(uint256).max);
        assertEq(repaid, 5000e6);
        // 5,000 USDC = $8,500; + 5% = $8,925; / $2,000 = 4.4625 ETH
        assertEq(seized, 4.4625e18);
    }

    function test_liquidate_becomesImpossibleAgainAfterPriceRecovers() public {
        _setEthPrice(1200);
        assertLt(market.healthFactor(bob), 1e18);
        _setEthPrice(2000);
        vm.prank(carol);
        vm.expectPartialRevert(LendingMarket.Market__PositionHealthy.selector);
        market.liquidate(bob, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              AMOUNTS
    //////////////////////////////////////////////////////////////*/

    function test_liquidate_ethCrash_closeFactorAndBonus() public {
        _setEthPrice(1200);
        uint256 carolUsdc = usdc.balanceOf(carol);
        uint256 carolWeth = weth.balanceOf(carol);

        vm.expectEmit(true, true, false, true, address(market));
        emit Liquidate(carol, bob, 5000e6, 4.375e18);
        (uint256 repaid, uint256 seized) = _liquidate(type(uint256).max);

        // close factor 50% of 10,000 = 5,000 USDC; value $5,000 * 1.05 / $1,200 = 4.375 ETH.
        assertEq(repaid, 5000e6);
        assertEq(seized, 4.375e18);

        assertEq(carolUsdc - usdc.balanceOf(carol), 5000e6);
        assertEq(weth.balanceOf(carol) - carolWeth, 4.375e18);

        assertEq(market.borrowBalance(bob), 5000e6);
        assertEq(market.collateralOf(bob), 5.625e18);
        assertEq(market.totalCollateral(), 5.625e18);
        assertEq(market.totalBadDebt(), 0);
        // Remaining: $6,750 * 0.8 / $5,000 = 1.08
        assertEq(market.healthFactor(bob), 1.08e18);
        _assertSolvencyIdentity();
    }

    function test_liquidate_liquidatorGainsTheBonusInValue() public {
        _setEthPrice(1200);
        (uint256 repaid, uint256 seized) = _liquidate(type(uint256).max);
        // value received = 4.375 * 1200 = $5,250; paid $5,000  =>  exactly 5% more.
        assertEq(seized * 1200 / 1e18, 5250);
        assertEq(repaid / 1e6, 5000);
    }

    function test_liquidate_partialRepayRequest() public {
        _setEthPrice(1200);
        (uint256 repaid, uint256 seized) = _liquidate(1000e6);
        assertEq(repaid, 1000e6);
        assertEq(seized, 0.875e18); // 1,000 * 1.05 / 1,200
        assertEq(market.borrowBalance(bob), 9000e6);
    }

    function test_liquidate_requestAboveCloseFactorIsCapped() public {
        _setEthPrice(1200);
        (uint256 repaid,) = _liquidate(9000e6);
        assertEq(repaid, 5000e6, "cannot repay more than the 50% close factor");
    }

    function test_liquidate_repeatedLiquidationsWorkDownTheDebt() public {
        _setEthPrice(1000); // coll $10,000*0.8 = 8,000 < 10,000
        (uint256 r1, uint256 s1) = _liquidate(type(uint256).max);
        assertEq(r1, 5000e6);
        assertEq(s1, 5.25e18); // 5,000 * 1.05 / 1,000

        // After: debt 5,000, coll 4.75 ETH = $4,750 * 0.8 = 3,800 < 5,000  => still liquidatable
        assertLt(market.healthFactor(bob), 1e18);
        (uint256 r2, uint256 s2) = _liquidate(type(uint256).max);
        assertEq(r2, 2500e6);
        assertEq(s2, 2.625e18);

        // After: debt 2,500, coll 2.125 ETH = $2,125 * 0.8 = 1,700 < 2,500 => still
        assertLt(market.healthFactor(bob), 1e18);
        assertEq(market.totalBadDebt(), 0);
        _assertSolvencyIdentity();
    }

    function test_liquidate_includesInterestAccruedInDebt() public {
        _skip(365 days);
        _setEthPrice(1200);
        uint256 debtBefore = market.borrowBalance(bob);
        assertGt(debtBefore, 10_000e6);

        (uint256 repaid, uint256 seized) = _liquidate(type(uint256).max);
        // Repaid is ceil(50%) of the INTEREST-INCLUSIVE debt.
        assertApproxEqAbs(repaid, debtBefore / 2, 1);
        // The seized amount follows the (separately tested) liquidation formula for THAT repayment.
        assertEq(seized, RiskMath.seizeForRepay(repaid, 1e18, 6, 1200e18, 18, 0.05e18));
    }

    function test_liquidate_dustDebtIsFullyLiquidatable() public {
        // Tiny position: 1e9 wei WETH of collateral, 1 micro-USDC of debt.
        _depositCollateral(dave, 1e9);
        _borrow(dave, 1);
        _setEthPrice(1000);
        assertLt(market.healthFactor(dave), 1e18);

        vm.prank(carol);
        (uint256 repaid, uint256 seized) = market.liquidate(dave, type(uint256).max);
        assertEq(repaid, 1, "ceil(50% of 1 wei) = 1");
        assertEq(seized, 1e9, "seizure capped at the collateral held");
        assertEq(market.borrowBalance(dave), 0);
        assertEq(market.collateralOf(dave), 0);
        assertEq(market.totalBadDebt(), 0, "fully repaid: no bad debt");
    }

    /*//////////////////////////////////////////////////////////////
                              BAD DEBT
    //////////////////////////////////////////////////////////////*/

    function test_badDebt_recordedWhenCollateralCannotCoverRepayment() public {
        _setEthPrice(500); // 10 ETH = $5,000 vs $10,000 debt
        uint256 supplyBefore = market.totalSupplyAssets();

        // Liquidator would owe 5,000 USDC of debt => 5,000 * 1.05 / 500 = 10.5 ETH > 10 held.
        // So all 10 ETH are seized and the liquidator is charged only ceil(10 * 500 / 1.05).
        vm.expectEmit(true, false, false, true, address(market));
        emit BadDebtRecorded(bob, 5_238_095_238, 5_238_095_238);
        (uint256 repaid, uint256 seized) = _liquidate(type(uint256).max);

        assertEq(seized, 10e18);
        assertEq(repaid, 4_761_904_762);

        // 10,000 - 4,761.904762 = 5,238.095238 USDC is written off and socialized.
        assertEq(market.totalBadDebt(), 5_238_095_238);
        assertEq(market.totalSupplyAssets(), supplyBefore - 5_238_095_238);
        assertEq(market.scaledDebt(bob), 0);
        assertEq(market.collateralOf(bob), 0);
        assertEq(market.totalScaledDebt(), 0);
        assertEq(market.totalBorrowAssets(), 0);

        // Accounting still balances: remaining supply claims are exactly the cash left.
        assertEq(market.totalSupplyAssets(), usdc.balanceOf(address(market)));
        _assertSolvencyIdentity();
    }

    function test_badDebt_socializedLossLowersSupplierBalances() public {
        _setEthPrice(500);
        _liquidate(type(uint256).max);

        uint256 aliceValue = market.supplyBalance(alice);
        assertLt(aliceValue, 100_000e6, "suppliers absorb the loss");
        assertApproxEqAbs(aliceValue, 94_761_904_762, 1);

        // Alice can still exit with everything that is left.
        uint256 aliceShares = market.supplyShares(alice);
        vm.prank(alice);
        uint256 out = market.redeem(aliceShares);
        assertApproxEqAbs(out, 94_761_904_762, 1);
    }

    function test_badDebt_lossIsSharedProRata() public {
        // Add dave as a second supplier with 1/4 of alice's shares BEFORE the loss.
        _supply(dave, 25_000e6);
        _setEthPrice(500);
        _liquidate(type(uint256).max);

        uint256 a = market.supplyBalance(alice);
        uint256 d = market.supplyBalance(dave);
        uint256 lossA = 100_000e6 - a;
        uint256 lossD = 25_000e6 - d;
        assertApproxEqAbs(lossA, 4 * lossD, 4);
    }

    function test_badDebt_notRecordedWhenCollateralStillCoversRepayment() public {
        _setEthPrice(1000); // coll $10,000 vs debt $10,000: underwater after fees but liquidatable
        _liquidate(type(uint256).max);
        assertEq(market.totalBadDebt(), 0);
        assertGt(market.collateralOf(bob), 0);
    }

    function test_badDebt_followUpLiquidationOfWrittenOffAccountReverts() public {
        _setEthPrice(500);
        _liquidate(type(uint256).max);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(LendingMarket.Market__NoDebt.selector, bob));
        market.liquidate(bob, type(uint256).max);
    }

    function test_badDebt_marketKeepsWorkingAfterwards() public {
        _setEthPrice(500);
        _liquidate(type(uint256).max);

        // New supplier and borrower are priced from the reduced share price.
        uint256 shares = _supply(dave, 10_000e6);
        assertGt(shares, 0);
        _depositCollateral(dave, 10e18); // $5,000 at the crashed price
        _borrow(dave, 3000e6); // 3,000 <= 5,000 * 0.75
        assertEq(market.borrowBalance(dave), 3000e6);
        _assertSolvencyIdentity();
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE FAILURES
    //////////////////////////////////////////////////////////////*/

    function test_liquidate_revertsWhenCollateralOracleStale() public {
        _setEthPrice(1200);
        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        vm.prank(carol);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.liquidate(bob, type(uint256).max);
    }

    function test_liquidate_revertsWhenCollateralPriceIsZero() public {
        ethFeed.setAnswer(0);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, int256(0))
        );
        market.liquidate(bob, type(uint256).max);
    }

    function test_liquidate_revertsWhenBorrowAssetPriceIsNegative() public {
        _setEthPrice(1200);
        usdcFeed.setAnswer(-1);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, int256(-1))
        );
        market.liquidate(bob, type(uint256).max);
    }

    function test_healthFactorView_revertsWhenOracleBroken() public {
        ethFeed.setShouldRevert(true);
        vm.expectRevert(ChainlinkOracle.Oracle__FeedCallFailed.selector);
        market.healthFactor(bob);
    }
}
