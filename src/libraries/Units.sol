// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev 18-decimal fixed point ("WAD"): prices, ratios, percentages and annual rates.
///      Example: 75% = 0.75e18.
uint256 constant WAD = 1e18;

/// @dev 27-decimal fixed point ("RAY"): per-second rates and the borrow index. The extra
///      precision matters because a per-second rate is tiny (5% APR ≈ 1.6e-9 per second);
///      in WAD it would keep only ~9 significant digits.
uint256 constant RAY = 1e27;

/// @dev RAY / WAD, used to lift a WAD value to RAY.
uint256 constant WAD_TO_RAY = 1e9;

/// @dev Year length used to convert annual rates to per-second rates. A flat 365 days (no leap
///      years): the model is "illustrative", and a fixed constant keeps the spec unambiguous.
uint256 constant SECONDS_PER_YEAR = 365 days;
