// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract ChainlinkOracleFuzzTest is Test {
    uint256 internal constant START = 10_000_000;

    function setUp() public {
        vm.warp(START);
    }

    function _deploy(uint8 decimals_, int256 answer, uint256 heartbeat)
        internal
        returns (MockAggregatorV3 feed, ChainlinkOracle oracle)
    {
        feed = new MockAggregatorV3(decimals_, "FUZZ / USD", answer);
        oracle = new ChainlinkOracle(AggregatorV3Interface(address(feed)), heartbeat);
    }

    /// Normalization is EXACT (pure multiplication) and invertible for every decimals <= 18.
    function testFuzz_price_normalizationIsExactAndInvertible(uint8 decimals_, uint256 rawAnswer)
        public
    {
        decimals_ = uint8(bound(decimals_, 0, 18));
        uint256 scale = 10 ** (18 - decimals_);
        // Keep answer * scale within uint256 and answer > 0.
        rawAnswer = bound(rawAnswer, 1, type(uint256).max / scale);
        // int256.max < uint256.max, so also respect the signed range of the feed.
        if (rawAnswer > uint256(type(int256).max)) rawAnswer = uint256(type(int256).max);

        (, ChainlinkOracle oracle) = _deploy(decimals_, int256(rawAnswer), 1 hours);

        uint256 p = oracle.price();
        assertEq(p, rawAnswer * scale, "exact scaling");
        assertEq(p / scale, rawAnswer, "round-trips back to the feed answer");
        assertEq(p % scale, 0, "no fractional dust");
    }

    /// Any non-positive answer must revert, for every decimals setting.
    function testFuzz_price_revertsOnNonPositiveAnswer(uint8 decimals_, int256 answer) public {
        decimals_ = uint8(bound(decimals_, 0, 18));
        answer = bound(answer, type(int256).min, 0);

        // The mock constructor stores the answer verbatim; the oracle rejects it on read.
        (, ChainlinkOracle oracle) = _deploy(decimals_, answer, 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, answer)
        );
        oracle.price();
    }

    /// Staleness boundary: age <= heartbeat passes, age > heartbeat reverts. Nothing in between.
    function testFuzz_price_stalenessBoundary(uint256 heartbeat, uint256 age) public {
        heartbeat = bound(heartbeat, 1, 7 days);
        age = bound(age, 0, 30 days);

        (, ChainlinkOracle oracle) = _deploy(8, 2000e8, heartbeat);
        vm.warp(START + age);

        if (age <= heartbeat) {
            assertEq(oracle.price(), 2000e18);
        } else {
            vm.expectRevert();
            oracle.price();
        }
    }

    /// Heartbeats outside (0, 7 days] are rejected at deployment.
    function testFuzz_constructor_rejectsInvalidHeartbeat(uint256 heartbeat) public {
        vm.assume(heartbeat == 0 || heartbeat > 7 days);
        MockAggregatorV3 feed = new MockAggregatorV3(8, "FUZZ / USD", 1e8);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidHeartbeat.selector, heartbeat)
        );
        new ChainlinkOracle(AggregatorV3Interface(address(feed)), heartbeat);
    }

    /// Price is monotonic in the feed answer (a higher feed answer never gives a lower price).
    function testFuzz_price_monotonicInAnswer(uint8 decimals_, uint256 a, uint256 b) public {
        decimals_ = uint8(bound(decimals_, 0, 18));
        uint256 scale = 10 ** (18 - decimals_);
        uint256 cap = type(uint256).max / scale;
        if (cap > uint256(type(int256).max)) cap = uint256(type(int256).max);
        a = bound(a, 1, cap);
        b = bound(b, 1, cap);

        (MockAggregatorV3 feed, ChainlinkOracle oracle) = _deploy(decimals_, int256(a), 1 hours);
        uint256 pa = oracle.price();
        feed.setAnswer(int256(b));
        uint256 pb = oracle.price();

        if (a <= b) assertLe(pa, pb);
        else assertGe(pa, pb);
    }

    /// A round whose answeredInRound < roundId always reverts, whatever else is valid.
    function testFuzz_price_revertsWhenAnsweredInRoundBehind(uint80 roundId, uint80 answered)
        public
    {
        roundId = uint80(bound(roundId, 1, type(uint80).max));
        answered = uint80(bound(answered, 0, roundId - 1));

        (MockAggregatorV3 feed, ChainlinkOracle oracle) = _deploy(8, 2000e8, 1 hours);
        feed.setRoundData(roundId, 2000e8, block.timestamp, block.timestamp, answered);

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__StaleRound.selector, roundId, answered)
        );
        oracle.price();
    }
}
