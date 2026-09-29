// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {IVRFCoordinatorV2Plus} from "../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken, ReenteringToken} from "./KeyfleetIncome.t.sol";
import {MockVRFCoordinatorV2Plus} from "./mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev The fleet's shared money: USDC from purchases and Cascade completions, and every token
/// other than USDC that reaches the fleet. It is spent only by an approved Pay, at any time, and
/// every payment is matched: it is at most the YES keys' share, and every other key sold collects
/// the same per key.
contract KeyfleetTreasuryTest is Test {
    string private constant BASE_URI = "https://keys.regents.sh/alpha/";

    MockToken private usdc;
    MockToken private other;
    MockVRFCoordinatorV2Plus private vrf;
    uint256 private vrfSubscription;

    /// @dev A Fibonacci Syndicate fleet with its first ten keys sold, built once so every test
    /// starts from it.
    Keyfleet private fib;

    address private buyer = address(0xB0B0B0);
    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private mallory = address(0x4A11);
    address private carol = address(0xCA201);

    event BudgetPaid(address indexed asset, address indexed recipient, uint256 amount, uint256 share, uint256 matched);
    event Collected(uint256 indexed proposalId, uint256 share, uint256[] tokenIds);
    event ProposalCreated(
        uint256 indexed proposalId,
        KeyfleetVotes.Kind indexed kind,
        address indexed proposer,
        uint64 openedBlock,
        bytes32 digest,
        string text
    );
    event PayProposed(uint256 indexed proposalId, address indexed asset, uint256 amount, address indexed recipient);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC");
        other = new MockToken("Other", "OTH");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        vm.warp(1_000_000);

        fib = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        _buyKeys(fib, 10);
    }

    // --- helpers ---------------------------------------------------------

    function _deploy(KeyfleetPresets.Preset preset) private returns (Keyfleet fleet) {
        fleet = new Keyfleet(
            preset,
            usdc,
            address(0x7EA5),
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

    function _ids(uint256 first, uint256 count) private pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    /// @dev Every key votes YES. Every key was bought before the proposal opened.
    function _passAll(Keyfleet fleet, uint256 proposalId) private {
        KeyfleetVotes votes = fleet.VOTES();
        uint256[] memory ids = _ids(1, fleet.totalMinted());
        vm.prank(alice);
        votes.vote(proposalId, ids, true);
    }

    /// @dev Proposes a Pay from `alice` in a fresh block, so every key already sold may vote on
    /// it, and passes it.
    function _approvedPay(Keyfleet fleet, address asset, uint256 amount, address recipient)
        private
        returns (uint256 proposalId)
    {
        vm.roll(block.number + 1);
        KeyfleetVotes votes = fleet.VOTES();
        vm.prank(alice);
        proposalId = votes.proposePay(1, asset, amount, recipient, "Pay for the audit", keccak256("invoice"));
        _passAll(fleet, proposalId);
    }

    /// @dev Sends `amount` of `token` to the fleet by plain transfer and sorts it, as anyone may.
    function _receive(Keyfleet fleet, MockToken token, uint256 amount) private returns (uint256 sorted) {
        token.mint(address(fleet), amount);
        vm.prank(bob);
        sorted = fleet.recognizeSurplus(address(token));
    }

    // --- 1. Pay proposals ----------------------------------------------------

    /// @dev Invariant: shared money can be spent all at once when every key votes YES. There is no
    /// cap and no period, and with no key left out nothing is matched.
    function test_payHasNoCap() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(fleet, 3);
        _receive(fleet, other, 50_000);

        uint256 proposalId = _approvedPay(fleet, address(other), 50_000, bob);
        KeyfleetVotes votes = fleet.VOTES();
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalExecuted(proposalId, mallory);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit BudgetPaid(address(other), bob, 50_000, 16_667, 0);
        vm.prank(mallory);
        votes.execute(proposalId);

        assertEq(other.balanceOf(bob), 50_000, "the whole of the shared money was paid");
        assertEq(fleet.freeCapital(address(other)), 0);
    }

    /// @dev Invariant: a Pay names a real asset, a nonzero amount and a real recipient, needs the
    /// same standing as any proposal, carries its reason in the creation event only, and stores
    /// exactly what it was given as kind 1 with the block it opened in.
    function test_proposePayChecksAndStoresItsPayload() public {
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
        vm.expectEmit(true, true, true, true, address(votes));
        emit ProposalCreated(expectedId, KeyfleetVotes.Kind.Pay, alice, uint64(block.number), digest, text);
        vm.expectEmit(true, true, true, true, address(votes));
        emit PayProposed(expectedId, address(other), 5_000, bob);
        vm.prank(alice);
        uint256 proposalId = votes.proposePay(1, address(other), 5_000, bob, text, digest);

        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(uint256(stored.kind), 1, "Pay is kind 1");
        assertEq(stored.asset, address(other));
        assertEq(stored.amount, 5_000);
        assertEq(stored.recipient, bob);
        assertEq(stored.digest, digest);
        assertEq(stored.openedBlock, block.number);
    }

    /// @dev Invariant: a payment can never be sent where it would be stuck for good: zero, the
    /// fleet itself, its voting controller and its ledger are refused when the Pay is proposed,
    /// before any vote.
    function test_aPayCannotNameTheFleetItsControllerItsLedgerOrZeroAsRecipient() public {
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

    /// @dev Invariant: a Pay above the YES keys' share is refused when carried out, consumes nothing
    /// and stays open, and the same approval pays once enough shared money has arrived. With every
    /// key voting YES their share is all of it.
    function test_aPayAboveTheSharedMoneyHeldWaitsForTheMoney() public {
        _receive(fib, other, 10_000);
        KeyfleetVotes votes = fib.VOTES();
        uint256 proposalId = _approvedPay(fib, address(other), 15_000, bob);

        vm.expectRevert(abi.encodeWithSelector(Keyfleet.AboveYesShare.selector, address(other), 15_000, 0, 10_000));
        votes.execute(proposalId);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Approved), "it is still open");
        assertFalse(votes.proposal(proposalId).executed, "and nothing was consumed");

        _receive(fib, other, 5_000);
        votes.execute(proposalId);
        assertEq(other.balanceOf(bob), 15_000, "the same approval paid");
        assertEq(fib.freeCapital(address(other)), 0);
    }

    /// @dev Invariant: an approved Pay never expires. Seven hundred days later it still pays.
    function test_anApprovedPayStaysOpenUntilItIsCarriedOut() public {
        _receive(fib, other, 10_000);
        KeyfleetVotes votes = fib.VOTES();
        uint256 first = _approvedPay(fib, address(other), 4_000, bob);
        uint256 second = _approvedPay(fib, address(other), 6_000, bob);

        votes.execute(first);
        vm.warp(block.timestamp + 700 days);
        vm.roll(block.number + 1_000_000);
        votes.execute(second);
        assertEq(other.balanceOf(bob), 10_000, "both paid, back to back and seven hundred days apart");
    }

    /// @dev Invariant: only the fleet's own voting controller can spend shared money. No holder,
    /// no passer-by and not the fleet itself can call the payment directly.
    function test_onlyTheVotingControllerMayPay() public {
        _receive(fib, other, 1_000);

        uint256 keys = fib.totalMinted();
        address[3] memory callers = [alice, mallory, address(fib)];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(Keyfleet.OnlyVotes.selector);
            fib.payFromBudget(address(other), 1, callers[i], keys);
        }

        vm.prank(address(fib.VOTES()));
        fib.payFromBudget(address(other), 1, bob, keys);
        assertEq(other.balanceOf(bob), 1, "the controller can");
    }

    /// @dev Invariant: a USDC payment draws on shared money alone. The Cascade completion reserve,
    /// the owed protocol share and the keys' USDC are separate figures a payment never touches,
    /// even when the fleet's balance would cover more.
    function test_aUsdcPaySpendsOnlySharedMoney() public {
        Keyfleet cascade = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _buyKeys(cascade, KeyfleetPresets.fibonacciLevelEnd(7) + 1); // opens level 8, so the reserve holds USDC.
        _receive(cascade, usdc, 1_000e6);
        KeyfleetVotes votes = cascade.VOTES();

        uint256 capital = cascade.freeCapital(address(usdc));
        uint256 reserve = cascade.cascadeReserve();
        uint256 owed = cascade.protocolShareOwed();
        uint256 backed = cascade.REWARDS().backed(address(usdc));
        assertGt(reserve, 0, "the reserve holds USDC");
        assertGt(usdc.balanceOf(address(cascade)), capital, "the balance would cover more");

        uint256 tooMuch = _approvedPay(cascade, address(usdc), capital + 1, bob);
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.AboveYesShare.selector, address(usdc), capital + 1, 0, capital));
        votes.execute(tooMuch);

        uint256 exact = _approvedPay(cascade, address(usdc), capital, bob);
        votes.execute(exact);

        assertEq(usdc.balanceOf(bob), capital);
        assertEq(cascade.freeCapital(address(usdc)), 0, "only shared money moved");
        assertEq(cascade.cascadeReserve(), reserve, "the reserve is untouched");
        assertEq(cascade.protocolShareOwed(), owed, "the owed share is untouched");
        assertEq(cascade.REWARDS().backed(address(usdc)), backed, "the keys' USDC is untouched");
        assertEq(cascade.surplus(address(usdc)), 0, "and the books still balance");
    }

    /// @dev Invariant: a paid asset that calls back into the fleet from inside the payment finds
    /// the fleet's guard held, so the whole execution reverts and the proposal stays open.
    function test_aPaidAssetThatCallsBackCannotReenterTheFleet() public {
        ReenteringToken token = new ReenteringToken();
        token.mint(address(fib), 1_000_000);
        fib.recognizeSurplus(address(token));
        assertEq(fib.freeCapital(address(token)), 1_000_000, "any other token is shared money");
        KeyfleetVotes votes = fib.VOTES();

        uint256 proposalId = _approvedPay(fib, address(token), 1_000, bob);
        token.arm(fib, Keyfleet.recognizeSurplus.selector);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        votes.execute(proposalId);
        assertEq(uint256(votes.state(proposalId)), uint256(KeyfleetVotes.State.Approved), "nothing was consumed");
        assertEq(token.balanceOf(bob), 0);
    }

    // --- 2. matched payments ----------------------------------------------------

    /// @dev Proposes a Pay from `alice` in a fresh block and has `alice`, who votes every key, vote
    /// YES with `yes` and NO with `no`. Every other key stays silent.
    function _pay(Keyfleet fleet, address asset, uint256 amount, uint256[] memory yes, uint256[] memory no)
        private
        returns (uint256 proposalId)
    {
        vm.roll(block.number + 1);
        KeyfleetVotes votes = fleet.VOTES();
        vm.startPrank(alice);
        proposalId = votes.proposePay(1, asset, amount, bob, "Pay for the audit", bytes32(0));
        if (yes.length != 0) votes.vote(proposalId, yes, true);
        if (no.length != 0) votes.vote(proposalId, no, false);
        vm.stopPrank();
    }

    function _none() private pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _one(uint256 tokenId) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    /// @dev Invariant, the worked example: a Fleet Tech Classic fleet sells all 1024 keys for
    /// 32,032.45 USDC and holds 90% of it, 28,829.205 USDC, as shared money. 512 YES keys, exactly
    /// half, cannot approve anything. With 513 YES keys a payment sets aside its share, rounded up,
    /// for each of the other 511 keys, whether they voted NO or stayed silent, so the largest payment
    /// is 14,442.755769 USDC: with 28.153521 set aside for each other key it uses the shared money
    /// exactly, and one atomic unit more no longer fits. Each other key collects its share, paid to
    /// whoever holds it, which leaves no shared money and nothing held for anyone.
    function test_classicFiveHundredThirteenOfOneThousandTwentyFourMatchesEveryOtherKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(fleet, KeyfleetPresets.CLASSIC_SUPPLY);
        KeyfleetVotes votes = fleet.VOTES();
        assertEq(fleet.freeCapital(address(usdc)), 28_829_205_000, "28,829.205 USDC of shared money");

        uint256 tooMuch = _pay(fleet, address(usdc), 14_442_755_770, _ids(1, 512), _ids(514, 200));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, 512, 1024));
        votes.execute(tooMuch);
        vm.prank(alice);
        votes.vote(tooMuch, _one(513), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                Keyfleet.AboveYesShare.selector, address(usdc), 14_442_755_770, 511 * 28_153_521, 28_829_205_000
            )
        );
        votes.execute(tooMuch);

        uint256 proposalId = _pay(fleet, address(usdc), 14_442_755_769, _ids(1, 513), _ids(514, 200));
        vm.expectEmit(true, true, true, true, address(fleet));
        emit BudgetPaid(address(usdc), bob, 14_442_755_769, 28_153_521, 14_386_449_231);
        votes.execute(proposalId);

        assertEq(usdc.balanceOf(bob), 14_442_755_769, "14,442.755769 paid");
        assertEq(usdc.balanceOf(address(votes)), 14_386_449_231, "28.153521 set aside for each of the 511 other keys");
        assertEq(fleet.freeCapital(address(usdc)), 0, "and no shared money is left");
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        assertEq(stored.share, 28_153_521);
        assertEq(stored.keysSold, 1024);

        uint256[] memory others = _ids(514, 511);
        vm.expectEmit(true, true, true, true, address(votes));
        emit Collected(proposalId, 28_153_521, others);
        vm.prank(mallory);
        votes.collect(proposalId, others);

        for (uint256 tokenId = 514; tokenId <= 1024; ++tokenId) {
            assertEq(usdc.balanceOf(_holder(tokenId)), 28_153_521, "each other key collected 28.153521");
        }
        assertEq(usdc.balanceOf(mallory), 0, "the caller is paid nothing");
        assertEq(usdc.balanceOf(address(votes)), 0, "and nothing is left held");
        assertEq(fleet.surplus(address(usdc)), 0, "the fleet's books still balance");
    }

    /// @dev Invariant: however many payments pass, with whichever keys voting YES, every key ends
    /// up with the same share of the shared money it started with, to within one atomic unit per
    /// payment: rounding each match up leaves every key that did not vote YES up to one unit ahead
    /// of the YES keys, and never behind. A key's share is what is left divided evenly, plus what it collected, plus what it
    /// spent: its equal part of each payment it voted YES on. Nothing is created or lost: the
    /// recipient, the keys and what is left add up to the starting money exactly.
    function testFuzz_everyKeyKeepsAnEqualShareAcrossRepeatedPayments(
        uint256 keys,
        uint256 start,
        uint256[3] memory yesCounts,
        uint256[3] memory offsets,
        uint256[3] memory amounts
    ) public {
        keys = bound(keys, 3, 21);
        start = bound(start, 1, 1e30);
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(fleet, keys);
        _receive(fleet, other, start);

        uint256[] memory spent = new uint256[](keys + 1);
        uint256[3] memory proposals;
        for (uint256 j = 0; j < 3; ++j) {
            proposals[j] = _fuzzPay(fleet, yesCounts[j], offsets[j], amounts[j], spent);
        }
        for (uint256 j = 0; j < 3; ++j) {
            _collectAll(fleet, proposals[j]);
        }

        assertEq(other.balanceOf(address(fleet.VOTES())), 0, "every match was collected");
        assertEq(fleet.surplus(address(other)), 0);
        _assertEqualShares(fleet, start, spent);
    }

    /// @dev One payment of the fuzz: YES from a run of keys starting at `offset`, wrapping round,
    /// more than half of them; an amount that fits with its matches rounded up, which the YES keys'
    /// share less one unit for each other key always does. Adds each YES key's equal part of the
    /// payment, times 1e18, to `spent`. Returns zero when there is too little to pay.
    function _fuzzPay(Keyfleet fleet, uint256 yesCount, uint256 offset, uint256 amount, uint256[] memory spent)
        private
        returns (uint256 proposalId)
    {
        uint256 keys = fleet.totalMinted();
        uint256 yesVotes = bound(yesCount, keys / 2 + 1, keys);
        uint256 available = fleet.freeCapital(address(other));
        if (available <= keys - yesVotes) return 0;
        uint256 most = Math.mulDiv(available - (keys - yesVotes), yesVotes, keys);
        if (most == 0) return 0;
        amount = bound(amount, 1, most);

        uint256[] memory yes = new uint256[](yesVotes);
        for (uint256 i = 0; i < yesVotes; ++i) {
            yes[i] = (offset % keys + i) % keys + 1;
            spent[yes[i]] += amount * 1e18 / yesVotes;
        }
        proposalId = _pay(fleet, address(other), amount, yes, _none());
        fleet.VOTES().execute(proposalId);
        assertEq(
            fleet.VOTES().proposal(proposalId).share,
            Math.ceilDiv(amount, yesVotes),
            "every other key is matched alike, rounded up"
        );
    }

    /// @dev Every key that may collect on `proposalId` does, one call each.
    function _collectAll(Keyfleet fleet, uint256 proposalId) private {
        KeyfleetVotes votes = fleet.VOTES();
        if (proposalId == 0 || votes.proposal(proposalId).share == 0) return;
        for (uint256 tokenId = 1; tokenId <= fleet.totalMinted(); ++tokenId) {
            if (votes.voteOf(proposalId, tokenId) != KeyfleetVotes.Choice.Yes) {
                votes.collect(proposalId, _one(tokenId));
            }
        }
    }

    /// @dev Each key's share, times the keys sold and 1e18, against the starting money times 1e18:
    /// what is left, plus the key's collected money and its spent parts each times the keys sold.
    /// Each payment can leave a key less than one atomic unit off, ahead when it did not vote YES
    /// and behind when it did, and each 1e18 floor less than one more at that scale. Then the money adds up exactly.
    function _assertEqualShares(Keyfleet fleet, uint256 start, uint256[] memory spent) private view {
        uint256 keys = fleet.totalMinted();
        uint256 left = fleet.freeCapital(address(other));
        uint256 collectedTotal;
        for (uint256 tokenId = 1; tokenId <= keys; ++tokenId) {
            uint256 collected = other.balanceOf(_holder(tokenId));
            collectedTotal += collected;
            uint256 value = keys * (collected * 1e18 + spent[tokenId]) + left * 1e18;
            uint256 gap = value > start * 1e18 ? value - start * 1e18 : start * 1e18 - value;
            assertLe(gap, keys * 3 * (1e18 + 1), "each key's share stayed equal");
        }
        assertEq(other.balanceOf(bob) + collectedTotal + left, start, "nothing created or lost");
    }

    /// @dev Invariant: a key that did not vote YES collects its match once, paid to whoever holds it
    /// when it collects, whoever calls. A key that voted YES never collects, even after it moves to
    /// a new holder, and neither does a key sold after the payment was carried out. Any refused id
    /// reverts the whole call, so no key in it is paid or marked.
    function test_aKeyCollectsItsMatchOnceAndOnlyIfItDidNotVoteYes() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(fleet, 5);
        _receive(fleet, other, 1_000);
        KeyfleetVotes votes = fleet.VOTES();

        uint256 proposalId = _pay(fleet, address(other), 300, _ids(1, 3), _one(4));
        votes.execute(proposalId);
        assertEq(other.balanceOf(address(votes)), 200, "100 set aside for each of keys 4 and 5");

        vm.prank(mallory);
        votes.collect(proposalId, _one(4));
        assertEq(other.balanceOf(_holder(4)), 100, "the NO key's holder was paid");
        assertEq(other.balanceOf(mallory), 0, "not the caller");

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyCollected.selector, 4));
        votes.collect(proposalId, _one(4));

        uint256[] memory twice = new uint256[](2);
        twice[0] = 5;
        twice[1] = 5;
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.AlreadyCollected.selector, 5));
        votes.collect(proposalId, twice);
        assertFalse(votes.collected(proposalId, 5), "the refused call marked nothing");

        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.VotedYes.selector, 1));
        votes.collect(proposalId, _one(1));
        vm.prank(alice);
        fleet.transferFrom(alice, carol, 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.VotedYes.selector, 1));
        votes.collect(proposalId, _one(1));

        _buyKeys(fleet, 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 6));
        votes.collect(proposalId, _one(6));
        vm.expectRevert(KeyfleetVotes.NoKeys.selector);
        votes.collect(proposalId, _none());

        vm.prank(_holder(5));
        fleet.transferFrom(_holder(5), carol, 5);
        votes.collect(proposalId, _one(5));
        assertEq(other.balanceOf(carol), 100, "the silent key's match went to its holder now");
        assertEq(other.balanceOf(_holder(5)), 0, "not the one it had when the payment passed");
        assertEq(other.balanceOf(address(votes)), 0);
    }

    /// @dev Invariant: only a carried-out payment can be collected. A payment not yet carried out
    /// and a decision have nothing to collect.
    function test_onlyACarriedOutPaymentHasAnythingToCollect() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(fleet, 5);
        _receive(fleet, other, 1_000);
        KeyfleetVotes votes = fleet.VOTES();

        uint256 waiting = _pay(fleet, address(other), 300, _ids(1, 3), _none());
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NothingToCollect.selector, waiting));
        votes.collect(waiting, _one(4));

        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 decision = votes.proposeDecision(1, "Adopt the logo", bytes32(0));
        _passAll(fleet, decision);
        votes.execute(decision);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NothingToCollect.selector, decision));
        votes.collect(decision, _one(4));
    }

    /// @dev Invariant: a match is rounded up, so a payment smaller than its YES votes still matches
    /// every other key with at least one unit, and repeating small payments can never spend the
    /// shared money without matching everyone else. On a 1024-key fleet with 513 YES keys, 512 units
    /// set aside 1 for each of the other 511 keys, and 1025 units set aside 2 each.
    function test_aMatchIsRoundedUpSoASmallPaymentStillMatchesEveryOtherKey() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(fleet, KeyfleetPresets.CLASSIC_SUPPLY);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 before = fleet.freeCapital(address(usdc));

        uint256 rounds = 5;
        uint256[] memory proposals = new uint256[](rounds);
        for (uint256 r = 0; r < rounds; ++r) {
            proposals[r] = _pay(fleet, address(usdc), 512, _ids(1, 513), _none());
            votes.execute(proposals[r]);
            assertEq(votes.proposal(proposals[r]).share, 1, "each other key is matched with one unit");
        }
        assertEq(usdc.balanceOf(bob), 512 * rounds);
        assertEq(before - fleet.freeCapital(address(usdc)), (512 + 511) * rounds, "every payment was matched");
        for (uint256 r = 0; r < rounds; ++r) {
            votes.collect(proposals[r], _ids(514, 511));
        }
        assertEq(usdc.balanceOf(_holder(1024)), rounds, "and every other key collected its unit each time");

        uint256 larger = _pay(fleet, address(usdc), 2 * 513 - 1, _ids(1, 513), _none());
        vm.expectEmit(true, true, true, true, address(fleet));
        emit BudgetPaid(address(usdc), bob, 1025, 2, 1022);
        votes.execute(larger);
        assertEq(votes.proposal(larger).share, 2, "1025 over 513 is rounded up to 2");
    }

    /// @dev Invariant: a key that voted YES and was then sold does not bind its buyer. The buyer can
    /// withdraw the seller's YES before the payment is carried out, though not cast a new vote, and
    /// the key then collects its match like any key that did not vote YES.
    function test_aBuyerCanWithdrawTheSellersYesAndCollectTheKeysMatch() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(fleet, 10);
        _receive(fleet, other, 1_000);
        KeyfleetVotes votes = fleet.VOTES();

        uint256 proposalId = _pay(fleet, address(other), 600, _ids(1, 7), _none());
        vm.prank(_holder(6));
        fleet.transferFrom(_holder(6), carol, 6);

        vm.startPrank(carol);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.KeyNotEligible.selector, 6));
        votes.vote(proposalId, _one(6), false);
        votes.withdrawVote(proposalId, _one(6));
        vm.stopPrank();
        assertEq(votes.proposal(proposalId).yesVotes, 6, "the seller's YES is gone");

        votes.execute(proposalId);
        assertEq(votes.proposal(proposalId).share, 100);
        votes.collect(proposalId, _one(6));
        assertEq(other.balanceOf(carol), 100, "the buyer collected the key's match");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.VotedYes.selector, 7));
        votes.collect(proposalId, _one(7));
    }

    /// @dev Invariant: money set aside for matches is never shared money. While matches wait to be
    /// collected the controller holds exactly what is still owed, the fleet's books still balance,
    /// and a later payment can only draw on what is left.
    function test_matchesWaitingToBeCollectedAreNeverSharedMoney() public {
        Keyfleet fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buyKeys(fleet, 7);
        _receive(fleet, other, 7_000);
        KeyfleetVotes votes = fleet.VOTES();

        uint256 first = _pay(fleet, address(other), 2_000, _ids(1, 4), _none());
        votes.execute(first);
        uint256 second = _pay(fleet, address(other), 1_000, _ids(3, 5), _ids(1, 2));
        votes.execute(second);
        votes.collect(first, _ids(5, 2));

        // The first set aside 500 for each of keys 5 to 7, and keys 5 and 6 have collected. The
        // second set aside 200 for each of keys 1 and 2, and neither has.
        uint256 owed = 500 + 2 * 200;
        assertEq(other.balanceOf(address(votes)), owed, "the controller holds exactly what is owed");
        uint256 left = 7_000 - 2_000 - 3 * 500 - 1_000 - 2 * 200;
        assertEq(fleet.freeCapital(address(other)), left, "shared money excludes every match");
        assertEq(other.balanceOf(address(fleet)), left, "and the fleet holds only shared money");
        assertEq(fleet.surplus(address(other)), 0, "so its books balance");

        uint256 tooMuch = _pay(fleet, address(other), left + 1, _ids(1, 7), _none());
        vm.expectRevert(abi.encodeWithSelector(Keyfleet.AboveYesShare.selector, address(other), left + 1, 0, left));
        votes.execute(tooMuch);

        votes.collect(first, _one(7));
        votes.collect(second, _ids(1, 2));
        assertEq(other.balanceOf(address(votes)), 0, "every match was paid in full");
    }
}
