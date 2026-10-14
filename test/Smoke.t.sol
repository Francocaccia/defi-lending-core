// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice M0 smoke test: proves the toolchain, pinned compiler and all three remappings
///         resolve. Imports are intentionally unused beyond compilation. Delete once real
///         tests exist (M1+).
contract SmokeTest is Test {
    /// @dev The pragma above is an exact pin, so this file only compiles under 0.8.28.
    function test_toolchainWorks() public pure {
        assertEq(uint256(1) + 1, 2);
    }
}
