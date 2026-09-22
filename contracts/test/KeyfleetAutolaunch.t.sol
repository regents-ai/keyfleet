// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {IRegentLBPStrategy} from "../src/interfaces/IRegentLBPStrategy.sol";
import {IRegentRevenueStaking} from "../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV1} from "../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";

contract MockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for the shared `RegentLBPStrategy`. It holds the one bound it publishes and the
/// per-auction record the fleet reads, and lets a test put an auction into any lifecycle the real
/// strategy can reach, with the four graduation artifacts a graduated record carries.
contract MockLBPStrategy is IRegentLBPStrategy {
    uint128 public constant MAX_REACHABLE_RAISE = 658_201_822_928_399_999_999_999_581_824_872_526;

    mapping(address auction => Distribution) private _distributions;

    function open(address auction, uint256 launchId, address subject, address escrow, address treasury, uint128 raise)
        external
    {
        Distribution storage d = _distributions[auction];
        d.lifecycle = Lifecycle.Active;
        d.startBlock = uint64(block.number) + 300;
        d.endBlock = d.startBlock + 86_401;
        d.requiredRegentRaised = raise;
        d.launchId = launchId;
        d.subject = subject;
        d.escrow = escrow;
        d.treasury = treasury;
    }

    function graduate(address auction, address splitter, address receiver, bytes32 poolId, uint256 lpTokenId) external {
        Distribution storage d = _distributions[auction];
        d.lifecycle = Lifecycle.Graduated;
        d.splitter = splitter;
        d.receiver = receiver;
        d.poolId = poolId;
        d.lpTokenId = lpTokenId;
    }

    function fail(address auction) external {
        _distributions[auction].lifecycle = Lifecycle.Failed;
    }

    function distribution(address auction) external view returns (Distribution memory) {
        return _distributions[auction];
    }
}

