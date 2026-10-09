// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetDeployer} from "../src/KeyfleetDeployers.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

/// @dev A token whose `transfer` returns false instead of paying.
contract FalseReturningToken is ERC20 {
    constructor() ERC20("False", "FLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev A payee that, on receiving ETH from the treasury, tries to reach protected accounting:
/// returning an advance, sending the protocol share and carrying out another proposal. It records
/// which attempts got through and never reverts itself.
contract ReenteringPayee {
    KeyfleetManager private immutable _fleet;
    uint256 private immutable _proposalId;
    KeyfleetTreasury.Call[] private _calls;
    uint256 public attempts;
    uint256 public gotThrough;

    constructor(KeyfleetManager fleet, uint256 proposalId, KeyfleetTreasury.Call[] memory calls) {
        _fleet = fleet;
        _proposalId = proposalId;
        for (uint256 i = 0; i < calls.length; ++i) {
            _calls.push(calls[i]);
        }
    }

    receive() external payable {
        _try(address(_fleet.TREASURY()), abi.encodeCall(KeyfleetTreasury.returnAdvance, (1, 0)));
        _try(address(_fleet), abi.encodeCall(KeyfleetManager.sendProtocolShare, ()));
        _try(address(_fleet.VOTES()), abi.encodeCall(KeyfleetVotes.execute, (_proposalId, _calls)));
    }

    function _try(address target, bytes memory data) private {
        ++attempts;
        (bool ok,) = target.call(data);
        if (ok) ++gotThrough;
    }
}

/// @dev Plan §4.10, execution: the treasury's typed payments and advances are reachable only
/// through an approved proposal's call, a payment that fails fails the whole batch, proposals
/// reserve nothing, and an advance can be returned only up to what is outstanding. An approved
/// call reaches its own fleet's profile, and never another fleet or any function kept for the
/// Safe, the factory, the keeper, a manager or the collection.
contract KeyfleetExecutionTest is KeyfleetFixture {
    address private constant NATIVE = address(0);

    address private operator = address(0x0E0E);
    address private mallory = address(0x4A11);

    event Paid(address indexed asset, address indexed to, uint32 sharePpm, uint256 amount);
    event AdvanceReturned(uint256 indexed advanceId, address indexed from, uint256 amount, uint256 outstanding);
    event ProfileChanged(string name, string description, string imageLink);

    /// @dev One privileged call an approved proposal tries, and the revert it must meet.
    struct Attempt {
        string label;
        address target;
        bytes data;
        bytes reason;
    }

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
    }

    /// @dev The founding Classic fleet with `count` keys sold and their treasury part turned into
    /// REGENT, old enough to take part, after its treasury opening, by when only a renewed key is
    /// present.
    function _classic(uint256 count) private returns (KeyfleetManager fleet, KeyfleetTreasury treasury) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        treasury = fleet.TREASURY();
        _buyMany(fleet, count);
        _convertAll();
        _mature();
        _openTreasury(fleet);
    }

    function _pay(KeyfleetTreasury treasury, address asset, address to, uint32 sharePpm)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.pay, (asset, to, sharePpm)));
    }

    function _advance(KeyfleetTreasury treasury, uint256 advanceId, address asset, uint32 sharePpm)
        private
        view
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(
            address(treasury),
            0,
            abi.encodeCall(KeyfleetTreasury.advance, (advanceId, operator, asset, sharePpm, keccak256("purpose")))
        );
    }

    /// @dev Proposes `calls` with key 1 as its owner, expecting the refusal `reason`.
    function _refused(KeyfleetManager fleet, KeyfleetTreasury.Call[] memory calls, bytes memory reason) private {
        uint256 first = _key(fleet, 1);
        KeyfleetVotes votes = fleet.VOTES();
        address author = keys.ownerOf(first);
        vm.prank(author);
        vm.expectRevert(reason);
        votes.propose(first, bytes32(0), calls);
    }

    // --- payments and advances ----------------------------------------------------------

    /// @dev Invariant: the treasury takes ETH from anyone, and pays ETH and tokens only through an
    /// approved proposal's call; nobody else reaches `pay` or `advance`, the voting controller and
    /// the manager included.
    function test_onlyAnApprovedCallPaysOrAdvances() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        vm.deal(mallory, 1 ether);
        vm.prank(mallory);
        (bool sent,) = address(treasury).call{value: 1 ether}("");
        assertTrue(sent, "the treasury takes ETH");

        address[3] memory callers = [mallory, address(fleet.VOTES()), address(fleet)];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(KeyfleetTreasury.OnlySelf.selector);
            treasury.pay(NATIVE, callers[i], 1);
            vm.expectRevert(KeyfleetTreasury.OnlySelf.selector);
            treasury.advance(1, callers[i], NATIVE, 1, bytes32(0));
            vm.stopPrank();
        }

        _execute(fleet, _pay(treasury, NATIVE, operator, 400_000));
        assertEq(operator.balance, 0.4 ether, "40% of the ETH");
        assertEq(address(treasury).balance, 0.6 ether);

        uint256 capital = regent.balanceOf(address(treasury));
        assertGt(capital, 0, "the first key's capital arrived as REGENT");
        KeyfleetTreasury.Call[] memory calls = _pay(treasury, address(regent), operator, 990_000);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectEmit(true, true, true, true, address(treasury));
        emit Paid(address(regent), operator, 990_000, capital * 99 / 100);
        votes.execute(proposalId, calls);
        assertEq(regent.balanceOf(operator), capital * 99 / 100, "at most 99% of a balance moves at once");
        assertEq(regent.balanceOf(address(treasury)), capital - capital * 99 / 100);
    }

    /// @dev Invariant: a payment is its share of the treasury's balance of its asset when it is
    /// carried out, rounded down, whatever the balance was when it was proposed.
    function test_aPaymentIsItsShareOfTheBalanceWhenCarriedOut() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        usdc.mint(address(treasury), 1_000_003);
        uint256 atProposal = usdc.balanceOf(address(treasury));
        KeyfleetTreasury.Call[] memory calls = _pay(treasury, address(usdc), operator, 333_333);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        usdc.mint(address(treasury), 7_777_777);
        uint256 atExecution = usdc.balanceOf(address(treasury));
        assertGt(atExecution, atProposal);

        vm.warp(votes.executableAt(proposalId));
        votes.execute(proposalId, calls);
        assertEq(usdc.balanceOf(operator), atExecution * 333_333 / 1_000_000, "the share of today's balance");
        assertEq(usdc.balanceOf(address(treasury)), atExecution - atExecution * 333_333 / 1_000_000);
    }

    /// @dev Invariant: a share is refused when proposed unless it is 1 to 990,000 parts per million
    /// (0.0001% to 99%), for payments and advances alike; both ends are allowed.
    function test_aShareOutsideTheRangeIsRefusedWhenProposed() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        uint32[3] memory refused = [uint32(0), 990_001, 1_000_000];
        for (uint256 i = 0; i < refused.length; ++i) {
            bytes memory reason = abi.encodeWithSelector(KeyfleetVotes.ShareOutOfRange.selector, refused[i]);
            _refused(fleet, _pay(treasury, address(regent), operator, refused[i]), reason);
            _refused(fleet, _advance(treasury, 1, address(regent), refused[i]), reason);
        }
        uint256 smallest = _approve(fleet, _pay(treasury, address(regent), operator, 1));
        uint256 largest = _approve(fleet, _advance(treasury, 1, address(regent), 990_000));
        assertEq(smallest + 1, largest, "both ends open");
    }

    /// @dev Invariant: a share that rounds down to nothing is not carried out, and the proposal
    /// stays approved until it expires.
    function test_aShareThatRoundsToNothingIsNotCarriedOut() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        usdc.mint(address(treasury), 999_999);
        KeyfleetTreasury.Call[] memory calls = _pay(treasury, address(usdc), operator, 1);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetTreasury.ShareRoundsToZero.selector, address(usdc), uint32(1), 999_999)
        );
        votes.execute(proposalId, calls);
        assertEq(uint256(votes.status(proposalId)), uint256(KeyfleetVotes.Status.Approved));

        usdc.mint(address(treasury), 1);
        votes.execute(proposalId, calls);
        assertEq(usdc.balanceOf(operator), 1, "one part in a million of 1,000,000 units");
    }

    /// @dev Invariant: a proposal moves money in at most one `pay`, `advance` or `runVotedSplit` call,
    /// so it names one asset and one share or runs the split once; a second is refused when proposed.
    function test_aProposalMovesMoneyInOneCallOnly() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](3);
        calls[0] = _pay(treasury, NATIVE, operator, 10)[0];
        calls[1] = _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (100)))[0];
        calls[2] = _pay(treasury, NATIVE, operator, 10)[0];
        bytes memory reason = abi.encodeWithSelector(KeyfleetVotes.OneMoneyMovePerProposal.selector);
        _refused(fleet, calls, reason);
        calls[2] = _advance(treasury, 1, address(usdc), 10)[0];
        _refused(fleet, calls, reason);
        KeyfleetTreasury.Call memory split =
            _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.runVotedSplit, ()))[0];
        calls[2] = split;
        _refused(fleet, calls, reason);
        calls[0] = split;
        _refused(fleet, calls, reason);
        calls[2] = calls[1];
        _approve(fleet, calls);
    }

    /// @dev Invariant: no call carries ETH; ETH leaves only through `pay` or `advance`.
    function test_noCallCarriesEth() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = _pay(treasury, NATIVE, operator, 10)[0];
        calls[1] = KeyfleetTreasury.Call(operator, 1, "");
        _refused(fleet, calls, abi.encodeWithSelector(KeyfleetVotes.CallCarriesValue.selector, 1));
        calls[0] = KeyfleetTreasury.Call(address(treasury), 1 wei, abi.encodeCall(treasury.runVotedSplit, ()));
        _refused(fleet, calls, abi.encodeWithSelector(KeyfleetVotes.CallCarriesValue.selector, 0));
    }

    /// @dev Invariant: no call uses a standard function that moves or approves tokens, on any
    /// contract, the fleet's own key collection included: money leaves only as a share.
    function test_rawTokenMovesAndApprovalsAreRefused() public {
        (KeyfleetManager fleet,) = _classic(1);
        bytes4[20] memory selectors = [
            bytes4(0xa9059cbb),
            0x23b872dd,
            0x095ea7b3,
            0x39509351,
            0xd505accf,
            0xa22cb465,
            0x42842e0e,
            0xb88d4fde,
            0xf242432a,
            0x2eb2c2d6,
            0x1296ee62,
            0x4000aea0,
            0xd8fbe994,
            0xc1d34b89,
            0x3177029f,
            0xcae9ca51,
            0x9bd9bbc6,
            0x62ad1b83,
            0x959b8c3f,
            0x87517c45
        ];
        address[3] memory targets = [address(usdc), address(regent), address(keys)];
        for (uint256 t = 0; t < targets.length; ++t) {
            for (uint256 i = 0; i < selectors.length; ++i) {
                KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
                calls[0] = _one(address(fleet), 0, abi.encodeCall(KeyfleetManager.setProfile, (_profile("x"))))[0];
                calls[1] = KeyfleetTreasury.Call(targets[t], 0, abi.encodePacked(selectors[i], uint256(1)));
                _refused(fleet, calls, abi.encodeWithSelector(KeyfleetVotes.TokenMoveRefused.selector, 1, selectors[i]));
            }
        }
        assertEq(KeyfleetTreasury.pay.selector, bytes4(0x5bc0a2ae));
        assertEq(KeyfleetTreasury.advance.selector, bytes4(0x18b18d1a));
    }

    /// @dev Invariant: a proposal that moves money waits a day after closing, then may be carried
    /// out for 48 hours: not a second before closing plus a day, nor from closing plus a day plus
    /// 48 hours. Waiting, it may still be cancelled. One that moves no money waits nothing.
    function test_aMoneyProposalWaitsADayAfterClosing() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        vm.deal(address(treasury), 1 ether);
        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetTreasury.Call[] memory calls = _pay(treasury, NATIVE, operator, 100_000);
        uint256 last = _approve(fleet, calls);
        uint256 expiring = _approve(fleet, calls);
        uint256 cancelled = _approve(fleet, calls);
        KeyfleetTreasury.Call[] memory free =
            _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (100)));
        uint256 rate = _approve(fleet, free);
        KeyfleetVotes.Proposal memory stored = votes.proposal(last);
        uint64 closesAt = stored.closesAt;
        assertEq(votes.MONEY_DELAY(), 1 days);
        assertEq(votes.executableAt(last), closesAt + 1 days);
        assertEq(stored.executionExpiry, closesAt + 1 days + 48 hours);
        assertEq(votes.executableAt(rate), closesAt, "moving no money, it waits nothing");
        assertEq(votes.proposal(rate).executionExpiry, closesAt + 48 hours);

        vm.warp(closesAt);
        votes.execute(rate, free);
        for (uint256 t = closesAt; t < closesAt + 1 days; t += 1 days - 1) {
            vm.warp(t);
            assertEq(uint256(votes.status(last)), uint256(KeyfleetVotes.Status.Waiting));
            vm.expectRevert(abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.Waiting));
            votes.execute(last, calls);
        }
        vm.prank(keys.ownerOf(_key(fleet, 1)));
        votes.cancel(cancelled);

        vm.warp(closesAt + 1 days);
        assertEq(uint256(votes.status(last)), uint256(KeyfleetVotes.Status.Approved));
        vm.warp(closesAt + 1 days + 48 hours - 1);
        votes.execute(last, calls);
        assertEq(operator.balance, 0.1 ether);
        vm.warp(closesAt + 1 days + 48 hours);
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetVotes.NotApproved.selector, KeyfleetVotes.Status.ExecutionExpired)
        );
        votes.execute(expiring, calls);
        assertEq(operator.balance, 0.1 ether);
    }

    /// @dev Invariant: a token that returns false instead of paying fails the payment, the whole
    /// batch with it, and the proposal stays approved.
    function test_aTokenThatReturnsFalseFailsThePayment() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        FalseReturningToken token = new FalseReturningToken();
        token.mint(address(treasury), 5);

        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetTreasury.Call[] memory calls = _pay(treasury, address(token), operator, 990_000);
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        votes.execute(proposalId, calls);
        assertEq(uint256(votes.status(proposalId)), uint256(KeyfleetVotes.Status.Approved));
        assertEq(token.balanceOf(address(treasury)), 5);
    }

    /// @dev Invariant: the ledger accepts split funding only from inside the treasury's own split
    /// routine, so an approved call from the treasury straight to either funding function reverts,
    /// even with the exact amounts already in the ledger.
    function test_anApprovedCallCannotFundTheSplit() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        vm.deal(address(rewards), 2 ether);
        regent.mint(address(rewards), 2e18);
        vm.deal(address(treasury), 2 ether);
        KeyfleetVotes votes = fleet.VOTES();

        KeyfleetTreasury.Call[] memory calls =
            _one(address(rewards), 0, abi.encodeCall(KeyfleetRewards.fundSplit, (address(regent), 1e18, 2)));
        uint256 proposalId = _approve(fleet, calls);
        KeyfleetTreasury.Call[] memory native =
            _one(address(rewards), 0, abi.encodeCall(KeyfleetRewards.fundSplitNative, (1 ether, 2)));
        uint256 nativeId = _approve(fleet, native);
        uint256 held = regent.balanceOf(address(treasury));

        vm.warp(votes.executableAt(nativeId));
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        votes.execute(proposalId, calls);
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        votes.execute(nativeId, native);

        assertFalse(treasury.splitInProgress());
        assertEq(rewards.splitIndex(address(regent)), 0);
        assertEq(rewards.splitIndex(NATIVE), 0);
        assertEq(regent.balanceOf(address(treasury)), held);
        assertEq(address(treasury).balance, 2 ether);
    }

    /// @dev Invariant: proposing reserves nothing, so each approved payment takes its share of
    /// what is left when it is carried out: two of 99% leave 0.01% behind, never less.
    function test_proposalsReserveNothingAndEachTakesItsShareOfWhatIsLeft() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        uint256 capital = regent.balanceOf(address(treasury));
        KeyfleetTreasury.Call[] memory first = _pay(treasury, address(regent), operator, 990_000);
        KeyfleetTreasury.Call[] memory second = _pay(treasury, address(regent), mallory, 990_000);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 firstId = _approve(fleet, first);
        uint256 secondId = _approve(fleet, second);
        assertEq(regent.balanceOf(address(treasury)), capital, "nothing moved or was set aside");

        vm.warp(votes.executableAt(secondId));
        votes.execute(secondId, second);
        uint256 toMallory = capital * 99 / 100;
        assertEq(regent.balanceOf(mallory), toMallory);
        votes.execute(firstId, first);
        uint256 toOperator = (capital - toMallory) * 99 / 100;
        assertEq(regent.balanceOf(operator), toOperator, "99% of what was left");
        assertEq(regent.balanceOf(address(treasury)), capital - toMallory - toOperator);
    }

    /// @dev Invariant: an advance is sent and recorded as outstanding under a new id; anyone may
    /// return it, in part or whole, but never more than is outstanding, so the same funds cannot be
    /// returned twice and a return cannot be labelled against more than was advanced.
    function test_aTokenAdvanceIsReturnedOnlyUpToWhatIsOutstanding() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        deal(address(regent), address(treasury), 6e18);
        _execute(fleet, _advance(treasury, 7, address(regent), 500_000));
        assertEq(regent.balanceOf(operator), 3e18, "half of 6 REGENT");
        (address recordedOperator, address asset, uint256 outstanding, bytes32 purposeHash) = treasury.advances(7);
        assertEq(recordedOperator, operator);
        assertEq(asset, address(regent));
        assertEq(outstanding, 3e18);
        assertEq(purposeHash, keccak256("purpose"));

        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetTreasury.Call[] memory again = _advance(treasury, 7, address(regent), 1);
        uint256 againId = _approve(fleet, again);
        vm.warp(votes.executableAt(againId));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.AdvanceIdTaken.selector, 7));
        votes.execute(againId, again);

        regent.mint(mallory, 10e18);
        vm.startPrank(mallory);
        regent.approve(address(treasury), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.ReturnAboveOutstanding.selector, 7, 3e18 + 1, 3e18));
        treasury.returnAdvance(7, 3e18 + 1);
        vm.deal(mallory, 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.WrongValue.selector, 1));
        treasury.returnAdvance{value: 1}(7, 1e18);

        uint256 before = regent.balanceOf(address(treasury));
        vm.expectEmit(true, true, true, true, address(treasury));
        emit AdvanceReturned(7, mallory, 1e18, 2e18);
        treasury.returnAdvance(7, 1e18);
        treasury.returnAdvance(7, 2e18);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.ReturnAboveOutstanding.selector, 7, 1, 0));
        treasury.returnAdvance(7, 1);
        vm.stopPrank();

        assertEq(regent.balanceOf(address(treasury)), before + 3e18, "each unit came back once");
        (,, outstanding,) = treasury.advances(7);
        assertEq(outstanding, 0);
    }

    /// @dev Invariant: an ETH advance comes back only with exactly the ETH named.
    function test_anEthAdvanceIsReturnedWithExactlyItsValue() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        vm.deal(address(treasury), 1 ether);
        _execute(fleet, _advance(treasury, 1, NATIVE, 250_000));
        assertEq(operator.balance, 0.25 ether);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.WrongValue.selector, 0.1 ether));
        treasury.returnAdvance{value: 0.1 ether}(1, 0.2 ether);
        treasury.returnAdvance{value: 0.25 ether}(1, 0.25 ether);
        vm.stopPrank();
        assertEq(address(treasury).balance, 1 ether);
    }

    /// @dev Invariant: a payee called back by a payment cannot reach protected accounting: returning
    /// an advance, sending the protocol share and carrying out another proposal all meet the
    /// treasury's and the controller's locks, and the manager's owed share is untouched.
    function test_aReentrantPayeeCannotReachProtectedAccounting() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        vm.deal(address(treasury), 1 ether);
        KeyfleetTreasury.Call[] memory inner = _pay(treasury, NATIVE, mallory, 100_000);
        uint256 innerId = _approve(fleet, inner);
        ReenteringPayee payee = new ReenteringPayee(fleet, innerId, inner);
        uint256 owed = fleet.protocolShareOwed();

        _execute(fleet, _pay(treasury, NATIVE, address(payee), 500_000));
        assertEq(payee.attempts(), 3);
        assertEq(payee.gotThrough(), 0, "every attempt met a lock");
        assertEq(fleet.protocolShareOwed(), owed);
        assertEq(staking.totalUsdcReceived(), 0, "nothing reached staking");
        assertEq(uint256(fleet.VOTES().status(innerId)), uint256(KeyfleetVotes.Status.Approved));
        assertEq(address(payee).balance, 0.5 ether);
    }

    // --- the fleet's own profile ---------------------------------------------------------

    /// @dev Invariant: an approved call from the fleet's treasury to its own manager's `setProfile`
    /// changes the profile and tells marketplaces to refresh the fleet's keys. That is the only way
    /// a profile changes: a stranger, the fleet's controller, its ledger, the factory and another
    /// fleet's treasury are all refused.
    function test_anApprovedCallSetsItsOwnFleetsProfile() public {
        (KeyfleetManager fleet,) = _classic(1);
        KeyfleetManager another = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetManager.Profile memory renamed = KeyfleetManager.Profile({
            name: "Renamed fleet", description: "Chosen by the keys.", imageLink: "https://media.regents.sh/ipfs/new"
        });

        address[5] memory outsiders =
            [mallory, address(fleet.VOTES()), address(fleet.REWARDS()), address(factory), address(another.TREASURY())];
        for (uint256 i = 0; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(KeyfleetManager.OnlyTreasury.selector);
            fleet.setProfile(renamed);
        }
        assertEq(fleet.profile().name, "Founding fleet", "nothing changed it");

        uint256 fleetId = fleet.FLEET_ID();
        KeyfleetTreasury.Call[] memory calls =
            _one(address(fleet), 0, abi.encodeCall(KeyfleetManager.setProfile, (renamed)));
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectEmit(true, true, true, true, address(fleet));
        emit ProfileChanged(renamed.name, renamed.description, renamed.imageLink);
        vm.expectEmit(true, true, true, true, address(keys));
        emit IERC4906.BatchMetadataUpdate(keys.tokenIdOf(fleetId, 1), keys.tokenIdOf(fleetId, keys.MAX_KEY_NUMBER()));
        votes.execute(proposalId, calls);

        KeyfleetManager.Profile memory stored = fleet.profile();
        assertEq(stored.name, renamed.name);
        assertEq(stored.description, renamed.description);
        assertEq(stored.imageLink, renamed.imageLink);
        assertEq(another.profile().name, "Founding fleet", "the other fleet's profile is untouched");
    }

    // --- what an approved call can never reach -----------------------------------------------

    /// @dev Invariant: an approved call from a fleet's treasury reaches nothing kept for the Safe,
    /// the factory, the keeper, a manager, the collection, the VRF coordinator or the Uniswap pools,
    /// in the shared contracts, in its own fleet or in another fleet, and nothing kept for another
    /// fleet's treasury. Each is tried behind a real payment in the same batch: every execution
    /// reverts whole with the target's own refusal, the payment does not happen, the proposal stays
    /// approved, and the collection, the other fleet and both ledgers are unchanged.
    function test_anApprovedCallCannotReachAnyPrivilegedFunction() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetManager another = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        _buy(another, _wallet(900));
        Attempt[] memory attempts = _privilegedAttempts(fleet, another);

        uint256[] memory proposalIds = new uint256[](attempts.length);
        KeyfleetTreasury.Call[][] memory batches = new KeyfleetTreasury.Call[][](attempts.length);
        for (uint256 i = 0; i < attempts.length; ++i) {
            batches[i] = new KeyfleetTreasury.Call[](2);
            batches[i][0] = _pay(treasury, address(regent), operator, 1)[0];
            batches[i][1] = KeyfleetTreasury.Call(attempts[i].target, 0, attempts[i].data);
            proposalIds[i] = _approve(fleet, batches[i]);
        }
        KeyfleetVotes votes = fleet.VOTES();
        vm.warp(votes.executableAt(proposalIds[attempts.length - 1]));
        Snapshot memory before = _snapshot(fleet, another);

        for (uint256 i = 0; i < attempts.length; ++i) {
            vm.expectRevert(attempts[i].reason);
            votes.execute(proposalIds[i], batches[i]);
            assertEq(uint256(votes.status(proposalIds[i])), uint256(KeyfleetVotes.Status.Approved), attempts[i].label);
        }

        Snapshot memory afterwards = _snapshot(fleet, another);
        assertEq(regent.balanceOf(operator), 0, "no batch half succeeded");
        assertEq(afterwards.treasuryRegent, before.treasuryRegent, "the treasury paid nothing");
        assertEq(afterwards.phase, before.phase, "the phase is unchanged");
        assertEq(afterwards.fleetCount, before.fleetCount, "no fleet was created");
        assertEq(afterwards.keeper, before.keeper, "the keeper is unchanged");
        assertEq(afterwards.deckHash, before.deckHash, "the other fleet's deck is unchanged");
        assertEq(afterwards.deckSize, before.deckSize);
        assertEq(afterwards.otherMinted, before.otherMinted, "no key was minted");
        assertEq(afterwards.otherProfileHash, before.otherProfileHash, "the other fleet's profile is unchanged");
        assertEq(afterwards.otherOwed, before.otherOwed, "its owed share is unchanged");
        assertEq(afterwards.otherBacked, before.otherBacked, "its ledger is unchanged");
        assertEq(afterwards.ownBacked, before.ownBacked, "and so is the fleet's own");
        assertEq(another.REWARDS().credits(address(usdc), address(treasury)), 0, "nothing was credited");
    }

    /// @dev What a privileged call from `fleet`'s treasury could have changed.
    struct Snapshot {
        uint8 phase;
        uint256 fleetCount;
        address keeper;
        bytes32 deckHash;
        uint256 deckSize;
        uint256 otherMinted;
        bytes32 otherProfileHash;
        uint256 otherOwed;
        uint256 otherBacked;
        uint256 ownBacked;
        uint256 treasuryRegent;
    }

    function _snapshot(KeyfleetManager fleet, KeyfleetManager another) private view returns (Snapshot memory s) {
        s.phase = keys.phase();
        s.fleetCount = keys.fleetCount();
        s.keeper = keys.keeper();
        (s.deckHash, s.deckSize) = keys.deckOf(another.FLEET_ID());
        s.otherMinted = another.totalMinted();
        s.otherProfileHash = keccak256(abi.encode(another.profile()));
        s.otherOwed = another.protocolShareOwed();
        s.otherBacked = another.REWARDS().backed(address(usdc));
        s.ownBacked = fleet.REWARDS().backed(address(usdc));
        s.treasuryRegent = regent.balanceOf(address(fleet.TREASURY()));
    }

    /// @dev Every privileged function an approved call of `fleet` might try, with the refusal it
    /// meets. `another` is a second fleet of the same collection.
    function _privilegedAttempts(KeyfleetManager fleet, KeyfleetManager another)
        private
        view
        returns (Attempt[] memory all)
    {
        address treasury = address(fleet.TREASURY());
        Attempt[][3] memory groups = [
            _sharedAttempts(treasury, another.FLEET_ID()),
            _managerAttempts(fleet, another, treasury),
            _ledgerAttempts(fleet, another, treasury)
        ];
        all = new Attempt[](groups[0].length + groups[1].length + groups[2].length);
        uint256 n;
        for (uint256 g = 0; g < groups.length; ++g) {
            for (uint256 i = 0; i < groups[g].length; ++i) {
                all[n++] = groups[g][i];
            }
        }
    }

    /// @dev The Safe's, the factory's, the keeper's, the coordinator's, a manager's and the pools'
    /// functions on the shared collection, factory, deployers and REGENT buyer.
    function _sharedAttempts(address treasury, uint256 otherId) private view returns (Attempt[] memory a) {
        bytes memory onlySafe = abi.encodeWithSelector(KeyfleetKeys.OnlySafe.selector, treasury);
        bytes memory onlyFactoryDeployer = abi.encodeWithSelector(KeyfleetDeployer.OnlyFactory.selector, treasury);
        bytes memory onlyManagerKeys = abi.encodeWithSelector(KeyfleetKeys.OnlyManager.selector, treasury);
        uint256 nextId = keys.fleetCount() + 1;
        a = new Attempt[](12);
        a[0] = _attempt(
            "advancePhase",
            address(keys),
            abi.encodeCall(KeyfleetKeys.advancePhase, (uint64(block.timestamp + 1))),
            onlySafe
        );
        a[1] = _attempt("setKeeper", address(keys), abi.encodeCall(KeyfleetKeys.setKeeper, (treasury)), onlySafe);
        a[2] = _attempt("addFactory", address(keys), abi.encodeCall(KeyfleetKeys.addFactory, (treasury)), onlySafe);
        a[3] = _attempt(
            "createFoundingFleet",
            address(factory),
            abi.encodeCall(
                KeyfleetFactory.createFoundingFleet,
                (KeyfleetPresets.Preset.FleetTechClassic, keccak256("deck"), DECK_SIZE, _profile("Hijacked"))
            ),
            abi.encodeWithSelector(KeyfleetFactory.OnlySafe.selector, treasury)
        );
        a[4] = _attempt(
            "registerFleet",
            address(keys),
            abi.encodeCall(KeyfleetKeys.registerFleet, (KeyfleetPresets.Preset.FleetTechClassic, treasury, 0, 0)),
            abi.encodeWithSelector(KeyfleetKeys.OnlyFactory.selector, treasury)
        );
        a[5] = _attempt(
            "deploy a manager",
            address(factory.MANAGER_DEPLOYER()),
            abi.encodeCall(KeyfleetDeployer.deploy, (nextId)),
            onlyFactoryDeployer
        );
        a[6] = _attempt(
            "deploy a treasury",
            address(factory.TREASURY_DEPLOYER()),
            abi.encodeCall(KeyfleetDeployer.deploy, (nextId)),
            onlyFactoryDeployer
        );
        a[7] = _attempt(
            "setDeck",
            address(keys),
            abi.encodeCall(KeyfleetKeys.setDeck, (otherId, keccak256("deck"), DECK_SIZE)),
            abi.encodeWithSelector(KeyfleetKeys.OnlyKeeper.selector, treasury)
        );
        a[8] = _attempt(
            "rawFulfillRandomWords",
            address(keys),
            abi.encodeCall(KeyfleetKeys.rawFulfillRandomWords, (1, new uint256[](1))),
            abi.encodeWithSelector(KeyfleetKeys.OnlyCoordinator.selector, treasury)
        );
        a[9] = _attempt("mint", address(keys), abi.encodeCall(KeyfleetKeys.mint, (treasury, 1)), onlyManagerKeys);
        a[10] = _attempt("refreshFleet", address(keys), abi.encodeCall(KeyfleetKeys.refreshFleet, ()), onlyManagerKeys);
        a[11] = _attempt(
            "uniswapV3SwapCallback",
            address(regentBuyer),
            abi.encodeCall(KeyfleetRegentBuyer.uniswapV3SwapCallback, (1, -1, "")),
            abi.encodeWithSelector(KeyfleetRegentBuyer.UnexpectedCallback.selector, treasury)
        );
    }

    /// @dev The factory's and the collection's functions on the fleet's own manager and the other
    /// fleet's, and the other fleet's treasury's `setProfile`.
    function _managerAttempts(KeyfleetManager fleet, KeyfleetManager another, address treasury)
        private
        view
        returns (Attempt[] memory a)
    {
        KeyfleetManager.Profile memory profile = _profile("Hijacked");
        KeyfleetManager.Requirements memory anyone;
        bytes memory onlyFactory = abi.encodeWithSelector(KeyfleetManager.OnlyFactory.selector);
        bytes memory onlyKeys = abi.encodeWithSelector(KeyfleetManager.OnlyKeys.selector);
        uint256 ownKey = _key(fleet, 1);
        uint256 otherKey = _key(another, 1);
        a = new Attempt[](6);
        a[0] = _attempt(
            "own initialize", address(fleet), abi.encodeCall(KeyfleetManager.initialize, (profile, anyone)), onlyFactory
        );
        a[1] = _attempt(
            "own sellFirstKey", address(fleet), abi.encodeCall(KeyfleetManager.sellFirstKey, (treasury)), onlyFactory
        );
        a[2] = _attempt(
            "other initialize",
            address(another),
            abi.encodeCall(KeyfleetManager.initialize, (profile, anyone)),
            onlyFactory
        );
        a[3] = _attempt(
            "own onKeyMoved",
            address(fleet),
            abi.encodeCall(KeyfleetManager.onKeyMoved, (ownKey, keys.ownerOf(ownKey))),
            onlyKeys
        );
        a[4] = _attempt(
            "other onKeyMoved",
            address(another),
            abi.encodeCall(KeyfleetManager.onKeyMoved, (otherKey, keys.ownerOf(otherKey))),
            onlyKeys
        );
        a[5] = _attempt(
            "other setProfile",
            address(another),
            abi.encodeCall(KeyfleetManager.setProfile, (profile)),
            abi.encodeWithSelector(KeyfleetManager.OnlyTreasury.selector)
        );
    }

    /// @dev A manager's functions on the ledgers, the controllers and the other fleet's treasury,
    /// and the other fleet's treasury's own functions on its controller and itself.
    function _ledgerAttempts(KeyfleetManager fleet, KeyfleetManager another, address treasury)
        private
        view
        returns (Attempt[] memory a)
    {
        bytes memory onlyManagerRewards = abi.encodeWithSelector(KeyfleetRewards.OnlyManager.selector);
        bytes memory onlyManagerVotes = abi.encodeWithSelector(KeyfleetVotes.OnlyManager.selector);
        address otherRewards = address(another.REWARDS());
        KeyfleetTreasury otherTreasury = another.TREASURY();
        uint256 otherKey = _key(another, 1);
        a = new Attempt[](11);
        a[0] = _attempt(
            "own credit",
            address(fleet.REWARDS()),
            abi.encodeCall(KeyfleetRewards.credit, (address(usdc), treasury, 1)),
            onlyManagerRewards
        );
        a[1] = _attempt(
            "other credit",
            otherRewards,
            abi.encodeCall(KeyfleetRewards.credit, (address(usdc), treasury, 1)),
            onlyManagerRewards
        );
        a[2] = _attempt(
            "other allocateToCohort",
            otherRewards,
            abi.encodeCall(KeyfleetRewards.allocateToCohort, (address(usdc), 0, 1)),
            onlyManagerRewards
        );
        a[3] = _attempt(
            "other enrollKey",
            otherRewards,
            abi.encodeCall(KeyfleetRewards.enrollKey, (_key(another, 3), 0)),
            onlyManagerRewards
        );
        a[4] = _attempt(
            "other settleKey",
            otherRewards,
            abi.encodeCall(KeyfleetRewards.settleKey, (otherKey, treasury)),
            onlyManagerRewards
        );
        a[5] = _attempt(
            "own votes onKeyMoved",
            address(fleet.VOTES()),
            abi.encodeCall(KeyfleetVotes.onKeyMoved, (_key(fleet, 1))),
            onlyManagerVotes
        );
        a[6] = _attempt(
            "other votes onKeyMoved",
            address(another.VOTES()),
            abi.encodeCall(KeyfleetVotes.onKeyMoved, (otherKey)),
            onlyManagerVotes
        );
        a[7] = _attempt(
            "other depositProtocolShare",
            address(otherTreasury),
            abi.encodeCall(KeyfleetTreasury.depositProtocolShare, (1)),
            abi.encodeWithSelector(KeyfleetTreasury.OnlyManager.selector)
        );
        a[8] = _attempt(
            "other setEditsRestricted",
            address(another.VOTES()),
            abi.encodeCall(KeyfleetVotes.setEditsRestricted, (otherKey, true)),
            abi.encodeWithSelector(KeyfleetVotes.OnlyTreasury.selector)
        );
        a[9] = _attempt(
            "other pay",
            address(otherTreasury),
            abi.encodeCall(KeyfleetTreasury.pay, (address(regent), treasury, uint32(1))),
            abi.encodeWithSelector(KeyfleetTreasury.OnlySelf.selector)
        );
        a[10] = _attempt(
            "other executeBatch",
            address(otherTreasury),
            abi.encodeCall(KeyfleetTreasury.executeBatch, (_pay(otherTreasury, address(regent), treasury, 1))),
            abi.encodeWithSelector(KeyfleetTreasury.OnlyVotes.selector)
        );
    }

    function _attempt(string memory label, address target, bytes memory data, bytes memory reason)
        private
        pure
        returns (Attempt memory)
    {
        return Attempt({label: label, target: target, data: data, reason: reason});
    }

    /// @dev Invariant: the treasury's own deposit, which only its manager may ask for, is not
    /// reachable by an approved call either: it meets the treasury's lock, held by the calls being
    /// carried out, before it checks the caller.
    function test_anApprovedCallCannotDepositTheProtocolShare() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        usdc.mint(address(treasury), 1e6);
        KeyfleetTreasury.Call[] memory calls =
            _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.depositProtocolShare, (1e6)));
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        votes.execute(proposalId, calls);
        assertEq(staking.totalUsdcReceived(), 0);
        assertEq(usdc.balanceOf(address(treasury)), 1e6);
    }
}
