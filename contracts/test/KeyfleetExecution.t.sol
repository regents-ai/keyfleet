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

    event Paid(address indexed asset, address indexed to, uint256 amount);
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

    function _classic(uint256 count) private returns (KeyfleetManager fleet, KeyfleetTreasury treasury) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        treasury = fleet.TREASURY();
        _buyMany(fleet, count);
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

        uint256 capital = regent.balanceOf(address(treasury));
        assertGt(capital, 0, "the first key's capital arrived as REGENT");
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = _pay(treasury, NATIVE, operator, 0.4 ether)[0];
        calls[1] = _pay(treasury, address(regent), operator, capital)[0];
        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit Paid(NATIVE, operator, 0.4 ether);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit Paid(address(regent), operator, capital);
        votes.execute(proposalId, calls);

        assertEq(operator.balance, 0.4 ether);
        assertEq(address(treasury).balance, 0.6 ether);
        assertEq(regent.balanceOf(operator), capital, "governance may spend all free capital");
        assertEq(regent.balanceOf(address(treasury)), 0);
    }

    /// @dev Invariant: a token that returns false instead of paying fails the payment, the whole
    /// batch with it, and the proposal stays approved.
    function test_aTokenThatReturnsFalseFailsThePayment() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
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
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        vm.deal(address(treasury), 2 ether);
        KeyfleetVotes votes = fleet.VOTES();

        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = KeyfleetTreasury.Call(address(regent), 0, abi.encodeCall(IERC20.transfer, (address(rewards), 2e18)));
        calls[1] = KeyfleetTreasury.Call(
            address(rewards), 0, abi.encodeCall(KeyfleetRewards.fundSplit, (address(regent), 1e18, 2))
        );
        uint256 proposalId = _approve(fleet, calls);
        KeyfleetTreasury.Call[] memory native =
            _one(address(rewards), 2 ether, abi.encodeCall(KeyfleetRewards.fundSplitNative, (1 ether, 2)));
        uint256 nativeId = _approve(fleet, native);
        uint256 held = regent.balanceOf(address(treasury));

        vm.warp(votes.proposal(nativeId).closesAt);
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

    /// @dev Invariant: proposing reserves nothing, so a proposal opened later may spend what an
    /// earlier one would have, and two approvals can never spend the same funds twice: the second
    /// batch fails and stays approved.
    function test_proposalsReserveNothingAndCannotDoubleSpend() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        uint256 capital = regent.balanceOf(address(treasury));
        KeyfleetTreasury.Call[] memory first = _pay(treasury, address(regent), operator, capital);
        KeyfleetTreasury.Call[] memory second = _pay(treasury, address(regent), mallory, capital);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 firstId = _approve(fleet, first);
        uint256 secondId = _approve(fleet, second);
        assertEq(regent.balanceOf(address(treasury)), capital, "nothing moved or was set aside");

        vm.warp(votes.proposal(secondId).closesAt);
        votes.execute(secondId, second);
        assertEq(regent.balanceOf(mallory), capital);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(treasury), 0, capital)
        );
        votes.execute(firstId, first);
        assertEq(uint256(votes.status(firstId)), uint256(KeyfleetVotes.Status.Approved));
        assertEq(regent.balanceOf(operator), 0);
    }

    /// @dev Invariant: an advance is sent and recorded as outstanding under a new id; anyone may
    /// return it, in part or whole, but never more than is outstanding, so the same funds cannot be
    /// returned twice and a return cannot be labelled against more than was advanced.
    function test_aTokenAdvanceIsReturnedOnlyUpToWhatIsOutstanding() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        _execute(fleet, _advance(treasury, 7, address(regent), 3e18));
        assertEq(regent.balanceOf(operator), 3e18);
        (address recordedOperator, address asset, uint256 outstanding, bytes32 purposeHash) = treasury.advances(7);
        assertEq(recordedOperator, operator);
        assertEq(asset, address(regent));
        assertEq(outstanding, 3e18);
        assertEq(purposeHash, keccak256("purpose"));

        KeyfleetVotes votes = fleet.VOTES();
        KeyfleetTreasury.Call[] memory again = _advance(treasury, 7, address(regent), 1);
        uint256 againId = _approve(fleet, again);
        vm.warp(votes.proposal(againId).closesAt);
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
    /// treasury's and the controller's locks, and the manager's owed share is untouched.
    function test_aReentrantPayeeCannotReachProtectedAccounting() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        vm.deal(address(treasury), 1 ether);
        KeyfleetTreasury.Call[] memory inner = _pay(treasury, NATIVE, mallory, 0.1 ether);
        uint256 innerId = _approve(fleet, inner);
        ReenteringPayee payee = new ReenteringPayee(fleet, innerId, inner);
        uint256 owed = fleet.protocolShareOwed();

        _execute(fleet, _pay(treasury, NATIVE, address(payee), 0.5 ether));
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
        vm.warp(votes.proposal(proposalId).closesAt);
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
        vm.warp(votes.proposal(proposalIds[attempts.length - 1]).closesAt);
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
        a[0] = _attempt("advancePhase", address(keys), abi.encodeCall(KeyfleetKeys.advancePhase, ()), onlySafe);
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
            abi.encodeCall(KeyfleetManager.onKeyMoved, (ownKey, keys.ownerOf(ownKey), treasury)),
            onlyKeys
        );
        a[4] = _attempt(
            "other onKeyMoved",
            address(another),
            abi.encodeCall(KeyfleetManager.onKeyMoved, (otherKey, keys.ownerOf(otherKey), treasury)),
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
            abi.encodeCall(KeyfleetTreasury.pay, (address(regent), treasury, 1)),
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
        vm.warp(votes.proposal(proposalId).closesAt);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        votes.execute(proposalId, calls);
        assertEq(staking.totalUsdcReceived(), 0);
        assertEq(usdc.balanceOf(address(treasury)), 1e6);
    }
}