/// @dev Stands in for `RegentsAutolaunchFactoryV1`. It applies the checks the real factory applies,
/// in the same order and with the same error shapes: launches are refused while paused, the five
/// metadata strings must be nonempty and within their byte caps, the treasury must be nonzero and
/// outside the system set, and the required raise must be positive and within the strategy's
/// ceiling. It records `msg.sender` as launcher, keeps the same `launches` and `launchIdOfSubject`
/// provenance, and opens the strategy's record for the new auction.
///
/// It also has two hostilities the real factory does not: it can record any of the five provenance
/// fields differently from the ones it returned, and can break the subject index, so every
/// condition of the fleet's provenance check can be exercised on its own against a factory that
/// lies; and it can call anywhere from inside `launch`, which is where a real launch artifact would
/// get its chance to re-enter.
contract MockAutolaunchFactory is IRegentsAutolaunchFactoryV1 {
    error LaunchesArePaused();
    error EmptyMetadataField(uint256 field);
    error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found);
    error RefusedTreasury(address treasury);
    error UnreachableRequiredRaise(uint128 requiredRegentRaised);

    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_DESCRIPTION_BYTES = 512;
    uint256 public constant MAX_WEBSITE_BYTES = 256;
    uint256 public constant MAX_IMAGE_BYTES = 256;

    /// @notice Every factory is born paused, exactly as the real one is.
    bool public launchesPaused = true;
    IRegentLBPStrategy public strategy;
    uint256 public nextLaunchId = 1;

    /// @notice The exact parameters the last caller supplied, for the suite to read back.
    LaunchParams public lastParams;
    /// @notice Fields written into the recorded launch instead of the honest ones, where nonzero.
    /// @dev Each field lies on its own, so one condition of the fleet's provenance check can be
    /// broken at a time. The subject index still answers for the SUBJECT that was returned, so a
    /// forced record subject breaks only the recorded-subject condition.
    Launch public forcedRecord;
    /// @notice Whether `launchIdOfSubject` answers with a different launch.
    bool public breakSubjectIndex;

    address private _reentryTarget;
    bytes private _reentryPayload;
    /// @notice Whether the call from inside `launch` ran, and how it came back.
    bool public reentryFired;
    bool public reentryOk;
    bytes public reentryReturn;

    mapping(address treasury => bool refused) public refusedTreasury;
    mapping(address subject => uint256 launchId) private _launchIdOfSubject;
    mapping(uint256 launchId => Launch) private _launches;

    constructor(MockLBPStrategy strategy_) {
        strategy = strategy_;
    }

    function openLaunches() external {
        launchesPaused = false;
    }

    function closeLaunches() external {
        launchesPaused = true;
    }

    function setRefusedTreasury(address treasury, bool refused) external {
        refusedTreasury[treasury] = refused;
    }

    function setForcedRecord(Launch calldata record) external {
        forcedRecord = record;
    }

    function setBreakSubjectIndex(bool broken) external {
        breakSubjectIndex = broken;
    }

    /// @dev Arming again clears what the last call back left behind, so a suite that arms twice is
    /// never reading the first call's answer for the second.
    function armReentry(address target, bytes calldata payload) external {
        _reentryTarget = target;
        _reentryPayload = payload;
        reentryFired = false;
        reentryOk = false;
        reentryReturn = "";
    }

    function launchIdOfSubject(address subject) external view returns (uint256) {
        uint256 launchId = _launchIdOfSubject[subject];
        return breakSubjectIndex ? launchId + 1 : launchId;
    }

    function launches(uint256 launchId) external view returns (Launch memory) {
        return _launches[launchId];
    }

    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow)
    {
        if (launchesPaused) revert LaunchesArePaused();
        _requireBytes(0, bytes(params.name).length, MAX_NAME_BYTES);
        _requireBytes(1, bytes(params.symbol).length, MAX_SYMBOL_BYTES);
        _requireBytes(2, bytes(params.description).length, MAX_DESCRIPTION_BYTES);
        _requireBytes(3, bytes(params.website).length, MAX_WEBSITE_BYTES);
        _requireBytes(4, bytes(params.image).length, MAX_IMAGE_BYTES);
        if (params.treasury == address(0) || refusedTreasury[params.treasury]) revert RefusedTreasury(params.treasury);
        if (params.requiredRegentRaised == 0 || params.requiredRegentRaised > strategy.MAX_REACHABLE_RAISE()) {
            revert UnreachableRequiredRaise(params.requiredRegentRaised);
        }

        lastParams = params;
        launchId = nextLaunchId;
        nextLaunchId = launchId + 1;
        subject = _derive("subject", launchId);
        auction = _derive("auction", launchId);
        escrow = _derive("escrow", launchId);

        _launches[launchId] = Launch(
            forcedRecord.launcher == address(0) ? msg.sender : forcedRecord.launcher,
            forcedRecord.subject == address(0) ? subject : forcedRecord.subject,
            forcedRecord.auction == address(0) ? auction : forcedRecord.auction,
            forcedRecord.escrow == address(0) ? escrow : forcedRecord.escrow,
            forcedRecord.treasury == address(0) ? params.treasury : forcedRecord.treasury
        );
        _launchIdOfSubject[subject] = launchId;
        MockLBPStrategy(address(strategy))
            .open(auction, launchId, subject, escrow, params.treasury, params.requiredRegentRaised);

        if (_reentryTarget != address(0) && !reentryFired) {
            reentryFired = true;
            (reentryOk, reentryReturn) = _reentryTarget.call(_reentryPayload);
        }
    }

    function _requireBytes(uint256 field, uint256 length, uint256 maximum) private pure {
        if (length == 0) revert EmptyMetadataField(field);
        if (length > maximum) revert MetadataFieldTooLong(field, maximum, length);
    }

    function _derive(string memory kind, uint256 launchId) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(kind, launchId)))));
    }
}

