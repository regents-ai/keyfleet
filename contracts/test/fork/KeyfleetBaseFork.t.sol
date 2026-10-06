// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeployKeyfleets} from "../../script/DeployKeyfleets.s.sol";
import {IVRFProvingKeys} from "../../script/KeyfleetManifest.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {KeyfleetStack} from "../../script/KeyfleetStack.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {IRegentRevenueStaking} from "../../src/interfaces/IRegentRevenueStaking.sol";

/// @notice The views and the pause of the deployed REGENT revenue staking contract this test reads
/// and, on the fork only, flips as its owner.
interface IRegentRevenueStakingViews {
    function totalUsdcReceived() external view returns (uint256);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function setPaused(bool paused) external;
}

/// @notice The coordinator's public table of accepted requests, which the vendored interface does
/// not declare.
interface IVRFRequestCommitments {
    function s_requestCommitments(uint256 requestId) external view returns (bytes32);
}

/// @dev A fleet against the real Base contracts on a fork of Base. It runs only when `BASE_RPC_URL`
/// is set in the environment, and skips itself otherwise; the URL is never printed. It reads the
/// pinned Base addresses (USDC, REGENT, REGENT staking, the VRF coordinator and its gas lanes), and
/// proves that the real coordinator accepts the fleet's request on its exact terms, that a fleet
/// not yet on the subscription still sells, that an answer delivered as the coordinator
/// delivers it fits the callback gas, and that the protocol share is deposited into the real
/// REGENT staking contract and waits, owed, while staking is paused.
contract KeyfleetBaseForkTest is Test {
    address private constant BUYER = address(0xB0B0B0);
    bytes32 private constant TRAIT_TABLE = keccak256("trait table");
    bytes32 private constant USDC_REVENUE_DEPOSITED =
        keccak256("USDCRevenueDeposited(uint256,uint256,uint256,uint8,address,bytes32,bytes32)");
    bytes32 private constant RANDOM_WORDS_REQUESTED =
        keccak256("RandomWordsRequested(bytes32,uint256,uint256,uint256,uint16,uint32,uint32,bytes,address)");

    event RevealRequestFailed(uint256 indexed tokenId);
    event KeyRevealed(uint256 indexed tokenId, uint256 indexed requestId, bytes32 seed);

    DeployKeyfleets private script;
    IVRFCoordinatorV2Plus private coordinator;
    bytes32 private keyHash;
    IERC20Metadata private usdc;
    IRegentRevenueStakingViews private staking;
    uint256 private subscriptionId;
    Keyfleet private fleet;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        script = new DeployKeyfleets();
        coordinator = IVRFCoordinatorV2Plus(script.BASE_VRF_COORDINATOR());
        keyHash = script.BASE_VRF_KEY_HASH_2_GWEI();
        usdc = IERC20Metadata(script.BASE_USDC());
        staking = IRegentRevenueStakingViews(script.BASE_REGENT_REVENUE_STAKING());

        subscriptionId = coordinator.createSubscription();
        vm.deal(address(this), 1 ether);
        coordinator.fundSubscriptionWithNative{value: 1 ether}(subscriptionId);

        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            IRegentRevenueStaking(address(staking)),
            Keyfleet.Metadata("Keyfleet Classic", "KEYFLEET", "https://keyfleet.ai/metadata/classic/"),
            Keyfleet.Randomness({coordinator: coordinator, subscriptionId: subscriptionId, keyHash: keyHash}),
            TRAIT_TABLE
        );
        deal(address(usdc), BUYER, 1_000_000e6);
        vm.prank(BUYER);
        usdc.approve(address(fleet), type(uint256).max);
    }

    function test_theBaseGasLanesExist() public view {
        (bool exists,) = IVRFProvingKeys(address(coordinator)).s_provingKeys(keyHash);
        assertTrue(exists, "the 2 gwei gas lane is registered on the Base coordinator");
        (exists,) = IVRFProvingKeys(address(coordinator)).s_provingKeys(script.BASE_VRF_KEY_HASH_30_GWEI());
        assertTrue(exists, "the 30 gwei gas lane is registered on the Base coordinator");
    }

    function test_thePinnedBaseTokensAndStakingAreLive() public view {
        assertEq(block.chainid, script.BASE_CHAIN_ID(), "a fork of Base");
        assertEq(usdc.decimals(), 6, "USDC has 6 decimals");
        assertEq(IERC20Metadata(script.BASE_REGENT()).decimals(), 18, "REGENT has 18 decimals");
        assertGt(script.BASE_REGENT_REVENUE_STAKING().code.length, 0, "REGENT staking is deployed");
        assertGt(script.BASE_REGENTS_SAFE().code.length, 0, "the Regents Safe is deployed");
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

    /// @dev The real staking contract takes the deposit through `depositUSDC`, tagged and from this
    /// fleet, and the treasury's approval ends at zero. While its owner, the Regents Safe, has it
    /// paused, the send reverts, the share stays owed in the fleet and keys still sell.
    function test_theProtocolShareIsDepositedIntoTheRealStaking() public {
        _buy();
        _buy();
        uint256 owed = fleet.protocolShareOwed();
        assertEq(owed, (KeyfleetPresets.classicPrice(1) + KeyfleetPresets.classicPrice(2)) / 10, "10% of each sale");
        assertFalse(staking.paused(), "staking takes deposits on the fork");
        assertEq(staking.owner(), script.BASE_REGENTS_SAFE(), "the Regents Safe owns staking");

        uint256 receivedBefore = staking.totalUsdcReceived();
        uint256 stakingBalanceBefore = usdc.balanceOf(address(staking));
        vm.recordLogs();
        vm.cool(address(fleet));
        vm.cool(address(fleet.TREASURY()));
        vm.cool(address(staking));
        uint256 before = gasleft();
        assertEq(fleet.sendProtocolShare(), owed, "the whole owed share");
        console2.log("protocol share deposit gas on the fork, cold:", before - gasleft());

        assertEq(staking.totalUsdcReceived() - receivedBefore, owed, "staking counts it as revenue");
        assertEq(usdc.balanceOf(address(staking)) - stakingBalanceBefore, owed, "and holds it");
        assertEq(usdc.allowance(address(fleet.TREASURY()), address(staking)), 0, "the approval ends at zero");
        assertEq(fleet.protocolShareOwed(), 0, "nothing is owed");
        _assertDepositEvent(owed);

        vm.prank(script.BASE_REGENTS_SAFE());
        staking.setPaused(true);
        _buy();
        uint256 owedWhilePaused = fleet.protocolShareOwed();
        assertGt(owedWhilePaused, 0, "a key sells while staking is paused");
        vm.expectRevert();
        fleet.sendProtocolShare();
        assertEq(fleet.protocolShareOwed(), owedWhilePaused, "the share stays owed in the fleet");
        assertEq(usdc.balanceOf(address(fleet)), owedWhilePaused, "and held by it");
    }

    /// @dev Staking's own revenue event names the fleet's treasury as the depositor, the Keyfleet
    /// protocol share tag and the fleet as the source.
    function _assertDepositEvent(uint256 amount) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(staking) || log.topics[0] != USDC_REVENUE_DEPOSITED) continue;
            assertEq(address(uint160(uint256(log.topics[2]))), address(fleet.TREASURY()), "the treasury deposited");
            assertEq(log.topics[3], bytes32(uint256(uint160(address(fleet)))), "for this fleet");
            (uint256 deposited,,, bytes32 tag) = abi.decode(log.data, (uint256, uint256, uint256, bytes32));
            assertEq(deposited, amount, "the whole owed share");
            assertEq(tag, fleet.TREASURY().PROTOCOL_SHARE_TAG(), "tagged as a protocol share");
            return;
        }
        revert("no USDCRevenueDeposited from staking");
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
