// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {KeyfleetClubClaims} from "../src/KeyfleetClubClaims.sol";
import {KeyfleetFactory} from "../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockContractWallet} from "./mocks/MockContractWallet.sol";

/// @dev A contract that cannot take an NFT sent with a safe transfer, as many Pass holders are.
contract NoReceiver {}

/// @dev A contract that takes NFTs but refuses ETH, as some Pass holders do.
contract EthRefuser is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev The Regents Club: the fifth founding fleet, one key per Regents Club Pass, given by the
/// Regents Safe and never sold, its cards dealt by number, and the claims contract that holds a
/// key for a Pass whose holder cannot take one until whoever holds that Pass claims it.
contract KeyfleetClubTest is KeyfleetFixture {
    KeyfleetManager private club;
    KeyfleetClubClaims private claims;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");

    event Given(uint256 indexed tokenId, address indexed receiver);
    event KeyClaimed(
        uint256 indexed passId,
        uint256 indexed tokenId,
        address indexed holder,
        address payee,
        address[] assets,
        uint256[] paid
    );

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        club = _deploy(KeyfleetPresets.Preset.RegentsClub);
        claims = factory.CLUB_CLAIMS();
    }

    function _give(address receiver) private {
        address[] memory receivers = new address[](1);
        receivers[0] = receiver;
        vm.prank(safe);
        club.give(receivers);
    }

    function _receivers(address a, address b, address c) private pure returns (address[] memory receivers) {
        receivers = new address[](3);
        (receivers[0], receivers[1], receivers[2]) = (a, b, c);
    }

    function _nonce() private view returns (uint64 nonce) {
        (, nonce) = vrf.consumerConfig(address(keys), vrfSubscription);
    }

    /// @dev Funds the Club treasury with ETH and REGENT above the split thresholds, waits until the
    /// keys given so far are mature and a split is due, and runs it.
    function _split() private {
        KeyfleetTreasury treasury = club.TREASURY();
        vm.deal(address(treasury), 1 ether);
        deal(address(regent), address(treasury), 1000e18);
        _joinSplit(club);
        uint256 due = treasury.nextRunAt();
        if (block.timestamp < due) vm.warp(due);
        treasury.runDailySplit();
    }

    // --- 1. the founding fleet ---------------------------------------------

    /// @dev Invariant: the Regents Club is the fifth founding fleet, bound to the Pass, with one
    /// card for each of its 1,998 keys, no price and no curve.
    function test_theClubIsTheFifthFoundingFleet() public view {
        assertEq(keys.FOUNDING_FLEETS(), 5);
        assertTrue(keys.foundingPreset(5) == KeyfleetPresets.Preset.RegentsClub, "the fifth founding type");
        assertEq(club.FLEET_ID(), 5);
        assertEq(claims.CLUB_FLEET(), 5, "the claims contract's fleet");
        assertEq(address(claims.KEYS()), address(keys));
        assertEq(address(claims.PASS()), address(clubPass));
        assertEq(address(factory.CLUB_PASS()), address(clubPass));
        assertEq(address(club.CLUB_PASS()), address(clubPass), "every fleet knows the Pass");
        assertEq(club.CLUB_CLAIMS(), address(claims), "and the claims contract");
        assertEq(club.maxSupply(), 1998);
        assertEq(club.START_PRICE(), 0, "no price");
        (, uint256 deckSize) = keys.deckOf(5);
        assertEq(deckSize, KeyfleetPresets.CLUB_SUPPLY, "one card per key");
    }

    /// @dev Invariant: no Regents Club key is ever sold.
    function test_theClubIsNeverSold() public {
        vm.expectRevert(KeyfleetManager.NotForSale.selector);
        club.nextPrice();
        vm.expectRevert(KeyfleetManager.NotForSale.selector);
        club.quote();
        usdc.mint(buyer, 1e30);
        vm.startPrank(buyer);
        usdc.approve(address(club), type(uint256).max);
        vm.expectRevert(KeyfleetManager.NotForSale.selector);
        club.purchase(buyer, type(uint256).max, block.timestamp, new bytes32[](0));
        vm.stopPrank();
        assertEq(club.totalMinted(), 0);
    }

    /// @dev Invariant: only the Safe's founding step makes a Regents Club; nobody creates another.
    function test_nobodyCreatesAnotherRegentsClub() public {
        _openCreation();
        KeyfleetManager.Requirements memory anyone;
        KeyfleetFactory.FleetTerms memory terms = _terms(KeyfleetPresets.Preset.RegentsClub, 10e6, anyone);
        usdc.mint(creator, 10e6);
        vm.startPrank(creator);
        usdc.approve(address(factory), 10e6);
        vm.expectRevert(KeyfleetFactory.RegentsClubIsFounding.selector);
        factory.createFleet(terms);
        vm.stopPrank();
    }

    // --- 2. gifts ----------------------------------------------------------

    /// @dev Invariant: the Safe gives key N to the holder of Pass N, in order, as a new key enrolled
    /// like any other, with no money moved and nothing drawn: key N holds card N.
    function test_theSafeGivesKeyNToTheHolderOfPassN() public {
        clubPass.mint(alice, 1);
        clubPass.mint(bob, 2);
        clubPass.mint(carol, 3);
        uint256 usdcBefore = usdc.totalSupply();
        uint64 nonceBefore = _nonce();

        for (uint256 n = 1; n <= 3; ++n) {
            vm.expectEmit(true, true, false, true, address(club));
            emit Given(keys.tokenIdOf(5, n), clubPass.ownerOf(n));
        }
        vm.prank(safe);
        club.give(_receivers(alice, bob, carol));

        assertEq(club.totalMinted(), 3);
        assertEq(club.firstMintAt(), block.timestamp, "the first gift starts the fleet's clock");
        for (uint256 n = 1; n <= 3; ++n) {
            uint256 tokenId = keys.tokenIdOf(5, n);
            assertEq(keys.ownerOf(tokenId), clubPass.ownerOf(n), "key N is Pass N's");
            assertEq(keys.ownershipEpoch(tokenId), 1);
            assertEq(keys.mintedAt(tokenId), block.timestamp);
            assertEq(club.VOTES().presentFrom(tokenId), block.timestamp + club.VOTES().KEY_MATURITY());
            assertTrue(keys.dealtByNumber(tokenId), "dealt by number");
            assertEq(keys.revealRequestedAt(tokenId), 0, "nothing drawn");
            vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.DealtByNumber.selector, tokenId));
            keys.requestReveal(tokenId);
        }
        assertEq(_nonce(), nonceBefore, "the coordinator was never asked");
        assertEq(usdc.totalSupply(), usdcBefore, "no USDC was minted for it");
        assertEq(usdc.balanceOf(address(club)), 0, "and none moved");
        assertEq(club.pendingConversion(), 0);
    }

    /// @dev Invariant: only the Regents Safe gives, and only on the Regents Club.
    function test_onlyTheSafeGivesAndOnlyClubKeys() public {
        clubPass.mint(alice, 1);
        address[4] memory strangers = [alice, keeper, creator, address(factory)];
        for (uint256 i = 0; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.OnlySafeGivesClubKeys.selector, strangers[i]));
            club.give(_receivers(alice, alice, alice));
        }
        for (uint256 id = 1; id <= 4; ++id) {
            KeyfleetManager other = KeyfleetManager(keys.managerOf(id));
            vm.prank(safe);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.OnlySafeGivesClubKeys.selector, safe));
            other.give(_receivers(alice, alice, alice));
        }
        assertEq(club.totalMinted(), 0);
    }

    /// @dev Invariant: key N goes only to whoever holds Pass N when the gift lands, or to the claims
    /// contract; a batch built from an older reading of the Pass reverts whole.
    function test_aGiftToAnyoneButThePassHolderIsRefused() public {
        clubPass.mint(alice, 1);
        clubPass.mint(bob, 2);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.NotPassHolder.selector, 1, bob));
        club.give(_receivers(bob, bob, bob));

        address[] memory stale = new address[](2);
        (stale[0], stale[1]) = (alice, bob);
        vm.prank(bob);
        clubPass.transferFrom(bob, carol, 2);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.NotPassHolder.selector, 2, bob));
        club.give(stale);
        assertEq(club.totalMinted(), 0, "the whole batch reverted");

        (stale[0], stale[1]) = (alice, carol);
        vm.prank(safe);
        club.give(stale);
        assertEq(keys.ownerOf(keys.tokenIdOf(5, 2)), carol, "the Pass's holder now");
    }

    /// @dev Invariant: a Pass burned or never minted holds up nothing: its key goes to the claims
    /// contract without the Pass being asked, and the keys after it are given as usual.
    function test_aMissingPassHoldsUpNoLaterKey() public {
        clubPass.mint(alice, 1);
        clubPass.burn(1);
        clubPass.mint(carol, 3);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        club.give(_receivers(alice, alice, carol));

        vm.prank(safe);
        club.give(_receivers(address(claims), address(claims), carol));
        assertEq(keys.ownerOf(keys.tokenIdOf(5, 1)), address(claims), "the burned Pass's key is held");
        assertEq(keys.ownerOf(keys.tokenIdOf(5, 2)), address(claims), "and the unminted Pass's");
        assertEq(keys.ownerOf(keys.tokenIdOf(5, 3)), carol, "the next key reaches its Pass");
    }

    /// @dev Invariant: gifts open with Classic #1, at the second phase 1 names, and not before.
    function test_giftsOpenWithClassicOne() public {
        _setUpFixture();
        for (uint256 id = 1; id <= keys.FOUNDING_FLEETS(); ++id) {
            _createFounding(keys.foundingPreset(id));
        }
        club = KeyfleetManager(keys.managerOf(5));
        clubPass.mint(alice, 1);
        vm.prank(safe);
        keys.advancePhase(uint64(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(KeyfleetKeys.SalesClosed.selector, 5));
        _give(alice);

        vm.warp(block.timestamp + 1);
        assertEq(keys.salesOpenAt(5), keys.salesOpenAt(1), "the Club opens with Classic #1");
        _give(alice);
        assertEq(keys.ownerOf(keys.tokenIdOf(5, 1)), alice);
    }

    /// @dev Invariant: the Club stops at its 1,998th key.
    function test_theClubStopsAtItsLastKey() public {
        uint256 batch = 222;
        for (uint256 from = 1; from <= KeyfleetPresets.CLUB_SUPPLY; from += batch) {
            address[] memory receivers = new address[](batch);
            for (uint256 i = 0; i < batch; ++i) {
                receivers[i] = _wallet(from + i);
                clubPass.mint(receivers[i], from + i);
            }
            vm.prank(safe);
            club.give(receivers);
        }
        assertEq(club.totalMinted(), KeyfleetPresets.CLUB_SUPPLY);
        assertEq(keys.ownerOf(keys.tokenIdOf(5, 1998)), _wallet(1998));

        clubPass.mint(alice, 1999);
        vm.prank(safe);
        vm.expectRevert(KeyfleetManager.SoldOut.selector);
        club.give(_receivers(alice, alice, alice));
    }

    // --- 3. the claims contract ----------------------------------------------

    /// @dev Invariant: a Pass in a contract that cannot take an NFT has its key held by the claims
    /// contract, which gives it to whoever holds that Pass when they claim, and to nobody else.
    function test_aHeldKeyGoesToWhoeverHoldsThePassWhenTheyClaim() public {
        NoReceiver vault = new NoReceiver();
        clubPass.mint(alice, 1);
        clubPass.mint(address(vault), 2);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(vault)));
        club.give(_receivers(alice, address(vault), alice));

        address[] memory receivers = new address[](2);
        (receivers[0], receivers[1]) = (alice, address(claims));
        vm.prank(safe);
        club.give(receivers);
        uint256 held = keys.tokenIdOf(5, 2);
        assertEq(keys.ownerOf(held), address(claims), "held for Pass 2");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetClubClaims.NotPassHolder.selector, 2, alice));
        claims.claim(2, alice);

        vm.prank(address(vault));
        clubPass.transferFrom(address(vault), bob, 2);
        address[] memory assets = club.REWARDS().rewardAssets();
        vm.expectEmit(true, true, true, true, address(claims));
        emit KeyClaimed(2, held, bob, bob, assets, new uint256[](assets.length));
        vm.prank(bob);
        (, uint256[] memory paid) = claims.claim(2, bob);
        assertEq(keys.ownerOf(held), bob, "the Pass's holder has the key");
        for (uint256 i = 0; i < paid.length; ++i) {
            assertEq(paid[i], 0, "nothing earned, nothing paid");
        }
        assertEq(keys.ownershipEpoch(held), 2, "a move like any other");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(claims), held)
        );
        claims.claim(2, bob);
    }

    /// @dev Invariant: what a held key earns while it waits is paid to whoever claims it, exactly
    /// what it earned, in each asset, and the claims contract keeps nothing.
    function test_aHeldKeysRewardsArePaidWithIt() public {
        clubPass.mint(alice, 1);
        clubPass.mint(carol, 2);
        address[] memory receivers = new address[](2);
        (receivers[0], receivers[1]) = (alice, address(claims));
        vm.prank(safe);
        club.give(receivers);
        _split();

        KeyfleetRewards rewards = club.REWARDS();
        uint256 held = keys.tokenIdOf(5, 2);
        uint256 eth = rewards.accrued(rewards.NATIVE(), held);
        uint256 earned = rewards.accrued(address(regent), held);
        assertGt(eth, 0, "the held key earned ETH");
        assertGt(earned, 0, "and REGENT");
        assertEq(eth, rewards.accrued(rewards.NATIVE(), keys.tokenIdOf(5, 1)), "as much as a given key");

        uint256 ethBefore = carol.balance;
        vm.prank(carol);
        (address[] memory assets, uint256[] memory paid) = claims.claim(2, carol);

        assertEq(keys.ownerOf(held), carol);
        assertEq(carol.balance - ethBefore, eth, "the ETH it earned");
        assertEq(regent.balanceOf(carol), earned, "the REGENT it earned");
        for (uint256 i = 0; i < assets.length; ++i) {
            if (assets[i] == rewards.NATIVE()) assertEq(paid[i], eth);
            if (assets[i] == address(regent)) assertEq(paid[i], earned);
            assertEq(rewards.credits(assets[i], address(claims)), 0, "nothing left to the claims contract");
            assertEq(rewards.accrued(assets[i], held), 0, "nothing left on the key");
        }
        assertEq(address(claims).balance, 0, "the claims contract keeps no ETH");
        assertEq(regent.balanceOf(address(claims)), 0, "and no REGENT");

        _split();
        assertGt(rewards.accrued(address(regent), held), 0, "the key earns for its holder from here");
        vm.prank(carol);
        rewards.claim(_ids(held), assets);
        assertGt(regent.balanceOf(carol), earned);
    }

    /// @dev Invariant: a Pass holder that refuses ETH still takes its key, and what the key earned
    /// while held goes to the wallet it names.
    function test_aHolderThatRefusesEthTakesItsKeyAndNamesWhereTheEarningsGo() public {
        EthRefuser refuser = new EthRefuser();
        clubPass.mint(alice, 1);
        clubPass.mint(address(refuser), 2);
        address[] memory receivers = new address[](2);
        (receivers[0], receivers[1]) = (alice, address(claims));
        vm.prank(safe);
        club.give(receivers);
        _split();

        KeyfleetRewards rewards = club.REWARDS();
        uint256 held = keys.tokenIdOf(5, 2);
        uint256 eth = rewards.accrued(rewards.NATIVE(), held);
        uint256 earned = rewards.accrued(address(regent), held);
        assertGt(eth, 0, "the held key earned ETH");

        vm.prank(address(refuser));
        vm.expectRevert(Errors.FailedCall.selector);
        claims.claim(2, address(refuser));

        vm.prank(address(refuser));
        vm.expectRevert(KeyfleetClubClaims.ZeroPayee.selector);
        claims.claim(2, address(0));

        uint256 ethBefore = carol.balance;
        vm.prank(address(refuser));
        claims.claim(2, carol);
        assertEq(keys.ownerOf(held), address(refuser), "the key goes to the Pass's holder");
        assertEq(carol.balance - ethBefore, eth, "the ETH it earned goes to the named wallet");
        assertEq(regent.balanceOf(carol), earned, "and the REGENT");
        assertEq(address(claims).balance, 0, "the claims contract keeps no ETH");
    }

    /// @dev Invariant: the claims contract takes only Regents Club keys as they are minted, and ETH
    /// only from the Club's ledger.
    function test_theClaimsContractTakesOnlyClubMintsAndClubEth() public {
        clubPass.mint(alice, 1);
        _give(alice);
        uint256 given = keys.tokenIdOf(5, 1);
        vm.prank(alice);
        vm.expectRevert(KeyfleetClubClaims.OnlyClubMints.selector);
        keys.safeTransferFrom(alice, address(claims), given);

        KeyfleetManager classic = KeyfleetManager(keys.managerOf(1));
        uint256 price = classic.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(classic), price);
        vm.expectRevert(KeyfleetClubClaims.OnlyClubMints.selector);
        classic.purchase(address(claims), price, block.timestamp, new bytes32[](0));
        vm.stopPrank();

        vm.prank(address(keys));
        vm.expectRevert(KeyfleetClubClaims.OnlyClubMints.selector);
        claims.onERC721Received(address(club), alice, given, "");
        vm.expectRevert(KeyfleetClubClaims.OnlyClubMints.selector);
        claims.onERC721Received(address(club), address(0), given, "");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory reason) = address(claims).call{value: 1 ether}("");
        assertFalse(ok, "a stranger's ETH is refused");
        assertEq(reason, abi.encodeWithSelector(KeyfleetClubClaims.OnlyRewards.selector, alice));
    }

    // --- 4. a given key is a key -----------------------------------------------

    /// @dev Invariant: a given key earns its share of the split and its holder claims it like any
    /// key's, and it is present on its own once mature.
    function test_aGivenKeySharesAndIsPresent() public {
        MockContractWallet wallet = new MockContractWallet(alice);
        clubPass.mint(address(wallet), 1);
        clubPass.mint(bob, 2);
        address[] memory receivers = new address[](2);
        (receivers[0], receivers[1]) = (address(wallet), bob);
        vm.prank(safe);
        club.give(receivers);
        _split();

        uint256 bobs = keys.tokenIdOf(5, 2);
        KeyfleetRewards rewards = club.REWARDS();
        assertTrue(club.VOTES().isActive(bobs), "present on its own once mature");
        uint256 earned = rewards.accrued(address(regent), bobs);
        assertGt(earned, 0);
        address[] memory assets = new address[](1);
        assets[0] = address(regent);
        vm.prank(bob);
        rewards.claim(_ids(bobs), assets);
        assertEq(regent.balanceOf(bob), earned);
        assertEq(keys.ownerOf(keys.tokenIdOf(5, 1)), address(wallet), "a contract that takes NFTs gets its own");
    }
}
