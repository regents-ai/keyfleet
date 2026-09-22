// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";

/// @dev Ownership oracle only. The real fleet is outside this slice; the test drives ownerOf
/// directly so that ownership changes can be sequenced around settlement.
contract MockFleet {
    mapping(uint256 tokenId => address owner) private _owners;

    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token whose outgoing transfers can be switched off, standing in for a pausable or
/// blocklisting reward token.
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
            _rewards.claim(address(this), new uint256[](0), address(0));
        }
        return super.transfer(to, amount);
    }
}

contract KeyfleetRewardsTest is Test {
    uint256 private constant PRECISION = 1e27;

    MockFleet private fleet;
    KeyfleetRewards private rewards;
    MockERC20 private usdc;
    MockERC20 private other;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCAC01);
    address private payout = address(0xDECAF);

    event AssetRegistered(address indexed asset);
    event KeyEnrolled(uint256 indexed tokenId, uint256 indexed cohortId);
    event Allocated(address indexed asset, uint256 indexed cohortId, uint256 amount, uint256 newIndex);
    event Credited(address indexed asset, address indexed account, uint256 amount);
    event Settled(uint256 indexed tokenId, address indexed asset, address indexed owner, uint256 amount);
    event Claimed(address indexed asset, address indexed account, address indexed to, uint256 amount);

    function setUp() public {
        fleet = new MockFleet();
        rewards = new KeyfleetRewards(address(fleet));
        usdc = new MockERC20("USD Coin", "USDC");
        other = new MockERC20("Other", "OTH");
        vm.startPrank(address(fleet));
        rewards.registerAsset(address(usdc));
        rewards.registerAsset(address(other));
        vm.stopPrank();
    }

    // --- helpers ---------------------------------------------------------

    function _enroll(uint256 tokenId, uint256 cohortId, address owner) private {
        fleet.setOwner(tokenId, owner);
        vm.prank(address(fleet));
        rewards.enrollKey(tokenId, cohortId);
    }

    function _fundAndAllocate(MockERC20 token, uint256 cohortId, uint256 amount) private {
        token.mint(address(rewards), amount);
        vm.prank(address(fleet));
        rewards.allocateToCohort(address(token), cohortId, amount);
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

    // --- 1. only the fleet writes ----------------------------------------

    function test_constructorBindsFleetAndRejectsZero() public {
        assertEq(rewards.FLEET(), address(fleet), "fleet binding is permanent");
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        new KeyfleetRewards(address(0));
    }

    function test_publishedBoundsAndIndexScaleAreFixed() public view {
        assertEq(rewards.MAX_REWARD_ASSETS(), 8, "lifetime reward asset bound");
        assertEq(rewards.MAX_COHORTS(), 32, "cohort id space");
        assertEq(rewards.PRECISION(), PRECISION, "index scale integrators read is 1e27");
    }

    function testFuzz_onlyFleetCanRegisterEnrollAllocateCreditAndSettle(address caller) public {
        vm.assume(caller != address(fleet) && caller != address(vm));
        _enroll(1, 0, alice);

        vm.startPrank(caller);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.registerAsset(address(0xFEED));
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.enrollKey(2, 0);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.allocateToCohort(address(usdc), 0, 1);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.credit(address(usdc), caller, 1);
        vm.expectRevert(KeyfleetRewards.OnlyFleet.selector);
        rewards.settleKey(1, caller);
        vm.stopPrank();

        assertEq(rewards.rewardAssets().length, 2, "no asset added by a stranger");
        assertEq(rewards.cohortSize(0), 1, "no key enrolled by a stranger");
        assertEq(rewards.cohortIndex(address(usdc), 0), 0, "no allocation by a stranger");
        assertEq(rewards.credits(address(usdc), caller), 0, "no credit by a stranger");
    }

    // --- 2. append-only, bounded asset list -------------------------------

    function test_assetListIsAppendOnlyBoundedAtEightAndInInsertionOrder() public {
        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.ZeroAddress.selector);
        rewards.registerAsset(address(0));
        vm.expectRevert(KeyfleetRewards.AssetAlreadyRegistered.selector);
        rewards.registerAsset(address(usdc));

        address[] memory expected = new address[](8);
        expected[0] = address(usdc);
        expected[1] = address(other);
        for (uint256 i = 2; i < 8; ++i) {
            expected[i] = address(uint160(0x1000) + uint160(i));
            rewards.registerAsset(expected[i]);
        }

        vm.expectRevert(KeyfleetRewards.AssetBoundReached.selector);
        rewards.registerAsset(address(0x9999));
        vm.expectRevert(KeyfleetRewards.AssetAlreadyRegistered.selector);
        rewards.registerAsset(address(usdc));
        vm.stopPrank();

        address[] memory listed = rewards.rewardAssets();
        assertEq(listed.length, rewards.MAX_REWARD_ASSETS(), "list stops at the bound");
        for (uint256 i = 0; i < 8; ++i) {
            assertEq(listed[i], expected[i], "insertion order preserved");
            assertTrue(rewards.isRewardAsset(expected[i]), "registered");
        }
        assertFalse(rewards.isRewardAsset(address(0x9999)), "the rejected ninth asset was not recorded");
    }

    // --- 3. allocation math and retained dust -----------------------------

    function test_threeKeyAllocationPaysFloorSharesAndCarriesTheRemainder() public {
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        _enroll(3, 0, carol);

        uint256 amount = 10e18;
        _fundAndAllocate(usdc, 0, amount);

        uint256 share = amount / 3;
        assertEq(rewards.backed(address(usdc)), amount, "the whole allocation is reserved, dust included");
        assertEq(rewards.accrued(address(usdc), 1), share, "floor share per key");

        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _ids(1), address(0)), share, "alice floor share");
        vm.prank(bob);
        assertEq(rewards.claim(address(usdc), _ids(2), address(0)), share, "bob floor share");
        vm.prank(carol);
        assertEq(rewards.claim(address(usdc), _ids(3), address(0)), share, "carol floor share");

        uint256 dust = amount - 3 * share;
        assertEq(dust, 1, "the remainder of 10e18 over three keys is one atomic unit");
        assertEq(usdc.balanceOf(address(rewards)), dust, "the remainder stays in the contract for now");
        assertEq(rewards.backed(address(usdc)), dust, "the remainder is still counted as backed, never free");

        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(address(usdc), _ids(1), address(0));
        vm.prank(carol);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(address(usdc), _ids(3), address(0));
    }

    // --- 4. eligibility and backing ---------------------------------------

    function test_allocationRequiresEligibleKeysAndTokensAlreadyPresent() public {
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.NoEligibleKeys.selector);
        rewards.allocateToCohort(address(usdc), 0, 1e18);

        _enroll(1, 0, alice);

        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.allocateToCohort(address(usdc), 0, 1e18);

        usdc.mint(address(rewards), 1e18 - 1);
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.allocateToCohort(address(usdc), 0, 1e18);

        usdc.mint(address(rewards), 1);
        vm.prank(address(fleet));
        rewards.allocateToCohort(address(usdc), 0, 1e18);
        assertEq(rewards.backed(address(usdc)), 1e18, "funded allocation reserves the amount");

        // A second allocation must be backed on top of the first, not against the same balance.
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.InsufficientBacking.selector);
        rewards.allocateToCohort(address(usdc), 0, 1);

        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.ZeroAmount.selector);
        rewards.allocateToCohort(address(usdc), 0, 0);
        vm.expectRevert(KeyfleetRewards.UnknownAsset.selector);
        rewards.allocateToCohort(address(0xBEEF), 0, 1);
        vm.expectRevert(KeyfleetRewards.CohortOutOfBounds.selector);
        rewards.allocateToCohort(address(usdc), 32, 1);
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
        vm.expectRevert(KeyfleetRewards.UnknownAsset.selector);
        rewards.credit(address(0xBEEF), bob, 1);
        vm.stopPrank();

        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _none(), address(0)), 5e18, "direct credit is claimable");
    }

    // --- 5. accrual belongs to the earning address ------------------------

    function test_accruedRewardsNeverTravelWithTheKey() public {
        _enroll(1, 0, alice);

        _fundAndAllocate(usdc, 0, 100e18); // allocation A, alice holds the key

        vm.prank(address(fleet));
        rewards.settleKey(1, alice);
        fleet.setOwner(1, bob);

        _fundAndAllocate(usdc, 0, 50e18); // allocation B, bob holds the key

        // Alice owns no key at all and still claims exactly A.
        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _none(), address(0)), 100e18, "alice keeps allocation A");
        assertEq(usdc.balanceOf(alice), 100e18, "alice paid A");

        vm.prank(bob);
        assertEq(rewards.claim(address(usdc), _ids(1), address(0)), 50e18, "bob earns only allocation B");
        assertEq(usdc.balanceOf(bob), 50e18, "bob paid B");

        // The key returns to alice. She must not re-earn A or B.
        vm.prank(address(fleet));
        rewards.settleKey(1, bob);
        fleet.setOwner(1, alice);
        _fundAndAllocate(usdc, 0, 25e18); // allocation C

        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _ids(1), address(0)), 25e18, "alice earns only C on her return");
        assertEq(usdc.balanceOf(alice), 125e18, "no double counting across re-acquisition");
        assertEq(usdc.balanceOf(bob), 50e18, "bob unchanged");
        assertEq(rewards.backed(address(usdc)), 0, "everything allocated was paid out, divides evenly");
    }

    function test_settlementBeforeTransferIsWhatProtectsTheOldOwner() public {
        _enroll(1, 0, alice);
        _fundAndAllocate(usdc, 0, 30e18);

        vm.prank(address(fleet));
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Settled(1, address(usdc), alice, 30e18);
        rewards.settleKey(1, alice);

        assertEq(rewards.credits(address(usdc), alice), 30e18, "settled to the old owner");
        assertEq(rewards.accrued(address(usdc), 1), 0, "key carries nothing forward after settlement");

        fleet.setOwner(1, bob);
        vm.prank(bob);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(address(usdc), _ids(1), address(0));
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

    function test_enrollmentIsPermanentAndBoundedToThirtyTwoCohorts() public {
        _enroll(1, 0, alice);
        vm.startPrank(address(fleet));
        vm.expectRevert(KeyfleetRewards.KeyAlreadyEnrolled.selector);
        rewards.enrollKey(1, 0);
        vm.expectRevert(KeyfleetRewards.KeyAlreadyEnrolled.selector);
        rewards.enrollKey(1, 5);
        vm.expectRevert(KeyfleetRewards.CohortOutOfBounds.selector);
        rewards.enrollKey(2, 32);
        rewards.enrollKey(2, 31);
        vm.stopPrank();
        assertEq(rewards.keyCohort(2), 31, "last cohort id is usable");
        assertEq(rewards.cohortSize(0), 1, "one key in cohort 0");
        assertEq(rewards.cohortSize(31), 1, "one key in cohort 31");
    }

    // --- 6. late enrollment earns nothing from earlier allocations --------

    function test_keyEnrolledAfterAnAllocationEarnsOnlyLaterOnes() public {
        _enroll(1, 0, alice);
        _fundAndAllocate(usdc, 0, 90e18);

        _enroll(2, 0, bob); // joins after allocation A
        assertEq(rewards.accrued(address(usdc), 2), 0, "the newcomer inherits nothing");
        assertEq(rewards.accrued(address(usdc), 1), 90e18, "the incumbent keeps all of A");

        _fundAndAllocate(usdc, 0, 40e18); // allocation B is split two ways

        assertEq(rewards.accrued(address(usdc), 2), 20e18, "newcomer earns half of B only");
        assertEq(rewards.accrued(address(usdc), 1), 110e18, "incumbent earns A plus half of B");

        // A cohort with no keys cannot receive an allocation at all, so a first key in a fresh
        // cohort can only ever earn from allocations made after it joined.
        vm.prank(address(fleet));
        vm.expectRevert(KeyfleetRewards.NoEligibleKeys.selector);
        rewards.allocateToCohort(address(usdc), 7, 1e18);
        _enroll(3, 7, carol);
        assertEq(rewards.accrued(address(usdc), 3), 0, "fresh cohort starts empty");
        _fundAndAllocate(usdc, 7, 1e18);
        assertEq(rewards.accrued(address(usdc), 3), 1e18, "and earns from the first allocation it can receive");
    }

    // --- 7. cohort isolation ----------------------------------------------

    function test_settlementTouchesOnlyTheKeysOwnCohort() public {
        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            _enroll(cohortId + 1, cohortId, alice);
        }
        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            _fundAndAllocate(usdc, cohortId, (cohortId + 1) * 1e18);
        }

        // Key 5 lives in cohort 4 and has accrued exactly that cohort's allocation.
        assertEq(rewards.keyCohort(5), 4, "key 5 is in cohort 4");
        assertEq(rewards.accrued(address(usdc), 5), 5e18, "only its own cohort's allocation");

        vm.prank(address(fleet));
        rewards.settleKey(5, alice);
        assertEq(rewards.credits(address(usdc), alice), 5e18, "one cohort settled, nineteen untouched");

        for (uint256 cohortId = 0; cohortId < 20; ++cohortId) {
            uint256 tokenId = cohortId + 1;
            uint256 expected = tokenId == 5 ? 0 : (cohortId + 1) * 1e18;
            assertEq(rewards.accrued(address(usdc), tokenId), expected, "other cohorts unaffected");
            assertEq(rewards.cohortIndex(address(usdc), cohortId), (cohortId + 1) * 1e18 * PRECISION, "index intact");
        }
    }

    // --- 8. worst-case settlement gas -------------------------------------

    /// @dev Worst case: all 8 reward assets registered, every one with a pending accrual, and
    /// every per-key slot cold and moving from zero. Measured 369,212 gas; the ceiling below is
    /// that plus 20% (443,000) and is the number the deployment manifest quotes.
    function test_worstCaseSettlementGasWithEightAssetsStaysUnderCeiling() public {
        MockERC20[] memory assets = new MockERC20[](8);
        assets[0] = usdc;
        assets[1] = other;
        vm.startPrank(address(fleet));
        for (uint256 i = 2; i < 8; ++i) {
            assets[i] = new MockERC20("Reward", "RWD");
            rewards.registerAsset(address(assets[i]));
        }
        vm.stopPrank();

        _enroll(1, 3, alice);
        for (uint256 i = 0; i < 8; ++i) {
            _fundAndAllocate(assets[i], 3, (i + 1) * 1e18);
        }

        vm.prank(address(fleet));
        uint256 before = gasleft();
        rewards.settleKey(1, alice);
        uint256 used = before - gasleft();
        console2.log("worst-case settleKey gas (8 assets, cold slots):", used);

        assertLt(used, 443_000, "worst-case settlement stays under the quoted ceiling");
        for (uint256 i = 0; i < 8; ++i) {
            assertEq(rewards.credits(address(assets[i]), alice), (i + 1) * 1e18, "every asset settled");
        }
    }

    // --- 9. claim semantics ------------------------------------------------

    function test_claimRejectsKeysTheCallerDoesNotOwn() public {
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        _fundAndAllocate(usdc, 0, 10e18);

        vm.prank(bob);
        vm.expectRevert(KeyfleetRewards.NotKeyOwner.selector);
        rewards.claim(address(usdc), _ids(1, 2), address(0));

        vm.expectRevert(KeyfleetRewards.NotKeyOwner.selector);
        rewards.claimable(address(usdc), bob, _ids(1));

        assertEq(rewards.credits(address(usdc), bob), 0, "no partial settlement survives the revert");
        assertEq(rewards.accrued(address(usdc), 1), 5e18, "alice's key untouched");

        fleet.setOwner(99, alice);
        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.KeyNotEnrolled.selector);
        rewards.claim(address(usdc), _ids(1, 99), address(0));
        vm.expectRevert(KeyfleetRewards.KeyNotEnrolled.selector);
        rewards.claimable(address(usdc), alice, _ids(99));
        assertEq(rewards.credits(address(usdc), alice), 0, "an owned but unenrolled key rolls the whole claim back");
    }

    function test_claimPaysTheCallerOrTheRecipientItNames() public {
        _enroll(1, 0, alice);
        _fundAndAllocate(usdc, 0, 10e18);

        usdc.mint(address(rewards), 1e18);
        vm.prank(address(fleet));
        rewards.credit(address(usdc), alice, 1e18);
        assertEq(
            rewards.claimable(address(usdc), alice, _ids(1)), 11e18, "claimable adds direct credits to key accruals"
        );
        assertEq(
            rewards.claimable(address(usdc), alice, _none()), 1e18, "with no keys the view is the credit balance alone"
        );
        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _none(), address(0)), 1e18, "credits pay out without any key");
        assertEq(rewards.claimable(address(usdc), alice, _ids(1)), 10e18, "claimable matches what claim pays");

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Claimed(address(usdc), alice, payout, 10e18);
        assertEq(rewards.claim(address(usdc), _ids(1), payout), 10e18, "explicit recipient");
        assertEq(usdc.balanceOf(payout), 10e18, "named recipient paid");
        assertEq(usdc.balanceOf(alice), 1e18, "caller holds only the earlier credit, not the payout it sent elsewhere");

        _fundAndAllocate(usdc, 0, 4e18);
        assertEq(rewards.claimable(address(usdc), alice, _ids(1)), 4e18, "view tracks the second allocation");
        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _ids(1), address(0)), 4e18, "zero recipient means self");
        assertEq(usdc.balanceOf(alice), 5e18, "caller paid");

        assertEq(rewards.claimable(address(usdc), alice, _ids(1)), 0, "nothing left");
        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(address(usdc), _ids(1), address(0));

        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.UnknownAsset.selector);
        rewards.claim(address(0xBEEF), _none(), address(0));
    }

    function test_oneFailingTokenCannotBlockAnotherAssetsClaim() public {
        RevertingERC20 stuck = new RevertingERC20();
        vm.prank(address(fleet));
        rewards.registerAsset(address(stuck));

        _enroll(1, 0, alice);
        stuck.mint(address(rewards), 7e18);
        vm.prank(address(fleet));
        rewards.allocateToCohort(address(stuck), 0, 7e18);
        _fundAndAllocate(usdc, 0, 3e18);

        stuck.setTransfersFail(true);
        vm.prank(alice);
        vm.expectRevert(RevertingERC20.TransferDisabled.selector);
        rewards.claim(address(stuck), _ids(1), address(0));

        // The failed asset left nothing behind and did not block the healthy one.
        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _ids(1), address(0)), 3e18, "asset Y claims independently");
        assertEq(usdc.balanceOf(alice), 3e18, "paid in asset Y");

        assertEq(rewards.accrued(address(stuck), 1), 7e18, "the blocked credit is preserved untouched");
        assertEq(rewards.backed(address(stuck)), 7e18, "still fully reserved");

        stuck.setTransfersFail(false);
        vm.prank(alice);
        assertEq(rewards.claim(address(stuck), _ids(1), address(0)), 7e18, "claimable again once the token works");
        assertEq(stuck.balanceOf(alice), 7e18, "paid in asset X");
        assertEq(rewards.backed(address(stuck)), 0, "reserve released only by the payout");
    }

    function test_claimSettlesOnlyTheAssetItPays() public {
        _enroll(1, 0, alice);
        _fundAndAllocate(usdc, 0, 6e18);
        _fundAndAllocate(other, 0, 8e18);

        vm.prank(alice);
        assertEq(rewards.claim(address(usdc), _ids(1), address(0)), 6e18, "usdc paid");
        assertEq(rewards.accrued(address(usdc), 1), 0, "usdc settled");
        assertEq(rewards.accrued(address(other), 1), 8e18, "the other asset is untouched by that claim");
        assertEq(other.balanceOf(address(rewards)), 8e18, "and its tokens stay put");
    }

    // --- 10. reentrancy ----------------------------------------------------

    function test_reentrantClaimDuringTransferIsRejectedByTheGuard() public {
        ReenteringERC20 evil = new ReenteringERC20();
        vm.prank(address(fleet));
        rewards.registerAsset(address(evil));

        _enroll(1, 0, alice);
        evil.mint(address(rewards), 10e18);
        vm.startPrank(address(fleet));
        rewards.allocateToCohort(address(evil), 0, 6e18);
        rewards.credit(address(evil), address(evil), 4e18);
        vm.stopPrank();

        evil.setRewards(rewards);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rewards.claim(address(evil), _ids(1), address(0));

        assertEq(evil.balanceOf(address(rewards)), 10e18, "nothing left the contract");
        assertEq(rewards.backed(address(evil)), 10e18, "reserve intact");
    }

    // --- 11. fractional carry ---------------------------------------------

    function test_fractionalCarryKeepsLifetimeDustUnderOneUnitPerKey() public {
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        _enroll(3, 0, carol);

        uint256 rounds = 12;
        uint256 amount = 100; // atomic units, deliberately indivisible by three
        uint256 paidToAlice;

        for (uint256 i = 0; i < rounds; ++i) {
            _fundAndAllocate(usdc, 0, amount);
            vm.prank(address(fleet));
            rewards.settleKey(1, alice); // settle every round: the carry must not compound
        }

        vm.prank(alice);
        paidToAlice = rewards.claim(address(usdc), _ids(1), address(0));

        uint256 exact = (rounds * amount) / 3; // 400
        assertEq(exact, 400, "exact share over the whole sequence");
        assertLe(exact - paidToAlice, 1, "lifetime shortfall is at most one atomic unit");
        assertEq(paidToAlice, 399, "twelve settlements lose less than a unit in total, not one per round");

        // Without the carry, settling every round would have cost a third of a unit each time.
        vm.prank(bob);
        uint256 paidToBob = rewards.claim(address(usdc), _ids(2), address(0)); // never settled mid-sequence
        assertLe(paidToBob - paidToAlice, 1, "settling often costs no more than settling once");
    }

    function test_carryIsPerKeyAndPerAssetNotShared() public {
        _enroll(1, 0, alice);
        _enroll(2, 0, bob);
        _enroll(3, 0, carol);

        _fundAndAllocate(usdc, 0, 2); // 0.666.. per key
        _fundAndAllocate(other, 0, 2);
        assertEq(rewards.accrued(address(usdc), 1), 0, "a sub-unit accrual pays nothing yet");

        vm.prank(address(fleet));
        rewards.settleKey(1, alice);
        assertEq(rewards.credits(address(usdc), alice), 0, "nothing to settle below one unit");

        _fundAndAllocate(usdc, 0, 2); // now 1.333.. per key
        assertEq(rewards.accrued(address(usdc), 1), 1, "the carried fraction pushes it over one unit");
        assertEq(rewards.accrued(address(other), 1), 0, "the other asset carries its own fraction");
    }

    // --- 12. fuzz invariant -------------------------------------------------

    function testFuzz_balanceAlwaysCoversBackedAndCredits(uint256 seed) public {
        address[3] memory holders = [alice, bob, carol];
        for (uint256 i = 0; i < 3; ++i) {
            _enroll(i + 1, i % 2, holders[i]);
        }

        for (uint256 step = 0; step < 16; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = seed % 5;
            address holder = holders[(seed >> 8) % 3];
            uint256 tokenId = ((seed >> 16) % 3) + 1;
            uint256 cohortId = (seed >> 24) % 3;
            uint256 amount = ((seed >> 32) % 1e18) + 1;

            if (action == 0) {
                uint256 newId = 4 + step;
                fleet.setOwner(newId, holder);
                vm.prank(address(fleet));
                rewards.enrollKey(newId, cohortId);
            } else if (action == 1) {
                usdc.mint(address(rewards), amount);
                vm.prank(address(fleet));
                try rewards.allocateToCohort(address(usdc), cohortId, amount) {} catch {}
            } else if (action == 2) {
                usdc.mint(address(rewards), amount);
                vm.prank(address(fleet));
                rewards.credit(address(usdc), holder, amount);
            } else if (action == 3) {
                address keyOwner = fleet.ownerOf(tokenId);
                vm.prank(address(fleet));
                rewards.settleKey(tokenId, keyOwner);
            } else {
                address owner = fleet.ownerOf(tokenId);
                vm.prank(owner);
                try rewards.claim(address(usdc), _ids(tokenId), address(0)) {} catch {}
            }

            uint256 reserved = rewards.backed(address(usdc));
            assertGe(usdc.balanceOf(address(rewards)), reserved, "balance always covers the reserve");

            uint256 outstanding;
            for (uint256 i = 0; i < 3; ++i) {
                outstanding += rewards.credits(address(usdc), holders[i]);
            }
            for (uint256 id = 1; id <= 4 + step; ++id) {
                outstanding += _accruedOrZero(id);
            }
            assertGe(reserved, outstanding, "reserve covers credits plus unsettled accruals");
        }
    }

    function _accruedOrZero(uint256 tokenId) private view returns (uint256) {
        try rewards.accrued(address(usdc), tokenId) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }
}
