// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {IKeyfleetFactory, KeyfleetWiring} from "../src/KeyfleetWiring.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev Names the factory and deploys a ledger outside any creation, as a deployer would.
contract RogueRewardsDeployer {
    IKeyfleetFactory public immutable FACTORY;

    constructor(IKeyfleetFactory factory) {
        FACTORY = factory;
    }

    function deploy() external returns (address) {
        return address(new KeyfleetRewards());
    }
}

/// @dev Code the test places at a treasury's address for one call, to set the split-in-progress
/// flag the treasury keeps in transient storage. Only the treasury's own split routine sets it, so
/// this is how the test stands inside that routine and funds the ledger with exact amounts.
contract SplitFlagWriter {
    /// @dev Writes the treasury's `SPLIT_IN_PROGRESS` transient slot.
    function write(bool on) external {
        assembly ("memory-safe") {
            tstore(0xd9aca5cd3a42e97768814a58347bfab1c7bcba20bf1fb9c47c8b9d767310a900, on)
        }
    }
}

/// @dev A token whose outgoing transfers can be switched off, standing in for a split asset that
/// pauses or blocklists.
contract RevertingERC20 is ERC20 {
    error TransferDisabled();

    bool public transfersFail;

    constructor() ERC20("Reverting", "REV") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransfersFail(bool value) external {
        transfersFail = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transfersFail) revert TransferDisabled();
        return super.transfer(to, amount);
    }
}

