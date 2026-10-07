// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetStack} from "./KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockRegentRevenueStaking} from "../test/mocks/MockRegentRevenueStaking.sol";
import {MockRegent} from "../test/mocks/MockRegent.sol";
import {MockAutolaunchFactory} from "../test/mocks/MockAutolaunchFactory.sol";
import {MockVRFCoordinatorV2Plus} from "../test/mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev A six-decimal stand-in for USDC, as a fleet requires, that mints to whoever asks.
contract AnvilLabUsdc is ERC20 {
    constructor() ERC20("Anvil Lab USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}

/// @notice Puts one fleet on a plain local anvil: for the anvil tests in `platform/`, and for the
/// local lab where a person tries every wallet button against the real contracts. Nothing here is
/// for a real network: the sender is an account anvil has unlocked, and no private key is read.
/// @dev The fleet is a Classic fleet whose protocol share goes to a stand-in REGENT staking
/// contract, launching through a stand-in Autolaunch factory, on a stand-in VRF coordinator whose
/// subscription holds 0.1 ETH. Two keys are sold while the coordinator refuses every request, so
/// neither key's reveal was ever accepted, and then the coordinator takes requests again. The
/// fleet owes the protocol share of both sales, the buyer holds and has approved the USDC for a
/// third key, and the treasury holds 1 ETH, 500 REGENT and 500 USDC, enough of each for the daily
/// split. With `ANVIL_LAB_HOLDER` set, that wallet is given both keys, 1 ETH and 10,000 USDC.
contract AnvilLab is Script {
    bytes32 private constant KEY_HASH = keccak256("anvil lab key hash");
    bytes32 private constant TRAIT_TABLE = keccak256("anvil lab trait table");

    Keyfleet private classic;
    AnvilLabUsdc private usdc;
    MockRegent private regent;
    MockRegentRevenueStaking private regentStaking;
    MockAutolaunchFactory private autolaunch;

    /// @notice Builds the lab, broadcast from `--sender`, which owns the subscription and buys
    /// both keys, and returns where the fleet's five contracts and its stand-ins are.
    function run()
        external
        returns (
            address fleet,
            address rewards,
            address shards,
            address votes,
            address treasury,
            address staking,
            address usdcToken,
            address regentToken,
            address autolaunchFactory
        )
    {
        vm.startBroadcast();
        _deploy();
        _sellTwoKeys();
        _fundTreasury();
        address holder = vm.envOr("ANVIL_LAB_HOLDER", address(0));
        if (holder != address(0)) _give(holder);
        vm.stopBroadcast();

        return (
            address(classic),
            address(classic.REWARDS()),
            address(classic.SHARDS()),
            address(classic.VOTES()),
            address(classic.TREASURY()),
            address(regentStaking),
            address(usdc),
            address(regent),
            address(autolaunch)
        );
    }

    function _deploy() private {
        usdc = new AnvilLabUsdc();
        regent = new MockRegent();
        autolaunch = new MockAutolaunchFactory();
        MockVRFCoordinatorV2Plus vrf = new MockVRFCoordinatorV2Plus();
        regentStaking = new MockRegentRevenueStaking(usdc);
        uint256 subscriptionId = vrf.createSubscription();
        vrf.fundSubscriptionWithNative{value: 0.1 ether}(subscriptionId);

        classic = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            regentStaking,
            regent,
            autolaunch,
            Keyfleet.Metadata("Anvil Lab Classic", "ALC", "https://keyfleet.ai/metadata/anvil-lab/"),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
            }),
            TRAIT_TABLE
        );
        vrf.addConsumer(subscriptionId, address(classic));
    }

    function _sellTwoKeys() private {
        MockVRFCoordinatorV2Plus vrf = MockVRFCoordinatorV2Plus(address(classic.VRF_COORDINATOR()));
        usdc.mint(3 * KeyfleetPresets.Q_USDC);
        usdc.approve(address(classic), 3 * KeyfleetPresets.Q_USDC);
        vrf.setRevertAll(true);
        classic.purchase(address(0), KeyfleetPresets.Q_USDC, block.timestamp + 1 hours);
        classic.purchase(address(0), KeyfleetPresets.Q_USDC, block.timestamp + 1 hours);
        vrf.setRevertAll(false);
    }

    function _fundTreasury() private {
        address treasury = address(classic.TREASURY());
        payable(treasury).transfer(1 ether);
        regent.mint(treasury, 500 ether);
        usdc.mint(500 * 1e6);
        usdc.transfer(treasury, 500 * 1e6);
    }

    function _give(address holder) private {
        address sender = classic.ownerOf(1);
        classic.transferFrom(sender, holder, 1);
        classic.transferFrom(sender, holder, 2);
        payable(holder).transfer(1 ether);
        usdc.mint(10_000 * 1e6);
        usdc.transfer(holder, 10_000 * 1e6);
    }
}
