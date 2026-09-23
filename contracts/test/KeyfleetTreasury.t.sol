// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetAssetRegistry} from "../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {MockToken, MockLBPStrategy, MockAutolaunchFactory} from "./KeyfleetAutolaunch.t.sol";
import {MockStaking, ReenteringToken} from "./KeyfleetDeposits.t.sol";

/// @dev The fleet after its launch: income recognized once the launch has graduated or failed is
/// split between the budget and the keys, and the budget is spent only by a passed Pay vote within
/// the per-period cap.
contract KeyfleetTreasuryTest is Test {
    uint64 private constant VOTING_WINDOW = 24 hours;
    uint128 private constant RAISE = 1_000_000e18;
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private usdc;
    MockToken private subject;
    KeyfleetAssetRegistry private registry;
    MockLBPStrategy private strategy;
    MockAutolaunchFactory private factory;
    MockStaking private staking;

    /// @dev A Fibonacci Syndicate fleet with its eighty-six keys sold and its launch created but
    /// not settled, built once so every fuzz run starts from it.
    Keyfleet private fib;

    address private safe = address(0x5AFE);
    address private treasury = address(0x7EA5);
    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private mallory = address(0x4A11);

    event SurplusRecognized(address indexed asset, address indexed caller, uint256 amount, uint256 net);
    event LaunchIncomeSplit(
        address indexed asset, address indexed caller, uint256 gross, uint256 fee, uint256 toBudget, uint256 toKeys
    );
    event BudgetPaid(
        address indexed asset, address indexed recipient, uint256 amount, uint256 periodStart, uint256 spentInPeriod
    );
    event LaunchSynced(Keyfleet.LaunchState state);
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
        subject = new MockToken("Subject", "SUBJ");
        registry = new KeyfleetAssetRegistry(safe, address(usdc));
        staking = new MockStaking(usdc);
        strategy = new MockLBPStrategy();
        factory = new MockAutolaunchFactory(strategy);
        factory.openLaunches();
        vm.warp(1_000_000);

        fib = _launchedFleet(KeyfleetPresets.Preset.FibonacciSyndicate);
        _admit(fib, address(subject));
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet) {
        return new Keyfleet(
            preset,
            usdc,
            treasury,
            registry,
            staking,
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", BASE_URI)
        );
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
            fleet.purchase(holder, address(0), price, block.timestamp);
            vm.stopPrank();
            if (holder != alice) {
                vm.prank(holder);
                votes.setVotingDelegate(alice);
            }
        }
    }

    function _holder(uint256 tokenId) private view returns (address) {
        return tokenId == 1 ? alice : address(uint160(0x100000 + tokenId));
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

    function _admit(Keyfleet fleet, address token) private {
        vm.startPrank(safe);
        registry.setFactoryTokenAllowed(token, true);
        registry.setFleetTokenAllowed(address(fleet), token, true);
        vm.stopPrank();
    }

    function _graduate(Keyfleet fleet) private {
        strategy.graduate(fleet.launchRecord().auction, address(0x591177), address(0xEC1E), keccak256("pool"), 4242);
        fleet.syncLaunch();
    }

    function _fail(Keyfleet fleet) private {
        strategy.fail(fleet.launchRecord().auction);
        fleet.syncLaunch();
    }

    /// @dev Sends `amount` of `token` to the fleet by bare transfer and recognizes it.
    function _recognize(Keyfleet fleet, MockToken token, uint256 amount) private returns (uint256 net) {
        token.mint(address(fleet), amount);
        vm.prank(bob);
        net = fleet.recognizeSurplus(address(token));
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

    /// @dev Proposes several Pay amounts at once and passes them all in the same window, so they
    /// can be executed later at chosen times. Leaves time at the window's close.
    function _passPays(Keyfleet fleet, uint256[] memory amounts) private returns (uint256[] memory proposalIds) {
        KeyfleetVotes votes = fleet.VOTES();
        proposalIds = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; ++i) {
            proposalIds[i] = _proposePay(fleet, address(subject), amounts[i], bob);
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

    // --- 1. before the launch settles --------------------------------------

    /// @dev Invariant: until the launch has graduated or failed, recognition is exactly what it
    /// always was: the whole post-fee amount becomes budget and nothing reaches the keys. That holds
    /// with no launch at all and with a launch the strategy still has open, which recognition asks
    /// about and leaves alone.
    function test_beforeTheLaunchSettlesRecognitionBooksEverythingAsBudget() public {
        Keyfleet unlaunched = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _admit(unlaunched, address(subject));
        Keyfleet[2] memory fleets = [unlaunched, fib];

        for (uint256 i = 0; i < fleets.length; ++i) {
            Keyfleet fleet = fleets[i];
            Keyfleet.LaunchState stateBefore = fleet.launchState();
            subject.mint(address(fleet), 1_000_000);

            vm.expectEmit(true, true, true, true, address(fleet));
            emit SurplusRecognized(address(subject), bob, 1_000_000, 980_000);
            vm.prank(bob);
            assertEq(fleet.recognizeSurplus(address(subject)), 980_000);

            assertEq(fleet.freeCapital(address(subject)), 980_000, "the whole net is budget");
            assertFalse(fleet.REWARDS().isRewardAsset(address(subject)), "and nothing reached the keys");
            assertEq(uint256(fleet.launchState()), uint256(stateBefore), "an open launch stays open");
            assertFalse(fleet.launchSettled());
        }
    }

    // --- 2. the split -----------------------------------------------------

    /// @dev Invariant: once the launch has graduated, a recognized surplus pays the 2% fee and then
    /// splits the rest: 20% of it, rounded down, becomes budget and the remainder is paid to the keys
    /// in the same transaction. The three parts add back up to the gross exactly, the keys' part is
    /// fully backed in the ledger, and the fleet keeps only the budget.
    function test_aGraduatedLaunchSplitsIncomeTwentyPercentToBudgetAndTheRestToKeys() public {
        _graduate(fib);
        assertTrue(fib.launchSettled());
        KeyfleetRewards rewards = fib.REWARDS();

        subject.mint(address(fib), 1_000_000);
        vm.expectEmit(true, true, true, true, address(fib));
        emit LaunchIncomeSplit(address(subject), bob, 1_000_000, 20_000, 196_000, 784_000);
        vm.prank(bob);
        assertEq(fib.recognizeSurplus(address(subject)), 980_000, "it returns the post-fee amount");

        assertEq(subject.balanceOf(treasury), 20_000, "the fee");
        assertEq(fib.freeCapital(address(subject)), 196_000, "the budget");
        assertEq(subject.balanceOf(address(fib)), 196_000, "the fleet keeps only the budget");
        assertEq(rewards.backed(address(subject)), 784_000, "the keys' part");
        assertEq(subject.balanceOf(address(rewards)), 784_000, "backed by tokens in the ledger");
        assertEq(fib.surplus(address(subject)), 0, "nothing is left unaccounted");

        _recognize(fib, subject, 500_000);
        assertEq(fib.freeCapital(address(subject)), 196_000 + 98_000, "a second recognition adds to the budget");
        assertEq(rewards.backed(address(subject)), 784_000 + 392_000, "and to the keys");
    }

    /// @dev Invariant: the split cannot be skipped by recognizing income after the strategy has
    /// settled the launch but before anyone synced it. Recognition syncs first, then splits.
    function test_recognitionSyncsALaunchTheStrategyHasSettled() public {
        strategy.graduate(fib.launchRecord().auction, address(0x591177), address(0xEC1E), keccak256("pool"), 4242);
        assertEq(uint256(fib.launchState()), uint256(Keyfleet.LaunchState.AuctionCreated), "nobody synced");

        subject.mint(address(fib), 1_000_000);
        vm.expectEmit(false, false, false, true, address(fib));
        emit LaunchSynced(Keyfleet.LaunchState.Graduated);
        vm.expectEmit(true, true, true, true, address(fib));
        emit LaunchIncomeSplit(address(subject), bob, 1_000_000, 20_000, 196_000, 784_000);
        vm.prank(bob);
        fib.recognizeSurplus(address(subject));

        assertEq(uint256(fib.launchState()), uint256(Keyfleet.LaunchState.Graduated));
        assertEq(fib.launchRecord().splitter, address(0x591177), "the sync recorded the artifacts");
    }

    /// @dev Invariant: after the launch, a Fibonacci fleet pays each completed level an equal share
    /// and each key an equal part of its level's share, by the same rule a revenue deposit uses. At
    /// eighty-six keys a level-1 key, one of two, receives seventeen times what a level-7 key, one of
    /// thirty-four, receives, and every key's holder can claim what it was allocated.
    function test_launchIncomePaysALevelOneKeySeventeenTimesALevelSevenKey() public {
        _graduate(fib);
        KeyfleetRewards rewards = fib.REWARDS();
        assertEq(fib.completedLevels(), 7);
        _recognize(fib, subject, 100_000_000);

        uint256 toKeys = 78_400_000;
        uint256 perLevel = toKeys / 7;
        assertEq(rewards.accrued(address(subject), 1), perLevel / 2, "a level-1 key");
        assertEq(rewards.accrued(address(subject), 86), perLevel / 34, "a level-7 key");
        assertApproxEqRel(
            rewards.accrued(address(subject), 1),
            17 * rewards.accrued(address(subject), 86),
            1e13,
            "seventeen times as much"
        );

        uint256 paid;
        for (uint256 tokenId = 1; tokenId <= 86; ++tokenId) {
            address holder = _holder(tokenId);
            uint256 expected = rewards.accrued(address(subject), tokenId);
            vm.prank(holder);
            assertEq(rewards.claim(address(subject), _ids(tokenId, 1), address(0)), expected);
            assertEq(subject.balanceOf(holder), expected, "the holder received its key's allocation");
            paid += expected;
        }
        assertLe(toKeys - paid, 86, "every key was paid, less at most one unit of rounding each");
        assertEq(rewards.backed(address(subject)), toKeys - paid, "and the rounding stays backed");
        assertEq(subject.balanceOf(address(rewards)), rewards.backed(address(subject)));
    }

    /// @dev Invariant: Classic and Accelerant have no levels, so launch income is shared equally by
    /// every key, and the two presets pay exactly the same per key for the same income.
    function test_classicAndAccelerantPayEqualAmountsPerKey() public {
        KeyfleetPresets.Preset[2] memory presets =
            [KeyfleetPresets.Preset.FleetTechClassic, KeyfleetPresets.Preset.FleetTechAccelerant];
        uint256[2] memory firstKey;

        for (uint256 i = 0; i < presets.length; ++i) {
            Keyfleet fleet = _launchedFleet(presets[i]);
            _admit(fleet, address(subject));
            _graduate(fleet);
            _recognize(fleet, subject, 1_000_000);

            KeyfleetRewards rewards = fleet.REWARDS();
            firstKey[i] = rewards.accrued(address(subject), 1);
            assertEq(firstKey[i], 7_840, "784,000 over one hundred keys");
            assertEq(rewards.accrued(address(subject), 100), firstKey[i], "the last key earns the same");
        }
        assertEq(firstKey[0], firstKey[1], "Classic and Accelerant pay the same per key");
    }

    /// @dev Invariant: for any amount and any number of recognitions, on a graduated or a failed
    /// launch, the fee, the budget and the keys' part add up to the gross exactly; the budget is
    /// exactly 20% of the post-fee amount rounded down; the fleet holds exactly its budget; and the
    /// ledger holds at least everything it owes, and owes no more than it was given.
    function testFuzz_theSplitAddsUpToTheGrossAndTheLedgerStaysBacked(uint256 first, uint256 second, bool failed)
        public
    {
        if (failed) _fail(fib);
        else _graduate(fib);
        KeyfleetRewards rewards = fib.REWARDS();

        uint256[2] memory grosses = [bound(first, 8, 1e36), bound(second, 8, 1e36)];
        uint256 keysTotal;
        for (uint256 i = 0; i < grosses.length; ++i) {
            uint256 gross = grosses[i];
            uint256 feeBefore = subject.balanceOf(treasury);
            uint256 budgetBefore = fib.freeCapital(address(subject));
            uint256 backedBefore = rewards.isRewardAsset(address(subject)) ? rewards.backed(address(subject)) : 0;

            uint256 net = _recognize(fib, subject, gross);

            uint256 fee = subject.balanceOf(treasury) - feeBefore;
            uint256 toBudget = fib.freeCapital(address(subject)) - budgetBefore;
            uint256 toKeys = rewards.backed(address(subject)) - backedBefore;
            keysTotal += toKeys;
            assertEq(fee + toBudget + toKeys, gross, "fee, budget and keys are the whole gross");
            assertEq(fee, (gross * 200) / 10_000, "the fee is two percent rounded down");
            assertEq(net, gross - fee);
            assertEq(toBudget, (net * 2_000) / 10_000, "the budget is twenty percent of the rest rounded down");
            assertEq(subject.balanceOf(address(fib)), fib.freeCapital(address(subject)), "the fleet holds its budget");
            assertEq(subject.balanceOf(address(rewards)), rewards.backed(address(subject)), "the ledger is backed");
        }

        uint256 owed;
        for (uint256 tokenId = 1; tokenId <= 86; ++tokenId) {
            owed += rewards.accrued(address(subject), tokenId);
        }
        assertLe(owed, keysTotal, "the keys are never owed more than they were given");
        assertLe(keysTotal - owed, 2 * 86, "and lose at most a unit of rounding per key per recognition");
    }

    /// @dev Invariant: the keys' part follows the ledger's rule that an amount smaller than the
    /// number of completed levels cannot be split equally. Such a surplus is refused, stays where it
    /// is, and is recognized whole once more arrives.
    function test_incomeTooSmallToSplitAcrossTheLevelsWaitsForMore() public {
        _graduate(fib);
        subject.mint(address(fib), 7);
        vm.expectRevert(KeyfleetRewards.ZeroAmount.selector);
        fib.recognizeSurplus(address(subject));
        assertEq(fib.surplus(address(subject)), 7, "the surplus is still there");

        subject.mint(address(fib), 1);
        vm.expectEmit(true, true, true, true, address(fib));
        emit LaunchIncomeSplit(address(subject), address(this), 8, 0, 1, 7);
        fib.recognizeSurplus(address(subject));
    }

    /// @dev Invariant: a failed launch settles the fleet as surely as a graduated one. Recognition
    /// syncs it, splits what arrives, and the budget can then be paid out by vote, so a fleet whose
    /// launch failed never has its own capital stranded.
    function test_aFailedLaunchAlsoSplitsIncomeAndUnlocksPay() public {
        strategy.fail(fib.launchRecord().auction);
        subject.mint(address(fib), 1_000_000);
        vm.expectEmit(false, false, false, true, address(fib));
        emit LaunchSynced(Keyfleet.LaunchState.EconomicallyFailed);
        vm.expectEmit(true, true, true, true, address(fib));
        emit LaunchIncomeSplit(address(subject), address(this), 1_000_000, 20_000, 196_000, 784_000);
        fib.recognizeSurplus(address(subject));
        assertTrue(fib.launchSettled());

        uint256[] memory ids = _passPays(fib, _one(39_200));
        fib.VOTES().execute(ids[0]);
        assertEq(subject.balanceOf(bob), 39_200, "the budget was paid");
        assertEq(fib.freeCapital(address(subject)), 196_000 - 39_200);
    }

    // --- 3. Pay proposals ----------------------------------------------------

    /// @dev Invariant: the budget is not the keys' to spend before the launch settles, so a Pay is
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
        _graduate(fib);
        KeyfleetVotes votes = fib.VOTES();

        vm.startPrank(alice);
        vm.expectRevert(KeyfleetVotes.ZeroAddress.selector);
        votes.proposePay(1, address(0), 1, bob, "", bytes32(0));
        vm.expectRevert(KeyfleetVotes.ZeroAmount.selector);
        votes.proposePay(1, address(subject), 0, bob, "", bytes32(0));
        vm.stopPrank();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotAuthorizedForKey.selector, 1, alice));
        votes.proposePay(1, address(subject), 1, bob, "", bytes32(0));

        bytes32 digest = keccak256("invoice");
        string memory text = "Pay the auditor for the October review";
        uint256 expectedId = votes.proposalCount() + 1;
        uint64 closesAt = uint64(block.timestamp) + VOTING_WINDOW;
        assertEq(votes.PAY_EXECUTION_WINDOW(), 30 days);
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(expectedId, KeyfleetVotes.Kind.Pay, alice, closesAt, 86, digest, text);
        vm.expectEmit(true, true, true, true, address(votes));
        emit PayProposed(expectedId, address(subject), 5_000, bob, closesAt + 30 days);
        vm.prank(alice);
        uint256 proposalId = votes.proposePay(1, address(subject), 5_000, bob, text, digest);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(uint256(stored.kind), 2, "Pay is kind 2");
        assertEq(stored.asset, address(subject));
        assertEq(stored.amount, 5_000);
        assertEq(stored.recipient, bob);
        assertEq(stored.digest, digest);
        assertEq(stored.snapshotMinted, 86);
    }

    /// @dev Invariant: a payment can never be sent where it would be stuck for good or charged the fee
    /// again: zero, the fleet itself, its voting controller and its ledger are refused when the Pay is
    /// proposed, before any vote.
    function test_aPayCannotNameTheFleetItsControllerItsLedgerOrZeroAsRecipient() public {
        _graduate(fib);
        KeyfleetVotes votes = fib.VOTES();
        address[4] memory refused = [address(0), address(fib), address(votes), address(fib.REWARDS())];
        uint256 before = votes.proposalCount();

        for (uint256 i = 0; i < refused.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.RecipientNotAllowed.selector, refused[i]));
            votes.proposePay(1, address(subject), 1, refused[i], "", bytes32(0));
        }
        assertEq(votes.proposalCount(), before, "no proposal was created");
    }

    /// @dev Invariant: a passed Pay can execute until exactly thirty days after its vote closes, the
    /// last second included, and never after. An expired Pay stays Passed and moves nothing. The
    /// window is the Pay's alone: a Decision passed alongside it still records afterwards.
    function test_aPassedPayExpiresThirtyDaysAfterItsVoteCloses() public {
        _graduate(fib);
        _recognize(fib, subject, 1_000_000);
        KeyfleetVotes votes = fib.VOTES();
        vm.startPrank(alice);
        uint256 decisionId = votes.proposeDecision(1, "Thank the auditor", bytes32(0));
        votes.vote(decisionId, _ids(1, 86), true);
        vm.stopPrank();
        uint256[] memory ids = _passPays(fib, _two(10_000, 10_000));
        uint64 closesAt = votes.proposal(ids[0]).closesAt;
        assertEq(votes.proposal(decisionId).closesAt, closesAt, "all three votes close together");
        uint64 expiry = closesAt + 30 days;

        vm.warp(expiry);
        votes.execute(ids[0]);
        assertEq(subject.balanceOf(bob), 10_000, "the last second still pays");

        vm.warp(expiry + 1);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.ProposalExpired.selector, expiry));
        votes.execute(ids[1]);
        assertEq(uint256(votes.state(ids[1])), uint256(KeyfleetVotes.State.Passed), "nothing was consumed");
        assertEq(subject.balanceOf(bob), 10_000, "and nothing moved");

        vm.expectEmit(true, true, true, true, address(votes));
        emit DecisionRecorded(decisionId, bytes32(0));
        votes.execute(decisionId);
    }

    /// @dev Invariant: a Pay a past majority approved cannot wait for the budget to grow and be taken
    /// long after those keys have changed hands. Passed while it did not fit, it is refused 700 days
    /// later even though the budget now covers it many times over.
    function test_aStalePayIsRefusedSevenHundredDaysLater() public {
        _graduate(fib);
        _recognize(fib, subject, 1_000_000); // budget 196,000, cap at a first payment 39,200.
        KeyfleetVotes votes = fib.VOTES();
        uint256[] memory ids = _passPays(fib, _one(500_000));
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(subject), 500_000, 39_200));
        votes.execute(ids[0]);

        for (uint256 tokenId = 1; tokenId <= 86; ++tokenId) {
            address holder = _holder(tokenId);
            vm.prank(holder);
            fib.transferFrom(holder, address(uint160(0xCAFE0000 + tokenId)), tokenId);
        }

        vm.warp(block.timestamp + 700 days);
        _recognize(fib, subject, 20_000_000); // budget 4,116,000, cap at a first payment 823,200.
        uint64 expiry = votes.proposal(ids[0]).closesAt + 30 days;
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.ProposalExpired.selector, expiry));
        votes.execute(ids[0]);
        assertEq(subject.balanceOf(bob), 0, "the stale payment never moves");
        assertEq(fib.freeCapital(address(subject)), 4_116_000, "and the budget is whole");
    }

    /// @dev Invariant: a passed Pay moves exactly its amount from the budget to its recipient, opens
    /// the asset's pay period at that moment, and touches nothing the keys are owed.
    function test_aPassedPayMovesBudgetToTheRecipient() public {
        _graduate(fib);
        _recognize(fib, subject, 1_000_000);
        uint256 backed = fib.REWARDS().backed(address(subject));
        KeyfleetVotes votes = fib.VOTES();

        uint256[] memory ids = _passPays(fib, _one(39_200));
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(ids[0], mallory);
        vm.expectEmit(true, true, true, true, address(fib));
        emit BudgetPaid(address(subject), bob, 39_200, block.timestamp, 39_200);
        vm.prank(mallory);
        votes.execute(ids[0]);

        assertEq(subject.balanceOf(bob), 39_200, "the recipient was paid");
        assertEq(fib.freeCapital(address(subject)), 156_800, "from the budget");
        assertEq(fib.REWARDS().backed(address(subject)), backed, "and nothing the keys are owed moved");
        assertEq(uint256(votes.state(ids[0])), uint256(KeyfleetVotes.State.Executed));
        (uint256 start, uint256 cap, uint256 spent) = _period(fib, address(subject));
        assertEq(start, block.timestamp);
        assertEq(cap, 39_200, "twenty percent of the budget at the first payment");
        assertEq(spent, 39_200);
    }

    /// @dev Invariant: payments passed side by side cannot together take more than the period's
    /// cap. The one that would go over reverts at execution with what is left, consumes nothing,
    /// and stays executable in a later period.
    function test_severalPaysInOnePeriodCannotTogetherExceedTheCap() public {
        _graduate(fib);
        _recognize(fib, subject, 1_000_000); // budget 196,000; cap at the first payment 39,200.
        KeyfleetVotes votes = fib.VOTES();

        uint256[] memory ids = _passPays(fib, _three(15_000, 15_000, 15_000));
        votes.execute(ids[0]);
        votes.execute(ids[1]);

        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(subject), 15_000, 9_200));
        votes.execute(ids[2]);
        assertEq(uint256(votes.state(ids[2])), uint256(KeyfleetVotes.State.Passed), "it is still waiting");
        assertEq(fib.freeCapital(address(subject)), 166_000, "only the two that fit were paid");
        (,, uint256 spent) = _period(fib, address(subject));
        assertEq(spent, 30_000);

        (uint256 start,,) = _period(fib, address(subject));
        vm.warp(start + fib.PAY_PERIOD());
        votes.execute(ids[2]);
        assertEq(subject.balanceOf(bob), 45_000, "the third was paid in the next period");
    }

    /// @dev Invariant: a pay period lasts exactly thirty days from its first payment. One second
    /// before that the old cap still binds; at thirty days a new period opens with a new cap. A
    /// period opens only at a payment, so after a quiet stretch the next one starts when the next
    /// payment is made, not thirty days after the last period ended.
    function test_thePayPeriodRollsOverAtExactlyThirtyDays() public {
        _graduate(fib);
        _recognize(fib, subject, 1_000_000);
        KeyfleetVotes votes = fib.VOTES();
        uint256 period = fib.PAY_PERIOD();
        assertEq(period, 30 days);

        uint256[] memory ids = _passPays(fib, _two(39_200, 10_000));
        uint256 t0 = block.timestamp;
        votes.execute(ids[0]); // the whole cap of the first period.

        vm.warp(t0 + period - 1);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(subject), 10_000, 0));
        votes.execute(ids[1]);

        vm.warp(t0 + period);
        vm.expectEmit(true, true, true, true, address(fib));
        emit BudgetPaid(address(subject), bob, 10_000, t0 + period, 10_000);
        votes.execute(ids[1]);
        (uint256 start, uint256 cap, uint256 spent) = _period(fib, address(subject));
        assertEq(start, t0 + period, "a new period opened at exactly thirty days");
        assertEq(cap, (156_800 * 2_000) / 10_000, "with a cap measured from the budget left then");
        assertEq(spent, 10_000);

        // Forty-five quiet days after the second period opened, a newly passed payment opens the third.
        vm.warp(t0 + period + 45 days);
        uint256[] memory later = _passPays(fib, _one(10_000));
        votes.execute(later[0]);
        (start,,) = _period(fib, address(subject));
        assertEq(start, block.timestamp, "the period starts at the payment, not on a calendar");
        assertGt(start, t0 + 2 * period);
    }

    /// @dev Invariant: the cap is 20% of the budget as it stands at the period's first payment. Income
    /// recognized between proposing and that payment counts; income recognized after it does not
    /// raise the cap until the next period.
    function test_theCapIsMeasuredAtThePeriodsFirstPayment() public {
        _graduate(fib);
        _recognize(fib, subject, 1_000_000); // budget 196,000.
        KeyfleetVotes votes = fib.VOTES();
        uint256[] memory ids = _passPays(fib, _three(10_000, 68_401, 68_400));

        _recognize(fib, subject, 1_000_000); // budget 392,000 before the first payment.
        votes.execute(ids[0]);
        (, uint256 cap,) = _period(fib, address(subject));
        assertEq(cap, 78_400, "twenty percent of the budget at the first payment, not at the proposal");

        _recognize(fib, subject, 1_000_000); // budget grows again mid-period.
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.PayCapExceeded.selector, address(subject), 68_401, 68_400));
        votes.execute(ids[1]);
        (, cap,) = _period(fib, address(subject));
        assertEq(cap, 78_400, "the cap did not grow with the new income");

        votes.execute(ids[2]);
        (,, uint256 spent) = _period(fib, address(subject));
        assertEq(spent, cap, "the period's cap is used exactly");
    }

    /// @dev Invariant: only the fleet's own voting controller can spend the budget. No holder, no
    /// Safe, no treasury and not the fleet itself can call the payment directly.
    function test_onlyTheVotingControllerMayPayFromTheBudget() public {
        _graduate(fib);
        _recognize(fib, subject, 1_000_000);

        address[5] memory callers = [alice, safe, treasury, mallory, address(fib)];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(Keyfleet.OnlyVotes.selector);
            fib.payFromBudget(address(subject), 1, callers[i]);
        }

        vm.prank(address(fib.VOTES()));
        fib.payFromBudget(address(subject), 1, bob);
        assertEq(subject.balanceOf(bob), 1, "the controller can");
    }

    /// @dev Invariant: a USDC payment draws on free capital alone. The Cascade completion reserve,
    /// the owed protocol share and the keys' USDC rewards are separate figures a payment never
    /// touches, and nothing is left over as surplus afterwards.
    function test_aUsdcPaySpendsOnlyFreeCapital() public {
        Keyfleet cascade = _launchedFleet(KeyfleetPresets.Preset.FibonacciCascade);
        _buyKeys(cascade, 1); // opens level 8, so the completion reserve is holding USDC.
        _graduate(cascade);
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
        assertEq(cascade.freeCapital(address(usdc)), capital - amount, "only free capital moved");
        assertEq(cascade.cascadeReserve(), reserve, "the reserve is untouched");
        assertEq(cascade.protocolShareOwed(), owed, "the owed share is untouched");
        assertEq(cascade.REWARDS().backed(address(usdc)), backed, "the keys' USDC is untouched");
        assertEq(cascade.surplus(address(usdc)), 0, "and the books still balance");
    }

    /// @dev Invariant: a paid asset that calls back into the fleet from inside the payment finds
    /// the fleet's guard held, so the whole execution reverts and the proposal stays unexecuted.
    function test_aPaidAssetThatCallsBackCannotReenterTheFleet() public {
        _graduate(fib);
        ReenteringToken token = new ReenteringToken();
        _admit(fib, address(token));
        token.mint(address(fib), 1_000_000);
        fib.recognizeSurplus(address(token));
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
