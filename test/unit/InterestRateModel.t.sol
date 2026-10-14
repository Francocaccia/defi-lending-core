// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {WAD, SECONDS_PER_YEAR} from "../../src/libraries/Units.sol";
import {InterestRateModelHarness} from "../harness/InterestRateModelHarness.sol";

/// @dev Expected values below were computed independently in Python (integer arithmetic), not
///      by running the Solidity under test.
contract InterestRateModelTest is Test {
    InterestRateModelHarness internal h;

    // Illustrative defaults: base 0%, slope1 4%, slope2 75%, kink at 80%.
    InterestRateModel.Params internal p0 = InterestRateModel.Params({
        baseRate: 0, slope1: 0.04e18, slope2: 0.75e18, optimalUtilization: 0.8e18
    });
    // Same curve with a 1% base rate.
    InterestRateModel.Params internal p1 = InterestRateModel.Params({
        baseRate: 0.01e18, slope1: 0.04e18, slope2: 0.75e18, optimalUtilization: 0.8e18
    });

    function setUp() public {
        h = new InterestRateModelHarness();
    }

    /*//////////////////////////////////////////////////////////////
                                VALIDATE
    //////////////////////////////////////////////////////////////*/

    function test_validate_acceptsIllustrativeParams() public view {
        h.validate(p0);
        h.validate(p1);
    }

    function test_validate_revertsOnZeroOptimal() public {
        InterestRateModel.Params memory p = p0;
        p.optimalUtilization = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InterestRateModel__InvalidOptimalUtilization.selector, 0
            )
        );
        h.validate(p);
    }

    function test_validate_revertsOnOptimalEqualToOne() public {
        InterestRateModel.Params memory p = p0;
        p.optimalUtilization = WAD;
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InterestRateModel__InvalidOptimalUtilization.selector, WAD
            )
        );
        h.validate(p);
    }

    function test_validate_acceptsOptimalNeighborsOfBounds() public view {
        InterestRateModel.Params memory p = p0;
        p.optimalUtilization = 1;
        h.validate(p);
        p.optimalUtilization = WAD - 1;
        h.validate(p);
    }

    function test_validate_revertsOnRateTooHigh() public {
        uint256 tooHigh = 10 * WAD + 1;
        InterestRateModel.Params memory p = p0;

        p.baseRate = tooHigh;
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InterestRateModel__RateTooHigh.selector, tooHigh
            )
        );
        h.validate(p);

        p = p0;
        p.slope1 = tooHigh;
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InterestRateModel__RateTooHigh.selector, tooHigh
            )
        );
        h.validate(p);

        p = p0;
        p.slope2 = tooHigh;
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InterestRateModel__RateTooHigh.selector, tooHigh
            )
        );
        h.validate(p);
    }

    function test_validate_acceptsRateAtCap() public view {
        InterestRateModel.Params memory p = p0;
        p.baseRate = 10 * WAD;
        p.slope1 = 10 * WAD;
        p.slope2 = 10 * WAD;
        h.validate(p);
    }

    /*//////////////////////////////////////////////////////////////
                              UTILIZATION
    //////////////////////////////////////////////////////////////*/

    function test_utilization_zeroSupplyIsZero() public view {
        assertEq(h.utilization(0, 0), 0);
        assertEq(h.utilization(0, 123), 0);
    }

    function test_utilization_noBorrowsIsZero() public view {
        assertEq(h.utilization(1000e6, 0), 0);
    }

    function test_utilization_half() public view {
        assertEq(h.utilization(1000e6, 500e6), 0.5e18);
    }

    function test_utilization_full() public view {
        assertEq(h.utilization(1000e6, 1000e6), WAD);
    }

    function test_utilization_cappedAtOneWhenBorrowsExceedSupply() public view {
        assertEq(h.utilization(1000e6, 1000e6 + 1), WAD);
        assertEq(h.utilization(1, type(uint256).max), WAD);
    }

    function test_utilization_floors() public view {
        assertEq(h.utilization(3, 1), 333_333_333_333_333_333); // 1/3
        assertEq(h.utilization(3, 2), 666_666_666_666_666_666); // 2/3
    }

    function test_utilization_handlesHugeValuesWithoutOverflow() public view {
        // borrows * WAD exceeds 2^256; mulDiv uses 512-bit intermediate so it must not revert.
        assertEq(h.utilization(type(uint256).max, type(uint256).max - 1) < WAD, true);
        // supply = 2 * (2^255 - 1), borrows = 2^255 - 1  =>  exactly one half.
        assertEq(h.utilization(type(uint256).max - 1, type(uint256).max / 2), 0.5e18);
        // max/2 against max is just BELOW one half, so the floor is 0.5e18 - 1.
        assertEq(h.utilization(type(uint256).max, type(uint256).max / 2), 0.5e18 - 1);
    }

    /*//////////////////////////////////////////////////////////////
                              ANNUAL RATE
    //////////////////////////////////////////////////////////////*/

    function test_rate_zeroBase() public view {
        assertEq(h.annualBorrowRate(p0, 0), 0);
        assertEq(h.annualBorrowRate(p0, 0.4e18), 0.02e18);
        assertEq(h.annualBorrowRate(p0, 0.8e18), 0.04e18); // kink
        assertEq(h.annualBorrowRate(p0, 0.9e18), 0.415e18);
        assertEq(h.annualBorrowRate(p0, 1e18), 0.79e18);
    }

    function test_rate_withBase() public view {
        assertEq(h.annualBorrowRate(p1, 0), 0.01e18);
        assertEq(h.annualBorrowRate(p1, 0.4e18), 0.03e18);
        assertEq(h.annualBorrowRate(p1, 0.8e18), 0.05e18); // kink = base + slope1
        assertEq(h.annualBorrowRate(p1, 0.9e18), 0.425e18);
        assertEq(h.annualBorrowRate(p1, 1e18), 0.8e18); // base + slope1 + slope2
    }

    function test_rate_floorsInLowerSegment() public view {
        // slope1 = 10 wei, U = 12.5% of K => 10 * 0.1e18 / 0.8e18 = 1.25 -> 1
        InterestRateModel.Params memory p = InterestRateModel.Params({
            baseRate: 0, slope1: 10, slope2: 0, optimalUtilization: 0.8e18
        });
        assertEq(h.annualBorrowRate(p, 0.1e18), 1);
    }

    function test_rate_oneThirdUtilization() public view {
        assertEq(h.annualBorrowRate(p0, 333_333_333_333_333_333), 16_666_666_666_666_666);
    }

    function test_rate_justAboveKinkContinuity() public view {
        // One wei above the kink: slope2 contribution is floor(0.75e18 * 1 / 0.2e18) = 3.
        assertEq(h.annualBorrowRate(p0, 0.8e18 + 1), 0.04e18 + 3);
    }

    function test_rate_revertsAboveFullUtilization() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InterestRateModel__InvalidUtilization.selector, WAD + 1
            )
        );
        h.annualBorrowRate(p0, WAD + 1);
    }

    function test_rate_flatCurveWhenSlopesAreZero() public view {
        InterestRateModel.Params memory p = InterestRateModel.Params({
            baseRate: 0.05e18, slope1: 0, slope2: 0, optimalUtilization: 0.8e18
        });
        assertEq(h.annualBorrowRate(p, 0), 0.05e18);
        assertEq(h.annualBorrowRate(p, 0.9e18), 0.05e18);
        assertEq(h.annualBorrowRate(p, 1e18), 0.05e18);
    }

    function test_rate_extremeKinkPositions() public view {
        // K = 1 wei: almost the whole range is the steep segment.
        InterestRateModel.Params memory p = InterestRateModel.Params({
            baseRate: 0, slope1: 0.1e18, slope2: 1e18, optimalUtilization: 1
        });
        assertEq(h.annualBorrowRate(p, 1), 0.1e18);
        assertEq(h.annualBorrowRate(p, WAD), 0.1e18 + 1e18);

        // K = 1e18 - 1: almost the whole range is the gentle segment.
        p.optimalUtilization = WAD - 1;
        assertEq(h.annualBorrowRate(p, WAD - 1), 0.1e18);
        assertEq(h.annualBorrowRate(p, WAD), 0.1e18 + 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            PER-SECOND RATE
    //////////////////////////////////////////////////////////////*/

    function test_perSecond_knownValues() public view {
        assertEq(h.borrowRatePerSecond(p0, 0), 0);
        // 4% APR: 0.04e18 * 1e9 / 31_536_000
        assertEq(h.borrowRatePerSecond(p0, 0.8e18), 1_268_391_679_350_583_460);
        // 2% APR
        assertEq(h.borrowRatePerSecond(p0, 0.4e18), 634_195_839_675_291_730);
        // 41.5% APR
        assertEq(h.borrowRatePerSecond(p0, 0.9e18), 13_159_563_673_262_303_399);
        // 79% APR
        assertEq(h.borrowRatePerSecond(p0, 1e18), 25_050_735_667_174_023_338);
    }

    function test_perSecond_secondsPerYearConstant() public pure {
        assertEq(SECONDS_PER_YEAR, 31_536_000);
    }

    function test_perSecond_oneYearApproximatesAnnualRate() public view {
        uint256 perSec = h.borrowRatePerSecond(p0, 0.8e18); // RAY per second
        // perSec * SPY / 1e9 must equal the annual WAD rate up to the flooring error.
        uint256 reconstructed = perSec * SECONDS_PER_YEAR / 1e9;
        assertLe(reconstructed, 0.04e18);
        assertGe(reconstructed, 0.04e18 - 1);
    }
}
