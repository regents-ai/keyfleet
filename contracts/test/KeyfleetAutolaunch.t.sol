// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";
import {IRegentLBPStrategy} from "../src/interfaces/IRegentLBPStrategy.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {MockToken} from "./KeyfleetIncome.t.sol";
import {IMintable, MockAutolaunchFactory, MockLBPStrategy} from "./mocks/MockAutolaunch.sol";

contract KeyfleetAutolaunchTest is Test {
    uint128 private constant RAISE = 1_000_000e18;
    uint256 private constant EXECUTION_GAS_CEILING = 1_750_000;
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private usdc;
    MockToken private regent;
    MockLBPStrategy private strategy;
    MockAutolaunchFactory private factory;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;
    IRegentRevenueStaking private staking = IRegentRevenueStaking(address(0x57A1));

    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private mallory = address(0x4A11);

    event AutolaunchProposed(uint256 indexed proposalId, bytes32 envelopeHash);
    event AutolaunchExecuted(
        uint256 indexed proposalId, uint256 indexed launchId, address indexed subject, address auction, address escrow
    );
    event LaunchSynced(Keyfleet.LaunchState state);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256[] tokenIds);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        regent = new MockToken("Regent", "REGENT");
        strategy = new MockLBPStrategy(IMintable(address(regent)));
        factory = new MockAutolaunchFactory(strategy);
        factory.openLaunches();
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        vm.warp(1_000_000);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = new Keyfleet(
            preset,
            usdc,
            regent,
            staking,
            factory,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    /// @dev A fleet's randomness: the mock coordinator and the suite's subscription.
    function _randomness() private view returns (Keyfleet.Randomness memory) {
        return Keyfleet.Randomness({
            coordinator: IVRFCoordinatorV2Plus(address(vrf)),
            subscriptionId: vrfSubscription,
            keyHash: keccak256("key hash")
        });
    }

    /// @dev A fleet that has sold exactly the keys its preset requires before it may propose a
    /// launch, with every key's vote in `alice`'s hands.
    function _launchReadyFleet(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = _deploy(preset);
        _buyKeys(fleet, _required(preset));
    }

    function _required(KeyfleetPresets.Preset preset) private pure returns (uint256) {
        return preset == KeyfleetPresets.Preset.FibonacciSyndicate || preset == KeyfleetPresets.Preset.FibonacciCascade
            ? KeyfleetPresets.FIBONACCI_AUTOLAUNCH_MIN_KEYS
            : KeyfleetPresets.FLEET_TECH_AUTOLAUNCH_MIN_KEYS;
    }

    /// @dev Buys the next `count` keys. Key 1 goes to `alice`, and every later key to a wallet of its
    /// own that makes `alice` its voting delegate: one key per wallet is what the Fibonacci holding
    /// limit requires below level 8, and the delegation lets `alice` vote any set of keys in one call.
    function _buyKeys(Keyfleet fleet, uint256 count) private {
        KeyfleetVotes votes = fleet.VOTES();
        for (uint256 i = 0; i < count; ++i) {
            uint256 tokenId = fleet.totalMinted() + 1;
            address holder = tokenId == 1 ? alice : address(uint160(0x100000 + tokenId));
            uint256 price = fleet.nextPrice();
            usdc.mint(buyer, price);
            vm.startPrank(buyer);
            usdc.approve(address(fleet), price);
            fleet.purchase(holder, price, block.timestamp);
            vm.stopPrank();
            if (holder != alice) {
                vm.prank(holder);
                votes.setVotingDelegate(alice);
            }
        }
    }

    /// @dev The ids `first..first + count - 1`.
    function _ids(uint256 first, uint256 count) private pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    function _envelope() private pure returns (Keyfleet.LaunchEnvelope memory) {
        return Keyfleet.LaunchEnvelope({
            name: "Alpha Fleet Token",
            symbol: "ALPHA",
            description: "The token the alpha fleet voted to launch.",
            website: "https://regents.sh/alpha",
            image: "ipfs://alpha-image",
            requiredRegentRaised: RAISE,
            narrativeDigest: keccak256("narrative")
        });
    }

    /// @dev Proposes in a fresh block, so every key already sold may vote on it.
    function _propose(Keyfleet fleet, Keyfleet.LaunchEnvelope memory envelope) private returns (uint256 proposalId) {
        KeyfleetVotes votes = fleet.VOTES();
        vm.roll(block.number + 1);
        vm.prank(alice);
        proposalId = votes.proposeAutolaunch(1, envelope);
    }

    /// @dev Proposes and votes every key YES.
    function _proposeAndPass(Keyfleet fleet, Keyfleet.LaunchEnvelope memory envelope)
        private
        returns (uint256 proposalId)
    {
        KeyfleetVotes votes = fleet.VOTES();
        proposalId = _propose(fleet, envelope);
        uint256[] memory ids = _ids(1, fleet.totalMinted());
        vm.prank(alice);
        votes.vote(proposalId, ids, true);
    }

    function _executeFor(Keyfleet fleet, Keyfleet.LaunchEnvelope memory envelope) private returns (uint256 proposalId) {
        proposalId = _proposeAndPass(fleet, envelope);
        fleet.VOTES().execute(proposalId);
    }

    function _string(uint256 length) private pure returns (string memory) {
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            out[i] = "a";
        }
        return string(out);
    }

    // --- 1. deployment and wiring ----------------------------------------

    /// @dev Invariant: a fleet is born pointing at exactly one Autolaunch factory, it can never be
    /// deployed without one, and it starts with no launch at all.
    function test_constructorBindsOneFactoryAndStartsWithNoLaunch() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);

        assertEq(address(fleet.FACTORY()), address(factory), "the fleet is bound to the pinned factory");
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.NotCreated), "no launch yet");

        Keyfleet.LaunchRecord memory record = fleet.launchRecord();
        assertEq(record.launchId, 0);
        assertEq(record.subject, address(0));
        assertEq(record.envelopeHash, bytes32(0));

        vm.expectRevert(Keyfleet.LaunchNotCreated.selector);
        fleet.launchDistribution();

        vm.expectRevert(Keyfleet.LaunchNotCreated.selector);
        fleet.syncLaunch();

        vm.expectRevert(Keyfleet.ZeroAddress.selector);
        new Keyfleet(
            KeyfleetPresets.Preset.FleetTechClassic,
            usdc,
            regent,
            staking,
            IRegentsAutolaunchFactoryV1(address(0)),
            Keyfleet.Metadata("n", "s", BASE_URI),
            _randomness(),
            keccak256("trait table")
        );
    }

    // --- 2. envelope validation at proposal time --------------------------

    /// @dev Invariant: an envelope the factory would refuse is refused when it is proposed, so the
    /// keys are never asked to vote on a launch that could not happen. The bounds are the factory's
    /// own published caps, read from it here exactly as the controller reads them. The caps are byte
    /// caps and the bound itself is accepted; only one byte over is not.
    function test_proposalRefusesAnyMetadataFieldThatIsEmptyOrOverItsByteCap() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256[5] memory caps = [
            factory.MAX_NAME_BYTES(),
            factory.MAX_SYMBOL_BYTES(),
            factory.MAX_DESCRIPTION_BYTES(),
            factory.MAX_WEBSITE_BYTES(),
            factory.MAX_IMAGE_BYTES()
        ];

        for (uint256 field = 0; field < 5; ++field) {
            Keyfleet.LaunchEnvelope memory empty = _envelope();
            _setField(empty, field, "");
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.EmptyMetadataField.selector, field));
            votes.proposeAutolaunch(1, empty);

            Keyfleet.LaunchEnvelope memory tooLong = _envelope();
            _setField(tooLong, field, _string(caps[field] + 1));
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(KeyfleetVotes.MetadataFieldTooLong.selector, field, caps[field], caps[field] + 1)
            );
            votes.proposeAutolaunch(1, tooLong);
        }

        Keyfleet.LaunchEnvelope memory atTheCaps = _envelope();
        for (uint256 field = 0; field < 5; ++field) {
            _setField(atTheCaps, field, _string(caps[field]));
        }
        assertEq(_propose(fleet, atTheCaps), 1, "a field of exactly its cap is accepted");
    }

    /// @dev Invariant: a raise no auction could ever settle on, and a raise of nothing, are both
    /// refused at proposal time, against the ceiling the strategy itself publishes. The ceiling is
    /// reachable and is accepted.
    function test_proposalRefusesARaiseOfZeroOrAboveTheReachableCeiling() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint128 ceiling = strategy.MAX_REACHABLE_RAISE();

        Keyfleet.LaunchEnvelope memory nothing = _envelope();
        nothing.requiredRegentRaised = 0;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.RaiseOutOfBounds.selector, uint128(0)));
        votes.proposeAutolaunch(1, nothing);

        Keyfleet.LaunchEnvelope memory unreachable = _envelope();
        unreachable.requiredRegentRaised = ceiling + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.RaiseOutOfBounds.selector, ceiling + 1));
        votes.proposeAutolaunch(1, unreachable);

        Keyfleet.LaunchEnvelope memory atTheCeiling = _envelope();
        atTheCeiling.requiredRegentRaised = ceiling;
        assertEq(_propose(fleet, atTheCeiling), 1, "the reachable ceiling itself is accepted");
    }

    /// @dev Invariant: proposing an Autolaunch takes the same standing as every other kind, and the
    /// envelope the proposal carries is exactly the one the caller supplied.
    function test_proposalTakesStandingAndStoresTheEnvelopeItWasGiven() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        Keyfleet.LaunchEnvelope memory envelope = _envelope();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, uint256(1), alice));
        votes.proposeAutolaunch(1, envelope);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(votes));
        emit AutolaunchProposed(1, keccak256(abi.encode(envelope)));
        uint256 proposalId = votes.proposeAutolaunch(1, envelope);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(uint256(stored.kind), uint256(KeyfleetVotes.Kind.Autolaunch));
        assertEq(stored.digest, envelope.narrativeDigest, "the narrative digest pins the proposal");

        Keyfleet.LaunchEnvelope memory read = votes.launchEnvelope(proposalId);
        assertEq(keccak256(abi.encode(read)), keccak256(abi.encode(envelope)), "stored whole and unedited");
        assertEq(read.symbol, envelope.symbol);
        assertEq(read.requiredRegentRaised, envelope.requiredRegentRaised);

        vm.prank(alice);
        uint256 decisionId = votes.proposeDecision(1, "record it", bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAnAutolaunch.selector, decisionId));
        votes.launchEnvelope(decisionId);
    }

    /// @dev The fleet reader in platform/lib/keyfleet/chain/launch_envelopes.ex keeps a launch only
    /// when the bytes `launchEnvelope` returns hash to the proposal's envelope hash. This is the
    /// launch platform/test/keyfleet/proposals_chain_test.exs encodes by hand, 1056 bytes long, and
    /// both sides pin the same digest: as emitted, and as the stored envelope is returned.
    function test_readerSampleLaunchHashesAlikeWhenEmittedAndReturned() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        bytes32 pinned = 0x2aca76a7e898ce8e57e3a2b570f5d8c44f8dcdebfec29e93de71e3421f328311;

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(votes));
        emit AutolaunchProposed(1, pinned);
        uint256 proposalId = votes.proposeAutolaunch(1, _readerSample());

        (bool ok, bytes memory returned) =
            address(votes).staticcall(abi.encodeCall(KeyfleetVotes.launchEnvelope, (proposalId)));
        assertTrue(ok);
        assertEq(returned.length, 8 * 132);
        assertEq(keccak256(returned), pinned);
    }

    function _readerSample() private pure returns (Keyfleet.LaunchEnvelope memory) {
        bytes memory repeated;
        for (uint256 i; i < 27; ++i) {
            repeated = bytes.concat(repeated, "A fleet's launch. ");
        }
        bytes memory description = new bytes(480);
        for (uint256 i; i < 480; ++i) {
            description[i] = repeated[i];
        }
        bytes memory image = "ipfs://";
        for (uint256 i; i < 50; ++i) {
            image = bytes.concat(image, "c");
        }

        return Keyfleet.LaunchEnvelope({
            name: "Cascade Research",
            symbol: "CSR",
            description: string(description),
            website: "https://example.test",
            image: string(image),
            requiredRegentRaised: 250_000,
            narrativeDigest: bytes32(0)
        });
    }

    // --- 3. execution ------------------------------------------------------

    /// @dev Invariant: a passed Autolaunch calls the factory once with the fleet as both launcher
    /// and treasury, and records only what the factory says it created. Nothing is approved, no
    /// token moves and the fleet's own capital is untouched.
    function test_executionLaunchesWithTheFleetAsLauncherAndTreasuryAndRecordsTheFactorysAnswer() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        Keyfleet.LaunchEnvelope memory envelope = _envelope();
        uint256 capitalBefore = fleet.freeCapital(address(usdc));
        uint256 balanceBefore = usdc.balanceOf(address(fleet));

        uint256 proposalId = _proposeAndPass(fleet, envelope);
        vm.recordLogs();
        fleet.VOTES().execute(proposalId);

        IRegentsAutolaunchFactoryV1.Launch memory recorded = factory.launches(1);
        _expectExecutedLog(address(fleet), proposalId, recorded);
        assertEq(recorded.launcher, address(fleet), "the factory recorded the fleet itself as launcher");
        assertEq(recorded.treasury, address(fleet), "and the fleet itself as treasury");

        (,,,,, address suppliedTreasury, uint128 suppliedRaise) = factory.lastParams();
        assertEq(suppliedTreasury, address(fleet), "the fleet forced the treasury, there is no field for anyone else");
        assertEq(suppliedRaise, envelope.requiredRegentRaised);

        Keyfleet.LaunchRecord memory record = fleet.launchRecord();
        assertEq(record.launchId, 1);
        assertEq(record.proposalId, proposalId, "the authorising vote is readable without the event");
        assertEq(record.subject, recorded.subject, "the SUBJECT is the factory's, not the proposal's");
        assertEq(record.auction, recorded.auction);
        assertEq(record.escrow, recorded.escrow);
        assertEq(record.envelopeHash, keccak256(abi.encode(envelope)), "the exact envelope that was approved");
        assertEq(record.createdAtBlock, uint64(block.number));
        assertEq(record.splitter, address(0), "graduation artifacts stay empty until the launch graduates");
        assertEq(record.receiver, address(0));
        assertEq(record.poolId, bytes32(0));
        assertEq(record.lpTokenId, 0);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated));

        assertEq(usdc.allowance(address(fleet), address(factory)), 0, "no allowance was granted to the factory");
        assertEq(usdc.allowance(address(fleet), record.subject), 0, "nor to anything the launch created");
        assertEq(usdc.balanceOf(address(fleet)), balanceBefore, "and not one atomic unit left the fleet");
        assertEq(fleet.freeCapital(address(usdc)), capitalBefore, "the fleet's capital is exactly as it was");
    }

    /// @dev Invariant: only the fleet's own voting controller may launch. No holder, no proposer and
    /// no passer-by can call the typed entry point directly.
    function test_onlyTheVotingControllerMayLaunch() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);

        vm.prank(alice);
        vm.expectRevert(Keyfleet.OnlyVotes.selector);
        fleet.executeAutolaunch(1, uint64(block.number - 1), _envelope());

        vm.prank(mallory);
        vm.expectRevert(Keyfleet.OnlyVotes.selector);
        fleet.executeAutolaunch(1, uint64(block.number - 1), _envelope());
    }

    /// @dev Invariant: every preset can launch. The spec requires the adapter to be testable across
    /// all four: a fleet that has sold the keys its preset requires can propose and execute one
    /// launch, whichever ladder it is on.
    function test_everyPresetCanProposeAndExecuteOneLaunch() public {
        KeyfleetPresets.Preset[4] memory presets = [
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FleetTechAccelerant
        ];

        for (uint256 i = 0; i < presets.length; ++i) {
            Keyfleet fleet = _launchReadyFleet(presets[i]);
            _executeFor(fleet, _envelope());
            assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated));
            assertEq(fleet.launchRecord().launchId, i + 1, "each fleet took the next launch from the shared factory");
        }
    }

    /// @dev Invariant: while a launch is running no other can be carried out, though one may be
    /// proposed and approved. Once the strategy records the running launch as failed, an approved
    /// launch proposed after it was created is carried out without anyone syncing first: it replaces
    /// the failed launch's record, and its SUBJECT replaces the failed SUBJECT as the third income
    /// token. One approved before the failed launch was created stays refused.
    function test_anotherLaunchCanFollowOnlyAFailedOne() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetRewards rewards = fleet.REWARDS();

        uint256 second = _proposeAndPass(fleet, _envelope());
        uint256 first = _executeFor(fleet, _envelope());
        Keyfleet.LaunchRecord memory failed = fleet.launchRecord();
        assertEq(failed.proposalId, first);

        vm.expectRevert(Keyfleet.LaunchAlreadyCreated.selector);
        votes.execute(second);
        assertFalse(votes.proposal(second).executed, "the refused attempt consumed nothing");
        uint256 third = _proposeAndPass(fleet, _envelope());
        assertEq(votes.proposal(third).openedBlock, block.number, "a launch can be proposed while one runs");

        strategy.fail(failed.auction);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated), "nobody synced");
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.StaleLaunch.selector, second));
        votes.execute(second);
        votes.execute(third);

        Keyfleet.LaunchRecord memory current = fleet.launchRecord();
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated), "a new launch runs");
        assertEq(current.proposalId, third, "the record is the new launch's");
        assertEq(current.launchId, failed.launchId + 1);
        assertTrue(current.subject != failed.subject && current.auction != failed.auction, "with its own tokens");
        assertEq(rewards.launchedToken(), current.subject, "its SUBJECT is the third income token");
        assertFalse(rewards.isRewardAsset(failed.subject), "and the failed SUBJECT no longer is");

        vm.expectRevert(Keyfleet.LaunchAlreadyCreated.selector);
        votes.execute(second);
        assertEq(factory.nextLaunchId(), 3, "the factory created exactly two launches for this fleet");
    }

    /// @dev Invariant: an approval given before a launch was created cannot be carried out once
    /// that launch fails, however long it waited and whoever holds its keys now. The new holders
    /// of keys that voted YES can withdraw those votes, and a launch proposed in the very block the
    /// failed one was created is refused too; one proposed in the next block runs.
    function test_aLaunchApprovedBeforeAFailedOneWasCreatedCannotFollowIt() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();

        Keyfleet.LaunchEnvelope memory oldEnvelope = _envelope();
        oldEnvelope.name = "Old Name, Low Raise";
        uint256 old = _proposeAndPass(fleet, oldEnvelope);
        uint256 chosen = _proposeAndPass(fleet, _envelope());
        votes.execute(chosen);
        vm.prank(alice);
        uint256 sameBlock = votes.proposeAutolaunch(1, _envelope());
        assertEq(votes.proposal(sameBlock).openedBlock, fleet.launchRecord().createdAtBlock);

        vm.roll(block.number + 1);
        address seller = address(uint160(0x100000 + 2));
        address newHolder = address(0xBEEF);
        vm.prank(seller);
        fleet.transferFrom(seller, newHolder, 2);
        vm.prank(newHolder);
        votes.withdrawVote(old, _ids(2, 1));
        assertEq(uint256(votes.voteOf(old, 2)), uint256(KeyfleetVotes.Choice.None), "the new holder took it back");

        uint256 fresh = _propose(fleet, _envelope());
        vm.roll(block.number + 1);
        vm.startPrank(alice);
        votes.vote(sameBlock, _ids(3, fleet.totalMinted() - 2), true);
        votes.vote(fresh, _ids(3, fleet.totalMinted() - 2), true);
        vm.stopPrank();

        strategy.fail(fleet.launchRecord().auction);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.StaleLaunch.selector, old));
        votes.execute(old);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.StaleLaunch.selector, sameBlock));
        votes.execute(sameBlock);
        assertFalse(votes.proposal(old).executed, "the refused attempts consumed nothing");

        votes.execute(fresh);
        assertEq(fleet.launchRecord().proposalId, fresh, "the launch proposed after the failed one was created runs");
    }

    /// @dev Invariant: a graduated launch is the fleet's last. An approved launch cannot be carried
    /// out after it, synced or not, and once the fleet knows, no launch can even be proposed.
    function test_aGraduatedLaunchIsTheFleetsLast() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 waiting = _proposeAndPass(fleet, _envelope());
        _executeFor(fleet, _envelope());

        strategy.graduate(fleet.launchRecord().auction, address(0x5), address(0x6), keccak256("pool"), 7, 10e18, 4e18);
        vm.expectRevert(Keyfleet.LaunchAlreadyCreated.selector);
        votes.execute(waiting);

        fleet.syncLaunch();
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.Graduated));
        vm.expectRevert(Keyfleet.LaunchAlreadyCreated.selector);
        votes.execute(waiting);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(Keyfleet.LaunchAlreadyCreated.selector);
        votes.proposeAutolaunch(1, _envelope());
        assertEq(factory.nextLaunchId(), 2, "the factory created exactly one launch for this fleet");
    }

    /// @dev Invariant: a factory that is refusing launches reverts the whole execution, so the
    /// proposal stays open and the fleet records nothing. This is the case the atomicity rule exists
    /// for: a fleet can wait for the factory to open and carry out the same approval afterwards,
    /// however long that takes, because an approved launch never expires.
    function test_aPausedFactoryLeavesTheProposalExecutable() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _proposeAndPass(fleet, _envelope());

        factory.closeLaunches();
        assertTrue(fleet.FACTORY().launchesPaused(), "the app can see why the next attempt will fail");
        vm.expectRevert(MockAutolaunchFactory.LaunchesArePaused.selector);
        votes.execute(proposalId);

        assertFalse(votes.proposal(proposalId).executed, "the execution mark was rolled back with the revert");
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Approved), "it is still approved");
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.NotCreated));
        assertEq(factory.nextLaunchId(), 1, "the factory consumed nothing");

        vm.warp(block.timestamp + 700 days);
        vm.roll(block.number + 1_000_000);
        factory.openLaunches();
        votes.execute(proposalId);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated), "the same approval lands");
    }

    /// @dev Invariant: a treasury the factory refuses fails the same atomic way. Nothing about the
    /// factory's own rules is predicted at proposal time, because they are not the fleet's to
    /// predict, and a refusal costs the proposal nothing.
    function test_aTreasuryTheFactoryRefusesRevertsTheWholeExecution() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _proposeAndPass(fleet, _envelope());

        factory.setRefusedTreasury(address(fleet), true);
        vm.expectRevert(abi.encodeWithSelector(MockAutolaunchFactory.RefusedTreasury.selector, address(fleet)));
        votes.execute(proposalId);

        assertFalse(votes.proposal(proposalId).executed);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.NotCreated));

        factory.setRefusedTreasury(address(fleet), false);
        votes.execute(proposalId);
        assertEq(fleet.launchRecord().launchId, 1);
    }

    /// @dev Invariant: the fleet believes the factory's own record and nothing else. Each of the six
    /// conditions is broken on its own here: a record naming a different launcher, SUBJECT, auction,
    /// escrow or treasury than the call returned, and an index that cannot map the SUBJECT back to
    /// the launch it just created. Every one of them rejects the whole launch rather than writing it
    /// down.
    function test_aFactoryThatDoesNotRecordThisFleetHasItsLaunchRejected() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _proposeAndPass(fleet, _envelope());

        IRegentsAutolaunchFactoryV1.Launch[5] memory lies = [
            IRegentsAutolaunchFactoryV1.Launch(mallory, address(0), address(0), address(0), address(0)),
            IRegentsAutolaunchFactoryV1.Launch(address(0), mallory, address(0), address(0), address(0)),
            IRegentsAutolaunchFactoryV1.Launch(address(0), address(0), mallory, address(0), address(0)),
            IRegentsAutolaunchFactoryV1.Launch(address(0), address(0), address(0), mallory, address(0)),
            IRegentsAutolaunchFactoryV1.Launch(address(0), address(0), address(0), address(0), mallory)
        ];
        for (uint256 field = 0; field < lies.length; ++field) {
            factory.setForcedRecord(lies[field]);
            vm.expectRevert(Keyfleet.LaunchProvenanceMismatch.selector);
            votes.execute(proposalId);
            assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.NotCreated), "nothing was recorded");
        }

        factory.setForcedRecord(
            IRegentsAutolaunchFactoryV1.Launch(address(0), address(0), address(0), address(0), address(0))
        );
        factory.setBreakSubjectIndex(true);
        vm.expectRevert(Keyfleet.LaunchProvenanceMismatch.selector);
        votes.execute(proposalId);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.NotCreated), "nothing was recorded");

        factory.setBreakSubjectIndex(false);
        votes.execute(proposalId);
        assertEq(factory.launches(fleet.launchRecord().launchId).launcher, address(fleet), "an honest record is kept");
    }

    // --- 4. reentrancy -----------------------------------------------------

    /// @dev Invariant: the guards hold while a launch is half done. A factory that calls back into
    /// the vote it is executing, or into the fleet's sorting path, is refused by the same
    /// reentrancy guard that protects every other entry point, and the launch itself still
    /// completes on the factory's own terms.
    function test_aFactoryThatCallsBackIsRefusedByTheGuards() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _proposeAndPass(fleet, _envelope());

        factory.armReentry(address(votes), abi.encodeCall(KeyfleetVotes.execute, (proposalId)));
        votes.execute(proposalId);

        assertTrue(factory.reentryFired(), "the factory did call back");
        assertFalse(factory.reentryOk(), "and the call back was refused");
        assertEq(
            bytes4(factory.reentryReturn()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "by the controller's own guard"
        );
        assertEq(fleet.launchRecord().launchId, 1, "one launch, recorded once");
        assertEq(factory.nextLaunchId(), 2);

        Keyfleet second = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 secondId = _proposeAndPass(second, _envelope());
        factory.armReentry(address(second), abi.encodeCall(Keyfleet.recognizeSurplus, (address(usdc))));
        second.VOTES().execute(secondId);

        assertTrue(factory.reentryFired(), "the factory called back a second time");
        assertFalse(factory.reentryOk(), "sorting from inside the launch is refused too");
        assertEq(
            bytes4(factory.reentryReturn()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "by the fleet's own guard"
        );
    }

    /// @dev Invariant: a proposal is marked executed before the fleet calls the factory, so anything
    /// the factory reads back mid-launch already sees the proposal as spent.
    function test_aProposalIsMarkedExecutedBeforeTheFactoryRuns() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _proposeAndPass(fleet, _envelope());

        factory.armReentry(address(votes), abi.encodeCall(KeyfleetVotes.proposal, (proposalId)));
        votes.execute(proposalId);

        assertTrue(factory.reentryFired(), "the factory read the proposal mid-launch");
        assertTrue(factory.reentryOk(), "a read is not refused by the guard");
        KeyfleetVotes.Proposal memory seen = abi.decode(factory.reentryReturn(), (KeyfleetVotes.Proposal));
        assertTrue(seen.executed, "and it was already marked executed");
    }

    // --- 5. sync -----------------------------------------------------------

    /// @dev Invariant: a launch the strategy has not settled is not economically failed. An auction
    /// that is still running, and one that has ended but has not been migrated, are both `Active`
    /// on the strategy, and a sync of either leaves the fleet exactly where it was and emits
    /// nothing at all.
    function test_syncLeavesAnUnsettledLaunchAloneAndEmitsNothing() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        _executeFor(fleet, _envelope());
        Keyfleet.LaunchRecord memory before = fleet.launchRecord();

        vm.recordLogs();
        assertEq(uint256(fleet.syncLaunch()), uint256(Keyfleet.LaunchState.AuctionCreated), "still pending");
        assertEq(vm.getRecordedLogs().length, 0, "an unsettled sync says nothing");
        assertEq(keccak256(abi.encode(fleet.launchRecord())), keccak256(abi.encode(before)), "and changes nothing");

        // Past the auction's end, still unmigrated: the strategy keeps it Active, and so does this.
        vm.roll(block.number + 300 + 86_401 + 1);
        assertEq(uint256(fleet.syncLaunch()), uint256(Keyfleet.LaunchState.AuctionCreated), "ended is not failed");
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated));
    }

    /// @dev Invariant: graduation records the four artifacts the strategy published and nothing
    /// else. The SUBJECT, the auction, the escrow and the approved envelope are untouched by it.
    function test_syncRecordsTheGraduationArtifactsAndReplacesNothing() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        _executeFor(fleet, _envelope());
        Keyfleet.LaunchRecord memory before = fleet.launchRecord();

        address splitter = address(0x591177);
        address receiver = address(0xEC1E);
        bytes32 poolId = keccak256("pool");
        strategy.graduate(before.auction, splitter, receiver, poolId, 4242, RAISE, RAISE / 2);

        vm.expectEmit(false, false, false, true, address(fleet));
        emit LaunchSynced(Keyfleet.LaunchState.Graduated);
        vm.prank(mallory);
        assertEq(uint256(fleet.syncLaunch()), uint256(Keyfleet.LaunchState.Graduated), "anyone may sync");

        Keyfleet.LaunchRecord memory after_ = fleet.launchRecord();
        assertEq(after_.splitter, splitter);
        assertEq(after_.receiver, receiver);
        assertEq(after_.poolId, poolId);
        assertEq(after_.lpTokenId, 4242);
        assertEq(after_.launchId, before.launchId, "the launch itself is untouched");
        assertEq(after_.subject, before.subject);
        assertEq(after_.auction, before.auction);
        assertEq(after_.escrow, before.escrow);
        assertEq(after_.envelopeHash, before.envelopeHash);

        IRegentLBPStrategy.Distribution memory published = fleet.launchDistribution();
        assertEq(uint256(published.lifecycle), uint256(IRegentLBPStrategy.Lifecycle.Graduated), "read live, not stored");
        assertEq(published.treasury, address(fleet));
    }

    /// @dev Invariant: an auction the strategy settled as failed makes the fleet economically
    /// failed, and a terminal state is terminal: a later sync changes nothing and says nothing.
    function test_syncRecordsFailureAndTerminalStatesNeverChangeAgain() public {
        Keyfleet failed = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        _executeFor(failed, _envelope());
        strategy.fail(failed.launchRecord().auction);

        vm.expectEmit(false, false, false, true, address(failed));
        emit LaunchSynced(Keyfleet.LaunchState.EconomicallyFailed);
        failed.syncLaunch();
        assertEq(uint256(failed.launchState()), uint256(Keyfleet.LaunchState.EconomicallyFailed));

        vm.recordLogs();
        assertEq(uint256(failed.syncLaunch()), uint256(Keyfleet.LaunchState.EconomicallyFailed), "still failed");
        assertEq(vm.getRecordedLogs().length, 0, "and silent");

        Keyfleet graduated = _launchReadyFleet(KeyfleetPresets.Preset.FleetTechClassic);
        _executeFor(graduated, _envelope());
        strategy.graduate(graduated.launchRecord().auction, address(0x1), address(0x2), keccak256("p"), 1, RAISE, 0);
        graduated.syncLaunch();

        strategy.fail(graduated.launchRecord().auction);
        graduated.syncLaunch();
        assertEq(uint256(graduated.launchState()), uint256(Keyfleet.LaunchState.Graduated), "graduation is forever");
    }

    // --- 6. gas ------------------------------------------------------------

    /// @dev Invariant: executing an Autolaunch costs a fixed amount, whatever the fleet's size.
    /// The figure is measured against the mock factory and most of it is the mock's own writing, so
    /// it is a regression bound on this side of the call rather than a prediction of the real cost.
    /// The ceiling is the measured figure plus twenty percent, rounded up to the nearest thousand.
    function test_autolaunchExecutionGas() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _proposeAndPass(fleet, _envelope());

        vm.cool(address(fleet));
        vm.cool(address(votes));
        vm.cool(address(factory));

        uint256 before = gasleft();
        votes.execute(proposalId);
        uint256 used = before - gasleft();

        console2.log("autolaunch execution gas through the mock factory:", used);
        assertLt(used, EXECUTION_GAS_CEILING, "an execution stays under the published ceiling");
        assertEq(fleet.launchRecord().launchId, 1);
    }

    // --- 7. eligibility -----------------------------------------------------

    /// @dev Invariant: a fleet may propose its launch only once it has sold the keys its preset
    /// requires: a Fibonacci fleet the last key of level 7, a Classic or Accelerant fleet one
    /// hundred keys. One key short is refused with both figures, and the key that reaches the
    /// threshold is enough on every preset.
    function test_aLaunchNeedsTheLastKeyOfLevelSevenOrOneHundredKeys() public {
        KeyfleetPresets.Preset[4] memory presets = [
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FleetTechAccelerant
        ];
        uint256[4] memory required = [uint256(86), 86, 100, 100];

        for (uint256 i = 0; i < presets.length; ++i) {
            Keyfleet fleet = _deploy(presets[i]);
            KeyfleetVotes votes = fleet.VOTES();
            _buyKeys(fleet, required[i] - 1);
            if (i < 2) assertEq(fleet.completedLevels(), 6, "one key short of level 7");

            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(KeyfleetVotes.LaunchNotYetEligible.selector, required[i] - 1, required[i])
            );
            votes.proposeAutolaunch(1, _envelope());

            _buyKeys(fleet, 1);
            if (i < 2) assertEq(fleet.completedLevels(), 7, "the last key of level 7 is sold");
            assertEq(_propose(fleet, _envelope()), 1, "the threshold itself is enough");
        }
    }

    // --- 8. one vote per key -----------------------------------------------

    /// @dev Invariant: a launch and a Decision both count one vote per key on a Fibonacci fleet. A
    /// level-1 key and a level-7 key each add exactly one, and both proposals are measured against
    /// all eighty-six keys.
    function test_aLaunchAndADecisionBothCountEveryFibonacciKeyAsOneVote() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 launch = _propose(fleet, _envelope());
        vm.prank(alice);
        uint256 decision = votes.proposeDecision(1, "record it", bytes32(0));
        assertEq(fleet.levelOf(1), 1);
        assertEq(fleet.levelOf(86), 7);

        uint256[2] memory proposals = [launch, decision];
        for (uint256 i = 0; i < proposals.length; ++i) {
            uint256 proposalId = proposals[i];
            vm.expectEmit(true, true, true, true, address(votes));
            emit VoteCast(proposalId, alice, true, _ids(1, 1));
            vm.prank(alice);
            votes.vote(proposalId, _ids(1, 1), true);

            vm.expectEmit(true, true, true, true, address(votes));
            emit VoteCast(proposalId, alice, false, _ids(86, 1));
            vm.prank(alice);
            votes.vote(proposalId, _ids(86, 1), false);

            KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
            assertEq(stored.yesVotes, 1, "a level-1 key is one vote");
            assertEq(stored.noVotes, 1, "and so is a level-7 key");
            assertEq(fleet.totalMinted(), 86, "eighty-six keys are eighty-six votes");
        }
    }

    /// @dev Invariant: a launch is approved only when more than half of all keys sold vote YES.
    /// Exactly half is not enough, one key more is, and silence counts against. A Decision follows the
    /// same rule, so the forty-three earliest keys carry neither.
    function test_aLaunchFailsAtExactlyHalfOfTheKeysAndPassesWithOneMore() public {
        Keyfleet fleet = _launchReadyFleet(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 half = _propose(fleet, _envelope());
        uint256 majority = _propose(fleet, _envelope());
        vm.prank(alice);
        uint256 decision = votes.proposeDecision(1, "record it", bytes32(0));

        vm.startPrank(alice);
        votes.vote(half, _ids(1, 43), true);
        votes.vote(majority, _ids(1, 44), true);
        votes.vote(decision, _ids(1, 43), true);
        vm.stopPrank();

        assertEq(uint256(votes.state(half)), uint256(KeyfleetVotes.State.Open), "43 of 86 is not a majority");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 43, 86));
        votes.execute(half);

        assertEq(uint256(votes.state(decision)), uint256(KeyfleetVotes.State.Open), "nor on a Decision");
        assertEq(uint256(votes.state(majority)), uint256(KeyfleetVotes.State.Approved), "44 of 86 is");
        votes.execute(majority);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated));
    }

    // --- 9. fuzz invariant ---------------------------------------------------

    /// @dev Invariant: across random votes on either Fibonacci preset, every key adds exactly one
    /// vote to a launch and to a Decision, whatever its level, and each is approved exactly when
    /// more than half of all the keys sold voted YES.
    function testFuzz_aLaunchAndADecisionCountOneVotePerKey(uint256 seed) public {
        KeyfleetPresets.Preset preset =
            seed % 2 == 0 ? KeyfleetPresets.Preset.FibonacciSyndicate : KeyfleetPresets.Preset.FibonacciCascade;
        Keyfleet fleet = _launchReadyFleet(preset);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 launch = _propose(fleet, _envelope());
        vm.prank(alice);
        uint256 decision = votes.proposeDecision(1, "record it", bytes32(0));

        // Every key abstains one time in eight, and otherwise votes YES with a random bias, so the
        // YES count lands on both sides of half the keys across runs.
        uint256 bias = seed % 100;
        uint256 yesKeys;
        uint256 cast;
        for (uint256 tokenId = 1; tokenId <= 86; ++tokenId) {
            uint256 roll = uint256(keccak256(abi.encode(seed, tokenId)));
            if (roll % 8 == 0) continue;
            bool support = (roll >> 8) % 100 < bias;

            vm.startPrank(alice);
            votes.vote(launch, _ids(tokenId, 1), support);
            votes.vote(decision, _ids(tokenId, 1), support);
            vm.stopPrank();
            ++cast;
            if (support) ++yesKeys;
        }

        uint256[2] memory proposals = [launch, decision];
        for (uint256 i = 0; i < proposals.length; ++i) {
            KeyfleetVotes.Proposal memory stored = votes.proposal(proposals[i]);
            assertEq(stored.yesVotes, yesKeys, "one vote per YES key");
            assertEq(stored.yesVotes + stored.noVotes, cast, "one vote per key cast");
            assertEq(
                votes.state(proposals[i]) == KeyfleetVotes.State.Approved,
                yesKeys * 2 > 86,
                "approved exactly above half the keys"
            );
        }
    }

    // --- helpers -----------------------------------------------------------

    /// @dev The fleet's `AutolaunchExecuted` log from the last recorded call names exactly what the
    /// factory recorded.
    function _expectExecutedLog(address fleet, uint256 proposalId, IRegentsAutolaunchFactoryV1.Launch memory recorded)
        private
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = Keyfleet.AutolaunchExecuted.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != fleet || logs[i].topics[0] != topic) continue;
            assertEq(uint256(logs[i].topics[1]), proposalId, "the authorising vote");
            assertEq(uint256(logs[i].topics[2]), 1, "the launch id");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), recorded.subject, "the recorded SUBJECT");
            (address auction, address escrow) = abi.decode(logs[i].data, (address, address));
            assertEq(auction, recorded.auction);
            assertEq(escrow, recorded.escrow);
            return;
        }
        revert("no AutolaunchExecuted log");
    }

    /// @dev Replaces one of the envelope's five metadata strings, numbered as the factory numbers
    /// its own fields.
    function _setField(Keyfleet.LaunchEnvelope memory envelope, uint256 field, string memory value) private pure {
        if (field == 0) envelope.name = value;
        else if (field == 1) envelope.symbol = value;
        else if (field == 2) envelope.description = value;
        else if (field == 3) envelope.website = value;
        else envelope.image = value;
    }
}
