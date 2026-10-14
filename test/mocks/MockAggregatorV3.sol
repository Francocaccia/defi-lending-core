// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title MockAggregatorV3
/// @notice Fully controllable Chainlink aggregator for tests, the local demo and Sepolia.
/// @dev Not part of the protocol: lives in `test/` so it can never be confused with deployable
///      code. Every field of the round can be set independently to build malformed rounds.
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 public immutable override decimals;
    string public override description;
    uint256 public constant override version = 1;

    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    /// @notice When true, `latestRoundData()` reverts (simulates a broken/paused feed).
    bool public shouldRevert;

    constructor(uint8 decimals_, string memory description_, int256 initialAnswer) {
        decimals = decimals_;
        description = description_;
        setAnswer(initialAnswer);
    }

    /// @notice Publish a NEW well-formed round at the current block time.
    function setAnswer(int256 newAnswer) public {
        roundId += 1;
        answer = newAnswer;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
    }

    /// @notice Overwrite every field of the latest round (for malformed-round tests).
    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    /// @notice Change only the last-update timestamp (to simulate staleness).
    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function getRoundData(uint80)
        external
        pure
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("MockAggregatorV3: getRoundData unsupported");
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        require(!shouldRevert, "MockAggregatorV3: feed down");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
