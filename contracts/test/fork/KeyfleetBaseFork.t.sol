// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {DeployKeyfleets} from "../../script/DeployKeyfleets.s.sol";
import {IVRFProvingKeys, KeyfleetManifest} from "../../script/KeyfleetManifest.sol";
import {KeyfleetSafeSteps} from "../../script/KeyfleetSafeSteps.s.sol";

/// @notice The views and the pause of the deployed REGENT revenue staking contract the fork tests
/// read and, on the fork only, flip as its owner.
interface IRegentRevenueStakingViews {
    function totalUsdcReceived() external view returns (uint256);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function setPaused(bool paused) external;
}

/// @notice The coordinator's public table of accepted requests, which the vendored interface does
/// not declare.
interface IVRFRequestCommitments {
    // forge-lint: disable-next-line(mixed-case-function)
    function s_requestCommitments(uint256 requestId) external view returns (bytes32);
}

/// @dev The Keyfleet system on a fork of Base, deployed the way the release deploys it: the
/// committed Base manifest through `DeployKeyfleets.deploy`, then the Regents Safe's own calls from
/// `KeyfleetSafeSteps`, made from the Safe's address on the fork. The manifest's keeper and VRF
/// subscription are still blank in the committed file, so a test keeper is written in and the test
/// creates and funds its own subscription on the real coordinator; the collection is not added to it
/// until a test does so. Everything runs in the local EVM only: nothing is sent to Base.
///
/// A fork test runs only when `BASE_RPC_URL` is set in the environment and skips itself otherwise;
/// the URL is never printed.
abstract contract KeyfleetForkFixture is Test {
    /// @dev The keeper the tests name; the committed manifest leaves it blank until release.
    address internal constant KEEPER = address(0x4EE9E4);

    DeployKeyfleets internal script;
    KeyfleetSafeSteps internal safeSteps;
    IVRFCoordinatorV2Plus internal coordinator;
    uint256 internal subscriptionId;
    IERC20Metadata internal usdc;
    IERC20Metadata internal regent;
    KeyfleetFactory internal factory;
    KeyfleetKeys internal keys;

    /// @dev Forks Base at `forkBlock`, or at its latest block when zero, and deploys the system from
    /// the committed Base manifest. Skips the test and returns false when `BASE_RPC_URL` is unset.
    function _setUpFork(uint256 forkBlock) internal returns (bool forked) {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        script = new DeployKeyfleets();
        safeSteps = new KeyfleetSafeSteps();
        coordinator = IVRFCoordinatorV2Plus(script.BASE_VRF_COORDINATOR());
        usdc = IERC20Metadata(script.BASE_USDC());
        regent = IERC20Metadata(script.BASE_REGENT());

        subscriptionId = coordinator.createSubscription();
        vm.deal(address(this), 1 ether);
        coordinator.fundSubscriptionWithNative{value: 1 ether}(subscriptionId);

        factory = script.deploy(_manifest());
        keys = factory.KEYS();
        return true;
    }

    /// @dev The committed Base manifest with the test keeper and the test's subscription written in.
    function _manifest() internal view returns (KeyfleetManifest.Manifest memory manifest) {
        manifest = script.readManifest("base");
        manifest.bindings.keeper = KEEPER;
        manifest.bindings.randomness.subscriptionId = subscriptionId;
    }

    /// @dev Makes the first `count` founding-fleet calls the Safe step builds, from the Safe.
    function _found(uint256 count) internal {
        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.foundingFleetCalls(_manifest(), factory);
        for (uint256 i = 0; i < count; ++i) {
            _asSafe(calls[i]);
        }
    }

    /// @dev Makes the Safe step's call moving the collection to its next phase, opening a second
    /// from now, from the Safe, and waits for that second.
    function _advancePhase() internal {
        _asSafe(safeSteps.advancePhaseCalls(_manifest(), factory, uint64(block.timestamp + 1))[0]);
        vm.warp(block.timestamp + 1);
    }

    function _asSafe(KeyfleetSafeSteps.SafeCall memory call) internal {
        address safe = script.BASE_REGENTS_SAFE();
        vm.prank(safe);
        Address.functionCall(call.to, call.data);
    }

    /// @dev The manager of fleet `fleetId`.
    function _fleet(uint256 fleetId) internal view returns (KeyfleetManager) {
        return KeyfleetManager(keys.managerOf(fleetId));
    }

    /// @dev The token id of key `keyNumber` of `fleet`.
    function _key(KeyfleetManager fleet, uint256 keyNumber) internal view returns (uint256) {
        return keys.tokenIdOf(fleet.FLEET_ID(), keyNumber);
    }

    /// @dev Gives `buyer` exactly the next key's price in USDC and approves `fleet` for it.
    function _fund(KeyfleetManager fleet, address buyer) internal returns (uint256 price) {
        price = fleet.nextPrice();
        deal(address(usdc), buyer, price);
        vm.prank(buyer);
        usdc.approve(address(fleet), price);
    }

    /// @dev `buyer` buys the next key of `fleet` for itself at exactly its price.
    function _buy(KeyfleetManager fleet, address buyer) internal returns (uint256 tokenId) {
        uint256 price = _fund(fleet, buyer);
        vm.prank(buyer);
        tokenId = fleet.purchase(buyer, price, block.timestamp, new bytes32[](0));
    }

    function _one(KeyfleetTreasury.Call memory call) internal pure returns (KeyfleetTreasury.Call[] memory calls) {
        calls = new KeyfleetTreasury.Call[](1);
        calls[0] = call;
    }

    function _ids(uint256 tokenId) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    /// @dev Moves time to the end of `fleet`'s 7-day opening, when a proposal may move money. Key 1,
    /// bought when sales opened, is then past its wait and its automatic presence.
    function _openTreasury(KeyfleetManager fleet) internal {
        uint256 opensAt = fleet.VOTES().treasuryOpensAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);
    }

    /// @dev Key 1's owner proposes `calls` and votes Yes; nobody else is present, so it is approved
    /// once it closes a second later.
    function _approve(KeyfleetManager fleet, KeyfleetTreasury.Call[] memory calls)
        internal
        returns (uint256 proposalId)
    {
        KeyfleetVotes votes = fleet.VOTES();
        uint256 first = _key(fleet, 1);
        address author = keys.ownerOf(first);
        vm.startPrank(author);
        proposalId = votes.propose(first, keccak256("narrative"), calls);
        votes.castBallot(proposalId, _ids(first), KeyfleetVotes.Choice.Yes);
        vm.stopPrank();
    }

    /// @dev Passes `calls` and carries them out.
    function _execute(KeyfleetManager fleet, KeyfleetTreasury.Call[] memory calls) internal {
        uint256 proposalId = _approve(fleet, calls);
        KeyfleetVotes votes = fleet.VOTES();
        vm.warp(votes.executableAt(proposalId));
        votes.execute(proposalId, calls);
    }
}

