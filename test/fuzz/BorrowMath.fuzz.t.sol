// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BorrowMath} from "../../src/libraries/BorrowMath.sol";
import {RAY} from "../../src/libraries/Units.sol";

contract BorrowMathFuzzTest is Test {
    uint256 internal constant MAX_ASSETS = 1e30;
    uint256 internal constant MAX_INDEX = 100e27; // 100x growth: far beyond any realistic horizon
    uint256 internal constant MAX_RATE = uint256(3e19) * 1e9 / 31_536_000; // top of the model's range, RAY/sec

    /// The index never decreases, and grows with both time and rate.
    function testFuzz_accrueIndex_isMonotone(uint256 index, uint256 rate, uint256 dt1, uint256 dt2)
        public
        pure
    {
        index = bound(index, RAY, MAX_INDEX);
        rate = bound(rate, 0, MAX_RATE);
        dt1 = bound(dt1, 0, 10 * 365 days);
        dt2 = bound(dt2, 0, 10 * 365 days);
        (uint256 lo, uint256 hi) = dt1 <= dt2 ? (dt1, dt2) : (dt2, dt1);

        uint256 a = BorrowMath.accrueIndex(index, rate, lo);
        uint256 b = BorrowMath.accrueIndex(index, rate, hi);
        assertGe(a, index);
        assertLe(a, b);
    }

    /// Splitting an interval in two (accruing in between) never yields LESS debt than one big
    /// step at the same rate: compounding can only help the protocol.
    function testFuzz_accrueIndex_splittingNeverLowersIndex(
        uint256 index,
        uint256 rate,
        uint256 dt1,
        uint256 dt2
    ) public pure {
        index = bound(index, RAY, MAX_INDEX);
        rate = bound(rate, 0, MAX_RATE);
        dt1 = bound(dt1, 0, 5 * 365 days);
        dt2 = bound(dt2, 0, 5 * 365 days);

        uint256 oneStep = BorrowMath.accrueIndex(index, rate, dt1 + dt2);
        uint256 twoSteps =
            BorrowMath.accrueIndex(BorrowMath.accrueIndex(index, rate, dt1), rate, dt2);
        assertGe(twoSteps, oneStep);
    }

    /// Borrowing X is NEVER recorded as less than X of debt.
    function testFuzz_borrowDebtIsAtLeastBorrowed(uint256 assets, uint256 index) public pure {
        assets = bound(assets, 0, MAX_ASSETS);
        index = bound(index, RAY, MAX_INDEX);
        uint256 scaled = BorrowMath.scaledFromAssetsUp(assets, index);
        assertGe(BorrowMath.debtFromScaled(scaled, index), assets);
    }

    /// Repaying X reduces the debt by AT MOST X, i.e. the burned scaled debt never covers more
    /// than what was paid.
    function testFuzz_partialRepayNeverOverCredits(uint256 assets, uint256 index) public pure {
        assets = bound(assets, 0, MAX_ASSETS);
        index = bound(index, RAY, MAX_INDEX);
        uint256 burned = BorrowMath.scaledFromAssetsDown(assets, index);
        assertLe(BorrowMath.debtFromScaled(burned, index), assets);
    }

    /// A partial repay (assets < debt) can never burn more scaled debt than the user has.
    function testFuzz_partialRepayBurnsLessThanBalance(uint256 scaled, uint256 index, uint256 cut)
        public
        pure
    {
        scaled = bound(scaled, 1, MAX_ASSETS);
        index = bound(index, RAY, MAX_INDEX);
        uint256 debt = BorrowMath.debtFromScaled(scaled, index);
        cut = bound(cut, 1, debt); // pay between 1 and debt (debt >= 1 since scaled >= 1)
        uint256 paid = debt - cut; // strictly less than debt
        vm.assume(paid > 0);
        assertLt(BorrowMath.scaledFromAssetsDown(paid, index), scaled);
    }

    /// Sum of independently-rounded user debts exceeds the derived total by 0 .. N-1 wei.
    function testFuzz_sumOfUserDebtsMatchesTotalWithinNMinusOne(
        uint256 s1,
        uint256 s2,
        uint256 s3,
        uint256 index
    ) public pure {
        s1 = bound(s1, 0, MAX_ASSETS);
        s2 = bound(s2, 0, MAX_ASSETS);
        s3 = bound(s3, 0, MAX_ASSETS);
        index = bound(index, RAY, MAX_INDEX);

        uint256 sumUsers = BorrowMath.debtFromScaled(s1, index)
            + BorrowMath.debtFromScaled(s2, index) + BorrowMath.debtFromScaled(s3, index);
        uint256 total = BorrowMath.debtFromScaled(s1 + s2 + s3, index);

        assertGe(sumUsers, total);
        assertLe(sumUsers - total, 2); // N = 3  =>  N - 1 = 2
    }
}
