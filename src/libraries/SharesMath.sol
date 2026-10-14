// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SharesMath
/// @notice Pure conversions between supplier ASSETS (borrow-token base units) and SHARES, with
///         virtual shares/assets.
/// @dev Why shares: interest increases `totalAssets` while `totalShares` stays put, so every
///      supplier's claim grows with no per-user loop and no per-user write.
///
///      Why VIRTUAL amounts: with a plain `assets * totalShares / totalAssets` an attacker can
///      deposit 1 wei (getting 1 share), then DONATE a large amount directly to the pool so the
///      next depositor's shares round down to 0 and the attacker captures their deposit. Adding
///      a virtual 1e6 shares and 1 asset to the ratio makes the first share worth ~1e-6 assets
///      and makes the donation cost the attacker ~1e6 times what they can steal (the same idea
///      as OpenZeppelin's ERC-4626 "decimals offset", re-derived here).
///
///      Rounding rule (always against the user, for the protocol):
///        deposit(assets)   -> shares rounded DOWN (user gets fewer shares)
///        withdraw(assets)  -> shares rounded UP   (user burns more shares)
///        redeem(shares)    -> assets rounded DOWN (user receives less)
library SharesMath {
    /// @notice Virtual shares added to the share supply in every ratio.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    /// @notice Virtual assets added to the asset supply in every ratio.
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice shares = floor(assets * (totalShares + VS) / (totalAssets + VA)).
    /// @param assets Amount in asset base units.
    /// @param totalAssets Total supplier-owned assets (interest included).
    /// @param totalShares Total supplier shares outstanding.
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @notice shares = ceil(assets * (totalShares + VS) / (totalAssets + VA)).
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(
            assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil
        );
    }

    /// @notice assets = floor(shares * (totalAssets + VA) / (totalShares + VS)).
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @notice assets = ceil(shares * (totalAssets + VA) / (totalShares + VS)).
    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(
            shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES, Math.Rounding.Ceil
        );
    }
}