contract KeyfleetAutolaunchTest is Test {
    uint256 private constant Q = 10e18;
    uint64 private constant VOTING_WINDOW = 24 hours;
    uint128 private constant RAISE = 1_000_000e18;
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private regent;
    MockToken private usdc;
    KeyfleetAssetRegistry private registry;
    MockLBPStrategy private strategy;
    MockAutolaunchFactory private factory;
    IRegentRevenueStaking private staking = IRegentRevenueStaking(address(0x57A1));

    address private safe = address(0x5AFE);
    address private treasury = address(0x7EA5);
    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private mallory = address(0x4A11);

    event AutolaunchProposed(uint256 indexed proposalId, bytes32 envelopeHash, uint64 executionExpiry);
    event AutolaunchExecuted(
        uint256 indexed proposalId, uint256 indexed launchId, address indexed subject, address auction, address escrow
    );
    event LaunchSynced(Keyfleet.LaunchState state);

    function setUp() public {
        regent = new MockToken("Regent", "REGENT");
        usdc = new MockToken("USD Coin", "USDC");
        registry = new KeyfleetAssetRegistry(safe, address(usdc));
        strategy = new MockLBPStrategy();
        factory = new MockAutolaunchFactory(strategy);
        factory.openLaunches();
        vm.warp(1_000_000);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet) {
        return new Keyfleet(
            preset,
            Q,
            regent,
            usdc,
            treasury,
            registry,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI)
        );
    }

    /// @dev A fleet holding exactly one key, owned by `alice`. One key is always a majority of the
    /// weight it is the whole of, on every preset, so a single YES carries any proposal here.
    function _fleetWithOneKey(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = _deploy(preset);
        uint256 price = fleet.nextPrice();
        regent.mint(buyer, price);
        vm.startPrank(buyer);
        regent.approve(address(fleet), price);
        fleet.purchase(alice, address(0), 2 * price, block.timestamp);
        vm.stopPrank();
    }

    function _envelope() private view returns (Keyfleet.LaunchEnvelope memory) {
        return Keyfleet.LaunchEnvelope({
            name: "Alpha Fleet Token",
            symbol: "ALPHA",
            description: "The token the alpha fleet voted to launch.",
            website: "https://regents.sh/alpha",
            image: "ipfs://alpha-image",
            requiredRegentRaised: RAISE,
            narrativeDigest: keccak256("narrative"),
            executionExpiry: uint64(block.timestamp) + VOTING_WINDOW + 7 days
        });
    }

    function _propose(Keyfleet fleet, Keyfleet.LaunchEnvelope memory envelope) private returns (uint256 proposalId) {
        KeyfleetVotes votes = fleet.VOTES();
        vm.prank(alice);
        proposalId = votes.proposeAutolaunch(1, envelope);
    }

    /// @dev Proposes, carries the vote and warps to the moment execution opens.
    function _proposeAndPass(Keyfleet fleet, Keyfleet.LaunchEnvelope memory envelope)
        private
        returns (uint256 proposalId)
    {
        KeyfleetVotes votes = fleet.VOTES();
        proposalId = _propose(fleet, envelope);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        votes.vote(proposalId, ids, true);
        vm.warp(votes.proposal(proposalId).closesAt);
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
            Q,
            regent,
            usdc,
            treasury,
            registry,
            staking,
            IRegentsAutolaunchFactoryV1(address(0)),
            VOTING_WINDOW,
            Keyfleet.Metadata("n", "s", BASE_URI)
        );
    }

    // --- 2. envelope validation at proposal time --------------------------

    /// @dev Invariant: an envelope the factory would refuse is refused when it is proposed, so the
    /// keys are never asked to vote on a launch that could not happen. The bounds are the factory's
    /// own published caps, read from it here exactly as the controller reads them. The caps are byte
    /// caps and the bound itself is accepted; only one byte over is not.
    function test_proposalRefusesAnyMetadataFieldThatIsEmptyOrOverItsByteCap() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
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
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
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

    /// @dev Invariant: an envelope must outlive the vote on it. An expiry at or before the moment
    /// voting closes could never be executed, so it is refused at proposal time rather than
    /// discovered by a fleet that voted for nothing.
    function test_proposalRefusesAnExpiryThatFallsAtOrBeforeTheVoteCloses() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint64 closesAt = uint64(block.timestamp) + VOTING_WINDOW;

        uint64[2] memory refused = [closesAt - 1, closesAt];
        for (uint256 i = 0; i < refused.length; ++i) {
            Keyfleet.LaunchEnvelope memory envelope = _envelope();
            envelope.executionExpiry = refused[i];
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.ExpiryNotAfterClose.selector, refused[i], closesAt));
            votes.proposeAutolaunch(1, envelope);
        }

        Keyfleet.LaunchEnvelope memory justEnough = _envelope();
        justEnough.executionExpiry = closesAt + 1;
        assertEq(_propose(fleet, justEnough), 1, "one second past the close is enough");
    }

    /// @dev Invariant: proposing an Autolaunch takes the same standing as every other kind, and the
    /// envelope the proposal carries is exactly the one the caller supplied.
    function test_proposalTakesStandingAndStoresTheEnvelopeItWasGiven() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        Keyfleet.LaunchEnvelope memory envelope = _envelope();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, uint256(1), alice));
        votes.proposeAutolaunch(1, envelope);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(votes));
        emit AutolaunchProposed(1, keccak256(abi.encode(envelope)), envelope.executionExpiry);
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

    // --- 3. execution ------------------------------------------------------

    /// @dev Invariant: a passed Autolaunch calls the factory once with the fleet as both launcher
    /// and treasury, and records only what the factory says it created. Nothing is approved, no
    /// token moves and the fleet's own capital is untouched.
    function test_executionLaunchesWithTheFleetAsLauncherAndTreasuryAndRecordsTheFactorysAnswer() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        Keyfleet.LaunchEnvelope memory envelope = _envelope();
        uint256 capitalBefore = fleet.freeCapital(address(regent));
        uint256 balanceBefore = regent.balanceOf(address(fleet));

        uint256 proposalId = _proposeAndPass(fleet, envelope);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit AutolaunchExecuted(
            proposalId,
            1,
            address(uint160(uint256(keccak256(abi.encode("subject", uint256(1)))))),
            address(uint160(uint256(keccak256(abi.encode("auction", uint256(1)))))),
            address(uint160(uint256(keccak256(abi.encode("escrow", uint256(1))))))
        );
        fleet.VOTES().execute(proposalId);

        IRegentsAutolaunchFactoryV1.Launch memory recorded = factory.launches(1);
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

        assertEq(regent.allowance(address(fleet), address(factory)), 0, "no allowance was granted to the factory");
        assertEq(regent.allowance(address(fleet), record.subject), 0, "nor to anything the launch created");
        assertEq(regent.balanceOf(address(fleet)), balanceBefore, "and not one atomic unit left the fleet");
        assertEq(fleet.freeCapital(address(regent)), capitalBefore, "the fleet's capital is exactly as it was");
    }

    /// @dev Invariant: only the fleet's own voting controller may launch. No holder, no proposer and
    /// no passer-by can call the typed entry point directly.
    function test_onlyTheVotingControllerMayLaunch() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);

        vm.prank(alice);
        vm.expectRevert(Keyfleet.OnlyVotes.selector);
        fleet.executeAutolaunch(1, _envelope());

        vm.prank(mallory);
        vm.expectRevert(Keyfleet.OnlyVotes.selector);
        fleet.executeAutolaunch(1, _envelope());
    }

    /// @dev Invariant: every preset can launch. The spec requires the adapter to be testable across
    /// all four, and the vote is the only gate in front of it: a fleet that has minted one key can
    /// propose and execute one launch, whichever ladder it is on.
    function test_everyPresetCanProposeAndExecuteOneLaunch() public {
        KeyfleetPresets.Preset[4] memory presets = [
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FleetTechAccelerant
        ];

        for (uint256 i = 0; i < presets.length; ++i) {
            Keyfleet fleet = _fleetWithOneKey(presets[i]);
            _executeFor(fleet, _envelope());
            assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated));
            assertEq(fleet.launchRecord().launchId, i + 1, "each fleet took the next launch from the shared factory");
        }
    }

    /// @dev Invariant: one created launch per fleet. A second proposal is refused outright once a
    /// launch exists, and a second proposal made before the first executed cannot execute after it.
    function test_aFleetCreatesOneLaunchAndOnlyOne() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();

        uint256 second = _proposeAndPass(fleet, _envelope());
        uint256 first = _proposeAndPass(fleet, _envelope());
        votes.execute(first);

        vm.expectRevert(Keyfleet.LaunchAlreadyCreated.selector);
        votes.execute(second);
        assertFalse(votes.proposal(second).executed, "the failed execution left the proposal unexecuted");

        vm.prank(alice);
        vm.expectRevert(Keyfleet.LaunchAlreadyCreated.selector);
        votes.proposeAutolaunch(1, _envelope());

        assertEq(factory.nextLaunchId(), 2, "the factory created exactly one launch for this fleet");
    }

    /// @dev Invariant: an approved launch that was not executed in time cannot be executed at all.
    /// The proposal is not consumed by the attempt; it is simply out of date.
    function test_anExpiredEnvelopeCannotExecuteAndConsumesNothing() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        Keyfleet.LaunchEnvelope memory envelope = _envelope();
        uint256 proposalId = _proposeAndPass(fleet, envelope);

        vm.warp(envelope.executionExpiry);
        votes.execute(proposalId);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated), "the last moment works");

        Keyfleet fresh = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes freshVotes = fresh.VOTES();
        Keyfleet.LaunchEnvelope memory late = _envelope();
        uint256 lateId = _proposeAndPass(fresh, late);

        vm.warp(late.executionExpiry + 1);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.ProposalExpired.selector, late.executionExpiry));
        freshVotes.execute(lateId);

        assertFalse(freshVotes.proposal(lateId).executed, "nothing was consumed");
        assertEq(uint256(fresh.launchState()), uint256(Keyfleet.LaunchState.NotCreated), "and nothing was created");
    }

    /// @dev Invariant: a factory that is refusing launches reverts the whole execution, so the
    /// proposal stays executable and the fleet records nothing. This is the case the atomicity rule
    /// exists for: a fleet can wait for the Safe to open the factory and execute the same approval
    /// afterwards, as long as its envelope has not expired.
    function test_aPausedFactoryLeavesTheProposalExecutable() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _proposeAndPass(fleet, _envelope());

        factory.closeLaunches();
        assertTrue(fleet.FACTORY().launchesPaused(), "the app can see why the next attempt will fail");
        vm.expectRevert(MockAutolaunchFactory.LaunchesArePaused.selector);
        votes.execute(proposalId);

        assertFalse(votes.proposal(proposalId).executed, "the execution mark was rolled back with the revert");
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Passed), "it is still a passed proposal");
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.NotCreated));
        assertEq(factory.nextLaunchId(), 1, "the factory consumed nothing");

        factory.openLaunches();
        votes.execute(proposalId);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated), "the same approval lands");
    }

    /// @dev Invariant: a treasury the factory refuses fails the same atomic way. Nothing about the
    /// factory's own rules is predicted at proposal time, because they are not the fleet's to
    /// predict, and a refusal costs the proposal nothing.
    function test_aTreasuryTheFactoryRefusesRevertsTheWholeExecution() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
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
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
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
    /// the vote it is executing, or into the fleet's deposit path, is refused by the same
    /// reentrancy guard that protects every other entry point, and the launch itself still
    /// completes on the factory's own terms.
    function test_aFactoryThatCallsBackIsRefusedByTheGuards() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
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

        Keyfleet second = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 secondId = _proposeAndPass(second, _envelope());
        factory.armReentry(address(second), abi.encodeCall(Keyfleet.depositCapital, (address(regent), 1e18)));
        second.VOTES().execute(secondId);

        assertTrue(factory.reentryFired(), "the factory called back a second time");
        assertFalse(factory.reentryOk(), "a deposit from inside the launch is refused too");
        assertEq(
            bytes4(factory.reentryReturn()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "by the fleet's own guard"
        );
    }

    // --- 5. sync -----------------------------------------------------------

    /// @dev Invariant: a launch the strategy has not settled is not economically failed. An auction
    /// that is still running, and one that has ended but has not been migrated, are both `Active`
    /// on the strategy, and a sync of either leaves the fleet exactly where it was and emits
    /// nothing at all.
    function test_syncLeavesAnUnsettledLaunchAloneAndEmitsNothing() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
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
    /// else. The SUBJECT, the auction, the escrow and the approved envelope are untouched by it,
    /// and the fleet's deposit admission is not turned on by it either.
    function test_syncRecordsTheGraduationArtifactsAndReplacesNothing() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        _executeFor(fleet, _envelope());
        Keyfleet.LaunchRecord memory before = fleet.launchRecord();

        address splitter = address(0x591177);
        address receiver = address(0xEC1E);
        bytes32 poolId = keccak256("pool");
        strategy.graduate(before.auction, splitter, receiver, poolId, 4242);

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
        assertFalse(registry.isTokenAllowed(address(fleet), after_.subject), "and SUBJECT is still not admitted");

        IRegentLBPStrategy.Distribution memory published = fleet.launchDistribution();
        assertEq(uint256(published.lifecycle), uint256(IRegentLBPStrategy.Lifecycle.Graduated), "read live, not stored");
        assertEq(published.treasury, address(fleet));
    }

    /// @dev Invariant: an auction the strategy settled as failed makes the fleet economically
    /// failed, and a terminal state is terminal: a later sync is refused rather than left to churn.
    function test_syncRecordsFailureAndTerminalStatesNeverChangeAgain() public {
        Keyfleet failed = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        _executeFor(failed, _envelope());
        strategy.fail(failed.launchRecord().auction);

        vm.expectEmit(false, false, false, true, address(failed));
        emit LaunchSynced(Keyfleet.LaunchState.EconomicallyFailed);
        failed.syncLaunch();
        assertEq(uint256(failed.launchState()), uint256(Keyfleet.LaunchState.EconomicallyFailed));

        vm.expectRevert(Keyfleet.LaunchSettled.selector);
        failed.syncLaunch();

        Keyfleet graduated = _fleetWithOneKey(KeyfleetPresets.Preset.FleetTechClassic);
        _executeFor(graduated, _envelope());
        strategy.graduate(graduated.launchRecord().auction, address(0x1), address(0x2), keccak256("p"), 1);
        graduated.syncLaunch();

        strategy.fail(graduated.launchRecord().auction);
        vm.expectRevert(Keyfleet.LaunchSettled.selector);
        graduated.syncLaunch();
        assertEq(uint256(graduated.launchState()), uint256(Keyfleet.LaunchState.Graduated), "graduation is forever");
    }

    // --- 6. gas ------------------------------------------------------------

    /// @dev Invariant: executing an Autolaunch costs a fixed amount, whatever the fleet's size.
    /// The figure is measured against the mock factory and most of it is the mock's own writing, so
    /// it is a regression bound on this side of the call rather than a prediction of the real cost:
    /// the real factory deploys a token, an escrow and an auction and spends far more than this.
    function test_autolaunchExecutionGas() public {
        Keyfleet fleet = _fleetWithOneKey(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _proposeAndPass(fleet, _envelope());

        vm.cool(address(fleet));
        vm.cool(address(votes));
        vm.cool(address(factory));

        uint256 before = gasleft();
        votes.execute(proposalId);
        uint256 used = before - gasleft();

        console2.log("autolaunch execution gas through the mock factory:", used);
        assertLt(used, 889_000, "an execution stays under the published ceiling");
        assertEq(fleet.launchRecord().launchId, 1);
    }

    // --- helpers -----------------------------------------------------------

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