/// @dev A split asset that also holds a key, and calls back into the ledger during its own transfer
/// to claim what its key earned. Without the guard this second payout would settle.
contract ReenteringERC20 is ERC20 {
    KeyfleetRewards private _rewards;
    uint256[] private _keys;
    bool private _reentering;

    constructor() ERC20("Reentering", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(KeyfleetRewards rewards, uint256[] calldata tokenIds) external {
        _rewards = rewards;
        _keys = tokenIds;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (address(_rewards) != address(0) && !_reentering) {
            _reentering = true;
            address[] memory assets = new address[](1);
            assets[0] = address(this);
            _rewards.claim(_keys, assets);
        }
        return super.transfer(to, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @dev A key holder that refuses ETH.
contract EthRefuser {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @dev A key holder that tries to claim again while being paid ETH.
contract EthReclaimer {
    KeyfleetRewards private immutable REWARDS;

    constructor(KeyfleetRewards rewards) {
        REWARDS = rewards;
    }

    receive() external payable {
        address[] memory assets = new address[](1);
        REWARDS.claim(new uint256[](0), assets);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @dev The reward ledger of real fleets. Purchases enroll keys and transfers settle them, as they
/// do on chain. To drive the ledger directly, the test calls it as the fleet's manager, and funds
/// the split as the fleet's treasury from inside its split flag.
contract KeyfleetRewardsTest is KeyfleetFixture {
    uint256 private constant PRECISION = 1e27;
    address private constant NATIVE = address(0);
    /// @dev The measured worst-case settlement, a cohort accrual and four split assets all cold,
    /// plus twenty percent, rounded up to the nearest thousand.
    uint256 private constant SETTLE_GAS_CEILING = 288_000;

    /// @dev The fleet in use, its ledger and its treasury.
    KeyfleetManager private fleet;
    KeyfleetRewards private rewards;
    KeyfleetTreasury private treasury;
    SplitFlagWriter private flagWriter;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCAC01);
    address private agent = address(0xA6E47);

    event KeyEnrolled(uint256 indexed tokenId, uint256 indexed cohortId);
    event Credited(address indexed asset, address indexed account, uint256 amount);
    event SplitFunded(address indexed asset, uint256 perKey, uint256 keys, uint256 newIndex);
    event Settled(uint256 indexed tokenId, address indexed asset, address indexed owner, uint256 amount);
    event Claimed(address indexed asset, address indexed account, address indexed by, uint256 amount);

    function setUp() public {
        _setUpFixture();
        flagWriter = new SplitFlagWriter();
        _use(_deploy(KeyfleetPresets.Preset.FleetTechClassic));
    }

    // --- helpers ---------------------------------------------------------

    /// @dev Makes `target` the fleet whose ledger the helpers drive.
    function _use(KeyfleetManager target) private {
        fleet = target;
        rewards = target.REWARDS();
        treasury = target.TREASURY();
    }

    /// @dev Enrolls a key that has not been minted, as the manager, into any cohort. The manager is
    /// the ledger's only writer and names the cohort; this reaches cohorts a real fleet takes
    /// thousands of purchases to reach.
    function _enrollAsManager(uint256 keyNumber, uint256 cohortId) private returns (uint256 tokenId) {
        tokenId = _key(fleet, keyNumber);
        vm.prank(address(fleet));
        rewards.enrollKey(tokenId, cohortId);
    }

    function _fundAndAllocate(uint256 cohortId, uint256 amount) private {
        usdc.mint(address(rewards), amount);
        vm.prank(address(fleet));
        rewards.allocateToCohort(address(usdc), cohortId, amount);
    }

    /// @dev Sets or clears `target`'s split-in-progress flag: places the writer's code at the
    /// treasury for one call, then puts the treasury's own code back. The flag lives in transient
    /// storage, so it lasts for the rest of the test's transaction.
    function _setSplitting(KeyfleetTreasury target, bool on) private {
        bytes memory code = address(target).code;
        vm.etch(address(target), address(flagWriter).code);
        SplitFlagWriter(address(target)).write(on);
        vm.etch(address(target), code);
        assertEq(target.splitInProgress(), on, "the treasury reports the flag the test set");
    }

    /// @dev Funds a split of `perKey` per minted key, as the treasury's split routine does.
    function _split(address asset, uint256 perKey) private {
        uint256 count = fleet.totalMinted();
        uint256 amount = perKey * count;
        _setSplitting(treasury, true);
        if (asset == NATIVE) {
            vm.deal(address(treasury), address(treasury).balance + amount);
            vm.prank(address(treasury));
            rewards.fundSplitNative{value: amount}(perKey, count);
        } else {
            MockToken(asset).mint(address(rewards), amount);
            vm.prank(address(treasury));
            rewards.fundSplit(asset, perKey, count);
        }
        _setSplitting(treasury, false);
    }

    function _claim(address caller, uint256[] memory ids, address asset) private returns (uint256) {
        vm.prank(caller);
        return rewards.claim(ids, _assets(asset))[0];
    }

    function _assets(address a) private pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = a;
    }

    function _assets(address a, address b) private pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = a;
        assets[1] = b;
    }

    function _pair(uint256 a, uint256 b) private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _none() private pure returns (uint256[] memory ids) {
        ids = new uint256[](0);
    }

    // --- 1. only the manager writes, only the treasury's split funds -------

    function test_theLedgerIsBoundToItsFleet() public view {
        assertEq(address(rewards.MANAGER()), address(fleet));
        assertEq(rewards.FLEET_ID(), fleet.FLEET_ID());
        assertEq(address(rewards.KEYS()), address(keys));
        assertEq(rewards.USDC(), address(usdc));
        assertEq(address(rewards.TREASURY()), address(treasury));
        assertEq(address(rewards.SHARDS()), address(shards), "the one shared shard record");
        assertEq(address(treasury.REWARDS()), address(rewards), "the treasury funds this ledger");
        assertEq(rewards.PRECISION(), PRECISION, "cohort index scale is 1e27");
    }

    /// @dev A ledger exists only as one of a fleet's four contracts, from the factory's own creation.
    function test_aLedgerCannotBeDeployedOutsideTheFactory() public {
        vm.expectRevert();
        new KeyfleetRewards();

        RogueRewardsDeployer rogue = new RogueRewardsDeployer(IKeyfleetFactory(address(factory)));
        address predicted = vm.computeCreateAddress(address(rogue), 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetWiring.NotWired.selector, predicted));
        rogue.deploy();
    }

    function testFuzz_onlyTheManagerCanEnrollAllocateCreditAndSettle(address caller) public {
        vm.assume(caller != address(fleet) && caller != address(vm));
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _key(fleet, 2);

        vm.startPrank(caller);
        vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
        rewards.enrollKey(k2, 0);
        vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
        rewards.allocateToCohort(address(usdc), 0, 1);
        vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
        rewards.credit(address(usdc), caller, 1);
        vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
        rewards.settleKey(k1, caller);
        vm.stopPrank();

        assertEq(rewards.cohortSize(0), 1, "no key enrolled by a stranger");
        assertEq(rewards.cohortIndex(address(usdc), 0), 0, "no allocation by a stranger");
        assertEq(rewards.credits(address(usdc), caller), 0, "no credit by a stranger");
    }

    function testFuzz_onlyTheTreasuryInsideItsSplitFundsTheSplit(address caller) public {
        vm.assume(caller != address(treasury) && caller != address(vm));
        _buy(fleet, alice);
        regent.mint(address(rewards), 1e18);
        vm.deal(caller, 1e18);
        vm.deal(address(treasury), 1e18);

        _setSplitting(treasury, true);
        vm.startPrank(caller);
        vm.expectRevert(KeyfleetRewards.OnlyTreasury.selector);
        rewards.fundSplit(address(regent), 1e18, 1);
        vm.expectRevert(KeyfleetRewards.OnlyTreasury.selector);
        rewards.fundSplitNative{value: 1e18}(1e18, 1);
        vm.stopPrank();

        _setSplitting(treasury, false);
        vm.startPrank(address(treasury));
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        rewards.fundSplit(address(regent), 1e18, 1);
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        rewards.fundSplitNative{value: 1e18}(1e18, 1);
        vm.stopPrank();

        assertEq(rewards.splitIndex(address(regent)), 0);
        assertEq(rewards.splitIndex(NATIVE), 0);
        assertEq(rewards.rewardAssets().length, 1, "nothing was added to the assets the ledger pays");
    }

    /// @dev An approved proposal's call reaches the ledger from the treasury, but outside the split
    /// routine, so it cannot fund the split.
    function test_anApprovedProposalCannotFundTheSplit() public {
        _buy(fleet, alice);
        _mature();
        _openTreasury(fleet);
        regent.mint(address(rewards), 1e18);
        KeyfleetTreasury.Call[] memory calls =
            _one(address(rewards), 0, abi.encodeCall(KeyfleetRewards.fundSplit, (address(regent), 1e18, 1)));

        KeyfleetVotes votes = fleet.VOTES();
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        votes.execute(proposalId, calls);
        assertEq(rewards.splitIndex(address(regent)), 0);
    }

    // --- 2. the cohort lane and direct credits take USDC only ---------------

    function test_theCohortLaneAndDirectCreditsTakeUsdcOnly() public {
        _buy(fleet, alice);
        regent.mint(address(rewards), 1e18);

        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.UnknownAsset.selector);
        rewards.allocateToCohort(address(regent), 0, 1e18);
        vm.expectRevert(KeyfleetRewards.UnknownAsset.selector);
        rewards.credit(address(regent), alice, 1e18);
        vm.stopPrank();
    }

    // --- 3. cohort allocation math and retained dust ----------------------

    function test_threeKeyAllocationPaysFloorSharesAndCarriesTheRemainder() public {
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _buy(fleet, bob);
        uint256 k3 = _buy(fleet, carol);

        uint256 amount = 10e18;
        _fundAndAllocate(0, amount);

        uint256 share = amount / 3;
        assertEq(rewards.backed(address(usdc)), amount, "the whole allocation is reserved, dust included");
        assertEq(rewards.accrued(address(usdc), k1), share, "floor share per key");

        assertEq(_claim(alice, _ids(k1), address(usdc)), share, "alice floor share");
        assertEq(_claim(bob, _ids(k2), address(usdc)), share, "bob floor share");
        assertEq(_claim(carol, _ids(k3), address(usdc)), share, "carol floor share");

        uint256 dust = amount - 3 * share;
        assertEq(dust, 1, "the remainder of 10e18 over three keys is one atomic unit");
        assertEq(usdc.balanceOf(address(rewards)), dust, "the remainder stays in the contract");
        assertEq(rewards.backed(address(usdc)), dust, "the remainder is still counted as backed, never free");

        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(_ids(k1), _assets(address(usdc)));
    }

    // --- 4. eligibility and backing ---------------------------------------

    function test_allocationRequiresEligibleKeysAndTokensAlreadyPresent() public {
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.NoEligibleKeys.selector);
        rewards.allocateToCohort(address(usdc), 0, 1e18);

        _buy(fleet, alice);

        usdc.mint(address(rewards), 1e18 - 1);
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.allocateToCohort(address(usdc), 0, 1e18);

        usdc.mint(address(rewards), 1);
        vm.prank(address(fleet));
        rewards.allocateToCohort(address(usdc), 0, 1e18);
        assertEq(rewards.backed(address(usdc)), 1e18, "funded allocation reserves the amount");

        // A second allocation must be backed on top of the first, not against the same balance.
        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.allocateToCohort(address(usdc), 0, 1);
        vm.expectRevert(KeyfleetRewards.ZeroAmount.selector);
        rewards.allocateToCohort(address(usdc), 0, 0);
        vm.stopPrank();
    }

    function test_creditRequiresPresentTokensAndAccumulatesBacking() public {
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.credit(address(usdc), alice, 5e18);

        usdc.mint(address(rewards), 5e18);
        vm.prank(address(fleet));
        vm.expectEmit(true, true, false, true, address(rewards));
        emit Credited(address(usdc), alice, 5e18);
        rewards.credit(address(usdc), alice, 5e18);
        assertEq(rewards.credits(address(usdc), alice), 5e18, "credit recorded");
        assertEq(rewards.backed(address(usdc)), 5e18, "credit reserved");

        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.credit(address(usdc), bob, 1);
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        rewards.credit(address(usdc), address(0), 1);
        vm.expectRevert(KeyfleetRewards.ZeroAmount.selector);
        rewards.credit(address(usdc), bob, 0);
        vm.stopPrank();

        assertEq(_claim(alice, _none(), address(usdc)), 5e18, "direct credit is claimable without any key");
    }

    // --- 5. the split lane --------------------------------------------------

    /// @dev On Syndicate a key's cohort is its level, so keys 1 to 6 sit in cohorts 1, 1, 2, 2, 2
    /// and 3, and the split still gives each the same amount.
    function test_aSplitGivesEveryMintedKeyTheSameWholeAmount() public {
        _use(_deploy(KeyfleetPresets.Preset.FibonacciSyndicate));
        _buyMany(fleet, 6);
        assertEq(rewards.keyCohort(_key(fleet, 1)), 1);
        assertEq(rewards.keyCohort(_key(fleet, 3)), 2);
        assertEq(rewards.keyCohort(_key(fleet, 6)), 3, "the keys span three cohorts");

        regent.mint(address(rewards), 30e18);
        _setSplitting(treasury, true);
        vm.prank(address(treasury));
        vm.expectEmit(true, false, false, true, address(rewards));
        emit SplitFunded(address(regent), 5e18, 6, 5e18);
        rewards.fundSplit(address(regent), 5e18, 6);
        _setSplitting(treasury, false);
        _split(NATIVE, 1 ether);

        for (uint256 n = 1; n <= 6; ++n) {
            assertEq(rewards.accrued(address(regent), _key(fleet, n)), 5e18, "every key, whatever its cohort");
            assertEq(rewards.accrued(NATIVE, _key(fleet, n)), 1 ether);
        }
        assertEq(rewards.backed(address(regent)), 30e18, "the whole allocation is reserved");
        assertEq(rewards.backed(NATIVE), 6 ether);
        assertEq(address(rewards).balance, 6 ether);

        address[] memory assets = rewards.rewardAssets();
        assertEq(assets.length, 3, "USDC, then each split asset in the order first funded");
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(regent));
        assertEq(assets[2], NATIVE);

        _split(address(usdc), 2e6);
        _split(address(regent), 1e18);
        assertEq(rewards.rewardAssets().length, 3, "USDC is listed once, and an asset once however often split");
        assertEq(rewards.splitIndex(address(regent)), 6e18, "the index is cumulative");
    }

    function test_aSplitMustCoverExactlyTheMintedKeysAndBeBacked() public {
        _buy(fleet, alice);
        _buy(fleet, bob);
        _setSplitting(treasury, true);
        regent.mint(address(rewards), 4e18);
        vm.deal(address(treasury), 10 ether);

        vm.startPrank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.KeyCountChanged.selector, 1, 2));
        rewards.fundSplit(address(regent), 2e18, 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.KeyCountChanged.selector, 3, 2));
        rewards.fundSplit(address(regent), 1e18, 3);
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.fundSplit(address(regent), 2e18 + 1, 2);
        vm.expectRevert(KeyfleetRewards.ZeroAmount.selector);
        rewards.fundSplit(address(regent), 0, 2);
        vm.expectRevert(KeyfleetRewards.UnknownAsset.selector);
        rewards.fundSplit(NATIVE, 1, 2);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.WrongValue.selector, 2 ether - 1));
        rewards.fundSplitNative{value: 2 ether - 1}(1 ether, 2);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.KeyCountChanged.selector, 1, 2));
        rewards.fundSplitNative{value: 2 ether}(2 ether, 1);

        rewards.fundSplit(address(regent), 2e18, 2);
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.fundSplit(address(regent), 1, 2);
        vm.stopPrank();
    }

    function test_aKeyMintedAfterASplitEarnsOnlyLaterSplits() public {
        uint256 k1 = _buy(fleet, alice);
        _split(address(regent), 9e18);
        _split(NATIVE, 1 ether);

        uint256 k2 = _buy(fleet, bob);
        assertEq(rewards.accrued(address(regent), k2), 0, "the newcomer inherits nothing");
        assertEq(rewards.accrued(NATIVE, k2), 0);
        assertEq(rewards.keySplitIndex(k2, address(regent)), 9e18, "it starts from the current index");

        _split(address(regent), 1e18);
        _split(address(usdc), 3e6); // first split of USDC, after both keys
        assertEq(rewards.accrued(address(regent), k1), 10e18);
        assertEq(rewards.accrued(address(regent), k2), 1e18);
        assertEq(rewards.accrued(address(usdc), k1), 3e6, "an asset first split later is shared by every key");
        assertEq(rewards.accrued(address(usdc), k2), 3e6);
    }

    function test_settlementMovesEveryAssetToTheOutgoingOwner() public {
        uint256 k1 = _buy(fleet, alice);
        _fundAndAllocate(0, 4e6);
        _split(address(usdc), 1e6);
        _split(address(regent), 2e18);
        _split(NATIVE, 3 ether);

        vm.prank(address(fleet));
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(k1, address(usdc), alice, 4e6);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(k1, address(usdc), alice, 1e6);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(k1, address(regent), alice, 2e18);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(k1, NATIVE, alice, 3 ether);
        rewards.settleKey(k1, alice);

        assertEq(rewards.credits(address(usdc), alice), 5e6, "the cohort and split lanes both");
        assertEq(rewards.credits(address(regent), alice), 2e18);
        assertEq(rewards.credits(NATIVE, alice), 3 ether);
        assertEq(rewards.accrued(address(usdc), k1), 0, "the key carries nothing forward");
        assertEq(rewards.accrued(address(regent), k1), 0);
        assertEq(rewards.accrued(NATIVE, k1), 0);
    }

    // --- 6. accrual belongs to the earning address ------------------------

    /// @dev Each move of the key goes through the collection, which has the manager settle the key
    /// to its outgoing owner first.
    function test_accruedRewardsNeverTravelWithTheKey() public {
        uint256 k1 = _buy(fleet, alice);
        _fundAndAllocate(0, 100e18); // allocation A, alice holds the key
        _split(NATIVE, 1 ether);

        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);
        assertEq(rewards.credits(address(usdc), alice), 100e18, "the move settled allocation A to alice");
        assertEq(rewards.accrued(address(usdc), k1), 0, "and the key carries none of it to bob");

        _fundAndAllocate(0, 50e18); // allocation B, bob holds the key
        _split(NATIVE, 2 ether);

        // Alice owns no key at all and still claims exactly what accrued under her.
        vm.prank(alice);
        uint256[] memory paid = rewards.claim(_none(), _assets(address(usdc), NATIVE));
        assertEq(paid[0], 100e18, "alice keeps allocation A");
        assertEq(paid[1], 1 ether, "and the first split");
        assertEq(alice.balance, 1 ether);

        vm.prank(bob);
        paid = rewards.claim(_ids(k1), _assets(address(usdc), NATIVE));
        assertEq(paid[0], 50e18, "bob earns only allocation B");
        assertEq(paid[1], 2 ether, "and the second split");

        // The key returns to alice. She must not re-earn anything.
        vm.prank(bob);
        keys.transferFrom(bob, alice, k1);
        _fundAndAllocate(0, 25e18);

        assertEq(_claim(alice, _ids(k1), address(usdc)), 25e18, "alice earns only C on her return");
        assertEq(usdc.balanceOf(alice), 125e18, "no double counting across re-acquisition");
        assertEq(rewards.backed(address(usdc)), 0, "everything allocated was paid out");
        assertEq(rewards.backed(NATIVE), 0);
    }

    function test_settleKeyRejectsZeroOwnerAndUnenrolledKeys() public {
        uint256 k1 = _buy(fleet, alice);
        uint256 unenrolled = _key(fleet, 99);
        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        rewards.settleKey(k1, address(0));
        vm.expectRevert(KeyfleetRewards.KeyNotEnrolled.selector);
        rewards.settleKey(unenrolled, alice);
        vm.stopPrank();

        vm.expectRevert(KeyfleetRewards.KeyNotEnrolled.selector);
        rewards.keyCohort(unenrolled);
        assertEq(rewards.keyCohort(k1), 0, "enrolled key reports its cohort");
    }

    /// @dev Cohort ids are the fleet's levels, which have no last one, so the ledger takes any
    /// cohort id the manager names.
    function test_enrollmentIsPermanentAndTakesAnyCohort() public {
        uint256 k1 = _buy(fleet, alice);
        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.KeyAlreadyEnrolled.selector);
        rewards.enrollKey(k1, 0);
        vm.expectRevert(KeyfleetRewards.KeyAlreadyEnrolled.selector);
        rewards.enrollKey(k1, 5);
        vm.stopPrank();

        vm.expectEmit(true, true, false, false, address(rewards));
        emit KeyEnrolled(_key(fleet, 2), 41);
        uint256 k2 = _enrollAsManager(2, 41);
        uint256 k3 = _enrollAsManager(3, 1_000);
        assertEq(rewards.keyCohort(k2), 41, "level 41 is a cohort like any other");
        assertEq(rewards.keyCohort(k3), 1_000);
        assertEq(rewards.cohortSize(0), 1, "one key in cohort 0");
        assertEq(rewards.cohortSize(41), 1, "one key in cohort 41");

        _fundAndAllocate(41, 3e18);
        assertEq(rewards.accrued(address(usdc), k2), 3e18, "and earns like any other");
    }

    // --- 7. late cohort enrollment and cohort isolation ---------------------

    function test_keyEnrolledAfterAnAllocationEarnsOnlyLaterOnes() public {
        uint256 k1 = _buy(fleet, alice);
        _fundAndAllocate(0, 90e18);

        uint256 k2 = _buy(fleet, bob); // joins after allocation A
        assertEq(rewards.accrued(address(usdc), k2), 0, "the newcomer inherits nothing");

        _fundAndAllocate(0, 40e18); // allocation B is split two ways
        assertEq(rewards.accrued(address(usdc), k2), 20e18, "newcomer earns half of B only");
        assertEq(rewards.accrued(address(usdc), k1), 110e18, "incumbent earns A plus half of B");

        // A cohort with no keys cannot receive an allocation at all.
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.NoEligibleKeys.selector);
        rewards.allocateToCohort(address(usdc), 7, 1e18);
        uint256 k3 = _enrollAsManager(3, 7);
        _fundAndAllocate(7, 1e18);
        assertEq(rewards.accrued(address(usdc), k3), 1e18, "and earns from the first allocation it can receive");
    }

    function test_settlementTouchesOnlyTheKeysOwnCohort() public {
        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            _enrollAsManager(cohortId + 1, cohortId);
        }
        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            _fundAndAllocate(cohortId, (cohortId + 1) * 1e18);
        }

        uint256 k5 = _key(fleet, 5);
        vm.prank(address(fleet));
        rewards.settleKey(k5, alice);
        assertEq(rewards.credits(address(usdc), alice), 5e18, "one cohort settled, nineteen untouched");

        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            uint256 keyNumber = cohortId + 1;
            uint256 expected = keyNumber == 5 ? 0 : (cohortId + 1) * 1e18;
            assertEq(rewards.accrued(address(usdc), _key(fleet, keyNumber)), expected, "other cohorts unaffected");
        }
    }

    // --- 8. worst-case settlement gas -------------------------------------

    /// @dev Worst case: a pending cohort accrual and a pending split in four assets, every per-key
    /// slot cold and moving from zero.
    function test_worstCaseSettlementGasStaysUnderCeiling() public {
        MockToken ousd = new MockToken("Origin Dollar", "OUSD");
        uint256 k1 = _buy(fleet, alice);
        _fundAndAllocate(0, 1e18);
        _split(NATIVE, 1 ether);
        _split(address(regent), 1e18);
        _split(address(usdc), 1e6);
        _split(address(ousd), 1e18);

        vm.cool(address(rewards));
        vm.prank(address(fleet));
        uint256 before = gasleft();
        rewards.settleKey(k1, alice);
        uint256 used = before - gasleft();
        console2.log("worst-case settleKey gas, cohort plus four split assets (cold slots):", used);

        assertLt(used, SETTLE_GAS_CEILING, "worst-case settlement stays under the ceiling");
        assertEq(rewards.credits(address(ousd), alice), 1e18, "the last asset settled");
    }

    // --- 9. who may claim, and who is paid ----------------------------------

    function test_claimNeedsTheHolderOrAnActiveShardOfEveryKey() public {
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _buy(fleet, bob);
        _fundAndAllocate(0, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, k1));
        rewards.claim(_pair(k2, k1), _assets(address(usdc)));
        assertEq(rewards.credits(address(usdc), bob), 0, "no partial settlement survives the revert");
        assertEq(rewards.accrued(address(usdc), k2), 5e18, "bob's key untouched");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, k1));
        rewards.claim(_ids(k1), _assets(address(usdc)));

        vm.prank(bob);
        shards.issue(_ids(k2), agent, 30);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, k1));
        rewards.claim(_pair(k2, k1), _assets(address(usdc)));

        // A key of this fleet that was never minted has no holder.
        uint256 unminted = _key(fleet, 99);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, unminted));
        rewards.claim(_pair(k1, unminted), _assets(address(usdc)));

        // A shard whose time has run out claims nothing more.
        vm.warp(block.timestamp + 30 days);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, k2));
        rewards.claim(_ids(k2), _assets(address(usdc)));
    }

    function test_anAgentsClaimPaysEachKeysHolderNeverTheAgent() public {
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _buy(fleet, bob);
        uint256 k3 = _buy(fleet, alice);
        _split(address(regent), 1e18);
        _split(NATIVE, 1 ether);
        vm.prank(alice);
        shards.issue(_pair(k1, k3), agent, 30);
        vm.prank(bob);
        shards.issue(_ids(k2), agent, 30);

        vm.prank(agent);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Claimed(address(regent), alice, agent, 2e18);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Claimed(address(regent), bob, agent, 1e18);
        uint256[] memory paid = rewards.claim(_range(k1, 3), _assets(address(regent), NATIVE));

        assertEq(paid[0], 3e18, "both holders paid in one call");
        assertEq(paid[1], 3 ether);
        assertEq(regent.balanceOf(alice), 2e18, "alice holds two of the keys");
        assertEq(regent.balanceOf(bob), 1e18);
        assertEq(alice.balance, 2 ether);
        assertEq(bob.balance, 1 ether);
        assertEq(regent.balanceOf(agent), 0, "the agent is paid nothing");
        assertEq(agent.balance, 0);
    }

    function test_theCallerIsPaidOnlyItsOwnCredit() public {
        uint256 k1 = _buy(fleet, alice);
        usdc.mint(address(rewards), 7e6);
        vm.prank(address(fleet));
        rewards.credit(address(usdc), agent, 7e6); // the agent once held a key
        _split(address(usdc), 1e6);
        vm.prank(alice);
        shards.issue(_ids(k1), agent, 30);

        vm.prank(agent);
        assertEq(rewards.claim(_ids(k1), _assets(address(usdc)))[0], 8e6, "its own credit and alice's key");
        assertEq(usdc.balanceOf(agent), 7e6, "the agent's own credit goes to the agent");
        assertEq(usdc.balanceOf(alice), 1e6, "the key's money goes to its holder");
    }

    function test_unknownOrRepeatedAssetsPayNothingMore() public {
        uint256 k1 = _buy(fleet, alice);
        _split(address(regent), 1e18);

        vm.prank(alice);
        uint256[] memory paid = rewards.claim(_ids(k1), _assets(address(regent), address(regent)));
        assertEq(paid[0], 1e18);
        assertEq(paid[1], 0, "a repeated asset finds nothing left");

        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(_ids(k1), _assets(address(0xBEEF)));
    }

    /// @dev A wallet that refuses ETH stops only a claim that pays it ETH: the same claim without
    /// ETH pays it, and other holders' ETH is unaffected.
    function test_aWalletThatRefusesEthBlocksOnlyItsOwnEth() public {
        address refuser = address(new EthRefuser());
        uint256 k1 = _buy(fleet, refuser);
        uint256 k2 = _buy(fleet, bob);
        _split(NATIVE, 1 ether);
        _split(address(regent), 1e18);
        vm.prank(refuser);
        shards.issue(_ids(k1), agent, 30);

        vm.prank(agent);
        vm.expectRevert(Errors.FailedCall.selector);
        rewards.claim(_ids(k1), _assets(NATIVE));
        assertEq(rewards.accrued(NATIVE, k1), 1 ether, "the ETH stays waiting for the key");

        vm.prank(agent);
        assertEq(rewards.claim(_ids(k1), _assets(address(regent)))[0], 1e18, "the same key's REGENT goes through");
        assertEq(regent.balanceOf(refuser), 1e18);
        assertEq(rewards.credits(NATIVE, refuser), 1 ether, "its ETH is now its credit, still backed");
        assertEq(rewards.backed(NATIVE), 2 ether);

        assertEq(_claim(bob, _ids(k2), NATIVE), 1 ether, "another holder's ETH is unaffected");
    }

    /// @dev A USDC that refuses a payout, as a paused or blocklisting USDC does, reverts the claim
    /// and leaves the accrual and its backing exactly as they were.
    function test_aRefusedUsdcPayoutLeavesTheCreditIntact() public {
        uint256 k1 = _buy(fleet, alice);
        _fundAndAllocate(0, 7e18);

        bytes memory paused = abi.encodeWithSelector(RevertingERC20.TransferDisabled.selector);
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector), paused);
        vm.prank(alice);
        vm.expectRevert(paused);
        rewards.claim(_ids(k1), _assets(address(usdc)));
        assertEq(rewards.accrued(address(usdc), k1), 7e18, "the accrual is preserved untouched");
        assertEq(rewards.backed(address(usdc)), 7e18, "still fully reserved");

        vm.clearMockedCalls();
        assertEq(_claim(alice, _ids(k1), address(usdc)), 7e18, "claimable again once USDC works");
        assertEq(rewards.backed(address(usdc)), 0, "reserve released only by the payout");
    }

    /// @dev The same for a split asset that refuses a payout.
    function test_aRefusedSplitPayoutLeavesTheCreditIntact() public {
        RevertingERC20 stuck = new RevertingERC20();
        uint256 k1 = _buy(fleet, alice);
        _split(address(stuck), 7e18);

        stuck.setTransfersFail(true);
        vm.prank(alice);
        vm.expectRevert(RevertingERC20.TransferDisabled.selector);
        rewards.claim(_ids(k1), _assets(address(stuck)));
        assertEq(rewards.accrued(address(stuck), k1), 7e18, "the accrual is preserved untouched");
        assertEq(rewards.backed(address(stuck)), 7e18, "still fully reserved");

        stuck.setTransfersFail(false);
        assertEq(_claim(alice, _ids(k1), address(stuck)), 7e18, "claimable again once the token works");
        assertEq(rewards.backed(address(stuck)), 0, "reserve released only by the payout");
    }

    // --- 10. reentrancy ----------------------------------------------------

    function test_aReentrantTokenClaimIsRejectedByTheGuard() public {
        ReenteringERC20 evil = new ReenteringERC20();
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _buy(fleet, address(evil));
        _split(address(evil), 5e18);

        evil.arm(rewards, _ids(k2));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        rewards.claim(_ids(k1), _assets(address(evil)));
        assertEq(rewards.backed(address(evil)), 10e18, "reserve intact");
        assertEq(rewards.accrued(address(evil), k1), 5e18, "alice's key untouched");
        assertEq(rewards.accrued(address(evil), k2), 5e18, "the token's own key untouched");
    }

    function test_aReentrantEthHolderIsRejectedByTheGuard() public {
        address reclaimer = address(new EthReclaimer(rewards));
        uint256 k1 = _buy(fleet, reclaimer);
        _split(NATIVE, 1 ether);

        vm.prank(reclaimer);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        rewards.claim(_ids(k1), _assets(NATIVE));
        assertEq(address(rewards).balance, 1 ether, "nothing left the contract");
        assertEq(rewards.backed(NATIVE), 1 ether);
    }

    // --- 11. fractional carry in the cohort lane --------------------------

    function test_fractionalCarryKeepsLifetimeDustUnderOneUnitPerKey() public {
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _buy(fleet, bob);
        _buy(fleet, carol);

        for (uint256 i = 0; i < 12; ++i) {
            _fundAndAllocate(0, 100); // atomic units, deliberately indivisible by three
            vm.prank(address(fleet));
            rewards.settleKey(k1, alice); // settle every round: the carry must not compound
        }

        uint256 paidToAlice = _claim(alice, _ids(k1), address(usdc));
        assertEq(paidToAlice, 399, "twelve settlements lose less than a unit in total, not one per round");
        uint256 paidToBob = _claim(bob, _ids(k2), address(usdc)); // never settled mid-sequence
        assertLe(paidToBob - paidToAlice, 1, "settling often costs no more than settling once");
    }

    // --- 12. fuzz: the ledger always holds what it owes ---------------------

    /// @dev On Cascade, where a key's cohort is its level and completing a level repays the level
    /// before it through the ledger, so purchases themselves allocate as well as the steps below.
    function testFuzz_balanceAlwaysCoversBackedAndCredits(uint256 seed) public {
        _use(_deploy(KeyfleetPresets.Preset.FibonacciCascade));
        address[3] memory holders = [alice, bob, carol];
        for (uint256 i = 0; i < 3; ++i) {
            _buy(fleet, holders[i]);
        }

        for (uint256 step = 0; step < 16; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = seed % 6;
            address holder = holders[(seed >> 8) % 3];
            uint256 tokenId = _key(fleet, ((seed >> 16) % fleet.totalMinted()) + 1);
            uint256 cohortId = ((seed >> 24) % 3) + 1;
            uint256 amount = ((seed >> 32) % 1e18) + 1;

            if (action == 0) {
                _buy(fleet, holder);
            } else if (action == 1) {
                usdc.mint(address(rewards), amount);
                vm.prank(address(fleet));
                try rewards.allocateToCohort(address(usdc), cohortId, amount) {} catch {}
            } else if (action == 2) {
                usdc.mint(address(rewards), amount);
                vm.prank(address(fleet));
                rewards.credit(address(usdc), holder, amount);
            } else if (action == 3) {
                _split((seed >> 40) % 2 == 0 ? address(usdc) : NATIVE, amount % 1e12 + 1);
            } else if (action == 4) {
                address keyOwner = keys.ownerOf(tokenId);
                if (keyOwner != holder) {
                    vm.prank(keyOwner);
                    keys.transferFrom(keyOwner, holder, tokenId);
                }
            } else {
                vm.prank(keys.ownerOf(tokenId));
                try rewards.claim(_ids(tokenId), _assets(address(usdc), NATIVE)) {} catch {}
            }

            _assertBacked(address(usdc), usdc.balanceOf(address(rewards)), holders);
            _assertBacked(NATIVE, address(rewards).balance, holders);
        }
    }

    function _assertBacked(address asset, uint256 balance, address[3] memory holders) private view {
        uint256 reserved = rewards.backed(asset);
        assertGe(balance, reserved, "balance always covers the reserve");
        uint256 outstanding;
        for (uint256 i = 0; i < 3; ++i) {
            outstanding += rewards.credits(asset, holders[i]);
        }
        for (uint256 n = 1; n <= fleet.totalMinted(); ++n) {
            outstanding += rewards.accrued(asset, _key(fleet, n));
        }
        assertGe(reserved, outstanding, "reserve covers credits plus unsettled accruals");
    }

    // --- 13. one fleet's ledger never takes another fleet's key -------------

    /// @dev Every pair of the four founding fleets and an open fleet of each type: a key of another
    /// fleet is refused before the ledger asks who holds it. The key's own holder is refused, a
    /// wallet holding an active shard of it is refused, a key of that fleet never minted is refused
    /// with the same error rather than as a missing token, and a claim naming one of its own keys
    /// as well settles nothing.
    function test_claimRefusesAKeyOfEveryOtherFleetBeforeAnyOwnershipCheck() public {
        KeyfleetPresets.Preset[4] memory presets = [
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FleetTechAccelerant,
            KeyfleetPresets.Preset.FibonacciCascade
        ];
        KeyfleetManager[8] memory fleets;
        for (uint256 i = 0; i < 4; ++i) {
            fleets[i] = _deploy(presets[i]);
            _buy(fleets[i], _wallet(100 + i));
        }
        for (uint256 i = 0; i < 4; ++i) {
            fleets[4 + i] = _createOpen(presets[i], 10e6);
        }
        for (uint256 i = 0; i < 8; ++i) {
            uint256 own = _key(fleets[i], 1);
            vm.prank(keys.ownerOf(own));
            shards.issue(_ids(own), agent, 30);
        }

        for (uint256 i = 0; i < 8; ++i) {
            KeyfleetRewards ledger = fleets[i].REWARDS();
            uint256 own = _key(fleets[i], 1);
            address ownHolder = keys.ownerOf(own);
            for (uint256 j = 0; j < 8; ++j) {
                if (j == i) continue;
                uint256 foreign = _key(fleets[j], 1);
                bytes memory refused = abi.encodeWithSelector(KeyfleetRewards.ForeignKey.selector, foreign);

                vm.prank(keys.ownerOf(foreign));
                vm.expectRevert(refused);
                ledger.claim(_ids(foreign), _assets(address(usdc)));

                vm.prank(agent);
                vm.expectRevert(refused);
                ledger.claim(_ids(foreign), _assets(address(usdc)));

                uint256 unminted = _key(fleets[j], 999);
                vm.prank(ownHolder);
                vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.ForeignKey.selector, unminted));
                ledger.claim(_ids(unminted), _assets(address(usdc)));

                vm.prank(ownHolder);
                vm.expectRevert(refused);
                ledger.claim(_pair(own, foreign), _assets(address(usdc)));
            }

            uint256 unknownFleet = keys.tokenIdOf(77, 1);
            vm.prank(ownHolder);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.ForeignKey.selector, unknownFleet));
            ledger.claim(_ids(unknownFleet), _assets(address(usdc)));
        }
    }

    // --- 14. two fleets' ledgers are fully separate --------------------------

    /// @dev Two fleets of one type, whose keys share key numbers and cohort 0: what one ledger
    /// credits, allocates, enrolls, splits and holds never shows up in the other, and neither
    /// fleet's manager or treasury can write the other's.
    function test_theLedgersOfTwoFleetsAreFullySeparate() public {
        KeyfleetManager fleetA = fleet;
        KeyfleetRewards ledgerA = rewards;
        KeyfleetTreasury treasuryA = treasury;
        uint256 a1 = _buy(fleetA, alice);
        uint256 a2 = _buy(fleetA, bob);

        KeyfleetManager fleetB = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        KeyfleetRewards ledgerB = fleetB.REWARDS();
        KeyfleetTreasury treasuryB = fleetB.TREASURY();
        uint256 b2 = _buy(fleetB, alice);
        assertTrue(address(ledgerA) != address(ledgerB), "each fleet has its own ledger");
        assertEq(keys.keyNumberOf(a1), keys.keyNumberOf(_key(fleetB, 1)), "the keys share numbers");
        assertEq(ledgerA.cohortSize(0), 2, "fleet A enrolled its two keys");
        assertEq(ledgerB.cohortSize(0), 2, "fleet B its creator's key and alice's");

        // Fleet A's manager allocates and credits; fleet B sees none of it.
        _fundAndAllocate(0, 30e6);
        usdc.mint(address(ledgerA), 5e6);
        vm.prank(address(fleetA));
        ledgerA.credit(address(usdc), alice, 5e6);
        assertEq(ledgerA.accrued(address(usdc), a1), 15e6);
        assertEq(ledgerB.cohortIndex(address(usdc), 0), 0, "fleet B's cohort 0 never moved");
        assertEq(ledgerB.accrued(address(usdc), b2), 0, "alice's fleet B key earned nothing");
        assertEq(ledgerB.credits(address(usdc), alice), 0, "and alice has no fleet B credit");
        assertEq(ledgerB.backed(address(usdc)), 0, "fleet B reserves nothing");

        // Fleet A's split reaches only fleet A's keys.
        _split(address(regent), 1e18);
        _split(NATIVE, 1 ether);
        assertEq(ledgerA.accrued(address(regent), a2), 1e18);
        assertEq(ledgerB.splitIndex(address(regent)), 0);
        assertEq(ledgerB.splitIndex(NATIVE), 0);
        assertEq(ledgerB.rewardAssets().length, 1, "fleet B pays only USDC still");

        // Tokens sent to fleet A's ledger never back fleet B's.
        vm.prank(address(fleetB));
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        ledgerB.allocateToCohort(address(usdc), 0, 1);

        // Neither fleet's manager nor treasury writes the other's ledger, and one treasury's split
        // flag does not open the other's.
        _setSplitting(treasuryA, true);
        regent.mint(address(ledgerB), 2e18);
        uint256 b3 = _key(fleetB, 3);
        vm.startPrank(address(fleetA));
        vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
        ledgerB.enrollKey(b3, 0);
        vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
        ledgerB.credit(address(usdc), alice, 1);
        vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
        ledgerB.settleKey(b2, alice);
        vm.stopPrank();
        vm.prank(address(treasuryA));
        vm.expectRevert(KeyfleetRewards.OnlyTreasury.selector);
        ledgerB.fundSplit(address(regent), 1e18, 2);
        vm.prank(address(treasuryB));
        vm.expectRevert(KeyfleetRewards.NotSplitting.selector);
        ledgerB.fundSplit(address(regent), 1e18, 2);
        _setSplitting(treasuryA, false);
        vm.prank(address(fleetB));
        vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
        ledgerA.credit(address(usdc), alice, 1);

        // Alice holds a key in both; each ledger pays her only its own.
        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        ledgerB.claim(_ids(b2), _assets(address(usdc), address(regent)));
        vm.prank(alice);
        uint256[] memory paid = ledgerA.claim(_ids(a1), _assets(address(usdc), address(regent)));
        assertEq(paid[0], 20e6, "her allocation share and her credit");
        assertEq(paid[1], 1e18, "her split");
        assertEq(ledgerB.backed(address(usdc)), 0);
    }

    /// @dev A real Accelerant rebate is credited in the Accelerant fleet's own ledger and nowhere
    /// else.
    function test_aRebateIsCreditedOnlyInItsOwnFleetsLedger() public {
        KeyfleetManager classic = fleet;
        KeyfleetManager accelerant = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        _buy(accelerant, alice);
        _buy(classic, alice);
        _buy(accelerant, bob); // pays alice a rebate for holding the preceding key

        uint256 rebate = accelerant.REWARDS().credits(address(usdc), alice);
        assertGt(rebate, 0, "the rebate is credited in the Accelerant ledger");
        assertEq(classic.REWARDS().credits(address(usdc), alice), 0, "and not in the Classic ledger");
        assertEq(classic.REWARDS().backed(address(usdc)), 0);
        assertEq(accelerant.REWARDS().backed(address(usdc)), rebate);
    }
}
