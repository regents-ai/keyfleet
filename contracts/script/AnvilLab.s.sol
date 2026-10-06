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

/// @notice Puts one fleet on a plain local anvil for the anvil tests in `platform/`: the wallet
/// buttons' steps and the rewards a key has waiting. Nothing here is for a real network: the
/// sender is an account anvil has unlocked, and no private key is read.
/// @dev The fleet is a Classic fleet whose protocol share goes to a stand-in REGENT staking
/// contract, on a stand-in VRF coordinator whose subscription holds 0.1 ETH. Two keys are sold while the
/// coordinator refuses every request, so neither key's reveal was ever accepted, and then the
/// coordinator takes requests again. The fleet owes the protocol share of both sales, and the
/// buyer holds and has approved the USDC for a third key, for the test to buy.
contract AnvilLab is Script {
    bytes32 private constant KEY_HASH = keccak256("anvil lab key hash");
    bytes32 private constant TRAIT_TABLE = keccak256("anvil lab trait table");

    /// @notice Builds the lab, broadcast from `--sender`, which owns the subscription and buys
    /// both keys.
    function run() external returns (address fleet, address staking, address shards) {
        vm.startBroadcast();
        AnvilLabUsdc usdc = new AnvilLabUsdc();
        MockVRFCoordinatorV2Plus vrf = new MockVRFCoordinatorV2Plus();
        MockRegentRevenueStaking regentStaking = new MockRegentRevenueStaking(usdc);
        uint256 subscriptionId = vrf.createSubscription();
        vrf.fundSubscriptionWithNative{value: 0.1 ether}(subscriptionId);

        Keyfleet classic = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            regentStaking,
            new MockRegent(),
            Keyfleet.Metadata("Anvil Lab Classic", "ALC", "https://keyfleet.ai/metadata/anvil-lab/"),
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

        return (address(classic), address(regentStaking), address(classic.SHARDS()));
    }
}
