// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RiskMath} from "../../src/libraries/RiskMath.sol";

/// @notice External wrappers over `RiskMath` so tests can use `vm.expectRevert` and so the future
///         differential tests exercise the exact same code.
contract RiskMathHarness {
    function validate(RiskMath.RiskParams memory p) external pure {
        RiskMath.validate(p);
    }

    function seizeForRepay(
        uint256 repay,
        uint256 debtPriceWad,
        uint8 debtDecimals,
        uint256 collPriceWad,
        uint8 collDecimals,
        uint256 bonus
    ) external pure returns (uint256) {
        return RiskMath.seizeForRepay(
            repay, debtPriceWad, debtDecimals, collPriceWad, collDecimals, bonus
        );
    }

    function repayForSeize(
        uint256 seize,
        uint256 debtPriceWad,
        uint8 debtDecimals,
        uint256 collPriceWad,
        uint8 collDecimals,
        uint256 bonus
    ) external pure returns (uint256) {
        return RiskMath.repayForSeize(
            seize, debtPriceWad, debtDecimals, collPriceWad, collDecimals, bonus
        );
    }
}
