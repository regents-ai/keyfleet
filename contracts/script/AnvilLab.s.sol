// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {V4PoolKey} from "../src/interfaces/IUniswapV4PoolManager.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {KeyfleetSystem} from "./KeyfleetSystem.sol";
import {MockAutolaunchFactory} from "../test/mocks/MockAutolaunchFactory.sol";
import {MockPoolManager} from "../test/mocks/MockPoolManager.sol";
import {MockRegent} from "../test/mocks/MockRegent.sol";
import {MockRegentRevenueStaking} from "../test/mocks/MockRegentRevenueStaking.sol";
import {MockToken} from "../test/mocks/MockToken.sol";
import {MockUniswapV3Pool} from "../test/mocks/MockUniswapV3Pool.sol";
import {MockVRFCoordinatorV2Plus} from "../test/mocks/MockVRFCoordinatorV2Plus.sol";
import {MockWeth} from "../test/mocks/MockWeth.sol";

/// @notice Puts the Keyfleet system with Classic #1 on a plain local anvil for the anvil tests in
/// `platform/`: the wallet buttons' steps and the rewards a key has waiting. Nothing here is for a
/// real network: the sender is an account anvil has unlocked, and no private key is read.
/// @dev Every outside contract is a local stand-in: USDC, WETH, REGENT, a USDC/WETH pool and a
/// WETH/REGENT pool manager at a fixed price where 1 USDC buys 1 REGENT, REGENT staking, the
/// Autolaunch factory, and a VRF coordinator whose subscription holds 0.1 ETH. The sender is the
/// Safe and the keeper. It runs in two steps, because the Safe must name a sales opening in the
/// future. `run` creates Classic #1 with a stand-in deck and moves the collection to phase 1, with
/// Classic #1's sales opening `OPENING` later. Once the chain's clock is past that, `sell` buys two
/// keys while the coordinator refuses every request, so neither key's reveal was ever accepted;
/// then the coordinator takes requests again, and it turns the treasury's booked USDC into REGENT
/// with one piece. The manager owes the protocol share of both sales, the treasury holds the REGENT
/// both bought, and the sender holds and has approved the USDC for a third key, for the test to buy.
contract AnvilLab is Script {
    /// @notice Where the lab's contracts are.
    struct Lab {
        address keys;
        address factory;
        address manager;
        address rewards;
        address shards;
        address votes;
        address treasury;
        address staking;
        address usdc;
        address regent;
    }

    bytes32 private constant KEY_HASH = keccak256("anvil lab key hash");
    bytes32 private constant TRAIT_TABLE = keccak256("anvil lab trait table");
    bytes32 private constant DECK = keccak256("anvil lab deck");
    uint256 private constant DECK_SIZE = 1000;
    /// @notice How long after `run` Classic #1's sales open.
    uint64 public constant OPENING = 1 minutes;

    /// @notice Builds the lab up to phase 1, broadcast from `--sender`, and returns where its
    /// contracts are.
    function run() external returns (Lab memory lab) {
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        MockToken usdc = new MockToken("Anvil Lab USDC", "USDC");
        MockRegent regent = new MockRegent();
        MockRegentRevenueStaking staking = new MockRegentRevenueStaking(usdc);
        MockVRFCoordinatorV2Plus vrf = new MockVRFCoordinatorV2Plus();
        uint256 subscriptionId = vrf.createSubscription();
        vrf.fundSubscriptionWithNative{value: 0.1 ether}(subscriptionId);

        KeyfleetFactory factory = KeyfleetSystem.deploy(
            KeyfleetSystem.Bindings({
                safe: sender,
                keeper: sender,
                staking: staking,
                autolaunch: new MockAutolaunchFactory(),
                collection: KeyfleetKeys.Collection({
                    name: "Keyfleet",
                    symbol: "KEYFLEET",
                    baseTokenURI: "http://localhost:4000/metadata/keys/",
                    contractURI: "http://localhost:4000/metadata/collection.json"
                }),
                randomness: KeyfleetKeys.Randomness({
                    coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
                }),
                traitTableHash: TRAIT_TABLE,
                route: _route(usdc, regent)
            })
        );
        KeyfleetKeys keys = factory.KEYS();
        vrf.addConsumer(subscriptionId, address(keys));

        factory.createFoundingFleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            DECK,
            DECK_SIZE,
            KeyfleetManager.Profile({name: "Classic #1", description: "", imageLink: ""})
        );
        keys.advancePhase(uint64(block.timestamp) + OPENING);
        KeyfleetManager classic = KeyfleetManager(keys.managerOf(1));

        uint256 start = classic.START_PRICE();
        uint256 prices = KeyfleetPresets.classicPrice(1, start) + KeyfleetPresets.classicPrice(2, start)
            + KeyfleetPresets.classicPrice(3, start);
        usdc.mint(sender, prices);
        usdc.approve(address(classic), prices);
        vm.stopBroadcast();

        lab = Lab({
            keys: address(keys),
            factory: address(factory),
            manager: address(classic),
            rewards: address(classic.REWARDS()),
            shards: address(factory.SHARDS()),
            votes: address(classic.VOTES()),
            treasury: address(classic.TREASURY()),
            staking: address(staking),
            usdc: address(usdc),
            regent: address(regent)
        });
    }

    /// @notice Buys keys 1 and 2 of Classic #1 for the sender with no reveal accepted, then turns the
    /// treasury's booked USDC into REGENT. Broadcast from the same `--sender` as `run`, once
    /// Classic #1's sales are open.
    function sell(KeyfleetManager classic) external {
        (IVRFCoordinatorV2Plus coordinator,,) = classic.KEYS().randomness();
        MockVRFCoordinatorV2Plus vrf = MockVRFCoordinatorV2Plus(address(coordinator));
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        vrf.setRevertAll(true);
        classic.purchase(sender, classic.nextPrice(), block.timestamp + 1 hours, new bytes32[](0));
        classic.purchase(sender, classic.nextPrice(), block.timestamp + 1 hours, new bytes32[](0));
        vrf.setRevertAll(false);
        classic.REGENT_BUYER().convert();
        vm.stopBroadcast();
    }

    /// @dev Stand-in pools at a fixed price, funded to pay out: one atomic USDC buys 4e8 wei of
    /// WETH, and one wei of WETH buys 2,500 atomic REGENT, so 1 USDC buys 1 REGENT.
    function _route(MockToken usdc, MockRegent regent) private returns (KeyfleetRegentBuyer.Route memory) {
        MockWeth weth = new MockWeth();
        MockUniswapV3Pool v3Pool = new MockUniswapV3Pool(address(usdc), address(weth), 4e8 * 1e18, 1e18 / 4e8);
        MockPoolManager poolManager = new MockPoolManager(address(weth), 2500e18, 1e18 / 2500);
        weth.mint(address(v3Pool), 1e36);
        regent.mint(address(poolManager), 1e45);
        return KeyfleetRegentBuyer.Route({
            usdc: address(usdc),
            weth: address(weth),
            regent: address(regent),
            v3Pool: address(v3Pool),
            poolManager: address(poolManager),
            v4Pool: V4PoolKey({
                currency0: address(weth), currency1: address(regent), fee: 0x800000, tickSpacing: 200, hooks: address(0)
            })
        });
    }
}
