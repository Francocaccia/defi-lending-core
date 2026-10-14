// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {WAD} from "../../src/libraries/Units.sol";
import {RiskMathHarness} from "../harness/RiskMathHarness.sol";

contract RiskMathTest is Test {
    RiskMathHarness internal h;

    RiskMath.RiskParams internal good = RiskMath.RiskParams({
        maxLtv: 0.75e18,
        liquidationThreshold: 0.8e18,
        liquidationBonus: 0.05e18,
        closeFactor: 0.5e18
    });

    function setUp() public {
        h = new RiskMathHarness();
    }

    /*//////////////////////////////////////////////////////////////
                               VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_validate_acceptsIllustrativeDefaults() public view {
        h.validate(good);
    }

    function test_validate_revertsOnZeroLtv() public {
        RiskMath.RiskParams memory p = good;
        p.maxLtv = 0;
        vm.expectRevert(
            abi.encodeWithSelector(RiskMath.RiskMath__InvalidLtvOrThreshold.selector, 0, 0.8e18)
        );
        h.validate(p);
    }

    function test_validate_revertsWhenLtvNotBelowThreshold() public {
        RiskMath.RiskParams memory p = good;
        p.maxLtv = 0.8e18; // equal
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskMath.RiskMath__InvalidLtvOrThreshold.selector, 0.8e18, 0.8e18
            )
        );
        h.validate(p);
    }

    function test_validate_revertsWhenThresholdAtOrAboveOne() public {
        RiskMath.RiskParams memory p = good;
        p.liquidationThreshold = WAD;
        vm.expectRevert(
            abi.encodeWithSelector(RiskMath.RiskMath__InvalidLtvOrThreshold.selector, 0.75e18, WAD)
        );
        h.validate(p);
    }

    function test_validate_revertsOnZeroBonus() public {
        RiskMath.RiskParams memory p = good;
        p.liquidationBonus = 0;
        vm.expectRevert(abi.encodeWithSelector(RiskMath.RiskMath__InvalidBonus.selector, 0));
        h.validate(p);
    }

    function test_validate_revertsOnBonusAboveCap() public {
        RiskMath.RiskParams memory p = good;
        p.liquidationBonus = 0.25e18 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RiskMath.RiskMath__InvalidBonus.selector, 0.25e18 + 1)
        );
        h.validate(p);
    }

    function test_validate_revertsWhenThresholdTimesBonusReachesOne() public {
        // LT = 0.9, bonus = 0.12 -> 0.9 * 1.12 = 1.008 >= 1
        RiskMath.RiskParams memory p = good;
        p.maxLtv = 0.85e18;
        p.liquidationThreshold = 0.9e18;
        p.liquidationBonus = 0.12e18;
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskMath.RiskMath__BonusTooHighForThreshold.selector, 0.9e18, 0.12e18
            )
        );
        h.validate(p);
    }

    function test_validate_acceptsThresholdTimesBonusJustBelowOne() public view {
        // LT = 0.95, bonus 0.05 -> 0.9975 < 1: OK.
        RiskMath.RiskParams memory p = good;
        p.maxLtv = 0.9e18;
        p.liquidationThreshold = 0.95e18;
        h.validate(p);
    }

    function test_validate_rejectsThresholdTimesBonusExactlyOne() public {
        // LT * (1 + b) == 1 exactly: LT = 0.8, b = 0.25 -> 1.0 -> must revert (strict <).
        RiskMath.RiskParams memory p = good;
        p.liquidationBonus = 0.25e18;
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskMath.RiskMath__BonusTooHighForThreshold.selector, 0.8e18, 0.25e18
            )
        );
        h.validate(p);
    }

    function test_validate_revertsOnBadCloseFactor() public {
        RiskMath.RiskParams memory p = good;
        p.closeFactor = 0;
        vm.expectRevert(abi.encodeWithSelector(RiskMath.RiskMath__InvalidCloseFactor.selector, 0));
        h.validate(p);

        p.closeFactor = WAD + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RiskMath.RiskMath__InvalidCloseFactor.selector, WAD + 1)
        );
        h.validate(p);
    }

    function test_validate_acceptsCloseFactorOfOne() public view {
        RiskMath.RiskParams memory p = good;
        p.closeFactor = WAD;
        h.validate(p);
    }

    /*//////////////////////////////////////////////////////////////
                               VALUATION
    //////////////////////////////////////////////////////////////*/

    function test_valuation_tenWethAt2000() public pure {
        assertEq(RiskMath.collateralValueUsd(10e18, 2000e18, 18), 20_000e18);
    }

    function test_valuation_tenThousandUsdc() public pure {
        assertEq(RiskMath.debtValueUsd(10_000e6, 1e18, 6), 10_000e18);
    }

    function test_valuation_depeggedStablecoin() public pure {
        assertEq(RiskMath.debtValueUsd(10_000e6, 0.97e18, 6), 9700e18);
    }

    function test_valuation_collateralRoundsDownDebtRoundsUp() public pure {
        // 1 wei of a 6-decimal token at $1: exact value is 1e12 wei-USD... use 1 wei of an
        // 18-decimal token at $1.5e-18-ish to force a fraction: 1 * 1.5 / 1e18 -> frac.
        assertEq(RiskMath.collateralValueUsd(1, 1, 18), 0);
        assertEq(RiskMath.debtValueUsd(1, 1, 18), 1);
        assertEq(RiskMath.debtValueUsd(0, 1e18, 6), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/

    function test_hf_noDebtIsMax() public pure {
        assertEq(RiskMath.healthFactor(1, 0, 0.8e18), type(uint256).max);
        assertEq(RiskMath.healthFactor(0, 0, 0.8e18), type(uint256).max);
        assertFalse(RiskMath.isLiquidatable(0, 0, 0.8e18));
    }

    function test_hf_example() public pure {
        // $20,000 collateral, $10,000 debt, LT 0.8 -> 1.6
        assertEq(RiskMath.healthFactor(20_000e18, 10_000e18, 0.8e18), 1.6e18);
    }

    function test_hf_exactlyOneIsNotLiquidatable() public pure {
        // c * LT == d  =>  HF == 1.0
        assertEq(RiskMath.healthFactor(12_500e18, 10_000e18, 0.8e18), 1e18);
        assertFalse(RiskMath.isLiquidatable(12_500e18, 10_000e18, 0.8e18));
    }

    function test_hf_oneWeiBelowIsLiquidatable() public pure {
        assertTrue(RiskMath.isLiquidatable(12_500e18 - 1, 10_000e18, 0.8e18));
    }

    function test_hf_zeroCollateralWithDebtIsLiquidatable() public pure {
        assertEq(RiskMath.healthFactor(0, 1, 0.8e18), 0);
        assertTrue(RiskMath.isLiquidatable(0, 1, 0.8e18));
    }

    /*//////////////////////////////////////////////////////////////
                              BORROW LIMIT
    //////////////////////////////////////////////////////////////*/

    function test_limit_example() public pure {
        assertEq(RiskMath.maxDebtValue(20_000e18, 0.75e18), 15_000e18);
        assertTrue(RiskMath.isWithinMaxLtv(20_000e18, 15_000e18, 0.75e18));
        assertFalse(RiskMath.isWithinMaxLtv(20_000e18, 15_000e18 + 1, 0.75e18));
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function test_maxRepayable() public pure {
        assertEq(RiskMath.maxRepayable(10_000e6, 0.5e18), 5000e6);
        assertEq(RiskMath.maxRepayable(1, 0.5e18), 1, "dust stays liquidatable");
        assertEq(RiskMath.maxRepayable(3, 0.5e18), 2);
        assertEq(RiskMath.maxRepayable(0, 0.5e18), 0);
        assertEq(RiskMath.maxRepayable(777, WAD), 777);
    }

    function test_seize_ethCrashExample() public pure {
        // Repay 5,000 USDC, ETH = $1,200, bonus 5%  ->  5000 * 1.05 / 1200 = 4.375 ETH
        uint256 seize = RiskMath.seizeForRepay(5000e6, 1e18, 6, 1200e18, 18, 0.05e18);
        assertEq(seize, 4.375e18);
        assertEq(RiskMath.repayForSeize(4.375e18, 1e18, 6, 1200e18, 18, 0.05e18), 5000e6);
    }

    function test_seize_badDebtExample() public pure {
        // ETH = $500, all 10 ETH seized -> repay = ceil(10 * 500 / 1.05) USDC = 4,761.904762
        assertEq(RiskMath.repayForSeize(10e18, 1e18, 6, 500e18, 18, 0.05e18), 4_761_904_762);
    }

    function test_seize_respectsDepeggedBorrowAsset() public pure {
        // Debt asset worth $0.97: repaying 1,000 of it (=$970) at ETH $2,000 with 5% bonus
        // -> 970 * 1.05 / 2000 = 0.50925 ETH
        assertEq(RiskMath.seizeForRepay(1000e6, 0.97e18, 6, 2000e18, 18, 0.05e18), 0.50925e18);
    }

    function test_seize_roundsDown() public pure {
        // 1 micro-USDC at ETH $3: 1e-6 * 1.05 / 3 ETH = 3.5e11 wei exactly; use ETH $7 for a fraction.
        // 1e-6 * 1.05 / 7 = 1.5e-7 ETH = 150_000_000_000 wei exactly; try $11:
        // 1e-6 * 1.05 / 11 = 9.54545...e-8 ETH -> 95_454_545_454 wei (floor).
        assertEq(RiskMath.seizeForRepay(1, 1e18, 6, 11e18, 18, 0.05e18), 95_454_545_454);
    }

    function test_seize_zeroRepayIsZero() public pure {
        assertEq(RiskMath.seizeForRepay(0, 1e18, 6, 2000e18, 18, 0.05e18), 0);
        assertEq(RiskMath.repayForSeize(0, 1e18, 6, 2000e18, 18, 0.05e18), 0);
    }
}
