// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";

/// @notice Deploys one fleet's contracts in the order they bind to each other.
/// @dev The fleet is deployed first and given the addresses its voting controller and treasury
/// will have, which are the deployer's next two contract addresses; it deploys its ledger and
/// shard record itself. The controller and the treasury are then deployed by the same deployer, and
/// each refuses a fleet that does not name it, so a wrong prediction reverts the deployment. The
/// deployer is the broadcasting account inside a broadcast, and the calling contract otherwise.
/// The deployment scripts, the anvil lab and the suite all deploy through here.
library KeyfleetStack {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Deploys a fleet, then its voting controller, then its treasury.
    function deploy(
        KeyfleetPresets.Preset preset,
        IERC20 usdc,
        address protocolTreasury,
        Keyfleet.Metadata memory metadata,
        Keyfleet.Randomness memory randomness,
        bytes32 traitTableHash
    ) internal returns (Keyfleet fleet) {
        fleet = new Keyfleet(
            preset, usdc, protocolTreasury, metadata, randomness, traitTableHash, companionsOfNextFleet()
        );
        new KeyfleetVotes(fleet);
        new KeyfleetTreasury(fleet);
    }

    /// @notice Where the voting controller and the treasury of the fleet the deployer creates next
    /// will be: the deployer's second and third contract addresses from now.
    function companionsOfNextFleet() internal returns (Keyfleet.Companions memory) {
        address deployer = _deployer();
        uint64 nonce = VM.getNonce(deployer);
        return Keyfleet.Companions({
            votes: KeyfleetVotes(VM.computeCreateAddress(deployer, nonce + 1)),
            treasury: KeyfleetTreasury(VM.computeCreateAddress(deployer, nonce + 2))
        });
    }

    function _deployer() private returns (address) {
        (VmSafe.CallerMode mode, address sender,) = VM.readCallers();
        if (mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast) return sender;
        return address(this);
    }
}
