// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeployKeyfleets} from "../../script/DeployKeyfleets.s.sol";
import {IVRFProvingKeys} from "../../script/KeyfleetManifest.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";

/// @notice The coordinator's public table of accepted requests, which the vendored interface does
/// not declare.
interface IVRFRequestCommitments {
    function s_requestCommitments(uint256 requestId) external view returns (bytes32);
}

/// @dev A fleet against the real Chainlink VRF v2.5 coordinator on a fork of Ethereum. It runs
/// only when `ETHEREUM_RPC_URL` is set in the environment, and skips itself otherwise; the URL is never
/// printed. It proves that the real coordinator accepts the fleet's request on its exact terms,
/// that a fleet not yet on the subscription still sells, and that an answer delivered as the
/// coordinator delivers it fits the callback gas.
contract KeyfleetRevealEthereumForkTest is Test {
    address private constant BUYER = address(0xB0B0B0);
    bytes32 private constant TRAIT_TABLE = keccak256("trait table");
    bytes32 private constant RANDOM_WORDS_REQUESTED =
        keccak256("RandomWordsRequested(bytes32,uint256,uint256,uint256,uint16,uint32,uint32,bytes,address)");

    event RevealRequestFailed(uint256 indexed tokenId);
    event KeyRevealed(uint256 indexed tokenId, uint256 indexed requestId, bytes32 seed);

    IVRFCoordinatorV2Plus private coordinator;
    bytes32 private keyHash;
    IERC20Metadata private usdc;
    uint256 private subscriptionId;
    Keyfleet private fleet;

    function setUp() public {
        string memory rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        DeployKeyfleets script = new DeployKeyfleets();
        coordinator = IVRFCoordinatorV2Plus(script.ETHEREUM_VRF_COORDINATOR());
        keyHash = script.ETHEREUM_VRF_KEY_HASH();
        usdc = IERC20Metadata(script.ETHEREUM_USDC());

        subscriptionId = coordinator.createSubscription();
        vm.deal(address(this), 1 ether);
        coordinator.fundSubscriptionWithNative{value: 1 ether}(subscriptionId);

        fleet = new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            address(0x7EA5),
            Keyfleet.Metadata("Keyfleet Classic", "KEYFLEET", "https://keyfleet.ai/metadata/classic/"),
            Keyfleet.Randomness({coordinator: coordinator, subscriptionId: subscriptionId, keyHash: keyHash}),
            TRAIT_TABLE
        );
        deal(address(usdc), BUYER, 1_000_000e6);
        vm.prank(BUYER);
        usdc.approve(address(fleet), type(uint256).max);
    }

    function test_theEthereumGasLaneExists() public view {
        (bool exists,) = IVRFProvingKeys(address(coordinator)).s_provingKeys(keyHash);
        assertTrue(exists, "the 200 gwei gas lane is registered on the Ethereum coordinator");
    }

    /// @dev The fleet is sold before it is a consumer, then added, then retried, then answered.
    function test_theRealCoordinatorAcceptsTheRequestAndTheAnswerFits() public {
        vm.expectEmit(true, false, false, false, address(fleet));
        emit RevealRequestFailed(1);
        _buy();
        assertEq(fleet.ownerOf(1), BUYER, "a fleet not yet on the subscription still sells");

        coordinator.addConsumer(subscriptionId, address(fleet));
        vm.recordLogs();
        vm.cool(address(fleet));
        vm.cool(address(coordinator));
        uint256 retryGas = gasleft();
        fleet.requestReveal(1);
        console2.log("retried reveal request gas on the fork, cold:", retryGas - gasleft());
        uint256 requestId = _requestedId();
        assertTrue(
            IVRFRequestCommitments(address(coordinator)).s_requestCommitments(requestId) != bytes32(0),
            "the coordinator holds the request"
        );

        vm.recordLogs();
        _buy();
        assertTrue(
            IVRFRequestCommitments(address(coordinator)).s_requestCommitments(_requestedId()) != bytes32(0),
            "a purchase by a consumer is accepted too"
        );

        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256("an answer"));
        bytes32 seed =
            keccak256(abi.encode(fleet.TRAIT_SEED_TAG(), block.chainid, address(fleet), uint256(1), words[0]));
        vm.cool(address(fleet));
        vm.prank(address(coordinator));
        vm.expectEmit(true, true, false, true, address(fleet));
        emit KeyRevealed(1, requestId, seed);
        uint256 before = gasleft();
        fleet.rawFulfillRandomWords{gas: 100_000}(requestId, words);
        console2.log("reveal callback gas on the fork, cold:", before - gasleft());
        assertEq(fleet.revealSeed(1), seed, "the seed");
    }

    function _buy() private {
        vm.prank(BUYER);
        fleet.purchase(BUYER, type(uint256).max, block.timestamp);
    }

    /// @dev Reads the coordinator's own request event out of the recorded logs and checks its
    /// terms: the fleet's gas lane and subscription, three confirmations, 100,000 callback gas, one
    /// word, paid in ETH.
    function _requestedId() private returns (uint256 requestId) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(coordinator) || log.topics[0] != RANDOM_WORDS_REQUESTED) continue;
            assertEq(log.topics[1], keyHash, "gas lane");
            assertEq(uint256(log.topics[2]), subscriptionId, "subscription");
            assertEq(address(uint160(uint256(log.topics[3]))), address(fleet), "sender");
            (uint256 id,, uint16 confirmations, uint32 callbackGas, uint32 numWords, bytes memory extraArgs) =
                abi.decode(log.data, (uint256, uint256, uint16, uint32, uint32, bytes));
            assertEq(confirmations, 3, "confirmations");
            assertEq(callbackGas, 100_000, "callback gas");
            assertEq(numWords, 1, "one word");
            assertEq(extraArgs, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true), "paid in ETH");
            return id;
        }
        revert("no RandomWordsRequested from the coordinator");
    }
}
