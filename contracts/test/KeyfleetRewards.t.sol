// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Keyfleet} from "../src/Keyfleet.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetShards} from "../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";

/// @dev Ownership and mint count only. The real fleet is outside this slice; the test drives
/// `ownerOf` and `totalMinted` directly so that ownership changes can be sequenced around
/// settlement.
contract MockFleet {
    mapping(uint256 tokenId => address owner) private _owners;
    uint256 public totalMinted;

    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function setTotalMinted(uint256 minted) external {
        totalMinted = minted;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}

/// @dev Which wallets hold an active shard of which key.
contract MockShards {
    mapping(uint256 tokenId => mapping(address wallet => bool active)) public isActive;

    function setActive(uint256 tokenId, address wallet, bool active) external {
        isActive[tokenId][wallet] = active;
    }
}

/// @dev Whether the treasury is inside its split routine; the test calls the ledger as it.
contract MockTreasury {
    bool public splitInProgress;

    function setSplitting(bool splitting) external {
        splitInProgress = splitting;
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token whose outgoing transfers can be switched off, standing in for a pausable or
/// blocklisting USDC.
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

/// @dev A token that calls back into the ledger during its own transfer, claiming the credit the
/// fleet granted to the token contract itself. Without the guard this second payout would settle.
contract ReenteringERC20 is ERC20 {
    KeyfleetRewards private _rewards;
    bool private _reentering;

    constructor() ERC20("Reentering", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRewards(KeyfleetRewards rewards) external {
        _rewards = rewards;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (address(_rewards) != address(0) && !_reentering) {
            _reentering = true;
            address[] memory assets = new address[](1);
            assets[0] = address(this);
            _rewards.claim(new uint256[](0), assets);
        }
        return super.transfer(to, amount);
    }
}

/// @dev A key holder that refuses ETH.
contract EthRefuser {}

/// @dev A key holder that tries to claim again while being paid ETH.
contract EthReclaimer {
    KeyfleetRewards private immutable _rewards;

    constructor(KeyfleetRewards rewards) {
        _rewards = rewards;
    }

    receive() external payable {
        address[] memory assets = new address[](1);
        _rewards.claim(new uint256[](0), assets);
    }
}

contract KeyfleetRewardsTest is Test {
    uint256 private constant PRECISION = 1e27;
    address private constant NATIVE = address(0);
    /// @dev The measured worst-case settlement, a cohort accrual and four split assets all cold,
    /// plus twenty percent, rounded up to the nearest thousand.
    uint256 private constant SETTLE_GAS_CEILING = 288_000;

    MockFleet private fleet;
    MockShards private shards;
    MockTreasury private treasury;
    KeyfleetRewards private rewards;
    MockERC20 private usdc;
    MockERC20 private regent;

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
        fleet = new MockFleet();
        shards = new MockShards();
        treasury = new MockTreasury();
        usdc = new MockERC20("USD Coin", "USDC");
        regent = new MockERC20("Regent", "REGENT");
        rewards = _ledger(address(usdc));
    }

    // --- helpers ---------------------------------------------------------

    function _ledger(address token) private returns (KeyfleetRewards) {
        return new KeyfleetRewards(
            Keyfleet(address(fleet)),
            token,
            KeyfleetTreasury(payable(address(treasury))),
            KeyfleetShards(address(shards))
        );
    }

    /// @dev Mints the next key to `owner` and enrolls it, as a purchase does.
    function _enroll(uint256 tokenId, uint256 cohortId, address owner) private {
        fleet.setOwner(tokenId, owner);
        fleet.setTotalMinted(tokenId);
        vm.prank(address(fleet));
        rewards.enrollKey(tokenId, cohortId);
    }

    function _fundAndAllocate(uint256 cohortId, uint256 amount) private {
        usdc.mint(address(rewards), amount);
        vm.prank(address(fleet));
        rewards.allocateToCohort(address(usdc), cohortId, amount);
    }

    /// @dev Funds a split of `perKey` per minted key, as the treasury's split routine does.
    function _split(address asset, uint256 perKey) private {
        uint256 keys = fleet.totalMinted();
        treasury.setSplitting(true);
        if (asset == NATIVE) {
            vm.deal(address(treasury), perKey * keys);
            vm.prank(address(treasury));
            rewards.fundSplitNative{value: perKey * keys}(perKey, keys);
        } else {
            MockERC20(asset).mint(address(rewards), perKey * keys);
            vm.prank(address(treasury));
            rewards.fundSplit(asset, perKey, keys);
        }
        treasury.setSplitting(false);
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

    function _ids(uint256 a) private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) private pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _none() private pure returns (uint256[] memory ids) {
        ids = new uint256[](0);
    }

    // --- 1. only the fleet writes, only the treasury's split funds ---------

    function test_constructorBindsEverythingAndRejectsZero() public {
        assertEq(address(rewards.FLEET()), address(fleet));
        assertEq(rewards.USDC(), address(usdc));
        assertEq(address(rewards.TREASURY()), address(treasury));
        assertEq(address(rewards.SHARDS()), address(shards));
        assertEq(rewards.PRECISION(), PRECISION, "cohort index scale is 1e27");

        Keyfleet f = Keyfleet(address(fleet));
        KeyfleetTreasury t = KeyfleetTreasury(payable(address(treasury)));
        KeyfleetShards s = KeyfleetShards(address(shards));
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        new KeyfleetRewards(Keyfleet(address(0)), address(usdc), t, s);
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        new KeyfleetRewards(f, address(0), t, s);
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        new KeyfleetRewards(f, address(usdc), KeyfleetTreasury(payable(address(0))), s);
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        new KeyfleetRewards(f, address(usdc), t, KeyfleetShards(address(0)));
    }

    function testFuzz_onlyFleetCanEnrollAllocateCreditAndSettle(address caller) public {
        vm.assume(caller != address(fleet) && caller != address(vm));
        _enroll(1, 0, alice);

        vm.startPrank(caller);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.enrollKey(2, 0);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.allocateToCohort(address(usdc), 0, 1);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.credit(address(usdc), caller, 1);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.settleKey(1, caller);
        vm.stopPrank();

        assertEq(rewards.cohortSize(0), 1, "no key enrolled by a stranger");
        assertEq(rewards.cohortIndex(address(usdc), 0), 0, "no allocation by a stranger");
        assertEq(rewards.credits(address(usdc), caller), 0, "no credit by a stranger");
    }

    function testFuzz_onlyTheTreasuryInsideItsSplitFundsTheSplit(address caller) public {
        vm.assume(caller != address(treasury) && caller != address(vm));
        _enroll(1, 0, alice);
        regent.mint(address(rewards), 1e18);
        vm.deal(caller, 1e18);
        vm.deal(address(treasury), 1e18);

        treasury.setSplitting(true);
        vm.startPrank(caller);
        vm.expectRevert(KeyfleetRewards.OnlyTreasury.selector);
        rewards.fundSplit(address(regent), 1e18, 1);
        vm.expectRevert(KeyfleetRewards.OnlyTreasury.selector);
        rewards.fundSplitNative{value: 1e18}(1e18, 1);
        vm.stopPrank();

        treasury.setSplitting(false);
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

    // --- 2. the cohort lane and direct credits take USDC only ---------------

    function test_theCohortLaneAndDirectCreditsTakeUsdcOnly() public {
        _enroll(1, 0, alice);
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
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        _enroll(3, 0, carol);

        uint256 amount = 10e18;
        _fundAndAllocate(0, amount);

        uint256 share = amount / 3;
        assertEq(rewards.backed(address(usdc)), amount, "the whole allocation is reserved, dust included");
        assertEq(rewards.accrued(address(usdc), 1), share, "floor share per key");

        assertEq(_claim(alice, _ids(1), address(usdc)), share, "alice floor share");
        assertEq(_claim(bob, _ids(2), address(usdc)), share, "bob floor share");
        assertEq(_claim(carol, _ids(3), address(usdc)), share, "carol floor share");

        uint256 dust = amount - 3 * share;
        assertEq(dust, 1, "the remainder of 10e18 over three keys is one atomic unit");
        assertEq(usdc.balanceOf(address(rewards)), dust, "the remainder stays in the contract");
        assertEq(rewards.backed(address(usdc)), dust, "the remainder is still counted as backed, never free");

        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(_ids(1), _assets(address(usdc)));
    }

    // --- 4. eligibility and backing ---------------------------------------

    function test_allocationRequiresEligibleKeysAndTokensAlreadyPresent() public {
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.NoEligibleKeys.selector);
        rewards.allocateToCohort(address(usdc), 0, 1e18);

        _enroll(1, 0, alice);

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

    function test_aSplitGivesEveryMintedKeyTheSameWholeAmount() public {
        _enroll(1, 0, alice);
        _enroll(2, 3, bob);
        _enroll(3, 7, carol);

        regent.mint(address(rewards), 15e18);
        treasury.setSplitting(true);
        vm.prank(address(treasury));
        vm.expectEmit(true, false, false, true, address(rewards));
        emit SplitFunded(address(regent), 5e18, 3, 5e18);
        rewards.fundSplit(address(regent), 5e18, 3);
        treasury.setSplitting(false);
        _split(NATIVE, 1 ether);

        for (uint256 tokenId = 1; tokenId <= 3; ++tokenId) {
            assertEq(rewards.accrued(address(regent), tokenId), 5e18, "every key, whatever its cohort");
            assertEq(rewards.accrued(NATIVE, tokenId), 1 ether);
        }
        assertEq(rewards.backed(address(regent)), 15e18, "the whole allocation is reserved");
        assertEq(rewards.backed(NATIVE), 3 ether);
        assertEq(address(rewards).balance, 3 ether);

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
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        treasury.setSplitting(true);
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
        _enroll(1, 0, alice);
        _split(address(regent), 9e18);
        _split(NATIVE, 1 ether);

        _enroll(2, 0, bob);
        assertEq(rewards.accrued(address(regent), 2), 0, "the newcomer inherits nothing");
        assertEq(rewards.accrued(NATIVE, 2), 0);
        assertEq(rewards.keySplitIndex(2, address(regent)), 9e18, "it starts from the current index");

        _split(address(regent), 1e18);
        _split(address(usdc), 3e6); // first split of USDC, after both keys
        assertEq(rewards.accrued(address(regent), 1), 10e18);
        assertEq(rewards.accrued(address(regent), 2), 1e18);
        assertEq(rewards.accrued(address(usdc), 1), 3e6, "an asset first split later is shared by every key");
        assertEq(rewards.accrued(address(usdc), 2), 3e6);
    }

    function test_settlementMovesEveryAssetToTheOutgoingOwner() public {
        _enroll(1, 0, alice);
        _fundAndAllocate(0, 4e6);
        _split(address(usdc), 1e6);
        _split(address(regent), 2e18);
        _split(NATIVE, 3 ether);

        vm.prank(address(fleet));
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(1, address(usdc), alice, 4e6);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(1, address(usdc), alice, 1e6);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(1, address(regent), alice, 2e18);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(1, NATIVE, alice, 3 ether);
        rewards.settleKey(1, alice);

        assertEq(rewards.credits(address(usdc), alice), 5e6, "the cohort and split lanes both");
        assertEq(rewards.credits(address(regent), alice), 2e18);
        assertEq(rewards.credits(NATIVE, alice), 3 ether);
        assertEq(rewards.accrued(address(usdc), 1), 0, "the key carries nothing forward");
        assertEq(rewards.accrued(address(regent), 1), 0);
        assertEq(rewards.accrued(NATIVE, 1), 0);
    }

    // --- 6. accrual belongs to the earning address ------------------------

    function test_accruedRewardsNeverTravelWithTheKey() public {
        _enroll(1, 0, alice);
        _fundAndAllocate(0, 100e18); // allocation A, alice holds the key
        _split(NATIVE, 1 ether);

        vm.prank(address(fleet));
        rewards.settleKey(1, alice);
        fleet.setOwner(1, bob);

        _fundAndAllocate(0, 50e18); // allocation B, bob holds the key
        _split(NATIVE, 2 ether);

        // Alice owns no key at all and still claims exactly what accrued under her.
        vm.prank(alice);
        uint256[] memory paid = rewards.claim(_none(), _assets(address(usdc), NATIVE));
        assertEq(paid[0], 100e18, "alice keeps allocation A");
        assertEq(paid[1], 1 ether, "and the first split");
        assertEq(alice.balance, 1 ether);

        vm.prank(bob);
        paid = rewards.claim(_ids(1), _assets(address(usdc), NATIVE));
        assertEq(paid[0], 50e18, "bob earns only allocation B");
        assertEq(paid[1], 2 ether, "and the second split");

        // The key returns to alice. She must not re-earn anything.
        vm.prank(address(fleet));
        rewards.settleKey(1, bob);
        fleet.setOwner(1, alice);
        _fundAndAllocate(0, 25e18);

        assertEq(_claim(alice, _ids(1), address(usdc)), 25e18, "alice earns only C on her return");
        assertEq(usdc.balanceOf(alice), 125e18, "no double counting across re-acquisition");
        assertEq(rewards.backed(address(usdc)), 0, "everything allocated was paid out");
        assertEq(rewards.backed(NATIVE), 0);
    }

    function test_settleKeyRejectsZeroOwnerAndUnenrolledKeys() public {
        _enroll(1, 0, alice);
        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        rewards.settleKey(1, address(0));
        vm.expectRevert(KeyfleetRewards.KeyNotEnrolled.selector);
        rewards.settleKey(99, alice);
        vm.stopPrank();

        vm.expectRevert(KeyfleetRewards.KeyNotEnrolled.selector);
        rewards.keyCohort(99);
        assertEq(rewards.keyCohort(1), 0, "enrolled key reports its cohort");
    }

    /// @dev Cohort ids are the fleet's levels, which have no last one, so the ledger takes any
    /// cohort id the fleet names.
    function test_enrollmentIsPermanentAndTakesAnyCohort() public {
        _enroll(1, 0, alice);
        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.KeyAlreadyEnrolled.selector);
        rewards.enrollKey(1, 0);
        vm.expectRevert(KeyfleetRewards.KeyAlreadyEnrolled.selector);
        rewards.enrollKey(1, 5);
        vm.stopPrank();
        _enroll(2, 41, bob);
        _enroll(3, 1_000, carol);
        assertEq(rewards.keyCohort(2), 41, "level 41 is a cohort like any other");
        assertEq(rewards.keyCohort(3), 1_000);
        assertEq(rewards.cohortSize(0), 1, "one key in cohort 0");
        assertEq(rewards.cohortSize(41), 1, "one key in cohort 41");

        _fundAndAllocate(41, 3e18);
        assertEq(rewards.accrued(address(usdc), 2), 3e18, "and earns like any other");
    }

    // --- 7. late cohort enrollment and cohort isolation ---------------------

    function test_keyEnrolledAfterAnAllocationEarnsOnlyLaterOnes() public {
        _enroll(1, 0, alice);
        _fundAndAllocate(0, 90e18);

        _enroll(2, 0, bob); // joins after allocation A
        assertEq(rewards.accrued(address(usdc), 2), 0, "the newcomer inherits nothing");

        _fundAndAllocate(0, 40e18); // allocation B is split two ways
        assertEq(rewards.accrued(address(usdc), 2), 20e18, "newcomer earns half of B only");
        assertEq(rewards.accrued(address(usdc), 1), 110e18, "incumbent earns A plus half of B");

        // A cohort with no keys cannot receive an allocation at all.
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.NoEligibleKeys.selector);
        rewards.allocateToCohort(address(usdc), 7, 1e18);
        _enroll(3, 7, carol);
        _fundAndAllocate(7, 1e18);
        assertEq(rewards.accrued(address(usdc), 3), 1e18, "and earns from the first allocation it can receive");
    }

    function test_settlementTouchesOnlyTheKeysOwnCohort() public {
        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            _enroll(cohortId + 1, cohortId, alice);
        }
        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            _fundAndAllocate(cohortId, (cohortId + 1) * 1e18);
        }

        vm.prank(address(fleet));
        rewards.settleKey(5, alice);
        assertEq(rewards.credits(address(usdc), alice), 5e18, "one cohort settled, nineteen untouched");

        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            uint256 tokenId = cohortId + 1;
            uint256 expected = tokenId == 5 ? 0 : (cohortId + 1) * 1e18;
            assertEq(rewards.accrued(address(usdc), tokenId), expected, "other cohorts unaffected");
        }
    }

    // --- 8. worst-case settlement gas -------------------------------------

    /// @dev Worst case: a pending cohort accrual in a high cohort and a pending split in four
    /// assets, every per-key slot cold and moving from zero.
    function test_worstCaseSettlementGasStaysUnderCeiling() public {
        MockERC20 ousd = new MockERC20("Origin Dollar", "OUSD");
        _enroll(1, 40, alice);
        _fundAndAllocate(40, 1e18);
        _split(NATIVE, 1 ether);
        _split(address(regent), 1e18);
        _split(address(usdc), 1e6);
        _split(address(ousd), 1e18);

        vm.cool(address(rewards));
        vm.prank(address(fleet));
        uint256 before = gasleft();
        rewards.settleKey(1, alice);
        uint256 used = before - gasleft();
        console2.log("worst-case settleKey gas, cohort plus four split assets (cold slots):", used);

        assertLt(used, SETTLE_GAS_CEILING, "worst-case settlement stays under the ceiling");
        assertEq(rewards.credits(address(ousd), alice), 1e18, "the last asset settled");
    }

    // --- 9. who may claim, and who is paid ----------------------------------

    function test_claimNeedsTheHolderOrAnActiveShardOfEveryKey() public {
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        _fundAndAllocate(0, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, 1));
        rewards.claim(_ids(2, 1), _assets(address(usdc)));
        assertEq(rewards.credits(address(usdc), bob), 0, "no partial settlement survives the revert");
        assertEq(rewards.accrued(address(usdc), 2), 5e18, "bob's key untouched");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, 1));
        rewards.claim(_ids(1), _assets(address(usdc)));

        shards.setActive(2, agent, true);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.NotKeyHolderOrAgent.selector, 1));
        rewards.claim(_ids(2, 1), _assets(address(usdc)));

        fleet.setOwner(99, alice);
        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.KeyNotEnrolled.selector);
        rewards.claim(_ids(1, 99), _assets(address(usdc)));
    }

    function test_anAgentsClaimPaysEachKeysHolderNeverTheAgent() public {
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        _enroll(3, 0, alice);
        _split(address(regent), 1e18);
        _split(NATIVE, 1 ether);
        shards.setActive(1, agent, true);
        shards.setActive(2, agent, true);
        shards.setActive(3, agent, true);

        vm.prank(agent);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Claimed(address(regent), alice, agent, 2e18);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Claimed(address(regent), bob, agent, 1e18);
        uint256[] memory paid = rewards.claim(_range3(), _assets(address(regent), NATIVE));

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
        _enroll(1, 0, alice);
        usdc.mint(address(rewards), 7e6);
        vm.prank(address(fleet));
        rewards.credit(address(usdc), agent, 7e6); // the agent once held a key
        _split(address(usdc), 1e6);
        shards.setActive(1, agent, true);

        vm.prank(agent);
        assertEq(rewards.claim(_ids(1), _assets(address(usdc)))[0], 8e6, "its own credit and alice's key");
        assertEq(usdc.balanceOf(agent), 7e6, "the agent's own credit goes to the agent");
        assertEq(usdc.balanceOf(alice), 1e6, "the key's money goes to its holder");
    }

    function test_unknownOrRepeatedAssetsPayNothingMore() public {
        _enroll(1, 0, alice);
        _split(address(regent), 1e18);

        vm.prank(alice);
        uint256[] memory paid = rewards.claim(_ids(1), _assets(address(regent), address(regent)));
        assertEq(paid[0], 1e18);
        assertEq(paid[1], 0, "a repeated asset finds nothing left");

        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(_ids(1), _assets(address(0xBEEF)));
    }

    /// @dev A wallet that refuses ETH stops only a claim that pays it ETH: the same claim without
    /// ETH pays it, and other holders' ETH is unaffected.
    function test_aWalletThatRefusesEthBlocksOnlyItsOwnEth() public {
        address refuser = address(new EthRefuser());
        _enroll(1, 0, refuser);
        _enroll(2, 0, bob);
        _split(NATIVE, 1 ether);
        _split(address(regent), 1e18);
        shards.setActive(1, agent, true);

        vm.prank(agent);
        vm.expectRevert();
        rewards.claim(_ids(1), _assets(NATIVE));
        assertEq(rewards.accrued(NATIVE, 1), 1 ether, "the ETH stays waiting for the key");

        vm.prank(agent);
        assertEq(rewards.claim(_ids(1), _assets(address(regent)))[0], 1e18, "the same key's REGENT goes through");
        assertEq(regent.balanceOf(refuser), 1e18);
        assertEq(rewards.credits(NATIVE, refuser), 1 ether, "its ETH is now its credit, still backed");
        assertEq(rewards.backed(NATIVE), 2 ether);

        assertEq(_claim(bob, _ids(2), NATIVE), 1 ether, "another holder's ETH is unaffected");
    }

    /// @dev A USDC that refuses a payout, as a paused or blocklisting USDC does, reverts the claim
    /// and leaves the accrual and its backing exactly as they were.
    function test_aRefusedPayoutLeavesTheCreditIntact() public {
        RevertingERC20 stuck = new RevertingERC20();
        rewards = _ledger(address(stuck));
        _enroll(1, 0, alice);
        stuck.mint(address(rewards), 7e18);
        vm.prank(address(fleet));
        rewards.allocateToCohort(address(stuck), 0, 7e18);

        stuck.setTransfersFail(true);
        vm.prank(alice);
        vm.expectRevert(RevertingERC20.TransferDisabled.selector);
        rewards.claim(_ids(1), _assets(address(stuck)));
        assertEq(rewards.accrued(address(stuck), 1), 7e18, "the accrual is preserved untouched");
        assertEq(rewards.backed(address(stuck)), 7e18, "still fully reserved");

        stuck.setTransfersFail(false);
        assertEq(_claim(alice, _ids(1), address(stuck)), 7e18, "claimable again once the token works");
        assertEq(rewards.backed(address(stuck)), 0, "reserve released only by the payout");
    }

    // --- 10. reentrancy ----------------------------------------------------

    function test_aReentrantTokenClaimIsRejectedByTheGuard() public {
        ReenteringERC20 evil = new ReenteringERC20();
        rewards = _ledger(address(evil));
        _enroll(1, 0, alice);
        evil.mint(address(rewards), 10e18);
        vm.startPrank(address(fleet));
        rewards.allocateToCohort(address(evil), 0, 6e18);
        rewards.credit(address(evil), address(evil), 4e18);
        vm.stopPrank();

        evil.setRewards(rewards);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        rewards.claim(_ids(1), _assets(address(evil)));
        assertEq(rewards.backed(address(evil)), 10e18, "reserve intact");
    }

    function test_aReentrantEthHolderIsRejectedByTheGuard() public {
        address reclaimer = address(new EthReclaimer(rewards));
        _enroll(1, 0, reclaimer);
        _split(NATIVE, 1 ether);

        vm.prank(reclaimer);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        rewards.claim(_ids(1), _assets(NATIVE));
        assertEq(address(rewards).balance, 1 ether, "nothing left the contract");
        assertEq(rewards.backed(NATIVE), 1 ether);
    }

    // --- 11. fractional carry in the cohort lane --------------------------

    function test_fractionalCarryKeepsLifetimeDustUnderOneUnitPerKey() public {
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        _enroll(3, 0, carol);

        for (uint256 i = 0; i < 12; ++i) {
            _fundAndAllocate(0, 100); // atomic units, deliberately indivisible by three
            vm.prank(address(fleet));
            rewards.settleKey(1, alice); // settle every round: the carry must not compound
        }

        uint256 paidToAlice = _claim(alice, _ids(1), address(usdc));
        assertEq(paidToAlice, 399, "twelve settlements lose less than a unit in total, not one per round");
        uint256 paidToBob = _claim(bob, _ids(2), address(usdc)); // never settled mid-sequence
        assertLe(paidToBob - paidToAlice, 1, "settling often costs no more than settling once");
    }

    // --- 12. fuzz: the ledger always holds what it owes ---------------------

    function testFuzz_balanceAlwaysCoversBackedAndCredits(uint256 seed) public {
        address[3] memory holders = [alice, bob, carol];
        for (uint256 i = 0; i < 3; ++i) {
            _enroll(i + 1, i % 2, holders[i]);
        }

        for (uint256 step = 0; step < 16; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = seed % 6;
            address holder = holders[(seed >> 8) % 3];
            uint256 tokenId = ((seed >> 16) % 3) + 1;
            uint256 cohortId = (seed >> 24) % 3;
            uint256 amount = ((seed >> 32) % 1e18) + 1;

            if (action == 0) {
                _enroll(fleet.totalMinted() + 1, cohortId, holder);
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
                address keyOwner = fleet.ownerOf(tokenId);
                vm.prank(address(fleet));
                rewards.settleKey(tokenId, keyOwner);
                fleet.setOwner(tokenId, holder);
            } else {
                vm.prank(fleet.ownerOf(tokenId));
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
        for (uint256 id = 1; id <= fleet.totalMinted(); ++id) {
            outstanding += rewards.accrued(asset, id);
        }
        assertGe(reserved, outstanding, "reserve covers credits plus unsettled accruals");
    }

    function _range3() private pure returns (uint256[] memory ids) {
        ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (1, 2, 3);
    }
}
