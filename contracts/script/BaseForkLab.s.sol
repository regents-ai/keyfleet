// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "../test/mocks/MockVRFCoordinatorV2Plus.sol";
import {KeyfleetManifest} from "./KeyfleetManifest.sol";
import {KeyfleetSystem} from "./KeyfleetSystem.sol";
import {RecordKeyfleets} from "./RecordKeyfleets.s.sol";

/// @notice The Base-fork lab: the Keyfleet system on a local anvil fork of Base, run on chain
/// 31337, with Classic #1 selling, for the site on http://localhost:4097. No part of a release.
/// @dev Everything comes from the committed Base manifest, `deployments/base.json`: Base's own
/// USDC, the USDC→WETH v3 and WETH→REGENT v4 route, REGENT revenue staking, the Autolaunch factory,
/// the trait table and Classic #1's deck and profile. Only five things are the lab's own: the chain
/// id, the Safe (the broadcasting account, which anvil has unlocked), the keeper, the metadata
/// addresses on the local site, and a stand-in VRF coordinator, whose draws `fulfil` answers.
/// Every step refuses any chain but 31337, so nothing here can reach Base itself.
///
/// `deploy` broadcasts and writes nothing. `record` then reads the system back from the chain
/// through `RecordKeyfleets`, the release's own record step, and writes `RECORD_FILE` in the shape
/// of the release's deployed record. `script/base-fork-lab.sh` runs the three steps.
contract BaseForkLab is KeyfleetManifest {
    /// @notice The lab's deployed record, in the shape of `deployments/base.deployed.json`.
    string public constant RECORD_FILE = "deployments/base-fork-lab.json";
    /// @notice The deploy step's latest broadcast on the lab chain.
    string public constant BROADCAST_FILE = "broadcast/BaseForkLab.s.sol/31337/deploy-latest.json";
    /// @notice The local site the collection's metadata addresses point at.
    string public constant SITE = "http://localhost:4097";
    /// @notice What the stand-in subscription is funded with.
    uint256 public constant SUBSCRIPTION_FUNDS = 0.1 ether;
    /// @notice The gas cap the stand-in coordinator records for the manifest's gas lane.
    uint64 public constant PROVING_KEY_MAX_GAS = 2_500_000;
    /// @notice How long after the deploy Classic #1's sales open; `script/base-fork-lab.sh` then
    /// moves the lab chain's clock past it.
    uint64 public constant LAB_OPENING = 10 minutes;

    /// @notice Deploys the system, creates the five founding fleets and moves the collection to
    /// phase 2, so Classic #1 sells and the Regents Club opens from `LAB_OPENING` later. Broadcast from the account that is to be the Safe.
    /// @param keeper The wallet that records open fleets' decks and asks for card refreshes.
    function deploy(address keeper) external returns (KeyfleetFactory factory) {
        _requireLabChain();
        Manifest memory base = readManifest("base");

        vm.startBroadcast();
        (, address safe,) = vm.readCallers();
        MockVRFCoordinatorV2Plus coordinator = new MockVRFCoordinatorV2Plus();
        coordinator.addProvingKey(base.bindings.randomness.keyHash, PROVING_KEY_MAX_GAS);
        uint256 subscriptionId = coordinator.createSubscription();
        coordinator.fundSubscriptionWithNative{value: SUBSCRIPTION_FUNDS}(subscriptionId);

        Manifest memory manifest =
            labManifest(base, safe, keeper, IVRFCoordinatorV2Plus(address(coordinator)), subscriptionId);
        factory = KeyfleetSystem.deploy(manifest.bindings);
        KeyfleetKeys keys = factory.KEYS();
        coordinator.addConsumer(subscriptionId, address(keys));
        for (uint256 index = 0; index < manifest.founding.length; ++index) {
            FoundingFleet memory founding = manifest.founding[index];
            factory.createFoundingFleet(founding.preset, founding.deckHash, founding.deckSize, founding.profile);
        }
        keys.advancePhase(uint64(block.timestamp) + LAB_OPENING);
        keys.advancePhase(uint64(block.timestamp) + LAB_OPENING);
        vm.stopBroadcast();
    }

    /// @notice Reads the deploy step's broadcast and the system back from the chain, and writes
    /// `RECORD_FILE`.
    function record() external {
        vm.writeJson(recordOf(readManifest("base"), parseBroadcast(vm.readFile(BROADCAST_FILE))), RECORD_FILE);
    }

    /// @notice Answers every draw the stand-in coordinator still holds, with words made from each
    /// request's id. Broadcast from any unlocked account.
    function fulfil() external {
        _requireLabChain();
        string memory json = vm.readFile(RECORD_FILE);
        MockVRFCoordinatorV2Plus coordinator = MockVRFCoordinatorV2Plus(vm.parseJsonAddress(json, ".vrf.coordinator"));
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = MockVRFCoordinatorV2Plus.RandomWordsRequested.selector;
        Vm.EthGetLogs[] memory requests =
            vm.eth_getLogs(vm.parseJsonUint(json, ".deploymentBlock"), block.number, address(coordinator), topics);

        vm.startBroadcast();
        for (uint256 index = 0; index < requests.length; ++index) {
            (uint256 requestId,,,, uint32 numWords,) =
                abi.decode(requests[index].data, (uint256, uint256, uint16, uint32, uint32, bytes));
            (address consumer,) = coordinator.pending(requestId);
            if (consumer == address(0)) continue;
            uint256[] memory words = new uint256[](numWords);
            for (uint256 word = 0; word < numWords; ++word) {
                words[word] = uint256(keccak256(abi.encode(requestId, word)));
            }
            coordinator.fulfill(requestId, words);
        }
        vm.stopBroadcast();
    }

    /// @notice The lab's deployed record of the system the broadcast created.
    function recordOf(Manifest memory base, BroadcastSummary memory summary) public returns (string memory) {
        KeyfleetKeys keys = summary.factory.KEYS();
        (IVRFCoordinatorV2Plus coordinator, uint256 subscriptionId,) = keys.randomness();
        Manifest memory manifest = labManifest(base, keys.SAFE(), keys.keeper(), coordinator, subscriptionId);
        return new RecordKeyfleets().record(manifest, summary);
    }

    /// @notice Turns the Base manifest into the lab's, in place: the lab's chain, Safe, keeper,
    /// metadata addresses and coordinator.
    function labManifest(
        Manifest memory manifest,
        address safe,
        address keeper,
        IVRFCoordinatorV2Plus coordinator,
        uint256 subscriptionId
    ) public pure returns (Manifest memory) {
        manifest.chainId = ANVIL_CHAIN_ID;
        manifest.bindings.safe = safe;
        manifest.bindings.keeper = keeper;
        manifest.bindings.collection.baseTokenURI = string.concat(SITE, "/metadata/keys/");
        manifest.bindings.collection.contractURI = string.concat(SITE, "/metadata/collection.json");
        manifest.bindings.randomness.coordinator = coordinator;
        manifest.bindings.randomness.subscriptionId = subscriptionId;
        return manifest;
    }

    function _requireLabChain() private view {
        if (block.chainid != ANVIL_CHAIN_ID) revert WrongChain(ANVIL_CHAIN_ID, block.chainid);
    }
}
