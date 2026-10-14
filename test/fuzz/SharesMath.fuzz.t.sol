// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SharesMath} from "../../src/libraries/SharesMath.sol";

contract SharesMathFuzzTest is Test {
    // Realistic ranges: assets/shares fit comfortably (shares ~ assets * 1e6 or more).
    uint256 internal constant MAX_ASSETS = 1e30;
    uint256 internal constant MAX_SHARES = 1e40;

    /// Depositing then redeeming everything minted NEVER returns more than was deposited.
    function testFuzz_depositRedeemRoundTripNeverProfits(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        assets = bound(assets, 0, MAX_ASSETS);
        totalAssets = bound(totalAssets, 0, MAX_ASSETS);
        totalShares = bound(totalShares, 0, MAX_SHARES);

        uint256 shares = SharesMath.toSharesDown(assets, totalAssets, totalShares);
        // The pool after the deposit:
        uint256 back = SharesMath.toAssetsDown(shares, totalAssets + assets, totalShares + shares);
        assertLe(back, assets, "round trip must not create value");
    }

    /// Burning `toSharesUp(a)` shares always covers a withdrawal of `a` assets (never under-burns).
    function testFuzz_withdrawBurnsEnoughShares(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        assets = bound(assets, 0, MAX_ASSETS);
        totalAssets = bound(totalAssets, 0, MAX_ASSETS);
        totalShares = bound(totalShares, 0, MAX_SHARES);

        uint256 burned = SharesMath.toSharesUp(assets, totalAssets, totalShares);
        assertGe(SharesMath.toAssetsDown(burned, totalAssets, totalShares), assets);
    }

    /// Rounding direction: Up >= Down, differing by at most 1.
    function testFuzz_upIsDownOrDownPlusOne(uint256 x, uint256 totalAssets, uint256 totalShares)
        public
        pure
    {
        // x <= 1e30 keeps the RESULT (x * 1e40 / small) inside uint256; an out-of-range result
        // correctly reverts in mulDiv and is not what this property is about.
        x = bound(x, 0, MAX_ASSETS);
        totalAssets = bound(totalAssets, 0, MAX_ASSETS);
        totalShares = bound(totalShares, 0, MAX_SHARES);

        uint256 sd = SharesMath.toSharesDown(x, totalAssets, totalShares);
        uint256 su = SharesMath.toSharesUp(x, totalAssets, totalShares);
        assertGe(su, sd);
        assertLe(su - sd, 1);

        uint256 ad = SharesMath.toAssetsDown(x, totalAssets, totalShares);
        uint256 au = SharesMath.toAssetsUp(x, totalAssets, totalShares);
        assertGe(au, ad);
        assertLe(au - ad, 1);
    }

    /// Monotonic: more assets never give fewer shares; more shares never give fewer assets.
    function testFuzz_monotonic(uint256 a, uint256 b, uint256 totalAssets, uint256 totalShares)
        public
        pure
    {
        a = bound(a, 0, MAX_ASSETS);
        b = bound(b, 0, MAX_ASSETS);
        totalAssets = bound(totalAssets, 0, MAX_ASSETS);
        totalShares = bound(totalShares, 0, MAX_SHARES);
        (uint256 lo, uint256 hi) = a <= b ? (a, b) : (b, a);

        assertLe(
            SharesMath.toSharesDown(lo, totalAssets, totalShares),
            SharesMath.toSharesDown(hi, totalAssets, totalShares)
        );
        assertLe(
            SharesMath.toAssetsDown(lo, totalAssets, totalShares),
            SharesMath.toAssetsDown(hi, totalAssets, totalShares)
        );
    }

    /// Existing holders are never diluted: after a deposit the value of the shares they already
    /// held does not decrease.
    function testFuzz_depositNeverDilutesExistingHolders(
        uint256 existingShares,
        uint256 totalAssets,
        uint256 totalShares,
        uint256 deposit
    ) public pure {
        totalAssets = bound(totalAssets, 0, MAX_ASSETS);
        totalShares = bound(totalShares, 0, MAX_SHARES);
        existingShares = bound(existingShares, 0, totalShares);
        deposit = bound(deposit, 0, MAX_ASSETS);

        uint256 before = SharesMath.toAssetsDown(existingShares, totalAssets, totalShares);
        uint256 minted = SharesMath.toSharesDown(deposit, totalAssets, totalShares);
        uint256 afterValue =
            SharesMath.toAssetsDown(existingShares, totalAssets + deposit, totalShares + minted);
        assertGe(afterValue, before);
    }
}
