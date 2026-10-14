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

    /// @dev Documented heartbeats (seconds) from the same registry. The oracle's configured
    ///      bound should be heartbeat + a safety margin.
    uint256 internal constant MAINNET_ETH_USD_HEARTBEAT = 3600;
    uint256 internal constant MAINNET_USDC_USD_HEARTBEAT = 82_800;

    /*//////////////////////////////////////////////////////////////
                          SEPOLIA TESTNET (chain id 11155111)
    //////////////////////////////////////////////////////////////*/

    /// @dev Chainlink ETH / USD on Sepolia, 8 decimals. Source: Chainlink feed registry
    ///      https://reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia.json
    ///      (the registry has a second, `hidden` ETH / USD entry 0xD9d6f482...: NOT used).
    address internal constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    /// @dev Chainlink USDC / USD on Sepolia, 8 decimals. Same registry file.
    address internal constant SEPOLIA_USDC_USD_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    uint256 internal constant SEPOLIA_ETH_USD_HEARTBEAT = 3600;
    uint256 internal constant SEPOLIA_USDC_USD_HEARTBEAT = 86_400;

    // NOTE: Sepolia WETH/USDC are intentionally absent. On Sepolia and locally the protocol
    // uses mock ERC20s (see test/mocks), so no third-party token address is needed.
}
