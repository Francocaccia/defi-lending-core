// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BorrowMath} from "../../src/libraries/BorrowMath.sol";
import {RAY} from "../../src/libraries/Units.sol";

/// @dev Expected numbers were computed independently in Python integer arithmetic.
contract BorrowMathTest is Test {
    uint256 internal constant RATE_4PCT = 1_268_391_679_350_583_460; // 4% APR per second, RAY

    function test_accrueIndex_noTimeOrNoRateIsIdentity() public pure {
        assertEq(BorrowMath.accrueIndex(RAY, RATE_4PCT, 0), RAY);
        assertEq(BorrowMath.accrueIndex(RAY, 0, 1 days), RAY);
        assertEq(BorrowMath.accrueIndex(1.05e27, 0, 365 days), 1.05e27);
    }

    function test_accrueIndex_oneSecond() public pure {
        assertEq(BorrowMath.accrueIndex(RAY, RATE_4PCT, 1), 1_000_000_001_268_391_679_350_583_460);
    }

    function test_accrueIndex_oneYearAt4Percent() public pure {
        // Slightly below 1.04 because the per-second rate was floored (documented, protocol-safe).
        assertEq(
            BorrowMath.accrueIndex(RAY, RATE_4PCT, 365 days), 1_039_999_999_999_999_999_994_560_000
        );
    }

    function test_accrueIndex_roundsUp() public pure {
        // index * rate * dt / RAY = 1 * 1 * 1 / 1e27 = 1e-27 -> ceil -> +1
        assertEq(BorrowMath.accrueIndex(1, 1, 1), 2);
    }

    function test_accrueIndex_compoundsAcrossAccruals() public pure {
        uint256 oneStep = BorrowMath.accrueIndex(RAY, RATE_4PCT, 200 days);
        uint256 half = BorrowMath.accrueIndex(RAY, RATE_4PCT, 100 days);
        uint256 twoSteps = BorrowMath.accrueIndex(half, RATE_4PCT, 100 days);
        assertGt(twoSteps, oneStep, "interest on interest");
    }

    function test_scaled_conversionsAtIndex() public pure {
        uint256 index = 1.05e27;
        assertEq(BorrowMath.scaledFromAssetsUp(1000e6, index), 952_380_953);
        assertEq(BorrowMath.scaledFromAssetsDown(1000e6, index), 952_380_952);
        assertEq(BorrowMath.debtFromScaled(952_380_953, index), 1_000_000_001);
        assertEq(BorrowMath.debtFromScaled(952_380_952, index), 1_000_000_000);
    }

    function test_scaled_atInitialIndexIsIdentity() public pure {
        assertEq(BorrowMath.scaledFromAssetsUp(123_456_789, RAY), 123_456_789);
        assertEq(BorrowMath.scaledFromAssetsDown(123_456_789, RAY), 123_456_789);
        assertEq(BorrowMath.debtFromScaled(123_456_789, RAY), 123_456_789);
    }

    function test_zero() public pure {
        assertEq(BorrowMath.scaledFromAssetsUp(0, 2e27), 0);
        assertEq(BorrowMath.scaledFromAssetsDown(0, 2e27), 0);
        assertEq(BorrowMath.debtFromScaled(0, 2e27), 0);
    }

    function test_sumOfUserDebtsVsDerivedTotal_toleranceIsNMinusOne() public pure {
        // 3 borrowers with scaled 1, 1, 1 at index 1.5e27: each ceil(1.5)=2 -> sum 6, total ceil(4.5)=5.
        uint256 index = 1.5e27;
        uint256 each = BorrowMath.debtFromScaled(1, index);
        uint256 sumOfUsers = 3 * each;
        uint256 total = BorrowMath.debtFromScaled(3, index);
        assertEq(each, 2);
        assertEq(sumOfUsers, 6);
        assertEq(total, 5);
        assertLe(sumOfUsers - total, 3 - 1);
    }
}
