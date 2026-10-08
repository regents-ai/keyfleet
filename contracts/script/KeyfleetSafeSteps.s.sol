// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";

/// @notice The Regents Safe's steps after the system is deployed: creating the five founding
/// fleets, moving the collection to its next phase, and giving the Regents Club keys.
/// @dev Each step is one call from the Safe, and each founding fleet is its own transaction, since
/// one creation uses about 10.4 million gas. Before anything leaves this script, every call is run
/// from the Safe's address against the chain's current state, in order, so a call that would revert
/// stops the step with the collection's or factory's own error.
///
/// On Base the steps are written, not sent: each call becomes its own file under
/// `deployments/safe/`, in the Safe Transaction Builder's batch format, for the Safe's signers to
/// load, check and sign. Nothing is signed or sent from here. On a local anvil chain the Safe is an
/// account anvil has unlocked and the calls are sent directly, from the Safe's address.
///
/// Moving to phase 1 opens Classic #1's sales and the Regents Club's gifts together, once all five
/// founding fleets exist, and phase 2 opens Syndicate, Accelerant and Cascade, at the second
/// `KEYFLEET_OPENS_AT` names (Unix time, in the future when the Safe's transaction lands), so the
/// phase step is run only when the founder says when sales open.
///
/// The Regents Club gifts are read from the Pass at the block the step runs on: key N goes to the
/// holder of Pass N, or to the claims contract when that holder is a contract that refuses the key
/// or Pass N has no holder, `CLUB_GIFT_BATCH` keys per call. A Pass that moves before its call lands
/// makes that call revert whole, and the step is run again. `KEYFLEET_CLUB_TO_CLAIMS`, a
/// comma-separated list of key numbers, sends those keys to the claims contract whoever holds their
/// Pass: for a holder contract that answers the check but refuses the real gift.
contract KeyfleetSafeSteps is KeyfleetManifest {
    /// @notice One call for the Safe to make.
    /// @param name What the call does, which also names its file.
    /// @param to The contract called.
    /// @param data The call data.
    struct SafeCall {
        string name;
        address to;
        bytes data;
    }

    /// @notice Regents Club keys given in one Safe call: about 13.2 million gas on Base.
    uint256 public constant CLUB_GIFT_BATCH = 80;

    /// @notice The step named by `KEYFLEET_STEP` is not `founding-fleets`, `advance-phase` or
    /// `club-gifts`.
    error UnknownStep(string step);

    /// @notice Runs the step named by `KEYFLEET_STEP` for the manifest named by `KEYFLEET_MANIFEST`,
    /// on the factory the deployment step's latest broadcast on this chain created.
    function run() external {
        string memory manifestName = vm.envString("KEYFLEET_MANIFEST");
        string memory step = vm.envString("KEYFLEET_STEP");
        Manifest memory manifest = readManifest(manifestName);
        KeyfleetFactory factory = readBroadcast().factory;

        SafeCall[] memory calls;
        if (_equal(step, "founding-fleets")) {
            calls = foundingFleetCalls(manifest, factory);
        } else if (_equal(step, "advance-phase")) {
            calls = advancePhaseCalls(manifest, factory, uint64(vm.envUint("KEYFLEET_OPENS_AT")));
        } else if (_equal(step, "club-gifts")) {
            calls = clubGiftCalls(manifest, factory, vm.envOr("KEYFLEET_CLUB_TO_CLAIMS", ",", new uint256[](0)));
        } else {
            revert UnknownStep(step);
        }

        if (block.chainid == ANVIL_CHAIN_ID) {
            _send(manifest.bindings.safe, calls);
        } else {
            _simulate(manifest.bindings.safe, calls);
            vm.createDir("deployments/safe", true);
            for (uint256 index = 0; index < calls.length; ++index) {
                vm.writeFile(
                    string.concat("deployments/safe/", manifestName, ".", calls[index].name, ".json"),
                    safeBatch(manifest.bindings.safe, calls[index])
                );
            }
        }
    }

    /// @notice The Safe's calls creating every founding fleet the collection does not have yet, in
    /// founding order, each with the manifest's deck and profile.
    function foundingFleetCalls(Manifest memory manifest, KeyfleetFactory factory)
        public
        view
        returns (SafeCall[] memory calls)
    {
        _requireManifestFitsChain(manifest);
        uint256 created = factory.KEYS().fleetCount();
        uint256 founding = manifest.founding.length;
        calls = new SafeCall[](created < founding ? founding - created : 0);
        for (uint256 index = 0; index < calls.length; ++index) {
            FoundingFleet memory fleet = manifest.founding[created + index];
            calls[index] = SafeCall({
                name: string.concat("founding-fleet-", vm.toString(created + index + 1)),
                to: address(factory),
                data: abi.encodeCall(
                    KeyfleetFactory.createFoundingFleet, (fleet.preset, fleet.deckHash, fleet.deckSize, fleet.profile)
                )
            });
        }
    }

    /// @notice The Safe's call moving the collection to its next phase, which opens at `opensAt`.
    function advancePhaseCalls(Manifest memory manifest, KeyfleetFactory factory, uint64 opensAt)
        public
        view
        returns (SafeCall[] memory calls)
    {
        _requireManifestFitsChain(manifest);
        KeyfleetKeys keys = factory.KEYS();
        calls = new SafeCall[](1);
        calls[0] = SafeCall({
            name: string.concat("phase-", vm.toString(keys.phase() + 1)),
            to: address(keys),
            data: abi.encodeCall(KeyfleetKeys.advancePhase, (opensAt))
        });
    }

    /// @notice The Safe's calls giving every Regents Club key not given yet, `CLUB_GIFT_BATCH` per
    /// call, each key to the holder of its Pass now, or to the claims contract when that holder is a
    /// contract that refuses it, Pass N has no holder, or `toClaims` names the key.
    function clubGiftCalls(Manifest memory manifest, KeyfleetFactory factory, uint256[] memory toClaims)
        public
        returns (SafeCall[] memory calls)
    {
        _requireManifestFitsChain(manifest);
        KeyfleetKeys keys = factory.KEYS();
        KeyfleetManager club = KeyfleetManager(keys.managerOf(factory.CLUB_CLAIMS().CLUB_FLEET()));
        uint256 first = club.totalMinted() + 1;
        uint256 left = KeyfleetPresets.CLUB_SUPPLY + 1 - first;
        calls = new SafeCall[]((left + CLUB_GIFT_BATCH - 1) / CLUB_GIFT_BATCH);
        for (uint256 index = 0; index < calls.length; ++index) {
            uint256 from = first + index * CLUB_GIFT_BATCH;
            uint256 to = from + CLUB_GIFT_BATCH - 1;
            if (to > KeyfleetPresets.CLUB_SUPPLY) to = KeyfleetPresets.CLUB_SUPPLY;
            address[] memory receivers = new address[](to + 1 - from);
            for (uint256 keyNumber = from; keyNumber <= to; ++keyNumber) {
                receivers[keyNumber - from] = _named(toClaims, keyNumber)
                    ? address(factory.CLUB_CLAIMS())
                    : clubReceiver(factory, club, keyNumber);
            }
            calls[index] = SafeCall({
                name: string.concat("club-gifts-", vm.toString(from), "-", vm.toString(to)),
                to: address(club),
                data: abi.encodeCall(KeyfleetManager.give, (receivers))
            });
        }
    }

    /// @notice Who receives Regents Club key `keyNumber` now: the holder of Pass `keyNumber`, or the
    /// claims contract when the Pass has no holder, burned or never minted, or the holder is a
    /// contract whose `onERC721Received`, asked as the collection asks it at a mint, does not answer
    /// with exactly its selector.
    function clubReceiver(KeyfleetFactory factory, KeyfleetManager club, uint256 keyNumber) public returns (address) {
        address holder;
        try factory.CLUB_PASS().ownerOf(keyNumber) returns (address owner) {
            holder = owner;
        } catch {
            return address(factory.CLUB_CLAIMS());
        }
        if (holder.code.length == 0) return holder;
        KeyfleetKeys keys = factory.KEYS();
        uint256 tokenId = keys.tokenIdOf(club.FLEET_ID(), keyNumber);
        bytes4 selector = IERC721Receiver.onERC721Received.selector;
        vm.prank(address(keys));
        (bool ok, bytes memory answer) =
            holder.call(abi.encodeWithSelector(selector, address(club), address(0), tokenId, ""));
        if (ok && answer.length >= 32 && abi.decode(answer, (bytes32)) == bytes32(selector)) return holder;
        return address(factory.CLUB_CLAIMS());
    }

    /// @notice One call as a Safe Transaction Builder batch file of one transaction, for the Safe
    /// at `safe` on this chain.
    function safeBatch(address safe, SafeCall memory call) public view returns (string memory) {
        return string.concat(
            "{\"version\":\"1.0\",\"chainId\":\"",
            vm.toString(block.chainid),
            "\",\"createdAt\":",
            vm.toString(vm.unixTime()),
            ",\"meta\":{\"name\":\"Keyfleet ",
            call.name,
            "\",\"description\":\"\",\"createdFromSafeAddress\":\"",
            vm.toString(safe),
            "\"},\"transactions\":[{\"to\":\"",
            vm.toString(call.to),
            "\",\"value\":\"0\",\"data\":\"",
            vm.toString(call.data),
            "\"}]}"
        );
    }

    /// @dev Runs every call from the Safe's address, in order, against this run's copy of the
    /// chain, and stops with the first call's own error.
    function _simulate(address safe, SafeCall[] memory calls) private {
        for (uint256 index = 0; index < calls.length; ++index) {
            vm.prank(safe);
            Address.functionCall(calls[index].to, calls[index].data);
        }
    }

    /// @dev Sends every call from the Safe's address, in order.
    function _send(address safe, SafeCall[] memory calls) private {
        for (uint256 index = 0; index < calls.length; ++index) {
            vm.broadcast(safe);
            Address.functionCall(calls[index].to, calls[index].data);
        }
    }

    /// @dev Whether `keyNumbers` names `keyNumber`.
    function _named(uint256[] memory keyNumbers, uint256 keyNumber) private pure returns (bool) {
        for (uint256 i = 0; i < keyNumbers.length; ++i) {
            if (keyNumbers[i] == keyNumber) return true;
        }
        return false;
    }
}
