// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

/// @dev A token whose `transfer` returns false instead of reverting when it cannot pay.
contract FalseReturningToken is ERC20 {
    constructor() ERC20("False", "FLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (balanceOf(msg.sender) < amount) return false;
        return super.transfer(to, amount);
    }
}

/// @dev A payee that, on receiving ETH from the treasury, tries to reach protected accounting:
/// returning an advance, sending the protocol share and carrying out another proposal. It records
/// which attempts got through and never reverts itself.
contract ReenteringPayee {
    Keyfleet private immutable _fleet;
    uint256 private immutable _proposalId;
    KeyfleetTreasury.Call[] private _calls;
    uint256 public attempts;
    uint256 public gotThrough;

    constructor(Keyfleet fleet, uint256 proposalId, KeyfleetTreasury.Call[] memory calls) {
        _fleet = fleet;
        _proposalId = proposalId;
        for (uint256 i = 0; i < calls.length; ++i) {
            _calls.push(calls[i]);
        }
    }

    receive() external payable {
        _try(address(_fleet.TREASURY()), abi.encodeCall(KeyfleetTreasury.returnAdvance, (1, 0)));
        _try(address(_fleet), abi.encodeCall(Keyfleet.sendProtocolShare, ()));
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
/// reserve nothing, and an advance can be returned only up to what is outstanding.
contract KeyfleetExecutionTest is KeyfleetFixture {
    address private constant NATIVE = address(0);

    address private operator = address(0x0E0E);
    address private mallory = address(0x4A11);

    event Paid(address indexed asset, address indexed to, uint256 amount);
    event AdvanceReturned(uint256 indexed advanceId, address indexed from, uint256 amount, uint256 outstanding);

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
    }

    function _classic(uint256 keys) private returns (Keyfleet fleet, KeyfleetTreasury treasury) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        treasury = fleet.TREASURY();
        _buyMany(fleet, keys);
    }

    function _pay(KeyfleetTreasury treasury, address asset, address to, uint256 amount)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(address(treasury), 0, abi.encodeCall(KeyfleetTreasury.pay, (asset, to, amount)));
    }

    function _advance(KeyfleetTreasury treasury, uint256 advanceId, address asset, uint256 amount)
        private
        view
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(
            address(treasury),
            0,
            abi.encodeCall(KeyfleetTreasury.advance, (advanceId, operator, asset, amount, keccak256("purpose")))
        );
    }

    /// @dev Invariant: the treasury takes ETH from anyone, and pays ETH and tokens only through an
    /// approved proposal's call; nobody else reaches `pay` or `advance`, the voting controller
    /// included.
    function test_onlyAnApprovedCallPaysOrAdvances() public {
        (Keyfleet fleet, KeyfleetTreasury treasury) = _classic(1);
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

        uint256 capital = usdc.balanceOf(address(treasury));
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = _pay(treasury, NATIVE, operator, 0.4 ether)[0];
        calls[1] = _pay(treasury, address(usdc), operator, capital)[0];
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit Paid(NATIVE, operator, 0.4 ether);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit Paid(address(usdc), operator, capital);
        votes.execute(proposalId, calls);

        assertEq(operator.balance, 0.4 ether);
        assertEq(address(treasury).balance, 0.6 ether);
        assertEq(usdc.balanceOf(operator), capital, "governance may spend all free capital");
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    /// @dev Invariant: a token that returns false instead of paying fails the payment, the whole
    /// batch with it, and the proposal stays approved.
    function test_aTokenThatReturnsFalseFailsThePayment() public {
        (Keyfleet fleet, KeyfleetTreasury treasury) = _classic(1);
        FalseReturningToken token = new FalseReturningToken();
        token.mint(address(treasury), 5);

        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetTreasury.Call[] memory calls = _pay(treasury, address(token), operator, 6);
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.proposal(proposalId).closesAt);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        votes.execute(proposalId, calls);
        assertEq(uint256(votes.status(proposalId)), uint256(KeyfleetVotes.Status.Approved));
        assertEq(token.balanceOf(address(treasury)), 5);
    }

    /// @dev Invariant: the ledger accepts split funding only from inside the treasury's own split
    /// routine, so an approved call from the treasury straight to either funding function reverts,
    /// even with the exact amounts already in the ledger.
    function test_anApprovedCallCannotFundTheSplit() public {
        (Keyfleet fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        vm.deal(address(treasury), 2 ether);
        KeyfleetVotes votes = fleet.VOTES();

        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = KeyfleetTreasury.Call(address(usdc), 0, abi.encodeCall(IERC20.transfer, (address(rewards), 2e6)));
        calls[1] = KeyfleetTreasury.Call(
            address(rewards), 0, abi.encodeCall(KeyfleetRewards.fundSplit, (address(usdc), 1e6, 2))
        );
        uint256 proposalId = _approve(fleet, calls);
        KeyfleetTreasury.Call[] memory native =
            _one(address(rewards), 2 ether, abi.encodeCall(KeyfleetRewards.fundSplitNative, (1 ether, 2)));
        uint256 nativeId = _approve(fleet, native);

        vm.warp(votes.proposal(nativeId).closesAt);
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        votes.execute(proposalId, calls);
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        votes.execute(nativeId, native);

        assertFalse(treasury.splitInProgress());
        assertEq(rewards.splitIndex(address(usdc)), 0);
        assertEq(rewards.splitIndex(NATIVE), 0);
        assertEq(address(treasury).balance, 2 ether);
    }

    /// @dev Invariant: proposing reserves nothing, so a proposal opened later may spend what an
    /// earlier one would have, and two approvals can never spend the same funds twice: the second
    /// batch fails and stays approved.
    function test_proposalsReserveNothingAndCannotDoubleSpend() public {
        (Keyfleet fleet, KeyfleetTreasury treasury) = _classic(1);
        uint256 capital = usdc.balanceOf(address(treasury));
        KeyfleetTreasury.Call[] memory first = _pay(treasury, address(usdc), operator, capital);
        KeyfleetTreasury.Call[] memory second = _pay(treasury, address(usdc), mallory, capital);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 firstId = _approve(fleet, first);
        uint256 secondId = _approve(fleet, second);
        assertEq(usdc.balanceOf(address(treasury)), capital, "nothing moved or was set aside");

        vm.warp(votes.proposal(secondId).closesAt);
        votes.execute(secondId, second);
        assertEq(usdc.balanceOf(mallory), capital);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(treasury), 0, capital)
        );
        votes.execute(firstId, first);
        assertEq(uint256(votes.status(firstId)), uint256(KeyfleetVotes.Status.Approved));
        assertEq(usdc.balanceOf(operator), 0);
    }

    /// @dev Invariant: an advance is sent and recorded as outstanding under a new id; anyone may
    /// return it, in part or whole, but never more than is outstanding, so the same funds cannot be
    /// returned twice and a return cannot be labelled against more than was advanced.
    function test_aTokenAdvanceIsReturnedOnlyUpToWhatIsOutstanding() public {
        (Keyfleet fleet, KeyfleetTreasury treasury) = _classic(1);
        _execute(fleet, _advance(treasury, 7, address(usdc), 3_000_000));
        assertEq(usdc.balanceOf(operator), 3_000_000);
        (address recordedOperator, address asset, uint256 outstanding, bytes32 purposeHash) = treasury.advances(7);
        assertEq(recordedOperator, operator);
        assertEq(asset, address(usdc));
        assertEq(outstanding, 3_000_000);
        assertEq(purposeHash, keccak256("purpose"));

        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetTreasury.Call[] memory again = _advance(treasury, 7, address(usdc), 1);
        uint256 againId = _approve(fleet, again);
        vm.warp(votes.proposal(againId).closesAt);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.AdvanceIdTaken.selector, 7));
        votes.execute(againId, again);

        usdc.mint(mallory, 10_000_000);
        vm.startPrank(mallory);
        usdc.approve(address(treasury), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(KeyfleetTreasury.ReturnAboveOutstanding.selector, 7, 3_000_001, 3_000_000)
        );
        treasury.returnAdvance(7, 3_000_001);
        vm.deal(mallory, 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.WrongValue.selector, 1));
        treasury.returnAdvance{value: 1}(7, 1_000_000);

        uint256 before = usdc.balanceOf(address(treasury));
        vm.expectEmit(true, true, true, true, address(treasury));
        emit AdvanceReturned(7, mallory, 1_000_000, 2_000_000);
        treasury.returnAdvance(7, 1_000_000);
        treasury.returnAdvance(7, 2_000_000);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.ReturnAboveOutstanding.selector, 7, 1, 0));
        treasury.returnAdvance(7, 1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(treasury)), before + 3_000_000, "each unit came back once");
        (,, outstanding,) = treasury.advances(7);
        assertEq(outstanding, 0);
    }

    /// @dev Invariant: an ETH advance comes back only with exactly the ETH named.
    function test_anEthAdvanceIsReturnedWithExactlyItsValue() public {
        (Keyfleet fleet, KeyfleetTreasury treasury) = _classic(1);
        vm.deal(address(treasury), 1 ether);
        _execute(fleet, _advance(treasury, 1, NATIVE, 0.25 ether));
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
    /// treasury's and the controller's locks, and the core's owed share is untouched.
    function test_aReentrantPayeeCannotReachProtectedAccounting() public {
        (Keyfleet fleet, KeyfleetTreasury treasury) = _classic(2);
        vm.deal(address(treasury), 1 ether);
        KeyfleetTreasury.Call[] memory inner = _pay(treasury, NATIVE, mallory, 0.1 ether);
        uint256 innerId = _approve(fleet, inner);
        ReenteringPayee payee = new ReenteringPayee(fleet, innerId, inner);
        uint256 owed = fleet.protocolShareOwed();

        _execute(fleet, _pay(treasury, NATIVE, address(payee), 0.5 ether));
        assertEq(payee.attempts(), 3);
        assertEq(payee.gotThrough(), 0, "every attempt met a lock");
        assertEq(fleet.protocolShareOwed(), owed);
        assertEq(uint256(fleet.VOTES().status(innerId)), uint256(KeyfleetVotes.Status.Approved));
        assertEq(address(payee).balance, 0.5 ether);
    }
}
