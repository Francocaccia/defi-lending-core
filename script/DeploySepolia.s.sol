// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {ChainlinkOracle} from "../src/oracle/ChainlinkOracle.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {InterestRateModel} from "../src/libraries/InterestRateModel.sol";
import {RiskMath} from "../src/libraries/RiskMath.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Addresses} from "./Addresses.sol";

/// @title DeploySepolia
/// @notice OPTIONAL testnet deployment. Uses the REAL Chainlink ETH/USD and USDC/USD feeds on
///         Sepolia (addresses in `Addresses.sol`, sourced from Chainlink's registry) and MOCK
///         WETH / USDC tokens (open `mint`, worthless): the point is to exercise the oracle
///         wrapper and the market against a live feed, never to hold value.
///
///         Safety rules for this script:
///           - Sepolia only: it refuses to run on any other chain id.
///           - Throwaway key only: set `PRIVATE_KEY` in `.env` to a FRESH wallet funded from a
///             faucet. Never reuse a key that has ever held real funds. The key is read from the
///             environment and is never printed or written anywhere.
///
///         Run (see README for verification):
///           forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
///         Dry run (simulation only, nothing is sent): omit `--broadcast`.
contract DeploySepolia is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    // Heartbeat = documented feed heartbeat + a safety margin (feeds may be a little late).
    uint256 internal constant ETH_HEARTBEAT = Addresses.SEPOLIA_ETH_USD_HEARTBEAT + 10 minutes;
    uint256 internal constant USDC_HEARTBEAT = Addresses.SEPOLIA_USDC_USD_HEARTBEAT + 1 hours;

    function run() external returns (LendingMarket market) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "DeploySepolia: Sepolia only");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockERC20 weth = new MockERC20("Mock Wrapped Ether", "mWETH", 18);
        MockERC20 usdc = new MockERC20("Mock USD Coin", "mUSDC", 6);

        ChainlinkOracle ethOracle = new ChainlinkOracle(
            AggregatorV3Interface(Addresses.SEPOLIA_ETH_USD_FEED), ETH_HEARTBEAT
        );
        ChainlinkOracle usdcOracle = new ChainlinkOracle(
            AggregatorV3Interface(Addresses.SEPOLIA_USDC_USD_FEED), USDC_HEARTBEAT
        );

        market = new LendingMarket(
            LendingMarket.MarketParams({
                collateralToken: IERC20Metadata(address(weth)),
                borrowToken: IERC20Metadata(address(usdc)),
                collateralOracle: IOracle(address(ethOracle)),
                borrowOracle: IOracle(address(usdcOracle)),
                rate: InterestRateModel.Params({
                    baseRate: 0, slope1: 0.04e18, slope2: 0.75e18, optimalUtilization: 0.8e18
                }),
                risk: RiskMath.RiskParams({
                    maxLtv: 0.75e18,
                    liquidationThreshold: 0.8e18,
                    liquidationBonus: 0.05e18,
                    closeFactor: 0.5e18
                })
            })
        );

        // Play money for the deployer so the market can be tried right away.
        weth.mint(deployer, 100e18);
        usdc.mint(deployer, 1_000_000e6);

        vm.stopBroadcast();

        // Sanity check AFTER deployment: the live feeds must be readable and fresh. If a feed is
        // stale or wrong, this reverts and tells you before you try to use the market.
        uint256 ethPrice = ethOracle.price();
        uint256 usdcPrice = usdcOracle.price();
        require(ethPrice > 0 && usdcPrice > 0, "DeploySepolia: oracle sanity check failed");

        console.log("deployer          ", deployer);
        console.log("market            ", address(market));
        console.log("mock WETH         ", address(weth));
        console.log("mock USDC         ", address(usdc));
        console.log("ETH oracle        ", address(ethOracle));
        console.log("USDC oracle       ", address(usdcOracle));
        console.log("live ETH/USD (1e18)", ethPrice);
        console.log("live USDC/USD (1e18)", usdcPrice);
    }
}
