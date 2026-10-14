// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOracle
/// @notice Minimal price source for ONE asset, quoted in USD.
/// @dev One oracle instance per asset (collateral and borrow asset each get their own), so the
///      stablecoin is never hardcoded at $1: a depeg shows up in the borrow-asset price.
interface IOracle {
    /// @notice USD price of ONE WHOLE token of the asset (10**assetDecimals base units),
    ///         scaled to 18 decimals (WAD). E.g. ETH at $2,000.50 returns 2_000.5e18.
    /// @dev MUST revert (never return a stale/zero/garbage value) if the price is not usable.
    /// @return priceWad The normalized USD price, 18 decimals, always > 0.
    function price() external view returns (uint256 priceWad);
}