/// @dev Fleet 1, Classic #1, against the real Base contracts on a fork of Base. It proves that the
/// real coordinator accepts the collection's reveal request on its exact terms, that a key sells
/// while the collection is not yet on the subscription, that an answer delivered as the coordinator
/// delivers it fits the callback gas, and that the protocol share is deposited into the real REGENT
/// staking contract and waits, owed, while staking is paused.
contract KeyfleetBaseForkTest is KeyfleetForkFixture {
    address private constant BUYER = address(0xB0B0B0);
    bytes32 private constant USDC_REVENUE_DEPOSITED =
        keccak256("USDCRevenueDeposited(uint256,uint256,uint256,uint8,address,bytes32,bytes32)");
    bytes32 private constant RANDOM_WORDS_REQUESTED =
        keccak256("RandomWordsRequested(bytes32,uint256,uint256,uint256,uint16,uint32,uint32,bytes,address)");

    IRegentRevenueStakingViews private staking;
    KeyfleetManager private classic;

    function setUp() public {
        if (!_setUpFork(0)) return;
        staking = IRegentRevenueStakingViews(script.BASE_REGENT_REVENUE_STAKING());
        _found(1);
        _advancePhase();
        classic = _fleet(1);
    }

    function test_theBaseGasLanesExist() public view {
        (bool exists,) = IVRFProvingKeys(address(coordinator)).s_provingKeys(script.BASE_VRF_KEY_HASH_2_GWEI());
        assertTrue(exists, "the 2 gwei gas lane is registered on the Base coordinator");
        (exists,) = IVRFProvingKeys(address(coordinator)).s_provingKeys(script.BASE_VRF_KEY_HASH_30_GWEI());
        assertTrue(exists, "the 30 gwei gas lane is registered on the Base coordinator");
    }

    /// @dev Every Base pin holds the contract it names, and the system deployed from the committed
    /// manifest carries them.
    function test_thePinnedBaseContractsAreLiveAndCarried() public view {
        assertEq(block.chainid, script.BASE_CHAIN_ID(), "a fork of Base");
        assertEq(usdc.decimals(), 6, "USDC has 6 decimals");
        assertEq(regent.decimals(), 18, "REGENT has 18 decimals");
        assertEq(IERC20Metadata(script.BASE_WETH()).decimals(), 18, "WETH has 18 decimals");
        address[7] memory pinned = [
            script.BASE_REGENT_REVENUE_STAKING(),
            script.BASE_REGENTS_SAFE(),
            script.BASE_AUTOLAUNCH_FACTORY(),
            script.BASE_VRF_COORDINATOR(),
            script.BASE_USDC_WETH_POOL(),
            script.BASE_POOL_MANAGER(),
            script.BASE_REGENT_POOL_HOOKS()
        ];
        for (uint256 i = 0; i < pinned.length; ++i) {
            assertGt(pinned[i].code.length, 0, "every pinned contract is deployed");
        }

        assertEq(keys.SAFE(), script.BASE_REGENTS_SAFE(), "the Regents Safe runs the collection");
        (IVRFCoordinatorV2Plus vrfCoordinator,, bytes32 keyHash) = keys.randomness();
        assertEq(address(vrfCoordinator), address(coordinator), "the Base coordinator");
        assertEq(keyHash, script.BASE_VRF_KEY_HASH_2_GWEI(), "the 2 gwei lane");
        assertEq(address(factory.REGENT_STAKING()), address(staking), "REGENT staking");
        assertEq(address(factory.AUTOLAUNCH()), script.BASE_AUTOLAUNCH_FACTORY(), "the Autolaunch factory");
        KeyfleetRegentBuyer buyer = factory.REGENT_BUYER();
        assertEq(address(buyer.V3_POOL()), script.BASE_USDC_WETH_POOL(), "the v3 pool");
        assertEq(address(buyer.POOL_MANAGER()), script.BASE_POOL_MANAGER(), "the PoolManager");
        assertEq(keys.fleetCount(), 1, "Classic #1 founded by the Safe's call");
        assertEq(keys.phase(), 1, "and opened by its phase call");
        assertTrue(keys.salesOpen(1), "Classic #1 sells");
    }

    /// @dev Key 1 is sold before the collection is a consumer, then the collection is added, the
    /// request is retried, and answered; key 2 sold by a consumer is accepted straight away.
    function test_theRealCoordinatorAcceptsTheRequestAndTheAnswerFits() public {
        uint256 first = _key(classic, 1);
        uint256 price = _fund(classic, BUYER);
        vm.expectEmit(true, false, false, false, address(keys));
        emit KeyfleetKeys.RevealRequestFailed(first);
        vm.prank(BUYER);
        classic.purchase(BUYER, price, block.timestamp, new bytes32[](0));
        assertEq(keys.ownerOf(first), BUYER, "a collection not yet on the subscription still sells");
        assertEq(keys.revealRequestedAt(first), 0, "and its key waits for a request");

        coordinator.addConsumer(subscriptionId, address(keys));
        vm.recordLogs();
        vm.cool(address(keys));
        vm.cool(address(coordinator));
        uint256 retryGas = gasleft();
        keys.requestReveal(first);
        console2.log("retried reveal request gas on the fork, cold:", retryGas - gasleft());
        uint256 requestId = _requestedId(first);
        assertTrue(
            IVRFRequestCommitments(address(coordinator)).s_requestCommitments(requestId) != bytes32(0),
            "the coordinator holds the request"
        );
        assertEq(keys.revealRequestedAt(first), block.timestamp, "and the collection records it");

        price = _fund(classic, BUYER);
        vm.recordLogs();
        vm.prank(BUYER);
        uint256 second = classic.purchase(BUYER, price, block.timestamp, new bytes32[](0));
        assertTrue(
            IVRFRequestCommitments(address(coordinator)).s_requestCommitments(_requestedId(second)) != bytes32(0),
            "a purchase by a consumer is accepted too"
        );

        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256("an answer"));
        bytes32 seed = keccak256(abi.encode(keys.TRAIT_SEED_TAG(), block.chainid, address(keys), first, words[0]));
        uint256 callbackGas = keys.REVEAL_CALLBACK_GAS_LIMIT();
        vm.cool(address(keys));
        vm.prank(address(coordinator));
        vm.expectEmit(true, true, true, true, address(keys));
        emit KeyfleetKeys.KeyRevealed(first, 1, 1, requestId, seed);
        uint256 before = gasleft();
        keys.rawFulfillRandomWords{gas: callbackGas}(requestId, words);
        console2.log("reveal callback gas on the fork, cold:", before - gasleft());
        assertEq(keys.revealSeed(first), seed, "the seed");
    }

    /// @dev The real staking contract takes the deposit through `depositUSDC`, tagged and naming the
    /// fleet's manager, from the fleet's treasury, whose approval ends at zero. While its owner, the
    /// Regents Safe, has it paused, the send reverts, the share stays owed in the manager and keys
    /// still sell.
    function test_theProtocolShareIsDepositedIntoTheRealStaking() public {
        uint256 owed = classic.quote().protocol;
        _buy(classic, BUYER);
        owed += classic.quote().protocol;
        _buy(classic, BUYER);
        assertEq(classic.protocolShareOwed(), owed, "10% of each sale");
        assertFalse(staking.paused(), "staking takes deposits on the fork");
        assertEq(staking.owner(), script.BASE_REGENTS_SAFE(), "the Regents Safe owns staking");

        KeyfleetTreasury treasury = classic.TREASURY();
        uint256 receivedBefore = staking.totalUsdcReceived();
        uint256 stakingBalanceBefore = usdc.balanceOf(address(staking));
        vm.recordLogs();
        vm.cool(address(classic));
        vm.cool(address(treasury));
        vm.cool(address(staking));
        uint256 before = gasleft();
        uint256 sent = classic.sendProtocolShare();
        console2.log("protocol share deposit gas on the fork, cold:", before - gasleft());
        assertEq(sent, owed, "the whole owed share");

        assertEq(staking.totalUsdcReceived() - receivedBefore, owed, "staking counts it as revenue");
        assertEq(usdc.balanceOf(address(staking)) - stakingBalanceBefore, owed, "and holds it");
        assertEq(usdc.allowance(address(treasury), address(staking)), 0, "the approval ends at zero");
        assertEq(usdc.balanceOf(address(treasury)), 0, "nothing stays in the treasury");
        assertEq(classic.protocolShareOwed(), 0, "nothing is owed");
        _assertDepositEvent(treasury, owed);

        vm.prank(script.BASE_REGENTS_SAFE());
        staking.setPaused(true);
        _buy(classic, BUYER);
        uint256 owedWhilePaused = classic.protocolShareOwed();
        assertGt(owedWhilePaused, 0, "a key sells while staking is paused");
        vm.expectRevert();
        classic.sendProtocolShare();
        assertEq(classic.protocolShareOwed(), owedWhilePaused, "the share stays owed in the manager");
        assertEq(
            usdc.balanceOf(address(classic)),
            owedWhilePaused + classic.pendingConversion(),
            "and held by it, beside the USDC booked for REGENT"
        );
    }

    /// @dev Staking's own revenue event names the fleet's treasury as the depositor, the fleet's
    /// manager as the source and the Keyfleet protocol share tag.
    function _assertDepositEvent(KeyfleetTreasury treasury, uint256 amount) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(staking) || log.topics[0] != USDC_REVENUE_DEPOSITED) continue;
            assertEq(address(uint160(uint256(log.topics[2]))), address(treasury), "the treasury deposited");
            assertEq(log.topics[3], bytes32(uint256(uint160(address(classic)))), "for this fleet's manager");
            (uint256 deposited,,, bytes32 tag) = abi.decode(log.data, (uint256, uint256, uint256, bytes32));
            assertEq(deposited, amount, "the whole owed share");
            assertEq(tag, treasury.PROTOCOL_SHARE_TAG(), "tagged as a protocol share");
            return;
        }
        revert("no USDCRevenueDeposited from staking");
    }

    /// @dev Reads the coordinator's own request event out of the recorded logs and checks its
    /// terms: the collection's gas lane and subscription, three confirmations, 100,000 callback gas,
    /// one word, paid in ETH; and that the collection recorded the same request for `tokenId`.
    function _requestedId(uint256 tokenId) private returns (uint256 requestId) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(coordinator) || log.topics[0] != RANDOM_WORDS_REQUESTED) continue;
            assertEq(log.topics[1], script.BASE_VRF_KEY_HASH_2_GWEI(), "gas lane");
            assertEq(uint256(log.topics[2]), subscriptionId, "subscription");
            assertEq(address(uint160(uint256(log.topics[3]))), address(keys), "sender");
            (uint256 id,, uint16 confirmations, uint32 callbackGas, uint32 numWords, bytes memory extraArgs) =
                abi.decode(log.data, (uint256, uint256, uint16, uint32, uint32, bytes));
            assertEq(confirmations, 3, "confirmations");
            assertEq(callbackGas, 100_000, "callback gas");
            assertEq(numWords, 1, "one word");
            assertEq(extraArgs, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true), "paid in ETH");
            requestId = id;
            found = true;
            break;
        }
        assertTrue(found, "the coordinator emitted RandomWordsRequested");
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(keys) || log.topics[0] != KeyfleetKeys.RevealRequested.selector) continue;
            assertEq(uint256(log.topics[1]), tokenId, "the collection's request is for this key");
            assertEq(uint256(log.topics[2]), requestId, "under the coordinator's id");
            return requestId;
        }
        revert("no RevealRequested from the collection");
    }
}
