// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "../interfaces/IOracle.sol";

/// @title ChainlinkOracle
/// @notice Wraps ONE Chainlink `AggregatorV3Interface` feed (e.g. ETH/USD) and exposes a
///         validated price normalized to 18 decimals.
/// @dev Design choices:
///      - Immutable config, no admin, no setters: nobody can swap the feed or loosen the
///        staleness bound after deployment (v1 has no privileged functions).
///      - Fail closed: any anomaly reverts with a custom error. The protocol must never act
///        (borrow, withdraw, liquidate) on a price it cannot trust, so there is no fallback.
///      - View-only: no state changes, hence no events.
contract ChainlinkOracle is IOracle {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Output precision of `price()`.
    uint8 public constant PRICE_DECIMALS = 18;

    /// @notice Sanity cap on the configured heartbeat (7 days). Guards against a unit mistake
    ///         (e.g. milliseconds) silently disabling the staleness check.
    uint256 public constant MAX_HEARTBEAT = 7 days;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Chainlink feed this oracle reads.
    AggregatorV3Interface public immutable FEED;

    /// @notice Maximum accepted age of the feed's last update, in seconds.
    /// @dev Choose it as the feed's documented heartbeat plus a small safety margin; the feed
    ///      is only required to update once per heartbeat, so a bound equal to the heartbeat
    ///      with zero margin can revert on a feed that is merely a few seconds late.
    uint256 public immutable HEARTBEAT;

    /// @notice Decimals reported by the feed (cached: Chainlink feed decimals never change).
    uint8 public immutable FEED_DECIMALS;

    /// @dev 10 ** (18 - FEED_DECIMALS), the exact multiplier used for normalization.
    uint256 private immutable _SCALE;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The feed address is zero or has no contract code.
    error Oracle__InvalidFeed(address feed);
    /// @notice The heartbeat is zero or above `MAX_HEARTBEAT`.
    error Oracle__InvalidHeartbeat(uint256 heartbeat);
    /// @notice The feed reports more than 18 decimals (not supported: would lose precision).
    error Oracle__UnsupportedDecimals(uint8 decimals);
    /// @notice The call to `latestRoundData()` reverted.
    error Oracle__FeedCallFailed();
    /// @notice The reported answer is zero or negative.
    error Oracle__InvalidPrice(int256 answer);
    /// @notice The round is not finished (`updatedAt == 0`).
    error Oracle__IncompleteRound(uint80 roundId);
    /// @notice `updatedAt` is in the future relative to this block.
    error Oracle__FutureTimestamp(uint256 updatedAt, uint256 currentTime);
    /// @notice The answer was carried over from an older round (`answeredInRound < roundId`).
    error Oracle__StaleRound(uint80 roundId, uint80 answeredInRound);
    /// @notice The last update is older than the configured heartbeat.
    error Oracle__StalePrice(uint256 updatedAt, uint256 currentTime, uint256 heartbeat);
    /// @notice Scaling the answer to 18 decimals overflowed uint256.
    error Oracle__PriceOverflow(int256 answer);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param feed Chainlink aggregator (or proxy) address for the asset/USD pair.
    /// @param heartbeat Max accepted age of the feed's last update, in seconds (1..7 days).
    constructor(AggregatorV3Interface feed, uint256 heartbeat) {
        if (address(feed) == address(0) || address(feed).code.length == 0) {
            revert Oracle__InvalidFeed(address(feed));
        }
        if (heartbeat == 0 || heartbeat > MAX_HEARTBEAT) {
            revert Oracle__InvalidHeartbeat(heartbeat);
        }

        uint8 feedDecimals = feed.decimals();
        // Only ≤ 18 decimals: scaling UP is exact (multiply), scaling DOWN would round and then
        // the rounding direction would matter to every consumer. Real USD feeds use 8.
        if (feedDecimals > PRICE_DECIMALS) revert Oracle__UnsupportedDecimals(feedDecimals);

        FEED = feed;
        HEARTBEAT = heartbeat;
        FEED_DECIMALS = feedDecimals;
        _SCALE = 10 ** (PRICE_DECIMALS - feedDecimals);
    }

    /*//////////////////////////////////////////////////////////////
                                  PRICE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOracle
    /// @dev Checks, in order (cheapest/most fundamental first):
    ///      1. the feed call itself succeeds;
    ///      2. answer > 0 (a zero/negative price would make debt free or collateral infinite);
    ///      3. the round is complete (`updatedAt != 0`) and not from the future;
    ///      4. `answeredInRound >= roundId` (legacy Chainlink check: answer not carried over);
    ///      5. age = now - updatedAt <= HEARTBEAT (a price exactly HEARTBEAT old is accepted);
    ///      6. the 18-decimal scaling does not overflow.
    function price() external view returns (uint256 priceWad) {
        (uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound) = _latestRound();

        if (answer <= 0) revert Oracle__InvalidPrice(answer);
        if (updatedAt == 0) revert Oracle__IncompleteRound(roundId);
        // Staleness compares against the block time on purpose: that IS the quantity we care
        // about (how old is this price right now). A proposer can skew `block.timestamp` by a few
        // seconds, which is negligible against a heartbeat measured in minutes/hours.
        // forge-lint: disable-start(block-timestamp)
        // Checked before the subtraction below so it cannot underflow into a Panic.
        if (updatedAt > block.timestamp) {
            revert Oracle__FutureTimestamp(updatedAt, block.timestamp);
        }
        if (answeredInRound < roundId) revert Oracle__StaleRound(roundId, answeredInRound);
        if (block.timestamp - updatedAt > HEARTBEAT) {
            revert Oracle__StalePrice(updatedAt, block.timestamp, HEARTBEAT);
        }
        // forge-lint: disable-end(block-timestamp)

        // tryMul turns an overflow into a custom error instead of a bare Panic.
        // casting to 'uint256' is safe because `answer > 0` was checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (bool ok, uint256 scaled) = Math.tryMul(uint256(answer), _SCALE);
        if (!ok) revert Oracle__PriceOverflow(answer);
        return scaled;
    }

    /// @dev try/catch so that ANY feed failure surfaces as our own custom error instead of
    ///      bubbling arbitrary revert data from an external contract. (A feed that returns
    ///      malformed data still reverts, just in the ABI decoder: the call fails closed.)
    ///      `startedAt` is deliberately ignored: only `updatedAt` matters for freshness.
    function _latestRound()
        private
        view
        returns (uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredInRound)
    {
        // Slither unused-return: `startedAt` is intentionally not read (see the @dev above).
        // slither-disable-next-line unused-return
        try FEED.latestRoundData() returns (uint80 r, int256 a, uint256, uint256 u, uint80 air) {
            return (r, a, u, air);
        } catch {
            revert Oracle__FeedCallFailed();
        }
    }
}
