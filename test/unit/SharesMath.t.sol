// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SharesMath} from "../../src/libraries/SharesMath.sol";

/// @dev Expected numbers were computed independently in Python integer arithmetic.
contract SharesMathTest is Test {
    function test_constants() public pure {
        assertEq(SharesMath.VIRTUAL_SHARES, 1e6);
        assertEq(SharesMath.VIRTUAL_ASSETS, 1);
    }

    function test_emptyPool_firstDepositGetsAssetsTimes1e6Shares() public pure {
        // 1000 USDC (6 dec) into an empty pool => 1e15 shares (12-decimal shares).
        assertEq(SharesMath.toSharesDown(1000e6, 0, 0), 1e15);
        assertEq(SharesMath.toSharesUp(1000e6, 0, 0), 1e15);
    }

    function test_emptyPool_sharesRoundTripBackToAssets() public pure {
        assertEq(SharesMath.toAssetsDown(1e15, 1000e6, 1e15), 1000e6);
        assertEq(SharesMath.toAssetsUp(1e15, 1000e6, 1e15), 1000e6);
    }

    function test_poolWithInterest_depositRoundsDownWithdrawRoundsUp() public pure {
        // Pool: 1050 USDC owed to suppliers, 1e15 shares (5% interest accrued).
        assertEq(SharesMath.toSharesDown(100e6, 1050e6, 1e15), 95_238_095_242_630);
        assertEq(SharesMath.toSharesUp(100e6, 1050e6, 1e15), 95_238_095_242_631);
    }

    function test_poolWithInterest_redeemRoundsDownAssetsUp() public pure {
        assertEq(SharesMath.toAssetsDown(1e14, 1050e6, 1e15), 104_999_999);
        assertEq(SharesMath.toAssetsUp(1e14, 1050e6, 1e15), 105_000_000);
    }

    function test_zeroInputs() public pure {
        assertEq(SharesMath.toSharesDown(0, 1000e6, 1e15), 0);
        assertEq(SharesMath.toSharesUp(0, 1000e6, 1e15), 0);
        assertEq(SharesMath.toAssetsDown(0, 1000e6, 1e15), 0);
        assertEq(SharesMath.toAssetsUp(0, 1000e6, 1e15), 0);
    }

    /// First-depositor inflation attack: 1 wei in, then a 1,000 USDC "donation" to the pool's
    /// accounted assets, then the victim deposits 1,000 USDC. Without virtual shares the
    /// victim would get 0 shares. With them the victim keeps ~100% and the attacker LOSES.
    function test_inflationAttack_isUnprofitableAndVictimIsNotRobbed() public pure {
        uint256 attackerShares = SharesMath.toSharesDown(1, 0, 0);
        assertEq(attackerShares, 1e6);

        uint256 assets = 1 + 1000e6; // 1 wei deposit + 1,000 USDC donation
        uint256 victimDeposit = 1000e6;
        uint256 victimShares = SharesMath.toSharesDown(victimDeposit, assets, attackerShares);
        assertEq(victimShares, 1_999_999);
        assertGt(victimShares, 0, "victim must not be rounded to zero");

        uint256 assetsAfter = assets + victimDeposit;
        uint256 sharesAfter = attackerShares + victimShares;

        uint256 attackerValue = SharesMath.toAssetsDown(attackerShares, assetsAfter, sharesAfter);
        uint256 victimValue = SharesMath.toAssetsDown(victimShares, assetsAfter, sharesAfter);
        assertEq(attackerValue, 500_000_125);
        assertEq(victimValue, 999_999_750);

        uint256 attackerSpent = 1 + 1000e6;
        assertLt(attackerValue, attackerSpent, "attacker loses money");
        assertGe(victimValue, victimDeposit - victimDeposit / 1e5, "victim loses < 0.001%");
    }

    function test_hugeValuesDoNotOverflowIntermediate() public pure {
        // assets * shares exceeds 2^256; mulDiv's 512-bit intermediate must handle it.
        uint256 shares =
            SharesMath.toSharesDown(type(uint128).max, type(uint128).max, type(uint128).max);
        assertGt(shares, 0);
    }
}
