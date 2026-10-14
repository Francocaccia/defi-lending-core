// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";

/// @notice Exposes the internal library functions as external calls so tests can use
///         `vm.expectRevert` (which only intercepts external call frames) and so the future
///         differential tests can call the exact same code path.
contract InterestRateModelHarness {
    function validate(InterestRateModel.Params memory p) external pure {
        InterestRateModel.validate(p);
    }

    function utilization(uint256 supply, uint256 borrows) external pure returns (uint256) {
        return InterestRateModel.utilization(supply, borrows);
    }

    function annualBorrowRate(InterestRateModel.Params memory p, uint256 u)
        external
        pure
        returns (uint256)
    {
        return InterestRateModel.annualBorrowRate(p, u);
    }

    function borrowRatePerSecond(InterestRateModel.Params memory p, uint256 u)
        external
        pure
        returns (uint256)
    {
        return InterestRateModel.borrowRatePerSecond(p, u);
    }
}
