// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {WAD, SECONDS_PER_YEAR} from "../../src/libraries/Units.sol";
import {InterestRateModelHarness} from "../harness/InterestRateModelHarness.sol";

contract InterestRateModelFuzzTest is Test {
    uint256 internal constant MAX_RATE = 10 * WAD;

    InterestRateModelHarness internal h;

    function setUp() public {
        h = new InterestRateModelHarness();
    }

    /// Builds a valid parameter set from raw fuzz inputs.
    function _params(uint256 base, uint256 s1, uint256 s2, uint256 kink)
        internal
        pure
        returns (InterestRateModel.Params memory p)
    {
        p = InterestRateModel.Params({
            baseRate: bound(base, 0, MAX_RATE),
            slope1: bound(s1, 0, MAX_RATE),
            slope2: bound(s2, 0, MAX_RATE),
            optimalUtilization: bound(kink, 1, WAD - 1)
        });
    }

    /// Every parameter set built by `_params` passes validation.
    function testFuzz_validate_acceptsAllInRangeParams(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 kink
    ) public view {
        h.validate(_params(base, s1, s2, kink));
    }

    /// MONOTONICITY: more utilization never lowers the rate.
    function testFuzz_rate_isMonotonicInUtilization(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 kink,
        uint256 u1,
        uint256 u2
    ) public view {
        InterestRateModel.Params memory p = _params(base, s1, s2, kink);
        u1 = bound(u1, 0, WAD);
        u2 = bound(u2, 0, WAD);
        (uint256 lo, uint256 hi) = u1 <= u2 ? (u1, u2) : (u2, u1);

        assertLe(h.annualBorrowRate(p, lo), h.annualBorrowRate(p, hi));
        assertLe(h.borrowRatePerSecond(p, lo), h.borrowRatePerSecond(p, hi));
    }

    /// BOUNDS: base <= rate <= base + slope1 + slope2, with the endpoints exact.
    function testFuzz_rate_isBoundedAndEndpointsAreExact(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 kink,
        uint256 u
    ) public view {
        InterestRateModel.Params memory p = _params(base, s1, s2, kink);
        u = bound(u, 0, WAD);

        uint256 r = h.annualBorrowRate(p, u);
        assertGe(r, p.baseRate);
        assertLe(r, p.baseRate + p.slope1 + p.slope2);

        assertEq(h.annualBorrowRate(p, 0), p.baseRate, "U=0 -> base");
        assertEq(h.annualBorrowRate(p, WAD), p.baseRate + p.slope1 + p.slope2, "U=100% -> max");
    }

    /// KINK: the rate AT the kink is exactly base + slope1 (no jump when crossing it).
    function testFuzz_rate_kinkValueAndContinuity(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 kink
    ) public view {
        InterestRateModel.Params memory p = _params(base, s1, s2, kink);
        uint256 k = p.optimalUtilization;

        uint256 atKink = h.annualBorrowRate(p, k);
        assertEq(atKink, p.baseRate + p.slope1, "rate at kink");

        // One wei above the kink can add at most ceil(slope2 / (1 - K)) wei: no jump.
        uint256 above = h.annualBorrowRate(p, k + 1);
        assertGe(above, atKink);
        assertLe(above - atKink, p.slope2 / (WAD - k) + 1);
    }

    /// SEGMENT FORMULAS: re-derive each segment independently (different expression order) and
    /// compare. Guards against swapping K and (1 - K), or a wrong subtraction base.
    function testFuzz_rate_matchesSegmentFormula(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 kink,
        uint256 u
    ) public view {
        InterestRateModel.Params memory p = _params(base, s1, s2, kink);
        u = bound(u, 0, WAD);

        uint256 expected;
        if (u <= p.optimalUtilization) {
            expected = p.baseRate + (p.slope1 * u) / p.optimalUtilization;
        } else {
            expected = p.baseRate + p.slope1 + (p.slope2 * (u - p.optimalUtilization))
                / (WAD - p.optimalUtilization);
        }
        assertEq(h.annualBorrowRate(p, u), expected);
    }

    /// STEEPNESS: above the kink, the rate grows at least as fast per unit utilization as the
    /// gentle segment whenever slope2 / (1 - K) >= slope1 / K (the "kinked" regime).
    /// Checked with cross-multiplication to avoid division: slope2 * K >= slope1 * (1 - K).
    function testFuzz_rate_upperSegmentIsSteeperWhenParamsSayso(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 kink
    ) public view {
        InterestRateModel.Params memory p = _params(base, s1, s2, kink);
        vm.assume(p.slope2 * p.optimalUtilization >= p.slope1 * (WAD - p.optimalUtilization));

        uint256 k = p.optimalUtilization;
        // Compare the total rise over equal-width windows: [k - w, k] vs [k, k + w].
        uint256 w = (k < WAD - k ? k : WAD - k) / 2; // fits in both segments
        vm.assume(w > 0);
        uint256 lowerRise = h.annualBorrowRate(p, k) - h.annualBorrowRate(p, k - w);
        uint256 upperRise = h.annualBorrowRate(p, k + w) - h.annualBorrowRate(p, k);
        // Two floors of at most 1 wei each can blur the comparison.
        assertGe(upperRise + 2, lowerRise);
    }

    /// UTILIZATION: always within [0, 1], monotone in borrows, antitone in supply.
    function testFuzz_utilization_isBoundedAndMonotone(uint256 supply, uint256 b1, uint256 b2)
        public
        view
    {
        uint256 u1 = h.utilization(supply, b1);
        assertLe(u1, WAD);

        (uint256 lo, uint256 hi) = b1 <= b2 ? (b1, b2) : (b2, b1);
        assertLe(h.utilization(supply, lo), h.utilization(supply, hi));

        if (supply != type(uint256).max && supply > 0) {
            assertGe(h.utilization(supply, b1), h.utilization(supply + 1, b1));
        }
    }

    /// UTILIZATION exact: floor(borrows * 1e18 / supply) whenever borrows < supply.
    function testFuzz_utilization_matchesFloorDivision(uint256 supply, uint256 borrows)
        public
        view
    {
        supply = bound(supply, 1, type(uint128).max); // keep the reference product in uint256
        borrows = bound(borrows, 0, supply - 1);
        assertEq(h.utilization(supply, borrows), (borrows * WAD) / supply);
    }

    /// PER-SECOND: floor error is bounded; one year of per-second rate never EXCEEDS the annual
    /// rate and falls short by at most 1 wei of WAD.
    function testFuzz_perSecond_reconstructsAnnualRate(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 kink,
        uint256 u
    ) public view {
        InterestRateModel.Params memory p = _params(base, s1, s2, kink);
        u = bound(u, 0, WAD);

        uint256 annual = h.annualBorrowRate(p, u);
        uint256 perSec = h.borrowRatePerSecond(p, u);

        assertEq(perSec, (annual * 1e9) / SECONDS_PER_YEAR, "formula");
        uint256 backToWad = (perSec * SECONDS_PER_YEAR) / 1e9;
        assertLe(backToWad, annual, "never over-charges vs the annual rate");
        assertGe(backToWad + 1, annual, "loses at most 1 wei of WAD per year");
    }

    /// Utilization above 100% always reverts.
    function testFuzz_rate_revertsAboveFullUtilization(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 kink,
        uint256 u
    ) public {
        InterestRateModel.Params memory p = _params(base, s1, s2, kink);
        u = bound(u, WAD + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InterestRateModel__InvalidUtilization.selector, u
            )
        );
        h.annualBorrowRate(p, u);
    }
}
