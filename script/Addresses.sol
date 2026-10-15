// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Addresses
/// @notice Third-party addresses used by fork tests and deploy scripts. Never used by `src/`.
/// @dev Every value was verified (2026-10-14) from the sources below AND on-chain
///      (`description()`, `decimals()`, `latestRoundData()` / `name()`, `symbol()`, `decimals()`
///      via a read-only public RPC on the matching chain id). Do not edit from memory:
///      re-verify against the source before changing anything.
library Addresses {
    /*//////////////////////////////////////////////////////////////
                           ETHEREUM MAINNET (chain id 1)
    //////////////////////////////////////////////////////////////*/

    /// @dev Wrapped Ether (WETH9), 18 decimals.
    ///      Source: https://etherscan.io/token/0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
    ///      (verified source, name "Wrapped Ether", symbol "WETH").
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Circle USDC (proxy), 6 decimals.
    ///      Source: https://developers.circle.com/stablecoins/usdc-contract-addresses
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Chainlink ETH / USD proxy, 8 decimals. Registry path "eth-usd" (the standard,
    ///      NON-SVR feed). Source: Chainlink feed registry
    ///      https://reference-data-directory.vercel.app/feeds-mainnet.json
    ///      (the file behind https://docs.chain.link/data-feeds/price-feeds/addresses).
    ///      Beware: the registry also lists "Aave SVR" / "Shared SVR" variants of ETH / USD
    ///      (e.g. 0x5147eA64..., 0xd82562bb...). Those are NOT this feed.
    address internal constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// @dev Chainlink USDC / USD proxy, 8 decimals. Registry path "usdc-usd" (non-SVR).
    ///      Same source as above. The SVR variants (0xfB6471AC..., 0x84E04574...) are NOT this.
    address internal constant MAINNET_USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    /// @dev HEARTBEATS (seconds) are what the feed is configured to do at minimum: the registry
    ///      value, NOT a safe staleness bound (feeds are often a little late). Use the
    ///      `*_ORACLE_MAX_AGE` constants below as the `heartbeat` argument of `ChainlinkOracle`.
    ///
    ///      Verified 2026-10-15 (see docs/DESIGN.md section 2.3):
    ///      - Chainlink registry (reference-data-directory.vercel.app/feeds-mainnet.json):
    ///        ETH/USD 3600 s, USDC/USD 82800 s. data.chain.link shows only the deviation threshold
    ///        (ETH/USD 0.5%, USDC/USD 0.25%) and a live countdown, not the configured interval.
    ///      - Measured on-chain from each feed's own round history (the real update gaps):
    ///        ETH/USD, last 3000 rounds: median 3600 s, MAX 3744 s (4% late).
    ///        USDC/USD, phase 4 (since 2026-09-14): 82824..82836 s, i.e. 23 h + ~30 s;
    ///        USDC/USD, phase 3 (2024-06..2026-09): up to 86472 s, i.e. the earlier config was 24 h.
    uint256 internal constant MAINNET_ETH_USD_HEARTBEAT = 3600;
    uint256 internal constant MAINNET_USDC_USD_HEARTBEAT = 82_800;

    /// @dev Staleness bound to pass to `ChainlinkOracle` = heartbeat + a deliberate margin:
    ///      - ETH/USD: 3600 + 10 min = 4200 s (worst observed gap 3744 s: margin >= 456 s).
    ///      - USDC/USD: 86400 + 1 h = 90000 s. It covers BOTH the 24 h heartbeat this feed had
    ///        until 2026-09 and today's 23 h one, so a configuration change by Chainlink back to
    ///        24 h cannot make a healthy feed look stale. For a stablecoin that is acceptable;
    ///        a depeg also triggers a deviation update (0.25%), so the bound is not what protects
    ///        against price moves.
    uint256 internal constant MAINNET_ETH_USD_ORACLE_MAX_AGE =
        MAINNET_ETH_USD_HEARTBEAT + 10 minutes;
    uint256 internal constant MAINNET_USDC_USD_ORACLE_MAX_AGE = 86_400 + 1 hours;

    /*//////////////////////////////////////////////////////////////
                          SEPOLIA TESTNET (chain id 11155111)
    //////////////////////////////////////////////////////////////*/

    /// @dev Chainlink ETH / USD on Sepolia, 8 decimals. Source: Chainlink feed registry
    ///      https://reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia.json
    ///      (the registry has a second, `hidden` ETH / USD entry 0xD9d6f482...: NOT used).
    address internal constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    /// @dev Chainlink USDC / USD on Sepolia, 8 decimals. Same registry file.
    address internal constant SEPOLIA_USDC_USD_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    /// @dev Sepolia heartbeats from the registry (ETH/USD 3600 s, USDC/USD 86400 s). Measured on
    ///      Sepolia 2026-10-15: ETH/USD median 3636 s, max 3732 s (healthy). USDC/USD median 86424 s
    ///      BUT gaps of up to 413496 s (4.8 days): the Sepolia USDC/USD feed is NOT production
    ///      grade, so a market using it can legitimately revert with `Oracle__StalePrice` for days.
    ///      That is the oracle failing closed as designed, but for a testnet demo prefer a mock
    ///      USDC feed if you need uninterrupted borrowing.
    uint256 internal constant SEPOLIA_ETH_USD_HEARTBEAT = 3600;
    uint256 internal constant SEPOLIA_USDC_USD_HEARTBEAT = 86_400;

    uint256 internal constant SEPOLIA_ETH_USD_ORACLE_MAX_AGE =
        SEPOLIA_ETH_USD_HEARTBEAT + 10 minutes;
    uint256 internal constant SEPOLIA_USDC_USD_ORACLE_MAX_AGE = SEPOLIA_USDC_USD_HEARTBEAT
        + 1 hours;

    // NOTE: Sepolia WETH/USDC are intentionally absent. On Sepolia and locally the protocol
    // uses mock ERC20s (see test/mocks), so no third-party token address is needed.
}
