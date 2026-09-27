// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken, MockStaking, ReenteringToken} from "./KeyfleetIncome.t.sol";
import {
    IMintable,
    MockAutolaunchFactory,
    MockEscrow,
    MockLaunchToken,
    MockLBPStrategy
} from "./mocks/MockAutolaunch.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev The fleet's shared money. The launch's own receipts are shared money: the REGENT the
/// strategy sends at graduation and every SUBJECT the escrow releases, each booked exactly once
/// from the launch's own records whatever order the calls come in. Every other income-token receipt
/// goes to the keys. Shared money is spent only by a passed Pay, once the launch has settled and
/// within the fleet's pay cap per period.
contract KeyfleetTreasuryTest is Test {
    uint64 private constant VOTING_WINDOW = 24 hours;
    uint128 private constant RAISE = 1_000_000e18;
    /// @dev What the auction raised, what the pool took of it, and so what reaches the fleet.
    uint128 private constant RAISED = 1_200_000e18;
    uint128 private constant LP_REGENT = 700_000e18;
    uint256 private constant HELD = RAISED - LP_REGENT;
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private usdc;
    MockToken private regent;
    MockToken private other;
    MockLBPStrategy private strategy;
    MockAutolaunchFactory private factory;
    MockStaking private staking;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    /// @dev A Fibonacci Syndicate fleet with its eighty-six keys sold and its launch created but
    /// not settled, built once so every fuzz run starts from it.
    Keyfleet private fib;
    MockLaunchToken private subject;
    MockEscrow private escrow;

    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private mallory = address(0x4A11);

    event IncomeRecognized(address indexed asset, address indexed caller, uint256 amount);
    event SharedMoneyRecognized(address indexed asset, address indexed caller, uint256 amount);
    event GraduationHoldingsBooked(address indexed asset, uint256 amount);
    event VestingBooked(address indexed asset, uint256 amount, uint256 totalReleased);
    event BudgetPaid(
        address indexed asset, address indexed recipient, uint256 amount, uint256 periodStart, uint256 spentInPeriod
    );
    event ProposalCreated(
        uint256 indexed proposalId,
        KeyfleetVotes.Kind indexed kind,
        address indexed proposer,
        uint64 closesAt,
        uint256 snapshotMinted,
        bytes32 digest,
        string text
    );
    event PayProposed(
        uint256 indexed proposalId,
        address indexed asset,
        uint256 amount,
        address indexed recipient,
        uint64 executionExpiry
    );
    event DecisionRecorded(uint256 indexed proposalId, bytes32 digest);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        regent = new MockToken("Regent", "REGENT");
        other = new MockToken("Other", "OTH");
        staking = new MockStaking(usdc);
        strategy = new MockLBPStrategy(IMintable(address(regent)));
        factory = new MockAutolaunchFactory(strategy);
        factory.openLaunches();
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        vm.warp(1_000_000);

        fib = _launchedFleet(KeyfleetPresets.Preset.FibonacciSyndicate);
        subject = MockLaunchToken(fib.launchRecord().subject);
        escrow = MockEscrow(fib.launchRecord().escrow);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = new Keyfleet(
            preset,
            usdc,
            regent,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: vrfSubscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    function _isFibonacci(KeyfleetPresets.Preset preset) private pure returns (bool) {
        return preset == KeyfleetPresets.Preset.FibonacciSyndicate || preset == KeyfleetPresets.Preset.FibonacciCascade;
    }

    /// @dev A fleet that sold exactly the keys its preset needs to launch and then created its
    /// launch by vote, which the strategy still has open.
    function _launchedFleet(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = _deploy(preset);
        _buyKeys(
            fleet,
            _isFibonacci(preset)
                ? KeyfleetPresets.FIBONACCI_AUTOLAUNCH_MIN_KEYS
                : KeyfleetPresets.FLEET_TECH_AUTOLAUNCH_MIN_KEYS
        );
        KeyfleetVotes votes = fleet.VOTES();
        vm.prank(alice);
        uint256 proposalId = votes.proposeAutolaunch(1, _envelope());
        _passAll(fleet, proposalId);
        votes.execute(proposalId);
        assertEq(uint256(fleet.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated));
    }

    /// @dev Key 1 goes to `alice` and every later key to a wallet of its own that makes `alice` its
    /// voting delegate, so `alice` can vote every key in one call.
    function _buyKeys(Keyfleet fleet, uint256 count) private {
        KeyfleetVotes votes = fleet.VOTES();
        for (uint256 i = 0; i < count; ++i) {
            uint256 tokenId = fleet.totalMinted() + 1;
            address holder = _holder(tokenId);
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

    function _holder(uint256 tokenId) private pure returns (address) {
        return tokenId == 1 ? address(0xA11CE) : address(uint160(0x100000 + tokenId));
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

    function _ids(uint256 first, uint256 count) private pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    /// @dev Every key votes YES, and time moves to the moment execution opens.
    function _passAll(Keyfleet fleet, uint256 proposalId) private {
        KeyfleetVotes votes = fleet.VOTES();
        uint256[] memory ids = _ids(1, votes.proposal(proposalId).snapshotMinted);
        vm.prank(alice);
        votes.vote(proposalId, ids, true);
        vm.warp(votes.proposal(proposalId).closesAt);
    }

    /// @dev Proposes a Pay from `alice` without voting on it.
    function _proposePay(Keyfleet fleet, address asset, uint256 amount, address recipient)
        private
        returns (uint256 proposalId)
    {
        KeyfleetVotes votes = fleet.VOTES();
        vm.prank(alice);
        proposalId = votes.proposePay(1, asset, amount, recipient, "Pay for the audit", keccak256("invoice"));
    }

    /// @dev Proposes several Pay amounts of `asset` at once and passes them all in the same window,
    /// so they can be executed later at chosen times. Leaves time at the window's close.
    function _passPays(Keyfleet fleet, address asset, uint256[] memory amounts)
        private
        returns (uint256[] memory proposalIds)
    {
        KeyfleetVotes votes = fleet.VOTES();
        proposalIds = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; ++i) {
            proposalIds[i] = _proposePay(fleet, asset, amounts[i], bob);
        }
        uint256 keys = votes.proposal(proposalIds[0]).snapshotMinted;
        vm.startPrank(alice);
        for (uint256 i = 0; i < amounts.length; ++i) {
            votes.vote(proposalIds[i], _ids(1, keys), true);
        }
        vm.stopPrank();
        vm.warp(votes.proposal(proposalIds[amounts.length - 1]).closesAt);
    }

    function _one(uint256 a) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function _two(uint256 a, uint256 b) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        (values[0], values[1]) = (a, b);
    }

    function _three(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory values) {
        values = new uint256[](3);
        (values[0], values[1], values[2]) = (a, b, c);
    }

    function _period(Keyfleet fleet, address asset) private view returns (uint256 start, uint256 cap, uint256 spent) {
        (start, cap, spent) = fleet.payPeriod(asset);
    }

    /// @dev The strategy graduates the launch and sends the fleet the raised REGENT the pool did not
    /// use. Nobody syncs.
    function _graduate(Keyfleet fleet) private {
        strategy.graduate(
            fleet.launchRecord().auction, address(0x591177), address(0xEC1E), keccak256("pool"), 4242, RAISED, LP_REGENT
        );
    }

    /// @dev The strategy graduates the launch and a sync records it, so the fleet's shared money
    /// may be paid out.
    function _settle(Keyfleet fleet) private {
        _graduate(fleet);
        fleet.syncLaunch();
    }

    /// @dev Sends `amount` of `token` to the fleet by plain transfer and sorts it, as anyone may.
    function _receive(Keyfleet fleet, MockToken token, uint256 amount) private returns (uint256 sorted) {
        token.mint(address(fleet), amount);
        vm.prank(bob);
        sorted = fleet.recognizeSurplus(address(token));
    }

    // --- 1. the launched token --------------------------------------------

    /// @dev Invariant: the SUBJECT a launch creates is an income token from the moment the launch
    /// is created. Any of it that reaches the fleet before the launch settles goes to the keys.
    function test_theLaunchedTokenIsAnIncomeTokenFromCreation() public {
        KeyfleetRewards rewards = fib.REWARDS();
        assertEq(rewards.launchedToken(), address(subject), "the ledger knows the launched token");
        assertEq(rewards.rewardAssets().length, 3, "USDC, REGENT and the launched token");
        assertTrue(rewards.isRewardAsset(address(subject)));

        subject.mint(address(fib), 10_000e18);
        vm.expectEmit(true, true, true, true, address(fib));
        emit IncomeRecognized(address(subject), bob, 10_000e18);
        vm.prank(bob);
        fib.recognizeSurplus(address(subject));

        assertEq(rewards.backed(address(subject)), 10_000e18, "all of it went to the keys");
        assertEq(fib.freeCapital(address(subject)), 0, "none of it is shared money");
        assertEq(uint256(fib.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated), "the launch is still open");
    }

    // --- 2. graduation ------------------------------------------------------

    /// @dev Invariant: at graduation the fleet receives the REGENT the auction raised less what the
    /// pool took, and exactly that figure, read from the auction and the strategy, is booked as
    /// shared money. None of it reaches the keys.
    function test_graduationBooksTheRaisedRegentThePoolDidNotUseAsSharedMoney() public {
        _graduate(fib);
        assertEq(regent.balanceOf(address(fib)), HELD, "the strategy sent the unused REGENT");
        assertEq(fib.surplus(address(regent)), HELD, "until it is booked it shows as unsorted");

        vm.expectEmit(true, true, true, true, address(fib));
        emit GraduationHoldingsBooked(address(regent), HELD);
        vm.prank(mallory);
        fib.syncLaunch();

        assertEq(uint256(fib.launchState()), uint256(Keyfleet.LaunchState.Graduated));
        assertEq(fib.freeCapital(address(regent)), HELD, "the whole figure is shared money");
        assertEq(fib.surplus(address(regent)), 0, "and nothing is left unsorted");
        assertEq(fib.REWARDS().backed(address(regent)), 0, "the keys received none of it");
        assertEq(fib.launchRecord().splitter, address(0x591177), "the sync recorded the graduation");
    }

    /// @dev Invariant: the graduation REGENT is shared money whichever call books it first: a sync
    /// or a sort of REGENT. REGENT income that arrives beside it still goes to the keys in full, so
    /// the call order never moves money from one class to the other.
    function test_graduationRegentIsSharedMoneyWhicheverCallComesFirst() public {
        uint256 income = 7_000e18;
        for (uint256 order = 0; order < 2; ++order) {
            Keyfleet fleet = _launchedFleet(KeyfleetPresets.Preset.FibonacciSyndicate);
            _graduate(fleet);
            regent.mint(address(fleet), income);

            if (order == 0) fleet.syncLaunch();
            fleet.recognizeSurplus(address(regent));

            assertEq(fleet.freeCapital(address(regent)), HELD, "the graduation REGENT is shared money");
            assertEq(fleet.REWARDS().backed(address(regent)), income, "and the income went to the keys");
            assertEq(regent.balanceOf(address(fleet)), HELD, "the fleet holds exactly its shared money");
        }
    }

    /// @dev Invariant: a failed launch sends the fleet nothing and books nothing. The launched token
    /// stays an income token and REGENT that arrives is income, and a sync of a failed launch is
    /// harmless and silent.
    function test_aFailedLaunchBooksNothing() public {
        strategy.fail(fib.launchRecord().auction);
        fib.syncLaunch();
        assertEq(uint256(fib.launchState()), uint256(Keyfleet.LaunchState.EconomicallyFailed));

        vm.recordLogs();
        assertEq(uint256(fib.syncLaunch()), uint256(Keyfleet.LaunchState.EconomicallyFailed), "still failed");
        assertEq(vm.getRecordedLogs().length, 0, "and silent");

        _receive(fib, regent, 10_000e18);
        assertEq(fib.freeCapital(address(regent)), 0, "nothing was booked as shared money");
        assertEq(fib.REWARDS().backed(address(regent)), 10_000e18, "REGENT that arrives is income");
    }

    // --- 3. vesting releases -------------------------------------------------

    /// @dev Invariant: every SUBJECT unit the escrow releases is shared money and is booked exactly
    /// once, from the escrow's own running total, however many releases happen between bookings and
    /// whichever call books them. Graduation that nobody synced is booked on the way.
    function test_everyEscrowReleaseIsSharedMoneyBookedExactlyOnce() public {
        _graduate(fib);
        escrow.release(1_000e18);

        vm.expectEmit(true, true, true, true, address(fib));
        emit VestingBooked(address(subject), 1_000e18, 1_000e18);
        assertEq(fib.recognizeSurplus(address(subject)), 0, "the release is booked, not sorted to the keys");
        assertEq(fib.freeCapital(address(subject)), 1_000e18, "it is shared money");
        assertEq(fib.vestingBooked(), 1_000e18);
        assertEq(fib.REWARDS().backed(address(subject)), 0, "the keys received none of it");
        assertEq(fib.freeCapital(address(regent)), HELD, "and the graduation was booked on the way");

        vm.recordLogs();
        fib.syncLaunch();
        assertEq(vm.getRecordedLogs().length, 0, "a second booking finds nothing new");
        assertEq(fib.freeCapital(address(subject)), 1_000e18, "and books nothing twice");

        escrow.release(500e18);
        escrow.release(250e18);
        vm.expectEmit(true, true, true, true, address(fib));
        emit VestingBooked(address(subject), 750e18, 1_750e18);
        fib.syncLaunch();
        assertEq(fib.freeCapital(address(subject)), 1_750e18, "two releases, one booking, each unit once");
        assertEq(subject.balanceOf(address(fib)), 1_750e18, "and the fleet holds exactly that");
    }

    /// @dev Invariant: SUBJECT that reaches the fleet from anywhere but the escrow is income, and a
    /// release is shared money, whichever arrives first and whether or not a sort ran between them.
    function test_launchedTokenFromElsewhereIsIncomeWhateverTheOrder() public {
        uint256 released = 1_000e18;
        uint256 income = 300e18;
        for (uint256 order = 0; order < 2; ++order) {
            Keyfleet fleet = _launchedFleet(KeyfleetPresets.Preset.FibonacciSyndicate);
            MockLaunchToken token = MockLaunchToken(fleet.launchRecord().subject);
            MockEscrow vesting = MockEscrow(fleet.launchRecord().escrow);
            _graduate(fleet);

            if (order == 0) {
                vesting.release(released);
                token.mint(address(fleet), income);
                fleet.recognizeSurplus(address(token));
            } else {
                token.mint(address(fleet), income);
                fleet.recognizeSurplus(address(token));
                vesting.release(released);
                fleet.recognizeSurplus(address(token));
            }

            assertEq(fleet.freeCapital(address(token)), released, "the release is shared money");
            assertEq(fleet.REWARDS().backed(address(token)), income, "everything else went to the keys");
        }
    }

    /// @dev Invariant: however releases, receipts, sorts and syncs are interleaved, each class ends
    /// up with exactly its own money: shared money holds every released SUBJECT unit and the
    /// graduation REGENT, the keys hold every other unit, and the fleet and its ledger each hold
    /// exactly what they have booked.
    function testFuzz_callOrderNeverChangesWhereMoneyLands(
        uint256 seed,
        uint96 firstRelease,
        uint96 laterRelease,
        uint96 subjectIncome,
        uint96 regentIncome
    ) public {
        // Seven levels are complete, so income below seven units cannot be divided and waits.
        subjectIncome = subjectIncome < 7 ? 0 : subjectIncome;
        regentIncome = regentIncome < 7 ? 0 : regentIncome;
        // The escrow holds 85 billion SUBJECT; each release takes at most 40 billion of it.
        firstRelease = uint96(bound(firstRelease, 0, 40_000_000_000e18));
        laterRelease = uint96(bound(laterRelease, 0, 40_000_000_000e18));
        _graduate(fib);

        uint256[7] memory steps = [uint256(0), 1, 2, 3, 4, 5, 6];
        for (uint256 i = steps.length - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (steps[i], steps[j]) = (steps[j], steps[i]);
        }
        for (uint256 i = 0; i < steps.length; ++i) {
            uint256 step = steps[i];
            if (step == 0) escrow.release(firstRelease);
            else if (step == 1) escrow.release(laterRelease);
            else if (step == 2) subject.mint(address(fib), subjectIncome);
            else if (step == 3) regent.mint(address(fib), regentIncome);
            else if (step == 4) fib.recognizeSurplus(address(subject));
            else if (step == 5) fib.recognizeSurplus(address(regent));
            else fib.syncLaunch();
        }
        fib.recognizeSurplus(address(subject));
        fib.recognizeSurplus(address(regent));

        KeyfleetRewards rewards = fib.REWARDS();
        uint256 released = uint256(firstRelease) + laterRelease;
        assertEq(fib.freeCapital(address(subject)), released, "every released unit is shared money");
        assertEq(fib.vestingBooked(), released, "booked exactly once");
        assertEq(rewards.backed(address(subject)), subjectIncome, "every other SUBJECT unit went to the keys");
        assertEq(fib.freeCapital(address(regent)), HELD, "the graduation REGENT is shared money");
        assertEq(rewards.backed(address(regent)), regentIncome, "every other REGENT unit went to the keys");
        assertEq(subject.balanceOf(address(fib)), fib.freeCapital(address(subject)), "the fleet holds its SUBJECT");
        assertEq(regent.balanceOf(address(fib)), fib.freeCapital(address(regent)), "and its REGENT");
        assertEq(subject.balanceOf(address(rewards)), rewards.backed(address(subject)), "the ledger its backing");
        assertEq(regent.balanceOf(address(rewards)), rewards.backed(address(regent)));
    }

    // --- 4. Pay proposals ----------------------------------------------------

    /// @dev Invariant: shared money is not the keys' to spend before the launch settles, so a Pay is
    /// refused at proposal time on a fleet with no launch and on one whose launch is still open,
    /// and the fleet refuses the payment itself too.
    function test_payIsRefusedBeforeTheLaunchSettles() public {
        Keyfleet unlaunched = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(unlaunched, 1);
        Keyfleet[2] memory fleets = [unlaunched, fib];

        for (uint256 i = 0; i < fleets.length; ++i) {
            Keyfleet fleet = fleets[i];
            KeyfleetVotes votes = fleet.VOTES();
            vm.prank(alice);
            vm.expectRevert(Keyfleet.LaunchNotSettled.selector);
            votes.proposePay(1, address(usdc), 1, bob, "", bytes32(0));

            vm.prank(address(votes));
            vm.expectRevert(Keyfleet.LaunchNotSettled.selector);
            fleet.payFromBudget(address(usdc), 1, bob);
        }
    }

    /// @dev Invariant: a Pay names a real asset, a nonzero amount and a real recipient, needs the
    /// same standing as any proposal, carries its reason in the creation event only, and stores
    /// exactly what it was given as kind 2 with an expiry thirty days after its vote closes.
    function test_proposePayChecksAndStoresItsPayload() public {
        _settle(fib);
        KeyfleetVotes votes = fib.VOTES();

        vm.startPrank(alice);
        vm.expectRevert(KeyfleetVotes.ZeroAddress.selector);
        votes.proposePay(1, address(0), 1, bob, "", bytes32(0));
        vm.expectRevert(KeyfleetVotes.ZeroAmount.selector);
        votes.proposePay(1, address(other), 0, bob, "", bytes32(0));
        vm.stopPrank();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, alice));
        votes.proposePay(1, address(other), 1, bob, "", bytes32(0));

        bytes32 digest = keccak256("invoice");
        string memory text = "Pay the auditor for the October review";
        uint256 expectedId = votes.proposalCount() + 1;
        uint64 closesAt = uint64(block.timestamp) + VOTING_WINDOW;
        assertEq(votes.PAY_EXECUTION_WINDOW(), 30 days);
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(expectedId, KeyfleetVotes.Kind.Pay, alice, closesAt, 86, digest, text);
        vm.expectEmit(true, true, true, true, address(votes));
        emit PayProposed(expectedId, address(other), 5_000, bob, closesAt + 30 days);
        vm.prank(alice);
        uint256 proposalId = votes.proposePay(1, address(other), 5_000, bob, text, digest);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(uint256(stored.kind), 2, "Pay is kind 2");
        assertEq(stored.asset, address(other));
        assertEq(stored.amount, 5_000);
        assertEq(stored.recipient, bob);
        assertEq(stored.digest, digest);
        assertEq(stored.snapshotMinted, 86);
    }

    /// @dev Invariant: a payment can never be sent where it would be stuck for good: zero, the
    /// fleet itself, its voting controller and its ledger are refused when the Pay is proposed,
    /// before any vote.
    function test_aPayCannotNameTheFleetItsControllerItsLedgerOrZeroAsRecipient() public {
        _settle(fib);
        KeyfleetVotes votes = fib.VOTES();
        address[4] memory refused = [address(0), address(fib), address(votes), address(fib.REWARDS())];
        uint256 before = votes.proposalCount();

        for (uint256 i = 0; i < refused.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.RecipientNotAllowed.selector, refused[i]));
            votes.proposePay(1, address(other), 1, refused[i], "", bytes32(0));
        }
        assertEq(votes.proposalCount(), before, "no proposal was created");
    }

    /// @dev Invariant: a passed Pay can execute until exactly thirty days after its vote closes, the
    /// last second included, and never after. An expired Pay stays Passed and moves nothing. The
    /// window is the Pay's alone: a Decision passed alongside it still records afterwards.
    function test_aPassedPayExpiresThirtyDaysAfterItsVoteCloses() public {
        _settle(fib);
        _receive(fib, other, 196_000);
        KeyfleetVotes votes = fib.VOTES();
        vm.startPrank(alice);
        uint256 decisionId = votes.proposeDecision(1, "Thank the auditor", bytes32(0));
        votes.vote(decisionId, _ids(1, 86), true);
        vm.stopPrank();
        uint256[] memory ids = _passPays(fib, address(other), _two(10_000, 10_000));
        uint64 closesAt = votes.proposal(ids[0]).closesAt;
        assertEq(votes.proposal(decisionId).closesAt, closesAt, "all three votes close together");
        uint64 expiry = closesAt + 30 days;

        vm.warp(expiry);
        votes.execute(ids[0]);
        assertEq(other.balanceOf(bob), 10_000, "the last second still pays");

        vm.warp(expiry + 1);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.ProposalExpired.selector, expiry));
        votes.execute(ids[1]);
        assertEq(uint256(votes.state(ids[1])), uint256(KeyfleetVotes.State.Passed), "nothing was consumed");
        assertEq(other.balanceOf(bob), 10_000, "and nothing moved");

        vm.expectEmit(true, true, true, true, address(votes));
        emit DecisionRecorded(decisionId, bytes32(0));
        votes.execute(decisionId);
    }

    /// @dev Invariant: a Pay a past majority approved cannot wait for shared money to grow and be
    /// taken long after those keys have changed hands. Passed while it did not fit, it is refused
    /// 700 days later even though shared money now covers it many times over.
    function test_aStalePayIsRefusedSevenHundredDaysLater() public {
        _settle(fib);
        _receive(fib, other, 196_000); // cap at a first payment 39,200.
        KeyfleetVotes votes = fib.VOTES();
        uint256[] memory ids = _passPays(fib, address(other), _one(500_000));
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(other), 500_000, 39_200));
        votes.execute(ids[0]);

        for (uint256 tokenId = 1; tokenId <= 86; ++tokenId) {
            address holder = _holder(tokenId);
            vm.prank(holder);
            fib.transferFrom(holder, address(uint160(0xCAFE0000 + tokenId)), tokenId);
        }

        vm.warp(block.timestamp + 700 days);
        _receive(fib, other, 3_920_000); // shared money 4,116,000, cap at a first payment 823,200.
        uint64 expiry = votes.proposal(ids[0]).closesAt + 30 days;
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.ProposalExpired.selector, expiry));
        votes.execute(ids[0]);
        assertEq(other.balanceOf(bob), 0, "the stale payment never moves");
        assertEq(fib.freeCapital(address(other)), 4_116_000, "and shared money is whole");
    }

    /// @dev Invariant: a passed Pay moves exactly its amount of shared money to its recipient, opens
    /// the asset's pay period at that moment, and touches nothing the keys are owed.
    function test_aPassedPayMovesSharedMoneyToTheRecipient() public {
        _settle(fib);
        _receive(fib, other, 196_000);
        KeyfleetVotes votes = fib.VOTES();

        uint256[] memory ids = _passPays(fib, address(other), _one(39_200));
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(ids[0], mallory);
        vm.expectEmit(true, true, true, true, address(fib));
        emit BudgetPaid(address(other), bob, 39_200, block.timestamp, 39_200);
        vm.prank(mallory);
        votes.execute(ids[0]);

        assertEq(other.balanceOf(bob), 39_200, "the recipient was paid");
        assertEq(fib.freeCapital(address(other)), 156_800, "from shared money");
        assertEq(uint256(votes.state(ids[0])), uint256(KeyfleetVotes.State.Executed));
        (uint256 start, uint256 cap, uint256 spent) = _period(fib, address(other));
        assertEq(start, block.timestamp);
        assertEq(cap, 39_200, "twenty percent of shared money at the first payment");
        assertEq(spent, 39_200);
    }

    /// @dev Invariant: payments passed side by side cannot together take more than the period's
    /// cap. The one that would go over reverts at execution with what is left, consumes nothing,
    /// and stays executable in a later period.
    function test_severalPaysInOnePeriodCannotTogetherExceedTheCap() public {
        _settle(fib);
        _receive(fib, other, 196_000); // cap at the first payment 39,200.
        KeyfleetVotes votes = fib.VOTES();

        uint256[] memory ids = _passPays(fib, address(other), _three(15_000, 15_000, 15_000));
        votes.execute(ids[0]);
        votes.execute(ids[1]);

        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(other), 15_000, 9_200));
        votes.execute(ids[2]);
        assertEq(uint256(votes.state(ids[2])), uint256(KeyfleetVotes.State.Passed), "it is still waiting");
        assertEq(fib.freeCapital(address(other)), 166_000, "only the two that fit were paid");
        (,, uint256 spent) = _period(fib, address(other));
        assertEq(spent, 30_000);

        (uint256 start,,) = _period(fib, address(other));
        vm.warp(start + fib.PAY_PERIOD());
        votes.execute(ids[2]);
        assertEq(other.balanceOf(bob), 45_000, "the third was paid in the next period");
    }

    /// @dev Invariant: a pay period lasts exactly thirty days from its first payment. One second
    /// before that the old cap still binds; at thirty days a new period opens with a new cap. A
    /// period opens only at a payment, so after a quiet stretch the next one starts when the next
    /// payment is made, not thirty days after the last period ended.
    function test_thePayPeriodRollsOverAtExactlyThirtyDays() public {
        _settle(fib);
        _receive(fib, other, 196_000);
        KeyfleetVotes votes = fib.VOTES();
        uint256 period = fib.PAY_PERIOD();
        assertEq(period, 30 days);

        uint256[] memory ids = _passPays(fib, address(other), _two(39_200, 10_000));
        uint256 t0 = block.timestamp;
        votes.execute(ids[0]); // the whole cap of the first period.

        vm.warp(t0 + period - 1);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(other), 10_000, 0));
        votes.execute(ids[1]);

        vm.warp(t0 + period);
        vm.expectEmit(true, true, true, true, address(fib));
        emit BudgetPaid(address(other), bob, 10_000, t0 + period, 10_000);
        votes.execute(ids[1]);
        (uint256 start, uint256 cap, uint256 spent) = _period(fib, address(other));
        assertEq(start, t0 + period, "a new period opened at exactly thirty days");
        assertEq(cap, (156_800 * 2_000) / 10_000, "with a cap measured from the shared money left then");
        assertEq(spent, 10_000);

        // Forty-five quiet days after the second period opened, a newly passed payment opens the third.
        vm.warp(t0 + period + 45 days);
        uint256[] memory later = _passPays(fib, address(other), _one(10_000));
        votes.execute(later[0]);
        (start,,) = _period(fib, address(other));
        assertEq(start, block.timestamp, "the period starts at the payment, not on a calendar");
        assertGt(start, t0 + 2 * period);
    }

    /// @dev Invariant: the cap is 20% of shared money as it stands at the period's first payment.
    /// Money received between proposing and that payment counts; money received after it does not
    /// raise the cap until the next period.
    function test_theCapIsMeasuredAtThePeriodsFirstPayment() public {
        _settle(fib);
        _receive(fib, other, 196_000);
        KeyfleetVotes votes = fib.VOTES();
        uint256[] memory ids = _passPays(fib, address(other), _three(10_000, 68_401, 68_400));

        _receive(fib, other, 196_000); // 392,000 before the first payment.
        votes.execute(ids[0]);
        (, uint256 cap,) = _period(fib, address(other));
        assertEq(cap, 78_400, "twenty percent of shared money at the first payment, not at the proposal");

        _receive(fib, other, 196_000); // shared money grows again mid-period.
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(other), 68_401, 68_400));
        votes.execute(ids[1]);
        (, cap,) = _period(fib, address(other));
        assertEq(cap, 78_400, "the cap did not grow with the new money");

        votes.execute(ids[2]);
        (,, uint256 spent) = _period(fib, address(other));
        assertEq(spent, cap, "the period's cap is used exactly");
    }

    /// @dev Invariant: only the fleet's own voting controller can spend shared money. No holder and
    /// not the fleet itself can call the payment directly.
    function test_onlyTheVotingControllerMayPay() public {
        _settle(fib);
        _receive(fib, other, 196_000);

        address[3] memory callers = [alice, mallory, address(fib)];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(Keyfleet.OnlyVotes.selector);
            fib.payFromBudget(address(other), 1, callers[i]);
        }

        vm.prank(address(fib.VOTES()));
        fib.payFromBudget(address(other), 1, bob);
        assertEq(other.balanceOf(bob), 1, "the controller can");
    }

    /// @dev Invariant: a USDC payment draws on shared money alone. The Cascade completion reserve,
    /// the owed protocol share and the keys' USDC rewards are separate figures a payment never
    /// touches, and nothing is left over as surplus afterwards.
    function test_aUsdcPaySpendsOnlySharedMoney() public {
        Keyfleet cascade = _launchedFleet(KeyfleetPresets.Preset.FibonacciCascade);
        _buyKeys(cascade, 1); // opens level 8, so the completion reserve is holding USDC.
        _settle(cascade);
        KeyfleetVotes votes = cascade.VOTES();

        uint256 capital = cascade.freeCapital(address(usdc));
        uint256 reserve = cascade.cascadeReserve();
        uint256 owed = cascade.protocolShareOwed();
        uint256 backed = cascade.REWARDS().backed(address(usdc));
        assertGt(reserve, 0, "the reserve holds USDC");
        uint256 amount = (capital * 2_000) / 10_000;

        vm.prank(alice);
        uint256 proposalId = votes.proposePay(1, address(usdc), amount, bob, "", bytes32(0));
        _passAll(cascade, proposalId);
        votes.execute(proposalId);

        assertEq(usdc.balanceOf(bob), amount);
        assertEq(cascade.freeCapital(address(usdc)), capital - amount, "only shared money moved");
        assertEq(cascade.cascadeReserve(), reserve, "the reserve is untouched");
        assertEq(cascade.protocolShareOwed(), owed, "the owed share is untouched");
        assertEq(cascade.REWARDS().backed(address(usdc)), backed, "the keys' USDC is untouched");
        assertEq(cascade.surplus(address(usdc)), 0, "and the books still balance");
    }

    /// @dev Invariant: a Pay of the launched token spends released SUBJECT only, never what the keys
    /// were paid, and books a release nobody has booked yet before it measures the cap.
    function test_aPayOfTheLaunchedTokenSpendsOnlyReleasedSubject() public {
        _settle(fib);
        subject.mint(address(fib), 300e18);
        fib.recognizeSurplus(address(subject));
        KeyfleetVotes votes = fib.VOTES();
        uint256[] memory ids = _passPays(fib, address(subject), _two(200e18 + 1, 200e18));
        escrow.release(1_000e18);

        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(subject), 200e18 + 1, 200e18));
        votes.execute(ids[0]);

        votes.execute(ids[1]);
        assertEq(subject.balanceOf(bob), 200e18, "a fifth of the release was paid out");
        assertEq(fib.freeCapital(address(subject)), 800e18, "the rest of the release is still shared money");
        assertEq(fib.REWARDS().backed(address(subject)), 300e18, "and the keys' SUBJECT is untouched");
    }

    /// @dev Invariant: a paid asset that calls back into the fleet from inside the payment finds
    /// the fleet's guard held, so the whole execution reverts and the proposal stays unexecuted.
    function test_aPaidAssetThatCallsBackCannotReenterTheFleet() public {
        _settle(fib);
        ReenteringToken token = new ReenteringToken();
        token.mint(address(fib), 1_000_000);
        fib.recognizeSurplus(address(token));
        assertEq(fib.freeCapital(address(token)), 1_000_000, "any other token is shared money");
        KeyfleetVotes votes = fib.VOTES();

        vm.prank(alice);
        uint256 proposalId = votes.proposePay(1, address(token), 1_000, bob, "", bytes32(0));
        _passAll(fib, proposalId);
        token.arm(fib, Keyfleet.recognizeSurplus.selector);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        votes.execute(proposalId);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Passed), "nothing was consumed");
        assertEq(token.balanceOf(bob), 0);
    }
}
