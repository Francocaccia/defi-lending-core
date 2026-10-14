// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract ChainlinkOracleTest is Test {
    uint256 internal constant HEARTBEAT = 1 hours;
    int256 internal constant ETH_PRICE_8D = 2000e8; // $2,000.00 with 8 decimals

    MockAggregatorV3 internal feed;
    ChainlinkOracle internal oracle;

    function setUp() public {
        // Non-trivial timestamp so "now - age" never underflows in tests.
        vm.warp(1_000_000);
        feed = new MockAggregatorV3(8, "ETH / USD", ETH_PRICE_8D);
        oracle = new ChainlinkOracle(AggregatorV3Interface(address(feed)), HEARTBEAT);
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_storesConfig() public view {
        assertEq(address(oracle.FEED()), address(feed));
        assertEq(oracle.HEARTBEAT(), HEARTBEAT);
        assertEq(oracle.FEED_DECIMALS(), 8);
        assertEq(oracle.PRICE_DECIMALS(), 18);
        assertEq(oracle.MAX_HEARTBEAT(), 7 days);
    }

    function test_constructor_revertsOnZeroFeed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidFeed.selector, address(0))
        );
        new ChainlinkOracle(AggregatorV3Interface(address(0)), HEARTBEAT);
    }

    function test_constructor_revertsOnEoaFeed() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidFeed.selector, eoa));
        new ChainlinkOracle(AggregatorV3Interface(eoa), HEARTBEAT);
    }

    function test_constructor_revertsOnZeroHeartbeat() public {
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidHeartbeat.selector, 0)
        );
        new ChainlinkOracle(AggregatorV3Interface(address(feed)), 0);
    }

    function test_constructor_revertsOnHeartbeatAboveMax() public {
        uint256 tooLong = 7 days + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidHeartbeat.selector, tooLong)
        );
        new ChainlinkOracle(AggregatorV3Interface(address(feed)), tooLong);
    }

    function test_constructor_acceptsHeartbeatBounds() public {
        new ChainlinkOracle(AggregatorV3Interface(address(feed)), 1);
        new ChainlinkOracle(AggregatorV3Interface(address(feed)), 7 days);
    }

    function test_constructor_revertsOnMoreThan18Decimals() public {
        MockAggregatorV3 weird = new MockAggregatorV3(19, "WEIRD / USD", 1);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__UnsupportedDecimals.selector, 19)
        );
        new ChainlinkOracle(AggregatorV3Interface(address(weird)), HEARTBEAT);
    }

    /*//////////////////////////////////////////////////////////////
                         DECIMALS NORMALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_price_scalesEightDecimalsTo18() public view {
        assertEq(oracle.price(), 2000e18);
    }

    function test_price_keepsFractionalPart() public {
        feed.setAnswer(200_050_000_000); // $2,000.50
        assertEq(oracle.price(), 2000.5e18);
    }

    function test_price_usdcDepegIsNotHardcodedToOne() public {
        MockAggregatorV3 usdcFeed = new MockAggregatorV3(8, "USDC / USD", 0.97e8);
        ChainlinkOracle usdcOracle =
            new ChainlinkOracle(AggregatorV3Interface(address(usdcFeed)), 1 days);
        assertEq(usdcOracle.price(), 0.97e18);
    }

    function test_price_eighteenDecimalFeedIsPassedThrough() public {
        MockAggregatorV3 f18 = new MockAggregatorV3(18, "X / USD", 1234.5678e18);
        ChainlinkOracle o18 = new ChainlinkOracle(AggregatorV3Interface(address(f18)), HEARTBEAT);
        assertEq(o18.price(), 1234.5678e18);
    }

    function test_price_zeroDecimalFeedIsScaledBy1e18() public {
        MockAggregatorV3 f0 = new MockAggregatorV3(0, "X / USD", 7);
        ChainlinkOracle o0 = new ChainlinkOracle(AggregatorV3Interface(address(f0)), HEARTBEAT);
        assertEq(o0.price(), 7e18);
    }

    function test_price_sixDecimalFeed() public {
        MockAggregatorV3 f6 = new MockAggregatorV3(6, "X / USD", 1_000_000);
        ChainlinkOracle o6 = new ChainlinkOracle(AggregatorV3Interface(address(f6)), HEARTBEAT);
        assertEq(o6.price(), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                              BAD ANSWERS
    //////////////////////////////////////////////////////////////*/

    function test_price_revertsOnZeroAnswer() public {
        feed.setAnswer(0);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, int256(0))
        );
        oracle.price();
    }

    function test_price_revertsOnNegativeAnswer() public {
        feed.setAnswer(-1);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, int256(-1))
        );
        oracle.price();
    }

    function test_price_revertsOnMinInt256Answer() public {
        feed.setAnswer(type(int256).min);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__InvalidPrice.selector, type(int256).min)
        );
        oracle.price();
    }

    function test_price_revertsWhenScalingOverflows() public {
        // 0-decimal feed => multiplier 1e18; int256.max * 1e18 overflows uint256.
        MockAggregatorV3 f0 = new MockAggregatorV3(0, "X / USD", type(int256).max);
        ChainlinkOracle o0 = new ChainlinkOracle(AggregatorV3Interface(address(f0)), HEARTBEAT);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__PriceOverflow.selector, type(int256).max)
        );
        o0.price();
    }

    /*//////////////////////////////////////////////////////////////
                              BAD ROUNDS
    //////////////////////////////////////////////////////////////*/

    function test_price_revertsOnIncompleteRound() public {
        feed.setRoundData(5, ETH_PRICE_8D, block.timestamp, 0, 5);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkOracle.Oracle__IncompleteRound.selector, uint80(5))
        );
        oracle.price();
    }

    function test_price_revertsOnFutureTimestamp() public {
        uint256 future = block.timestamp + 1;
        feed.setRoundData(5, ETH_PRICE_8D, block.timestamp, future, 5);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracle.Oracle__FutureTimestamp.selector, future, block.timestamp
            )
        );
        oracle.price();
    }

    function test_price_updatedAtEqualToNowIsValid() public {
        feed.setRoundData(5, ETH_PRICE_8D, block.timestamp, block.timestamp, 5);
        assertEq(oracle.price(), 2000e18);
    }

    function test_price_revertsWhenAnsweredInOlderRound() public {
        feed.setRoundData(10, ETH_PRICE_8D, block.timestamp, block.timestamp, 9);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracle.Oracle__StaleRound.selector, uint80(10), uint80(9)
            )
        );
        oracle.price();
    }

    function test_price_answeredInNewerRoundIsAccepted() public {
        // answeredInRound > roundId is not a staleness signal; only `<` is rejected.
        feed.setRoundData(10, ETH_PRICE_8D, block.timestamp, block.timestamp, 11);
        assertEq(oracle.price(), 2000e18);
    }

    function test_price_revertsWhenFeedReverts() public {
        feed.setShouldRevert(true);
        vm.expectRevert(ChainlinkOracle.Oracle__FeedCallFailed.selector);
        oracle.price();
    }

    /*//////////////////////////////////////////////////////////////
                               STALENESS
    //////////////////////////////////////////////////////////////*/

    function test_price_acceptsPriceExactlyAtHeartbeatAge() public {
        vm.warp(feed.updatedAt() + HEARTBEAT);
        assertEq(oracle.price(), 2000e18);
    }

    function test_price_revertsOneSecondPastHeartbeat() public {
        uint256 updatedAt = feed.updatedAt();
        uint256 later = updatedAt + HEARTBEAT + 1;
        vm.warp(later);
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkOracle.Oracle__StalePrice.selector, updatedAt, later, HEARTBEAT
            )
        );
        oracle.price();
    }

    function test_price_recoversAfterFreshUpdate() public {
        vm.warp(feed.updatedAt() + HEARTBEAT + 100);
        vm.expectRevert();
        oracle.price();

        feed.setAnswer(1900e8);
        assertEq(oracle.price(), 1900e18);
    }

    function test_price_followsFeedUpdates() public {
        feed.setAnswer(1500e8);
        assertEq(oracle.price(), 1500e18);
        feed.setAnswer(1e8);
        assertEq(oracle.price(), 1e18);
    }

    function test_price_revertsWhenUpdatedAtIsFarInThePast() public {
        feed.setUpdatedAt(1); // timestamp is 1_000_000 in setUp
        vm.expectRevert();
        oracle.price();
    }

    /*//////////////////////////////////////////////////////////////
                              MOCK SANITY
    //////////////////////////////////////////////////////////////*/

    function test_mock_setAnswerBumpsRound() public {
        uint80 before = feed.roundId();
        feed.setAnswer(1e8);
        assertEq(feed.roundId(), before + 1);
        assertEq(feed.answeredInRound(), feed.roundId());
    }

    function test_mock_getRoundDataUnsupported() public {
        vm.expectRevert();
        feed.getRoundData(1);
    }
}
