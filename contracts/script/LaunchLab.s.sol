// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockStaking} from "../test/KeyfleetIncome.t.sol";
import {MockVRFCoordinatorV2Plus} from "../test/mocks/MockVRFCoordinatorV2Plus.sol";

/// @notice Puts one Classic fleet that may propose a launch on a local fork of a chain carrying the
/// Autolaunch v2 contracts, for the launch test in `platform/`, which then proposes, votes, bids
/// and settles the launch through the site's own steps and the keeper. Nothing here is for a real
/// network: the sender is an account the fork has unlocked, and no private key is read.
/// @dev The fleet pays in the chain's own USDC and REGENT, Base's, and launches through `factory`.
/// Its key reveals go to a stand-in VRF coordinator, because the fork need not carry Chainlink's;
/// reveals are not what the launch test covers. The sender must hold the USDC for the keys, and
/// buys every key a Classic fleet must sell before it may propose a launch.
contract LaunchLab is Script {
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;
    bytes32 private constant KEY_HASH = keccak256("launch lab key hash");
    bytes32 private constant TRAIT_TABLE = keccak256("launch lab trait table");

    /// @notice Builds the lab, broadcast from `--sender`, which owns the subscription and buys
    /// every key.
    function run(IRegentsAutolaunchFactoryV2 factory) external returns (address fleet) {
        uint256 keys = KeyfleetPresets.FLEET_TECH_AUTOLAUNCH_MIN_KEYS;

        vm.startBroadcast();
        MockVRFCoordinatorV2Plus vrf = new MockVRFCoordinatorV2Plus();
        uint256 subscriptionId = vrf.createSubscription();

        Keyfleet classic = new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            IERC20(USDC),
            IERC20(REGENT),
            new MockStaking(IERC20(USDC)),
            factory,
            Keyfleet.Metadata("Launch Lab Classic", "LLC", "https://keyfleet.ai/metadata/launch-lab/"),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)), subscriptionId: subscriptionId, keyHash: KEY_HASH
            }),
            TRAIT_TABLE
        );
        vrf.addConsumer(subscriptionId, address(classic));

        IERC20(USDC).approve(address(classic), keys * KeyfleetPresets.Q_USDC);
        for (uint256 i = 0; i < keys; ++i) {
            classic.purchase(address(0), KeyfleetPresets.Q_USDC, block.timestamp + 1 hours);
        }
        vm.stopBroadcast();

        return address(classic);
    }
}
