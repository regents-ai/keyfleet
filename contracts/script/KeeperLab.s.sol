// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockStaking} from "../test/KeyfleetIncome.t.sol";
import {MockVRFCoordinatorV2Plus} from "../test/mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev A six-decimal stand-in for USDC, as a fleet requires, that mints to whoever asks.
contract KeeperLabUsdc is ERC20 {
    constructor() ERC20("Keeper Lab USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}

/// @dev An eighteen-decimal stand-in for REGENT.
contract KeeperLabRegent is ERC20 {
    constructor() ERC20("Keeper Lab REGENT", "REGENT") {}
}

/// @notice Puts one fleet on a plain local anvil for the keeper's external test in `platform/`,
/// which then drives the keeper against it. Nothing here is for a real network: the sender is an
/// account anvil has unlocked, and no private key is read.
/// @dev The fleet is a Classic fleet paying its protocol share to a stand-in staking contract, on
/// a stand-in VRF coordinator whose subscription holds 0.05 ETH. Two keys are sold while the
/// coordinator refuses every request, so neither key's reveal was ever accepted, and then the
/// coordinator takes requests again. The fleet owes the protocol share of both sales, and the
/// buyer holds and has approved the USDC for a third key, for the test to buy. The fleet's
/// Autolaunch factory holds no code, since the fleet never launches here.
contract KeeperLab is Script {
    bytes32 private constant KEY_HASH = keccak256("keeper lab key hash");
    bytes32 private constant TRAIT_TABLE = keccak256("keeper lab trait table");

    /// @notice Builds the lab, broadcast from `--sender`, which owns the subscription and buys
    /// both keys.
    function run() external returns (address fleet, address staking) {
        vm.startBroadcast();
        KeeperLabUsdc usdc = new KeeperLabUsdc();
        MockStaking mockStaking = new MockStaking(IERC20(address(usdc)));
        MockVRFCoordinatorV2Plus vrf = new MockVRFCoordinatorV2Plus();
        uint256 subscriptionId = vrf.createSubscription();
        vrf.fundSubscriptionWithNative{value: 0.05 ether}(subscriptionId);

        Keyfleet classic = new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            new KeeperLabRegent(),
            mockStaking,
            IRegentsAutolaunchFactoryV1(address(0xFAC7)),
            Keyfleet.Metadata("Keeper Lab Classic", "KLC", "https://keyfleet.ai/metadata/keeper-lab/"),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
            }),
            TRAIT_TABLE
        );
        vrf.addConsumer(subscriptionId, address(classic));

        usdc.mint(3 * KeyfleetPresets.Q_USDC);
        usdc.approve(address(classic), 3 * KeyfleetPresets.Q_USDC);
        vrf.setRevertAll(true);
        classic.purchase(address(0), KeyfleetPresets.Q_USDC, block.timestamp + 1 hours);
        classic.purchase(address(0), KeyfleetPresets.Q_USDC, block.timestamp + 1 hours);
        vrf.setRevertAll(false);
        vm.stopBroadcast();

        return (address(classic), address(mockStaking));
    }
}
