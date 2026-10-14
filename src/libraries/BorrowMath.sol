// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RAY} from "./Units.sol";

/// @title BorrowMath
/// @notice Pure math for the global borrow index and "scaled" (index-normalized) debt.
/// @dev Model: the protocol keeps ONE global `index` (RAY, starts at 1e27) that grows with
///      interest. Each borrower stores a `scaled` amount such that
///
///          debt(now) = ceil(scaled * index / RAY)
///
///      so interest accrues to EVERY borrower by updating a single number, with no loop. This is
///      the compound-style index: each accrual multiplies the previous index, so interest earns
///      interest across accruals (within one interval the growth is linear).
///
///      The aggregate `totalScaled = sum(scaled_i)` is exact, and total borrows are DERIVED from
///      it (`totalDebt`), never tracked separately. That removes any drift between the global
///      figure and the per-user figures: the only difference is the per-user ceil, so
///      sum(userDebt_i) - totalDebt is in [0, N - 1] wei for N borrowers.
///
///      Rounding rules (against the borrower, for the protocol):
///        index growth          : UP   (debt grows at least as fast as the exact rate)
///        borrow  -> scaled     : UP   (borrower is assigned slightly more debt than received)
///        repay   -> scaled burn: DOWN (repaying X reduces debt by at most X)
///        scaled  -> debt       : UP
library BorrowMath {
    /// @notice index' = index + ceil(index * ratePerSecond * dt / RAY).
    /// @dev `ratePerSecond * dt` is the RAY-scaled interest factor for the interval. The rate is
    ///      the one in force at the START of the interval (utilization before the accrual).
    /// @param index Current borrow index (RAY).
    /// @param ratePerSecond Borrow rate per second (RAY).
    /// @param dt Seconds elapsed since the last accrual.
    function accrueIndex(uint256 index, uint256 ratePerSecond, uint256 dt)
        internal
        pure
        returns (uint256)
    {
        return index + Math.mulDiv(index, ratePerSecond * dt, RAY, Math.Rounding.Ceil);
    }

    /// @notice scaled = ceil(assets * RAY / index): debt units assigned for a NEW borrow.
    function scaledFromAssetsUp(uint256 assets, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(assets, RAY, index, Math.Rounding.Ceil);
    }

    /// @notice scaled = floor(assets * RAY / index): debt units burned by a PARTIAL repay.
    function scaledFromAssetsDown(uint256 assets, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(assets, RAY, index);
    }

    /// @notice assets = ceil(scaled * index / RAY): the debt (or total debt) represented by
    ///         `scaled` at `index`.
    function debtFromScaled(uint256 scaled, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(scaled, index, RAY, Math.Rounding.Ceil);
    }
}
