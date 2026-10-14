// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Demo} from "../../script/Demo.s.sol";

/// @notice Keeps the demo script honest: it must run to completion and tell the story its
///         README promises, with numbers that match the hand-computed ones in the unit tests.
contract DemoTest is Test {
    Demo internal demo;

    function setUp() public {
        demo = new Demo();
    }

    function test_demo_runsAndTellsTheStory() public {
        Demo.Result memory r = demo.runWithInterest();

        // 10 WETH ($20k) against 10,000 USDC => HF 20,000 * 0.8 / 10,000.
        assertEq(r.bobHealthBefore, 1.6e18);
        // After a year of interest and ETH at $1,200 he is liquidatable ...
        assertLt(r.bobHealthAfterCrash, 1e18);
        // ... a 50% liquidation restores health ...
        assertGt(r.bobHealthAfterLiquidation, 1e18);
        // ... the repaid amount is half of the interest-inclusive debt (10,050 / 2) ...
        assertEq(r.firstRepaid, 5025e6);
        // ... and the seized collateral is worth 5% more than the repayment: 5025 * 1.05 / 1200.
        assertEq(r.firstSeized, 4.396875e18);
        // The second, deeper crash leaves bad debt that suppliers absorb.
        assertGt(r.badDebt, 0);
        assertLt(r.aliceBalanceAtEnd, 100_000e6);
        assertEq(r.badDebt, 3_424_107_143);
        assertEq(r.aliceBalanceAtEnd, 96_625_892_857);
    }
}
