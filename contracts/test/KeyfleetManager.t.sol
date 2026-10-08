// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetKeys} from "../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetRegentBuyer} from "../src/KeyfleetRegentBuyer.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev Buys a key and tries to buy another from inside `onERC721Received`. It holds allowance and
/// balance, so a successful second purchase would mean the guard is missing.
contract ReenteringReceiver is IERC721Receiver {
    KeyfleetManager private immutable FLEET;
    bool private _entered;

    constructor(KeyfleetManager fleet) {
        FLEET = fleet;
    }

    function approveFleet(IERC20 token) external {
        token.approve(address(FLEET), type(uint256).max);
    }

    function buy() external returns (uint256) {
        return FLEET.purchase(address(this), type(uint256).max, block.timestamp, new bytes32[](0));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!_entered) {
            _entered = true;
            FLEET.purchase(address(this), type(uint256).max, block.timestamp, new bytes32[](0));
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Tries the fleet's three money entry points from inside `onERC721Received`, and records
/// whether each one was turned away by the fleet's reentrancy guard.
contract ReentryProbe is IERC721Receiver {
    KeyfleetManager private immutable FLEET;
    bool public purchaseRefused;
    bool public surplusRefused;
    bool public sendRefused;
    bool public probed;

    constructor(KeyfleetManager fleet) {
        FLEET = fleet;
    }

    function approveFleet(IERC20 token) external {
        token.approve(address(FLEET), type(uint256).max);
    }

    function probe() public {
        probed = true;
        try FLEET.purchase(address(this), type(uint256).max, block.timestamp, new bytes32[](0)) {}
        catch (bytes memory reason) {
            purchaseRefused = _isGuard(reason);
        }
        try FLEET.recognizeSurplus(address(FLEET.USDC())) {}
        catch (bytes memory reason) {
            surplusRefused = _isGuard(reason);
        }
        try FLEET.sendProtocolShare() {}
        catch (bytes memory reason) {
            sendRefused = _isGuard(reason);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        probe();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _isGuard(bytes memory reason) private pure returns (bool) {
        // The first four bytes of a revert reason are its error selector, so keeping only them is the point.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(reason) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
    }
}

/// @dev A router-style receiver: it forwards a key on from inside `onERC721Received`, either the key
/// it was just handed or another key it already holds.
contract ForwardingReceiver is IERC721Receiver {
    KeyfleetManager private immutable FLEET;
    KeyfleetKeys private immutable KEYS;
    address private _destination;
    uint256 private _tokenId;

    /// @notice What the collection reported about the new key while the hook was running.
    uint64 public observedEpoch;

    constructor(KeyfleetManager fleet, KeyfleetKeys keys) {
        FLEET = fleet;
        KEYS = keys;
    }

    function approveFleet(IERC20 token) external {
        token.approve(address(FLEET), type(uint256).max);
    }

    /// @dev A `tokenId` of zero forwards whichever key the hook is handed.
    function setForward(address destination, uint256 tokenId) external {
        _destination = destination;
        _tokenId = tokenId;
    }

    function disableForward() external {
        _destination = address(0);
    }

    function buy() external returns (uint256) {
        return FLEET.purchase(address(this), type(uint256).max, block.timestamp, new bytes32[](0));
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        observedEpoch = KEYS.ownershipEpoch(tokenId);
        if (_destination != address(0)) {
            KEYS.transferFrom(address(this), _destination, _tokenId == 0 ? tokenId : _tokenId);
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev An ERC-721 collection a fleet's creator may name as a joining requirement.
contract MockPassNft is ERC721 {
    constructor() ERC721("Pass", "PASS") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev A requirement contract whose `balanceOf` reverts.
contract RevertingBalance {
    function balanceOf(address) external pure returns (uint256) {
        revert("no balance");
    }
}

/// @dev A requirement contract that answers every call with a single byte.
contract ShortAnswer {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

/// @dev A requirement contract that answers every call with nothing at all.
contract SilentAnswer {
    fallback() external {}
}

/// @dev A requirement contract whose `balanceOf` tries to write state, which a read-only call
/// turns into a failure that spends all the gas it was given.
contract StatefulBalance {
    uint256 public calls;

    function balanceOf(address) external returns (uint256) {
        ++calls;
        return type(uint128).max;
    }
}

/// @dev A requirement contract whose `balanceOf` answers a balance of one followed by 200 KB of
/// padding.
contract LongAnswer {
    function balanceOf(address) external pure returns (uint256) {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 204800)
        }
    }
}

contract KeyfleetManagerTest is KeyfleetFixture {
    using stdStorage for StdStorage;

    /// @dev The reference price, 10 USDC in atomic units: the start of every founding fleet.
    uint256 private constant Q = KeyfleetPresets.Q_USDC;
    /// @dev The 10% protocol share of a ten-USDC purchase.
    uint256 private constant Q_PROTOCOL = Q / 10;
    /// @dev The start the Classic table is written for, 10 USDC.
    uint256 private constant CLASSIC_START = KeyfleetPresets.CLASSIC_START_USDC;
    /// @dev The founding Accelerant fleet's step, and the one the fixture gives open Accelerant fleets.
    uint256 private constant STEP = KeyfleetPresets.MAX_ACCELERANT_STEP_PERCENT;
    /// @dev The costliest first purchase measured, the founding Accelerant fleet's key 1 (557,166
    /// gas), plus twenty percent, rounded up to the nearest thousand.
    uint256 private constant PURCHASE_GAS_CEILING = 669_000;

    StdStorage private fleetStore;

    MockToken private other;

    address private alice = address(0xA11CE);
    address private bob = address(0xB0B);
    address private carol = address(0xCA201);
    address private dave = address(0xDA7E);
    address private erin = address(0xE217);

    function setUp() public {
        _setUpFixture();
        other = new MockToken("Other", "OTH");
    }

    // --- helpers ---------------------------------------------------------

    /// @dev Funds and approves the next price without buying, so an event expectation can be set
    /// immediately before the purchase call itself.
    function _fundNext(KeyfleetManager fleet) private returns (uint256 price) {
        price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.prank(buyer);
        usdc.approve(address(fleet), price);
    }

    /// @dev Buys the next key as `payer` for `receiver`, with `proof`.
    function _buyWith(KeyfleetManager fleet, address payer, address receiver, bytes32[] memory proof)
        private
        returns (uint256 tokenId)
    {
        uint256 price = fleet.nextPrice();
        usdc.mint(payer, price);
        vm.startPrank(payer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, price, block.timestamp, proof);
        vm.stopPrank();
    }

    /// @dev Expects `payer`'s purchase for `receiver` to be refused because `refused` meets none of
    /// the fleet's joining requirements.
    function _expectRefused(
        KeyfleetManager fleet,
        address payer,
        address receiver,
        bytes32[] memory proof,
        address refused
    ) private {
        uint256 price = fleet.nextPrice();
        usdc.mint(payer, price);
        vm.startPrank(payer);
        usdc.approve(address(fleet), price);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.RequirementNotMet.selector, refused));
        fleet.purchase(receiver, price, block.timestamp, proof);
        usdc.approve(address(fleet), 0);
        vm.stopPrank();
    }

    function _noProof() private pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _none() private pure returns (uint256[] memory ids) {
        ids = new uint256[](0);
    }

    function _usdcOnly() private view returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = address(usdc);
    }

    /// @dev The REGENT this fleet's treasury holds: every unit of its USDC capital, swapped.
    function _treasuryRegent(KeyfleetManager fleet) private view returns (uint256) {
        return regent.balanceOf(address(fleet.TREASURY()));
    }

    /// @dev The manager holds no capital: its USDC is exactly the Cascade reserve, the owed share and
    /// the USDC booked for conversion, and it holds no WETH or REGENT. The shared REGENT buyer holds
    /// nothing and has no allowance left over, and the treasury holds no USDC from purchases.
    function _assertBalanceInvariant(KeyfleetManager fleet) private view {
        assertEq(
            usdc.balanceOf(address(fleet)),
            fleet.cascadeReserve() + fleet.protocolShareOwed() + fleet.pendingConversion(),
            "fleet USDC balance equals reserve plus the owed protocol share plus the booked conversion"
        );
        assertEq(regent.balanceOf(address(fleet)), 0, "the manager holds no REGENT");
        assertEq(weth.balanceOf(address(fleet)), 0, "the manager holds no WETH");
        assertEq(usdc.allowance(address(fleet), address(regentBuyer)), 0, "no allowance is left to the buyer");
        assertEq(usdc.balanceOf(address(regentBuyer)), 0, "the buyer holds no USDC");
        assertEq(weth.balanceOf(address(regentBuyer)), 0, "the buyer holds no WETH");
        assertEq(regent.balanceOf(address(regentBuyer)), 0, "the buyer holds no REGENT");
        assertEq(usdc.balanceOf(address(fleet.TREASURY())), 0, "the treasury's part never arrives as USDC");
    }

    /// @dev Proposes and approves `calls` with key 1, then moves to the moment it closes, so the
    /// test can set expectations right before carrying it out.
    function _pass(KeyfleetManager fleet, KeyfleetTreasury.Call[] memory calls) private returns (uint256 id) {
        id = _approve(fleet, calls);
        vm.warp(fleet.VOTES().proposal(id).closesAt);
    }

    function _setProfileCall(KeyfleetManager target, KeyfleetManager.Profile memory profile)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(address(target), 0, abi.encodeCall(KeyfleetManager.setProfile, (profile)));
    }

    // --- Merkle list -----------------------------------------------------

    /// @dev OpenZeppelin's standard leaf: the address, ABI-encoded and hashed twice.
    function _leaf(address account) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account))));
    }

    /// @dev OpenZeppelin's sorted pair hash.
    function _node(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev The list Alice, Bob, Carol and Dave as a four-leaf tree: its root and each member's proof.
    function _list() private view returns (bytes32 root, bytes32[][4] memory proofs) {
        bytes32[4] memory leaves = [_leaf(alice), _leaf(bob), _leaf(carol), _leaf(dave)];
        bytes32 left = _node(leaves[0], leaves[1]);
        bytes32 right = _node(leaves[2], leaves[3]);
        root = _node(left, right);
        for (uint256 i = 0; i < 4; ++i) {
            proofs[i] = new bytes32[](2);
            proofs[i][0] = leaves[i ^ 1];
            proofs[i][1] = i < 2 ? right : left;
        }
    }

    function _listOnly(bytes32 root) private pure returns (KeyfleetManager.Requirements memory req) {
        req.merkleRoot = root;
    }

    // --- 1. wiring and access --------------------------------------------

    /// @dev Invariant: a founding fleet starts with nothing sold, nothing owed and USDC as its one
    /// reward asset, at 10 USDC; only Accelerant keeps a running price, and only it has a step.
    function test_aFoundingFleetStartsEmptyAtItsFoundingPrice() public {
        for (uint256 p = 0; p < 4; ++p) {
            KeyfleetPresets.Preset preset = KeyfleetPresets.Preset(p);
            KeyfleetManager fleet = _deploy(preset);
            address[] memory assets = fleet.REWARDS().rewardAssets();
            assertEq(assets.length, 1, "USDC is the one income token");
            assertEq(assets[0], address(usdc));
            assertEq(fleet.totalMinted(), 0);
            assertEq(fleet.firstMintAt(), 0);
            assertEq(fleet.protocolShareOwed(), 0);
            assertEq(fleet.cascadeReserve(), 0);
            assertEq(fleet.START_PRICE(), Q);
            assertEq(fleet.nextPrice(), Q, "key 1 costs the start");
            bool accelerant = preset == KeyfleetPresets.Preset.FleetTechAccelerant;
            assertEq(fleet.ACCELERANT_STEP_PERCENT(), accelerant ? 5 : 0, "a 5% step on Accelerant only");
            assertEq(fleet.currentPrice(), accelerant ? Q : 0, "only Accelerant persists a price");
        }
    }

    /// @dev Invariant: only the fleet's own manager may write to its ledger, never a stranger, the
    /// collection or another fleet's manager.
    function test_onlyTheManagerCanWriteToItsLedger() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager otherFleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetRewards rewards = fleet.REWARDS();
        _buy(fleet, alice);
        usdc.mint(address(rewards), Q);

        uint256 k1 = _key(fleet, 1);
        uint256 k2 = _key(fleet, 2);

        address[3] memory callers = [alice, address(otherFleet), address(keys)];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
            rewards.enrollKey(k2, 0);
            vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
            rewards.credit(address(usdc), callers[i], Q);
            vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
            rewards.allocateToCohort(address(usdc), 0, Q);
            vm.expectRevert(KeyfleetRewards.OnlyManager.selector);
            rewards.settleKey(k1, alice);
            vm.stopPrank();
        }
    }

    /// @dev Invariant: only the collection tells a manager a key moved, so nobody can fake a move to
    /// settle rewards or clear presence.
    function test_onlyTheCollectionCallsTheKeyHook() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetManager otherFleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        uint256 k1 = _buy(fleet, alice);

        address[3] memory callers = [alice, address(otherFleet), safe];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(KeyfleetManager.OnlyKeys.selector);
            fleet.onKeyMoved(k1, alice);
        }
        assertEq(keys.ownerOf(k1), alice, "the key did not move");
    }

    /// @dev Invariant: only the factory writes a fleet's profile and requirements, once, and sells
    /// its key 1, once.
    function test_onlyTheFactoryInitializesAndSellsKeyOneOnce() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        KeyfleetManager.Requirements memory anyone;

        vm.prank(alice);
        vm.expectRevert(KeyfleetManager.OnlyFactory.selector);
        fleet.initialize(_profile("Taken"), anyone);
        vm.prank(alice);
        vm.expectRevert(KeyfleetManager.OnlyFactory.selector);
        fleet.sellFirstKey(alice);

        vm.startPrank(address(factory));
        vm.expectRevert(KeyfleetManager.AlreadyInitialized.selector);
        fleet.initialize(_profile("Taken"), anyone);
        vm.expectRevert(KeyfleetManager.FirstKeySold.selector);
        fleet.sellFirstKey(alice);
        vm.stopPrank();
    }

    // --- 2. purchase authorization ---------------------------------------

    /// @dev Invariant: the purchase authorizations are the buyer's only protection against a slot
    /// that moved, so each one is checked before any token moves.
    function test_purchaseHonoursDeadlineMaximumPriceAndDefaultReceiver() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, 10 * price);
        vm.prank(buyer);
        usdc.approve(address(fleet), type(uint256).max);

        vm.warp(1000);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.Expired.selector, 999));
        fleet.purchase(alice, price, 999, _noProof());

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetManager.PriceAboveMax.selector, price, price - 1));
        fleet.purchase(alice, price - 1, block.timestamp, _noProof());

        vm.prank(buyer);
        uint256 tokenId = fleet.purchase(address(0), 2 * price, block.timestamp, _noProof());
        assertEq(keys.ownerOf(tokenId), buyer, "zero receiver mints to the caller");
        assertEq(tokenId, _key(fleet, 1), "key numbers start at one");
        assertEq(usdc.balanceOf(buyer), 9 * price, "only the price was taken, not the maximum");
    }

    /// @dev Invariant: Classic stops at 1024 keys, each sold at its own price on the curve from
    /// 10 USDC to 100 USDC; 10% of every sale is owed to REGENT staking in USDC and the other 90% is in
    /// the treasury as REGENT.
    function test_classicSellsExactlyOneThousandTwentyFourKeysAlongItsPriceCurve() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        assertEq(fleet.maxSupply(), 1024);

        uint256 paid;
        for (uint256 i = 0; i < KeyfleetPresets.CLASSIC_SUPPLY; ++i) {
            uint256 price = fleet.nextPrice();
            assertEq(price, KeyfleetPresets.classicPrice(i + 1, CLASSIC_START), "each key costs its own price");
            assertEq(fleet.remainingSupply(), 1024 - i);
            paid += price;
            _buy(fleet, _wallet(i));
        }

        assertEq(paid, 40_040_480_000, "the whole fleet cost 40,040.48 USDC");
        assertEq(fleet.protocolShareOwed(), paid / 10, "10% of every sale is owed to staking");
        assertEq(fleet.pendingConversion(), paid - paid / 10, "and the rest is booked for the treasury");
        _assertBalanceInvariant(fleet);
        _convertAll();
        assertEq(_treasuryRegent(fleet), _regentFor(paid - paid / 10), "and arrives as REGENT in the treasury");
        _assertBalanceInvariant(fleet);

        assertEq(fleet.remainingSupply(), 0);
        vm.expectRevert(KeyfleetManager.SoldOut.selector);
        fleet.nextPrice();

        usdc.mint(buyer, 100 * Q);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), 100 * Q);
        vm.expectRevert(KeyfleetManager.SoldOut.selector);
        fleet.purchase(alice, 100 * Q, block.timestamp, _noProof());
        vm.stopPrank();
    }

    /// @dev Invariant: Accelerant steps its price once per primary mint and stops at 2000 keys. The
    /// first keys are bought for real; past about key 460 a key costs more than all the USDC in
    /// existence, so the count is then written straight to key 1999 and to the end.
    function test_accelerantSellsExactlyTwoThousandKeysAndThenStops() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        assertEq(fleet.maxSupply(), 2000);

        for (uint256 i = 0; i < 30; ++i) {
            assertEq(fleet.currentPrice(), KeyfleetPresets.accelerantPrice(i, Q, STEP), "one step per primary mint");
            _buy(fleet, alice);
        }

        uint256 last = KeyfleetPresets.accelerantPrice(1999, Q, STEP);
        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(uint256(1999));
        fleetStore.target(address(fleet)).sig("currentPrice()").checked_write(last);
        assertEq(fleet.remainingSupply(), 1, "one key left");
        assertEq(fleet.nextPrice(), last, "the last key costs the compounded price");

        fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(uint256(2000));
        assertEq(fleet.remainingSupply(), 0);
        vm.expectRevert(KeyfleetManager.SoldOut.selector);
        fleet.nextPrice();
        vm.prank(buyer);
        vm.expectRevert(KeyfleetManager.SoldOut.selector);
        fleet.purchase(alice, type(uint256).max, block.timestamp, _noProof());
    }

    /// @dev Invariant: a Fibonacci fleet has no last level and never sells out. Supply limits are a
    /// Fleet.Tech notion, so the two supply views refuse to answer rather than invent a number.
    /// Minting 701 million keys is not practical, so the counter is written directly to the end of
    /// level 40, and the next purchase opens level 41 at its own price.
    function test_fibonacciHasNoLastLevelAndNeverSellsOut() public {
        KeyfleetPresets.Preset[2] memory fibonacci =
            [KeyfleetPresets.Preset.FibonacciSyndicate, KeyfleetPresets.Preset.FibonacciCascade];
        for (uint256 p = 0; p < 2; ++p) {
            KeyfleetManager fleet = _deploy(fibonacci[p]);
            vm.expectRevert(KeyfleetManager.NotFleetTechPreset.selector);
            fleet.maxSupply();
            vm.expectRevert(KeyfleetManager.NotFleetTechPreset.selector);
            fleet.remainingSupply();

            uint256 endOfForty = KeyfleetPresets.fibonacciLevelEnd(40);
            assertEq(endOfForty, 701_408_730, "701,408,730 keys fill levels 1 to 40");
            fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(endOfForty);
            assertEq(fleet.levelOf(endOfForty), 40, "the last key of level 40");
            assertEq(fleet.levelOf(endOfForty + 1), 41, "the next key opens level 41");
            assertEq(fleet.nextPrice(), KeyfleetPresets.fibonacciLevelPrice(41, Q), "at level 41's price");

            uint256 tokenId = _buy(fleet, alice);
            assertEq(tokenId, _key(fleet, endOfForty + 1));
            assertEq(keys.keyNumberOf(tokenId), endOfForty + 1);
            assertEq(keys.ownerOf(tokenId), alice, "the purchase goes through");
            assertEq(fleet.REWARDS().keyCohort(tokenId), 41, "and the key joins its level's cohort");
        }
    }

    // --- 3. Syndicate and Classic ledgers ---------------------------------

    /// @dev Invariant: 10% is owed to REGENT staking in USDC and every remaining unit is booked for
    /// the treasury, which later receives it as REGENT; the purchase itself swaps nothing.
    function test_syndicatePurchaseOwesStakingTenPercentAndBooksTheRestForRegent() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);

        uint256 price = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit KeyfleetManager.Purchased(_key(fleet, 1), buyer, alice, Q, Q_PROTOCOL, Q - Q_PROTOCOL, 0, 0);
        vm.expectEmit(true, true, true, true, address(regentBuyer));
        emit KeyfleetRegentBuyer.Queued(address(fleet));
        vm.prank(buyer);
        fleet.purchase(alice, 2 * price, block.timestamp, _noProof());

        assertEq(fleet.protocolShareOwed(), Q_PROTOCOL, "10% owed to staking");
        assertEq(fleet.pendingConversion(), Q - Q_PROTOCOL, "90% booked for the treasury");
        assertEq(usdc.balanceOf(address(v3Pool)), 0, "nothing swapped in the purchase");
        _assertBalanceInvariant(fleet);
        _convertAll();
        assertEq(_treasuryRegent(fleet), _regentFor(Q - Q_PROTOCOL), "90% arrives as REGENT");
        assertEq(fleet.cascadeReserve(), 0, "Syndicate holds no reserve");
        assertEq(usdc.balanceOf(address(fleet.REWARDS())), 0, "no reward backing from a Syndicate purchase");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: across many purchases every USDC unit paid ends up in exactly one place: swapped
    /// for the treasury's REGENT, the Cascade reserve, the owed share or the ledger's backing. The
    /// manager and the ledger hold no free capital, and every swapped unit arrives as REGENT in this
    /// fleet's treasury.
    function test_everyPaidUnitLandsInRegentReserveOwedShareOrRewardBacking() public {
        for (uint256 p = 0; p < 4; ++p) {
            KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset(p));
            uint256 swappedBefore = usdc.balanceOf(address(v3Pool));
            uint256 totalPaid;
            for (uint256 i = 0; i < 20; ++i) {
                totalPaid += fleet.nextPrice();
                _buy(fleet, _wallet(i));
                _assertBalanceInvariant(fleet);
            }
            _convertAll();

            uint256 swapped = usdc.balanceOf(address(v3Pool)) - swappedBefore;
            assertEq(_treasuryRegent(fleet), _regentFor(swapped), "every swapped unit is REGENT in the treasury");
            assertEq(
                swapped + fleet.cascadeReserve() + fleet.protocolShareOwed() + usdc.balanceOf(address(fleet.REWARDS())),
                totalPaid,
                "swap, reserve, owed share and reward backing account for every unit"
            );
            assertEq(
                usdc.balanceOf(address(fleet.REWARDS())),
                fleet.REWARDS().backed(address(usdc)),
                "the ledger holds exactly its backing"
            );
        }
    }

    /// @dev Invariant: a primary purchase touches USDC only; a stray token stays where it is.
    function test_purchasesNeverTouchANonUsdcBucket() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        other.mint(address(fleet), 500e6);

        _buy(fleet, alice);
        _buy(fleet, bob);

        assertEq(other.balanceOf(address(fleet.TREASURY())), 0, "a stray token is not forwarded by a purchase");
        assertEq(other.balanceOf(address(fleet)), 500e6, "it stays in the fleet until it is sorted");
        assertEq(fleet.surplus(address(other)), 500e6);
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: on every preset each purchase adds exactly 10% of its gross, floored, to the
    /// protocol share owed to staking, and the ledger's balance is exactly what it has backed.
    function test_everyPresetOwesStakingTenPercentOfEachPurchase() public {
        for (uint256 p = 0; p < 4; ++p) {
            KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset(p));
            KeyfleetRewards rewards = fleet.REWARDS();
            uint256 owed;
            for (uint256 i = 0; i < 12; ++i) {
                uint256 price = fleet.nextPrice();
                _buy(fleet, _wallet(i));
                owed += (price * 1000) / 10_000;
                assertEq(fleet.protocolShareOwed(), owed, "each purchase adds its floored 10%");
                _assertBalanceInvariant(fleet);
                assertEq(
                    usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "the ledger holds its backing"
                );
            }
        }
    }

    // --- 4. Accelerant ----------------------------------------------------

    /// @dev Invariant: the first Accelerant mint has no predecessor, so all post-fee proceeds become
    /// the treasury's REGENT and nobody is credited a rebate.
    function test_firstAccelerantMintSwapsEveryPostFeeUnitForTheTreasury() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        assertEq(fleet.currentPrice(), Q, "the first key costs the reference price");

        _buy(fleet, alice);
        _convertAll();

        assertEq(_treasuryRegent(fleet), _regentFor(Q - Q_PROTOCOL), "90% arrives as REGENT");
        assertEq(usdc.balanceOf(address(fleet.REWARDS())), 0, "no rebate on the first mint");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: only primary mints advance the Accelerant price, and each one advances it by
    /// exactly 105/100 rounded up. The first three USDC prices are pinned because the platform
    /// mirrors them.
    function test_accelerantPriceStepsFivePercentPerPrimaryMintOnly() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        uint256[3] memory pinned = [uint256(10_000_000), 10_500_000, 11_025_000];

        uint256 expected = Q;
        for (uint256 i = 0; i < 6; ++i) {
            if (i < 3) assertEq(fleet.nextPrice(), pinned[i], "pinned USDC price");
            assertEq(fleet.nextPrice(), expected, "quoted price follows the ladder");
            assertEq(fleet.nextPrice(), KeyfleetPresets.accelerantPrice(i, Q, STEP), "and matches the library");
            _buy(fleet, _wallet(i));
            expected = KeyfleetPresets.accelerantNextPrice(expected, STEP);
        }

        uint256 beforeTransfer = fleet.nextPrice();
        uint256 k1 = _key(fleet, 1);
        vm.prank(_wallet(0));
        keys.transferFrom(_wallet(0), bob, k1);
        assertEq(fleet.nextPrice(), beforeTransfer, "a secondary sale does not advance the price");
    }

    /// @dev Invariant: the rebate is fixed at the moment of the mint and goes to whoever holds the
    /// preceding key then, not to whoever minted it. It stays USDC; only the 20% capital is swapped.
    function test_accelerantRebateGoesToTheCurrentHolderOfThePrecedingKey() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetRewards rewards = fleet.REWARDS();

        uint256 k1 = _buy(fleet, alice);
        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);

        uint256 price = fleet.nextPrice();
        uint256 protocol = price / 10;
        uint256 capital = price / 5;
        uint256 rebate = price - protocol - capital;
        _buy(fleet, carol);

        assertEq(rewards.credits(address(usdc), bob), rebate, "the current holder is rebated");
        assertEq(rewards.credits(address(usdc), alice), 0, "the original minter is not");
        assertEq(usdc.balanceOf(address(rewards)), rebate, "the rebate is backed in USDC in the ledger");
        _convertAll();
        assertEq(_treasuryRegent(fleet), _regentFor((Q - Q_PROTOCOL) + capital), "the treasury's 20% is REGENT");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: each Accelerant rebate goes to the holder of the key immediately before the
    /// new one, never to the holder of the first key. The third mint costs 11,025,000 and rebates
    /// 70% of it, 7,717,500, to the holder of key 2.
    function test_accelerantThirdMintRebatesTheHolderOfKeyTwoNotKeyOne() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetRewards rewards = fleet.REWARDS();

        _buy(fleet, alice);
        _buy(fleet, bob);
        uint256 aliceAfterTwo = rewards.credits(address(usdc), alice);
        assertEq(fleet.nextPrice(), 11_025_000, "third mint price");
        _buy(fleet, carol);

        assertEq(rewards.credits(address(usdc), bob), 7_717_500, "the holder of key 2 is rebated");
        assertEq(rewards.credits(address(usdc), alice), aliceAfterTwo, "the holder of key 1 gains nothing");
        assertEq(rewards.credits(address(usdc), carol), 0, "the new holder rebates no one");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: the rebate is bound to the holder of the preceding key as it stood before the
    /// mint, so a receiver cannot sell that key from inside its own mint hook and redirect the rebate
    /// it is about to be paid.
    function test_accelerantRebateIsBoundBeforeTheMintHookRuns() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        KeyfleetRewards rewards = fleet.REWARDS();
        ForwardingReceiver receiver = new ForwardingReceiver(fleet, keys);
        usdc.mint(address(receiver), 100 * Q);
        receiver.approveFleet(usdc);
        uint256 k1 = _key(fleet, 1);

        receiver.disableForward();
        assertEq(receiver.buy(), k1);

        uint256 price = fleet.nextPrice();
        uint256 rebate = price - price / 10 - price / 5;
        receiver.setForward(alice, k1);
        assertEq(receiver.buy(), _key(fleet, 2));

        assertEq(keys.ownerOf(k1), alice, "the preceding key left inside the same purchase");
        assertEq(rewards.credits(address(usdc), address(receiver)), rebate, "the rebate was already bound");
        assertEq(rewards.credits(address(usdc), alice), 0, "the new holder gets no part of it");
        assertEq(keys.ownerOf(_key(fleet, 2)), address(receiver));
        _assertBalanceInvariant(fleet);
    }

    // --- 5. Cascade -------------------------------------------------------

    /// @dev Invariant: Cascade proceeds are held in the USDC reserve and nothing is swapped until a
    /// level completes. Level 1 has no predecessor, so its whole reserve is swapped for the treasury
    /// in the purchase that completes it.
    function test_cascadeLevelOneSwapsItsWholeReserveForTheTreasury() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);

        _buy(fleet, alice);
        assertEq(_treasuryRegent(fleet), 0, "nothing is swapped before completion");
        assertEq(usdc.balanceOf(address(v3Pool)), 0, "not one unit went to the pool");
        assertEq(fleet.cascadeReserve(), Q - Q_PROTOCOL, "everything after the protocol share is reserved");
        assertFalse(fleet.levelCompleted(1));

        uint256 price = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit KeyfleetManager.LevelCompleted(1, 0, 2 * (Q - Q_PROTOCOL));
        vm.expectEmit(true, true, true, true, address(regentBuyer));
        emit KeyfleetRegentBuyer.Queued(address(fleet));
        vm.prank(buyer);
        fleet.purchase(bob, 2 * price, block.timestamp, _noProof());

        assertTrue(fleet.levelCompleted(1), "level 1 completed on its last key");
        assertEq(fleet.cascadeReserve(), 0, "the reserve is emptied");
        assertEq(fleet.pendingConversion(), 2 * (Q - Q_PROTOCOL), "into the queue for REGENT");
        _assertBalanceInvariant(fleet);
        _convertAll();
        assertEq(_treasuryRegent(fleet), _regentFor(2 * (Q - Q_PROTOCOL)), "and swapped for the treasury");
        assertEq(fleet.levelGrossPaid(1), 2 * Q, "gross paid for level 1 is recorded");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: completing level 2 repays level 1's original gross exactly once, in USDC,
    /// allocated to the level-1 cohort, and swaps only the surplus for the treasury.
    function test_cascadeLevelTwoReimbursesLevelOneGrossAndSwapsTheSurplus() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();

        _buy(fleet, alice);
        _buy(fleet, bob);
        _convertAll();
        uint256 regentAfterLevelOne = _treasuryRegent(fleet);

        uint256 levelTwoPrice = fleet.nextPrice();
        assertEq(levelTwoPrice, (Q * 120) / 100, "level 2 costs 20% more");
        uint256 levelTwoReserve = 3 * (levelTwoPrice - levelTwoPrice / 10);
        uint256 reimbursement = 2 * Q;
        uint256 surplus = levelTwoReserve - reimbursement;

        _buy(fleet, carol);
        _buy(fleet, dave);
        uint256 price = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit KeyfleetManager.LevelCompleted(2, reimbursement, surplus);
        vm.prank(buyer);
        fleet.purchase(_wallet(9), 2 * price, block.timestamp, _noProof());

        assertTrue(fleet.levelCompleted(2));
        assertEq(fleet.cascadeReserve(), 0, "the reserve is emptied again");
        assertEq(fleet.pendingConversion(), surplus, "only the surplus is booked");
        _assertBalanceInvariant(fleet);
        _convertAll();
        assertEq(_treasuryRegent(fleet), regentAfterLevelOne + _regentFor(surplus), "and swapped");
        assertEq(usdc.balanceOf(address(rewards)), reimbursement, "the repayment is backed in USDC in the ledger");
        assertEq(rewards.accrued(address(usdc), _key(fleet, 1)), Q, "each level-1 key earns its own gross back");
        assertEq(rewards.accrued(address(usdc), _key(fleet, 2)), Q);
        assertEq(rewards.accrued(address(usdc), _key(fleet, 3)), 0, "level-2 keys are not repaid by their own level");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: a repayment belongs to whoever holds the key when the level completes, and a
    /// repayment already accrued stays with the address that held the key then.
    function test_cascadeRepaymentFollowsTheHolderAtCompletionAndNeverTravelsAfterwards() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        uint256 k1 = _key(fleet, 1);
        uint256 k2 = _key(fleet, 2);

        _buy(fleet, alice);
        _buy(fleet, bob);

        // Alice sells key 1 before level 2 completes, so the future repayment goes with the key.
        vm.prank(alice);
        keys.transferFrom(alice, carol, k1);

        _buy(fleet, _wallet(1));
        _buy(fleet, _wallet(2));
        _buy(fleet, _wallet(3));

        assertEq(rewards.accrued(address(usdc), k1), Q, "key 1 accrued the repayment");
        vm.prank(carol);
        assertEq(rewards.claim(_ids(k1), _usdcOnly())[0], Q, "the holder at completion is repaid");
        vm.prank(alice);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(_none(), _usdcOnly());

        // Bob keeps his accrual when he sells key 2 afterwards.
        vm.prank(bob);
        keys.transferFrom(bob, dave, k2);
        assertEq(rewards.credits(address(usdc), bob), Q, "settlement kept the repayment with Bob");
        assertEq(rewards.accrued(address(usdc), k2), 0, "and the key carries nothing to Dave");
        vm.prank(dave);
        vm.expectRevert(KeyfleetRewards.NothingToClaim.selector);
        rewards.claim(_ids(k2), _usdcOnly());
        vm.prank(bob);
        assertEq(rewards.claim(_none(), _usdcOnly())[0], Q, "Bob claims after selling every key");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: across the first twenty levels, completing each level repays every key of the
    /// level before it its whole gross price, never a part of it, and swaps the rest of the reserve
    /// for the treasury. Every key through level 20 is bought, so every completion is made by real
    /// purchases. Buying all 46,365 keys costs far more gas than one test may spend, so gas is not
    /// metered here; what a purchase costs is measured by `test_purchaseGasStaysUnderTheCeiling`.
    function test_cascadeRepaysEveryCompletedLevelInFullAcrossTwentyLevels() public {
        vm.pauseGasMetering();
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        usdc.mint(buyer, type(uint128).max);
        vm.prank(buyer);
        usdc.approve(address(fleet), type(uint256).max);

        uint256 repaid;
        uint256 totalPaid;
        for (uint256 level = 1; level <= 20; ++level) {
            uint256 supply = KeyfleetPresets.fibonacciLevelSupply(level);
            for (uint256 i = 0; i < supply; ++i) {
                vm.prank(buyer);
                fleet.purchase(_wallet(i), type(uint256).max, block.timestamp, _noProof());
            }
            totalPaid += fleet.levelGrossPaid(level);

            assertTrue(fleet.levelCompleted(level), "the level completed on its last key");
            assertEq(fleet.cascadeReserve(), 0, "every completion empties the reserve");
            if (level > 1) {
                uint256 previous = level - 1;
                uint256 price = KeyfleetPresets.fibonacciLevelPrice(previous, Q);
                assertEq(fleet.levelGrossPaid(previous), KeyfleetPresets.fibonacciLevelSupply(previous) * price);
                uint256 first = _key(fleet, KeyfleetPresets.fibonacciLevelStart(previous));
                uint256 last = _key(fleet, KeyfleetPresets.fibonacciLevelEnd(previous));
                assertEq(rewards.accrued(address(usdc), first), price, "the first key is repaid its whole price");
                assertEq(rewards.accrued(address(usdc), last), price, "and so is the last");
                repaid += fleet.levelGrossPaid(previous);
            }
            _assertBalanceInvariant(fleet);
        }

        assertEq(fleet.totalMinted(), 46_365, "every key through level 20 was sold");
        assertEq(usdc.balanceOf(address(rewards)), repaid, "the ledger holds every repayment in full");
        _convertAll();
        assertEq(
            _treasuryRegent(fleet),
            _regentFor(totalPaid - fleet.protocolShareOwed() - repaid),
            "everything neither owed nor repaid was swapped for the treasury"
        );
        assertEq(fleet.levelOf(fleet.totalMinted() + 1), 21, "and level 21 is open");
    }

    /// @dev Invariant: a level completes exactly once; later resales of its keys cannot re-run the
    /// repayment or reopen the level.
    function test_aCompletedCascadeLevelIsNeverCompletedAgain() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        uint256 k1 = _buy(fleet, alice);
        uint256 k2 = _buy(fleet, bob);
        uint256 treasuryRegent = _treasuryRegent(fleet);

        vm.prank(alice);
        keys.transferFrom(alice, carol, k1);
        vm.prank(bob);
        keys.transferFrom(bob, dave, k2);

        assertTrue(fleet.levelCompleted(1));
        assertEq(_treasuryRegent(fleet), treasuryRegent, "resales change no bucket");
        assertEq(fleet.cascadeReserve(), 0);
        _assertBalanceInvariant(fleet);
    }

    // --- 6. no wallet cap -----------------------------------------------------

    /// @dev Invariant: no preset caps how many keys one wallet buys or holds, of one level or of
    /// many, by purchase or by transfer.
    function test_aWalletMayBuyAndHoldAnyNumberOfKeysOnEveryPreset() public {
        KeyfleetPresets.Preset[4] memory presets = [
            KeyfleetPresets.Preset.FibonacciSyndicate,
            KeyfleetPresets.Preset.FibonacciCascade,
            KeyfleetPresets.Preset.FleetTechClassic,
            KeyfleetPresets.Preset.FleetTechAccelerant
        ];
        for (uint256 p = 0; p < presets.length; ++p) {
            KeyfleetManager fleet = _deploy(presets[p]);
            uint256 balanceBefore = keys.balanceOf(alice);
            for (uint256 i = 0; i < 6; ++i) {
                _buy(fleet, alice);
            }
            uint256 fromBob = _buy(fleet, bob);
            vm.prank(bob);
            keys.transferFrom(bob, alice, fromBob);
            assertEq(keys.balanceOf(alice) - balanceBefore, 7, "six bought and one received");
        }
    }

    /// @dev Invariant: on a Fibonacci fleet one wallet may hold every key of a level.
    function test_oneWalletMayHoldAWholeFibonacciLevel() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        uint256 throughTwo = KeyfleetPresets.fibonacciTotalSupplyThrough(2);
        for (uint256 i = 0; i < throughTwo; ++i) {
            _buy(fleet, alice);
        }
        assertEq(fleet.levelOf(throughTwo), 2);
        assertEq(keys.balanceOf(alice), throughTwo, "Alice holds every key of levels 1 and 2");
    }

    /// @dev Invariant: the two Fleet.Tech presets have no levels.
    function test_fleetTechPresetsHaveNoLevels() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        vm.expectRevert(KeyfleetManager.NotFibonacciPreset.selector);
        fleet.levelOf(1);
    }

    // --- 7. first sale ------------------------------------------------------

    /// @dev Invariant: the fleet records when its first key was sold, and later sales and
    /// transfers never change it.
    function test_firstMintAtIsTheFirstSaleAndNeverChanges() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        assertEq(fleet.firstMintAt(), 0, "nothing sold yet");
        vm.warp(5_000);
        _buy(fleet, alice);
        assertEq(fleet.firstMintAt(), 5_000, "the first sale");

        vm.warp(9_000);
        _buy(fleet, carol);
        uint256 k1 = _key(fleet, 1);
        vm.prank(alice);
        keys.transferFrom(alice, bob, k1);
        assertEq(fleet.firstMintAt(), 5_000, "later sales and transfers leave it alone");
    }

    // --- 8. reentrancy and receiver hooks ---------------------------------

    /// @dev Invariant: a receiver cannot buy again from inside the mint hook.
    function test_reenteringPurchaseFromTheReceiverHookIsRejected() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        ReenteringReceiver receiver = new ReenteringReceiver(fleet);
        usdc.mint(address(receiver), 10 * Q);
        receiver.approveFleet(usdc);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        receiver.buy();

        assertEq(fleet.totalMinted(), 0, "nothing was minted");
        assertEq(usdc.balanceOf(address(fleet)), 0, "and nothing was taken");
    }

    /// @dev Invariant: the mint hook cannot reach the fleet's money. Buying, sorting the fleet's USDC
    /// and sending the owed share from inside the hook are all turned away by the guard, and the
    /// purchase itself completes.
    function test_theMintHookCannotReachTheMoneyEntryPoints() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        ReentryProbe receiver = new ReentryProbe(fleet);
        usdc.mint(address(receiver), 10 * Q);
        receiver.approveFleet(usdc);
        _buy(fleet, alice);
        _buy(fleet, address(receiver));

        assertTrue(receiver.probed());
        assertTrue(receiver.purchaseRefused(), "buying from the hook was refused");
        assertTrue(receiver.surplusRefused(), "sorting from the hook was refused");
        assertTrue(receiver.sendRefused(), "sending the owed share from the hook was refused");
        assertEq(keys.ownerOf(_key(fleet, 2)), address(receiver), "and the purchase completed");
        assertEq(fleet.totalMinted(), 2);
        assertEq(fleet.surplus(address(usdc)), 0, "with every unit it paid booked");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: the REGENT pool's hook, third-party code, never runs inside a purchase, which
    /// swaps nothing. It runs only inside a piece, once the fleet has handed the piece over, and from
    /// there it can only do what anyone may: sorting a stray transfer and sending the owed share both
    /// go through and leave the fleet's books exact. A purchase from inside a piece is in
    /// KeyfleetRegentBuyer.t.sol.
    function test_theRegentPoolHookRunsOnlyInsideAPieceAndLeavesTheBooksExact() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetTreasury treasury = fleet.TREASURY();
        // With nothing to sort the hook's call reverts, so a hook inside the purchase would stop it.
        poolManager.setHook(address(fleet), abi.encodeCall(KeyfleetManager.recognizeSurplus, (address(usdc))));
        _buy(fleet, alice);
        assertEq(fleet.totalMinted(), 1, "the purchase never reached the pool");

        usdc.mint(address(fleet), Q);
        regentBuyer.convert();
        assertEq(usdc.balanceOf(address(treasury)), Q, "the hook sorted the stray to the treasury");
        assertEq(_treasuryRegent(fleet), _regentFor(Q - Q_PROTOCOL), "and the piece still paid the treasury");
        assertEq(usdc.balanceOf(address(fleet)), fleet.accountedBalance(address(usdc)), "every unit has a purpose");

        poolManager.setHook(address(fleet), abi.encodeCall(KeyfleetManager.sendProtocolShare, ()));
        _buy(fleet, bob);
        uint256 owed = fleet.protocolShareOwed();
        vm.warp(regentBuyer.nextPieceAt());
        regentBuyer.convert();
        assertEq(staking.totalUsdcReceived(), owed, "the hook sent the owed share");
        assertEq(fleet.protocolShareOwed(), 0);
        assertEq(usdc.balanceOf(address(fleet)), fleet.accountedBalance(address(usdc)), "every unit has a purpose");
        assertEq(fleet.pendingConversion(), 0, "and every booked unit became REGENT");
    }

    /// @dev Invariant: after every purchase on every preset, the shared REGENT buyer holds no USDC,
    /// WETH or REGENT, no allowance to it is left behind, and the stand-in PoolManager is owed
    /// nothing either way.
    function test_aPurchaseLeavesNoAllowanceAndNoTokensWithTheRegentBuyer() public {
        for (uint256 p = 0; p < 4; ++p) {
            KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset(p));
            for (uint256 i = 0; i < 6; ++i) {
                _buy(fleet, _wallet(i));
                _assertBalanceInvariant(fleet);
                assertEq(poolManager.delta(address(weth)), 0, "nothing owed in WETH");
                assertEq(poolManager.delta(address(regent)), 0, "nothing owed in REGENT");
                assertEq(weth.balanceOf(address(fleet.TREASURY())), 0, "the treasury receives REGENT, not WETH");
            }
        }
    }

    /// @dev Invariant: because a key is enrolled and the purchase fully booked before it is minted, a
    /// router-style receiver may forward a key on from inside the mint hook. The forwarded key lands
    /// on the destination with its second epoch. A Cascade completion is
    /// booked before the mint, so when the completing key's receiver passes on a level-1 key from
    /// inside the hook, the receiver held that key at completion and the repayment is settled to it.
    function test_aReceiverMayForwardAKeyFromItsMintHook() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetRewards rewards = fleet.REWARDS();
        ForwardingReceiver receiver = new ForwardingReceiver(fleet, keys);
        usdc.mint(address(receiver), 100 * Q);
        receiver.approveFleet(usdc);
        uint256 k1 = _key(fleet, 1);
        uint256 k2 = _key(fleet, 2);
        uint256 k5 = _key(fleet, 5);

        // The key it is handed goes straight on to Alice.
        receiver.setForward(alice, 0);
        assertEq(receiver.buy(), k1);
        assertEq(receiver.observedEpoch(), 1, "the hook already sees the mint epoch");
        assertEq(keys.ownerOf(k1), alice, "the hook forwarded the key it was handed");
        assertEq(keys.ownershipEpoch(k1), 2, "mint then forward is the second epoch");
        assertEq(keys.balanceOf(address(receiver)), 0, "the router holds nothing");

        // Keep the next key, which completes level 1.
        receiver.disableForward();
        assertEq(receiver.buy(), k2);
        assertTrue(fleet.levelCompleted(1));

        _buy(fleet, carol);
        _buy(fleet, _wallet(1));

        // The key that completes level 2 is minted to the router, whose hook passes its level-1 key
        // to Dave after the completion was booked.
        receiver.setForward(dave, k2);
        assertEq(receiver.buy(), k5);
        assertTrue(fleet.levelCompleted(2));

        assertEq(keys.ownerOf(k2), dave, "the level-1 key moved inside the completing purchase");
        assertEq(keys.ownershipEpoch(k2), 2);
        assertEq(rewards.credits(address(usdc), address(receiver)), Q, "the holder at completion was repaid");
        assertEq(rewards.accrued(address(usdc), k2), 0, "and the key carries nothing to Dave");
        assertEq(rewards.accrued(address(usdc), k1), Q, "Alice's level-1 key was repaid too");
        assertEq(keys.ownerOf(k5), address(receiver), "the router kept the key it bought");
        assertEq(keys.ownershipEpoch(k5), 1);
        assertEq(keys.balanceOf(address(receiver)), 1, "the router holds only the key it kept");
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: minting uses the safe path, so a contract that cannot hold ERC721s is not
    /// handed a key.
    function test_mintingToAContractWithoutTheReceiverHookReverts() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(other)));
        fleet.purchase(address(other), 2 * price, block.timestamp, _noProof());
        vm.stopPrank();
    }

    // --- 9. views ---------------------------------------------------------

    /// @dev Invariant: the quote a buyer is shown is the split the purchase actually performs.
    function test_quoteMatchesTheSplitTheNextPurchasePerforms() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);

        // On a fresh Accelerant fleet there is no predecessor, so the quote rebates nothing and
        // sends everything after the protocol share to capital, and the first purchase does exactly that.
        KeyfleetPresets.PurchaseSplit memory first = fleet.quote();
        assertEq(first.rebate, 0, "nothing to rebate before the first key exists");
        assertEq(first.capital, Q - Q_PROTOCOL, "everything after the protocol share is capital");

        uint256 firstPrice = _fundNext(fleet);
        vm.expectEmit(true, true, true, true, address(fleet));
        emit KeyfleetManager.Purchased(_key(fleet, 1), buyer, alice, Q, first.protocol, first.capital, 0, 0);
        vm.prank(buyer);
        fleet.purchase(alice, 2 * firstPrice, block.timestamp, _noProof());

        KeyfleetPresets.PurchaseSplit memory next = fleet.quote();
        uint256 price = _fundNext(fleet);

        assertEq(next.protocol + next.capital + next.reserve + next.rebate, price, "sums to gross");
        assertEq(next.rebate, price - price / 10 - price / 5, "70% rebate");

        uint256 bookedBefore = fleet.pendingConversion();
        vm.expectEmit(true, true, true, true, address(fleet));
        emit KeyfleetManager.Purchased(_key(fleet, 2), buyer, bob, price, next.protocol, next.capital, 0, next.rebate);
        vm.prank(buyer);
        fleet.purchase(bob, 2 * price, block.timestamp, _noProof());
        assertEq(fleet.pendingConversion() - bookedBefore, next.capital, "the quoted capital is booked");
    }

    /// @dev Invariant: level boundaries the fleet reports are the library's, so app, contract and
    /// tests quote one ladder. `levelOf` takes a key number, not a token id.
    function test_levelViewsAgreeWithThePresetLibrary() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);

        assertEq(fleet.levelOf(1), 1);
        assertEq(fleet.levelOf(2), 1);
        assertEq(fleet.levelOf(3), 2);
        assertEq(fleet.levelOf(46_365), 20);
        assertEq(fleet.levelOf(46_366), 21);

        vm.expectRevert(KeyfleetPresets.KeyNumberOutOfBounds.selector);
        fleet.levelOf(0);
    }

    // --- 10. surplus and the protocol share --------------------------------

    /// @dev Invariant: the owed protocol share stays USDC in the manager until anyone sends it, and
    /// then goes whole into REGENT revenue staking through the fleet's treasury, tagged with the
    /// manager, leaving no USDC and no allowance behind. Nothing owed refuses a send.
    function test_sendProtocolShareDepositsTheWholeOwedShareIntoStaking() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetTreasury treasury = fleet.TREASURY();
        _buy(fleet, alice);
        _buy(fleet, bob);
        _buy(fleet, carol);
        uint256 owed = fleet.protocolShareOwed();
        uint256 reserve = fleet.cascadeReserve();
        assertGt(reserve, 0, "a reserve is held while the share is sent");

        vm.expectEmit(true, true, true, true, address(fleet));
        emit KeyfleetManager.ProtocolShareSent(erin, owed);
        vm.prank(erin);
        assertEq(fleet.sendProtocolShare(), owed);

        assertEq(staking.totalUsdcReceived(), owed, "the whole share reached staking");
        assertEq(staking.lastSourceRef(), bytes32(uint256(uint160(address(fleet)))), "tagged with the manager");
        assertEq(fleet.protocolShareOwed(), 0);
        assertEq(usdc.balanceOf(address(fleet)), reserve + fleet.pendingConversion(), "the reserve was not touched");
        assertEq(usdc.balanceOf(address(treasury)), 0, "the treasury passed it straight on");
        assertEq(usdc.allowance(address(treasury), address(staking)), 0);

        vm.expectRevert(KeyfleetManager.ZeroAmount.selector);
        fleet.sendProtocolShare();
    }

    /// @dev Invariant: only a fleet's own manager may deposit its protocol share through its treasury.
    function test_onlyTheManagerDepositsTheProtocolShareThroughItsTreasury() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager otherFleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetTreasury treasury = fleet.TREASURY();
        address[2] memory callers = [alice, address(otherFleet)];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(KeyfleetTreasury.OnlyManager.selector);
            treasury.depositProtocolShare(1);
        }
    }

    /// @dev Invariant: only what nobody has a claim on is surplus. Stray USDC and stray tokens are
    /// forwarded whole and unswapped to the treasury, the reserve and the owed share stay, and a
    /// zero surplus is a quiet no-op.
    function test_recognizeSurplusForwardsOnlyUnaccountedTokensUnswapped() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        address treasury = address(fleet.TREASURY());
        _buy(fleet, alice);
        uint256 reserve = fleet.cascadeReserve();
        uint256 owed = fleet.protocolShareOwed();
        usdc.mint(address(fleet), 7e6);
        other.mint(address(fleet), 5e6);

        assertEq(fleet.accountedBalance(address(usdc)), reserve + owed);
        assertEq(fleet.accountedBalance(address(other)), 0);
        assertEq(fleet.surplus(address(usdc)), 7e6);

        vm.expectEmit(true, true, true, true, address(fleet));
        emit KeyfleetManager.ForwardedToTreasury(address(usdc), erin, 7e6);
        vm.prank(erin);
        assertEq(fleet.recognizeSurplus(address(usdc)), 7e6);
        assertEq(usdc.balanceOf(treasury), 7e6, "stray USDC arrives as USDC");
        assertEq(regent.balanceOf(treasury), 0, "nothing was swapped");
        assertEq(fleet.cascadeReserve(), reserve, "the reserve stays");
        assertEq(fleet.protocolShareOwed(), owed, "and so does the owed share");
        assertEq(usdc.balanceOf(address(fleet)), reserve + owed);

        vm.prank(erin);
        assertEq(fleet.recognizeSurplus(address(other)), 5e6);
        assertEq(other.balanceOf(treasury), 5e6);

        vm.recordLogs();
        assertEq(fleet.recognizeSurplus(address(usdc)), 0, "nothing more to forward");
        assertEq(vm.getRecordedLogs().length, 0, "and nothing is announced");
    }

    // --- 11. open fleets: prices from the starting price -------------------

    /// @dev Invariant: an open Classic fleet's creator pays the starting price for key 1, and every
    /// later key costs today's table scaled to that start, rounded up to the cent.
    function test_openClassicPricesFollowTheTableScaledToTheStartingPrice() public {
        uint256 start = 12_340_000;
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, start);
        assertEq(fleet.START_PRICE(), start);
        assertEq(fleet.totalMinted(), 1);
        assertEq(keys.ownerOf(_key(fleet, 1)), creator, "the creator bought key 1");
        assertEq(fleet.protocolShareOwed(), start / 10, "at the starting price");

        for (uint256 n = 2; n <= 40; ++n) {
            assertEq(fleet.nextPrice(), KeyfleetPresets.classicPrice(n, start), "the scaled table");
            _buy(fleet, _wallet(n));
        }
        assertGt(KeyfleetPresets.classicPrice(40, start), KeyfleetPresets.classicPrice(40, CLASSIC_START));
        _assertBalanceInvariant(fleet);
    }

    /// @dev Invariant: an open Syndicate or Cascade fleet's level 1 costs the starting price and each
    /// later level 20% more, rounded up; a Cascade completion repays the creator's key its whole
    /// starting price.
    function test_openFibonacciLevelsStartFromTheStartingPrice() public {
        uint256 start = 25e6;
        KeyfleetPresets.Preset[2] memory fibonacci =
            [KeyfleetPresets.Preset.FibonacciSyndicate, KeyfleetPresets.Preset.FibonacciCascade];
        for (uint256 p = 0; p < 2; ++p) {
            KeyfleetManager fleet = _createOpen(fibonacci[p], start);
            for (uint256 n = 2; n <= KeyfleetPresets.fibonacciLevelEnd(4); ++n) {
                uint256 level = KeyfleetPresets.fibonacciLevelOf(n);
                assertEq(fleet.nextPrice(), KeyfleetPresets.fibonacciLevelPrice(level, start), "the scaled ladder");
                _buy(fleet, _wallet(n));
            }
            _assertBalanceInvariant(fleet);
            if (fibonacci[p] == KeyfleetPresets.Preset.FibonacciCascade) {
                assertEq(fleet.levelGrossPaid(1), 2 * start);
                assertEq(fleet.REWARDS().accrued(address(usdc), _key(fleet, 1)), start, "the creator is repaid");
            }
        }
    }

    /// @dev Invariant: an open Accelerant fleet's key 1 costs the starting price and each later key
    /// 5% more, and the creator is rebated on key 2 like any holder of a preceding key.
    function test_openAccelerantStepsFivePercentPerKeyFromTheStartingPrice() public {
        uint256 start = 20e6;
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechAccelerant, start);
        assertEq(fleet.nextPrice(), 21e6, "key 2 costs 5% more");

        _buy(fleet, alice);
        assertEq(fleet.REWARDS().credits(address(usdc), creator), 21e6 - 2_100_000 - 4_200_000, "70% to the creator");
        for (uint256 i = 2; i < 12; ++i) {
            assertEq(fleet.nextPrice(), KeyfleetPresets.accelerantPrice(i, start, STEP), "the scaled ladder");
            _buy(fleet, _wallet(i));
        }
        _assertBalanceInvariant(fleet);
    }

    // --- 12. joining requirements -----------------------------------------

    /// @dev Invariant: an address on the creator's list buys with its own proof of OpenZeppelin's
    /// standard double-hashed leaf.
    function test_anAddressOnTheListBuysWithItsProof() public {
        (bytes32 root, bytes32[][4] memory proofs) = _list();
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, _listOnly(root));

        assertTrue(fleet.meetsRequirements(alice, proofs[0]));
        assertTrue(fleet.meetsRequirements(carol, proofs[2]));
        uint256 tokenId = _buyWith(fleet, alice, alice, proofs[0]);
        assertEq(keys.ownerOf(tokenId), alice);
        tokenId = _buyWith(fleet, carol, carol, proofs[2]);
        assertEq(keys.ownerOf(tokenId), carol);
    }

    /// @dev Invariant: an address off the list, a missing proof, or another member's proof is refused
    /// before any USDC moves.
    function test_aMissingWrongOrBorrowedProofIsRefused() public {
        (bytes32 root, bytes32[][4] memory proofs) = _list();
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, _listOnly(root));

        _expectRefused(fleet, erin, erin, proofs[0], erin);
        _expectRefused(fleet, alice, alice, _noProof(), alice);
        _expectRefused(fleet, alice, alice, proofs[1], alice);
        bytes32[] memory leafAsProof = new bytes32[](1);
        leafAsProof[0] = _leaf(bob);
        _expectRefused(fleet, alice, alice, leafAsProof, alice);
        assertFalse(fleet.meetsRequirements(erin, proofs[0]));
        assertEq(fleet.totalMinted(), 1, "only the creator's key exists");
        assertEq(
            usdc.balanceOf(address(fleet)),
            fleet.protocolShareOwed() + fleet.pendingConversion(),
            "no refused USDC arrived"
        );
    }

    /// @dev Invariant: holding at least one token of the named collection qualifies, read live at
    /// each purchase.
    function test_holdingAnNftQualifies() public {
        MockPassNft pass = new MockPassNft();
        pass.mint(alice, 1);
        KeyfleetManager.Requirements memory req;
        req.nft = address(pass);
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, req);

        _buyWith(fleet, alice, alice, _noProof());
        _expectRefused(fleet, bob, bob, _noProof(), bob);

        vm.prank(alice);
        pass.transferFrom(alice, bob, 1);
        _buyWith(fleet, bob, bob, _noProof());
        _expectRefused(fleet, alice, alice, _noProof(), alice);
    }

    /// @dev Invariant: holding at least `tokenMin` of the named token qualifies, and one unit less
    /// does not.
    function test_holdingEnoughOfATokenQualifies() public {
        MockToken pass = new MockToken("Pass", "PASS");
        pass.mint(alice, 5e6);
        pass.mint(bob, 5e6 - 1);
        KeyfleetManager.Requirements memory req;
        req.token = address(pass);
        req.tokenMin = 5e6;
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, req);

        _buyWith(fleet, alice, alice, _noProof());
        _expectRefused(fleet, bob, bob, _noProof(), bob);
    }

    /// @dev Invariant: with several requirements set, meeting any one of them is enough, and meeting
    /// none is refused.
    function test_meetingAnyOneRequirementIsEnough() public {
        (bytes32 root, bytes32[][4] memory proofs) = _list();
        MockPassNft nft = new MockPassNft();
        MockToken token = new MockToken("Pass", "PASS");
        nft.mint(erin, 1);
        token.mint(address(0xF00D), 3e6);
        KeyfleetManager.Requirements memory req =
            KeyfleetManager.Requirements({merkleRoot: root, nft: address(nft), token: address(token), tokenMin: 3e6});
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, req);

        _buyWith(fleet, alice, alice, proofs[0]);
        _buyWith(fleet, erin, erin, _noProof());
        _buyWith(fleet, address(0xF00D), address(0xF00D), _noProof());
        _expectRefused(fleet, address(0xBAD), address(0xBAD), _noProof(), address(0xBAD));
        _expectRefused(fleet, address(0xBAD), address(0xBAD), proofs[0], address(0xBAD));
        assertEq(fleet.totalMinted(), 4);
    }

    /// @dev Invariant: the requirement is checked against the wallet receiving the key, never the
    /// one paying: a qualified payer cannot buy for an unqualified wallet, an unqualified payer may
    /// buy for a qualified one, and with no receiver named the payer is the receiver.
    function test_theReceiverIsCheckedNotThePayer() public {
        (bytes32 root, bytes32[][4] memory proofs) = _list();
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, _listOnly(root));

        uint256 tokenId = _buyWith(fleet, buyer, alice, proofs[0]);
        assertEq(keys.ownerOf(tokenId), alice, "an unlisted payer bought for a listed wallet");

        _expectRefused(fleet, alice, erin, proofs[0], erin);

        tokenId = _buyWith(fleet, bob, address(0), proofs[1]);
        assertEq(keys.ownerOf(tokenId), bob, "no receiver means the payer, who is checked");
        _expectRefused(fleet, erin, address(0), proofs[0], erin);
    }

    /// @dev Invariant: a requirement contract that reverts, answers with too little data or answers
    /// nothing counts as not met.
    function test_aRequirementContractThatRevertsOrAnswersBadlyCountsAsNotMet() public {
        address[3] memory hostile =
            [address(new RevertingBalance()), address(new ShortAnswer()), address(new SilentAnswer())];
        for (uint256 i = 0; i < hostile.length; ++i) {
            KeyfleetManager.Requirements memory asNft;
            asNft.nft = hostile[i];
            KeyfleetManager nftFleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, asNft);
            assertFalse(nftFleet.meetsRequirements(alice, _noProof()));
            _expectRefused(nftFleet, alice, alice, _noProof(), alice);

            KeyfleetManager.Requirements memory asToken;
            asToken.token = hostile[i];
            asToken.tokenMin = 1;
            KeyfleetManager tokenFleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, asToken);
            assertFalse(tokenFleet.meetsRequirements(alice, _noProof()));
            _expectRefused(tokenFleet, alice, alice, _noProof(), alice);
        }
    }

    /// @dev Invariant: a requirement contract that tries to write state counts as not met and
    /// cannot change state during the check, given gas enough to survive the failed call.
    function test_aRequirementContractThatWritesStateCountsAsNotMetAndWritesNothing() public {
        StatefulBalance stateful = new StatefulBalance();
        KeyfleetManager.Requirements memory req;
        req.nft = address(stateful);
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, req);

        assertFalse(fleet.meetsRequirements{gas: 5_000_000}(alice, _noProof()));
        assertEq(stateful.calls(), 0, "the read-only check wrote nothing");
    }

    /// @dev Invariant: a requirement contract that burns every unit of gas it is given spends at
    /// most `REQUIREMENT_READ_GAS`, so a buyer who meets another requirement, checked after it, buys
    /// on the same gas budget as on a fleet naming only that requirement.
    function test_aGasBurningRequirementCannotStarveABuyerWhoMeetsAnother() public {
        MockToken pass = new MockToken("Pass", "PASS");
        pass.mint(alice, 1e6);

        KeyfleetManager.Requirements memory tokenOnly;
        tokenOnly.token = address(pass);
        tokenOnly.tokenMin = 1e6;
        KeyfleetManager control = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, tokenOnly);

        KeyfleetManager.Requirements memory both = tokenOnly;
        both.nft = address(new StatefulBalance());
        KeyfleetManager burning = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, both);

        uint256 budget = 2_000_000;
        assertTrue(_tryBuy(control, alice, budget), "the budget buys where only the token is named");
        assertTrue(_tryBuy(burning, alice, budget), "and buys behind the burning collection");

        uint256 before = gasleft();
        burning.meetsRequirements(bob, _noProof());
        assertLt(before - gasleft(), burning.REQUIREMENT_READ_GAS() + 30_000, "the burn is capped");
    }

    /// @dev Invariant: a requirement contract answers with as much data as it likes, but only its
    /// first word is read and nothing more is copied, so a long answer costs the buyer no more than
    /// a short one.
    function test_aLongRequirementAnswerIsReadByItsFirstWordOnly() public {
        KeyfleetManager.Requirements memory req;
        req.nft = address(new LongAnswer());
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, req);

        assertTrue(fleet.meetsRequirements(alice, _noProof()), "a balance of one is held");
        assertTrue(_tryBuy(fleet, alice, 2_000_000), "and buys on a normal budget");
    }

    /// @dev Buys the next key of `fleet` for `payer` with at most `gasBudget` gas, and says whether
    /// it went through.
    function _tryBuy(KeyfleetManager fleet, address payer, uint256 gasBudget) private returns (bool ok) {
        uint256 price = fleet.nextPrice();
        usdc.mint(payer, price);
        vm.startPrank(payer);
        usdc.approve(address(fleet), price);
        bytes memory data = abi.encodeCall(KeyfleetManager.purchase, (payer, price, block.timestamp, _noProof()));
        (ok,) = address(fleet).call{gas: gasBudget}(data);
        vm.stopPrank();
    }

    /// @dev Invariant: a hostile requirement only stops its own part; a buyer meeting another part
    /// still buys.
    function test_aHostileRequirementDoesNotBlockAnotherPart() public {
        (bytes32 root, bytes32[][4] memory proofs) = _list();
        KeyfleetManager.Requirements memory req = _listOnly(root);
        req.nft = address(new RevertingBalance());
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, req);

        _buyWith(fleet, dave, dave, proofs[3]);
        _expectRefused(fleet, erin, erin, _noProof(), erin);
    }

    /// @dev Invariant: requirements are checked only when buying from the fleet: a key bought by a
    /// qualified wallet may be sold or given to anyone, and on from there.
    function test_resalesAndTransfersAreNeverChecked() public {
        (bytes32 root, bytes32[][4] memory proofs) = _list();
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6, _listOnly(root));
        uint256 tokenId = _buyWith(fleet, alice, alice, proofs[0]);

        vm.prank(alice);
        keys.transferFrom(alice, erin, tokenId);
        vm.prank(erin);
        keys.safeTransferFrom(erin, address(0xBAD), tokenId);
        assertEq(keys.ownerOf(tokenId), address(0xBAD), "an unlisted wallet holds the key");
        assertFalse(fleet.meetsRequirements(address(0xBAD), _noProof()));
    }

    /// @dev Invariant: the creator's own key 1 is not checked against the fleet's requirements.
    function test_theCreatorsKeyOneIsNotChecked() public {
        (bytes32 root,) = _list();
        MockToken token = new MockToken("Pass", "PASS");
        KeyfleetManager.Requirements memory req =
            KeyfleetManager.Requirements({merkleRoot: root, nft: address(0), token: address(token), tokenMin: 1});
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FibonacciSyndicate, 10e6, req);

        assertFalse(fleet.meetsRequirements(creator, _noProof()), "the creator meets none of them");
        assertEq(keys.ownerOf(_key(fleet, 1)), creator, "and still holds key 1");
        _expectRefused(fleet, creator, creator, _noProof(), creator);
    }

    // --- 13. profile ------------------------------------------------------

    /// @dev Invariant: the fleet's own treasury, carrying out an approved proposal of its keys,
    /// changes the profile; the manager announces it and the collection refreshes every key of the
    /// fleet, and no other fleet.
    function test_theFleetsOwnTreasuryChangesItsProfileThroughAnApprovedProposal() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _buy(fleet, alice);
        _mature();
        KeyfleetManager.Profile memory next = KeyfleetManager.Profile({
            name: "Night Fleet", description: "Keys that keep watch.", imageLink: "https://media.regents.sh/ipfs/night"
        });
        KeyfleetTreasury.Call[] memory calls = _setProfileCall(fleet, next);
        uint256 id = _pass(fleet, calls);
        KeyfleetVotes votes = fleet.VOTES();
        uint256 lastId = keys.tokenIdOf(fleet.FLEET_ID(), type(uint32).max);
        uint256 firstId = _key(fleet, 1);

        vm.expectEmit(true, true, true, true, address(fleet));
        emit KeyfleetManager.ProfileChanged(next.name, next.description, next.imageLink);
        vm.expectEmit(true, true, true, true, address(keys));
        emit IERC4906.BatchMetadataUpdate(firstId, lastId);
        votes.execute(id, calls);

        KeyfleetManager.Profile memory stored = fleet.profile();
        assertEq(stored.name, next.name);
        assertEq(stored.description, next.description);
        assertEq(stored.imageLink, next.imageLink);
        assertEq(KeyfleetManager(keys.managerOf(2)).profile().name, "Founding fleet", "no other fleet changed");
    }

    /// @dev Invariant: nobody but the fleet's own treasury sets its profile: not a holder, the Safe,
    /// the keeper, the factory, the fleet's own controller, the collection, or another fleet's
    /// treasury, even carrying out that fleet's approved proposal.
    function test_onlyTheFleetsOwnTreasurySetsItsProfile() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetManager otherFleet = _deploy(KeyfleetPresets.Preset.FibonacciSyndicate);
        KeyfleetManager.Profile memory next = _profile("Hijacked");

        address[7] memory callers = [
            alice, safe, keeper, address(factory), address(fleet.VOTES()), address(keys), address(otherFleet.TREASURY())
        ];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(KeyfleetManager.OnlyTreasury.selector);
            fleet.setProfile(next);
        }

        _buy(otherFleet, bob);
        _mature();
        _openTreasury(otherFleet);
        KeyfleetTreasury.Call[] memory calls = _setProfileCall(fleet, next);
        uint256 id = _pass(otherFleet, calls);
        KeyfleetVotes otherVotes = otherFleet.VOTES();
        vm.warp(otherVotes.executableAt(id));
        vm.expectRevert(KeyfleetManager.OnlyTreasury.selector);
        otherVotes.execute(id, calls);
        assertEq(fleet.profile().name, "Founding fleet", "the profile is unchanged");
    }

    /// @dev Invariant: a name is 1 to 100 bytes, a description up to 2,000 and an image link up to
    /// 512; each limit is accepted exactly and refused one byte over.
    function test_profileLimitsAreOneHundredTwoThousandAndFiveHundredTwelveBytes() public {
        KeyfleetManager fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        address treasury = address(fleet.TREASURY());

        KeyfleetManager.Profile memory atLimits = KeyfleetManager.Profile({
            name: string(new bytes(100)), description: string(new bytes(2000)), imageLink: string(new bytes(512))
        });
        vm.prank(treasury);
        fleet.setProfile(atLimits);
        assertEq(bytes(fleet.profile().description).length, 2000);

        KeyfleetManager.Profile memory smallest = KeyfleetManager.Profile({name: "K", description: "", imageLink: ""});
        vm.prank(treasury);
        fleet.setProfile(smallest);
        assertEq(fleet.profile().name, "K");

        KeyfleetManager.Profile[4] memory bad = [
            KeyfleetManager.Profile({name: "", description: "", imageLink: ""}),
            KeyfleetManager.Profile({name: string(new bytes(101)), description: "", imageLink: ""}),
            KeyfleetManager.Profile({name: "K", description: string(new bytes(2001)), imageLink: ""}),
            KeyfleetManager.Profile({name: "K", description: "", imageLink: string(new bytes(513))})
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(treasury);
            vm.expectRevert(KeyfleetManager.ProfileInvalid.selector);
            fleet.setProfile(bad[i]);
        }
        assertEq(fleet.profile().name, "K", "a refused profile changes nothing");
    }

    // --- 14. gas ----------------------------------------------------------

    /// @dev Makes every account and slot a purchase reads cold again, as it is at the start of the
    /// buyer's own transaction, so a measurement is not flattered by the test's earlier reads.
    function _coolPurchasePath(KeyfleetManager fleet, address receiver) private {
        vm.cool(address(fleet));
        vm.cool(address(fleet.REWARDS()));
        vm.cool(address(fleet.VOTES()));
        vm.cool(address(fleet.TREASURY()));
        vm.cool(address(keys));
        vm.cool(address(usdc));
        vm.cool(address(vrf));
        vm.cool(address(regentBuyer));
        vm.cool(address(v3Pool));
        vm.cool(address(poolManager));
        vm.cool(address(weth));
        vm.cool(address(regent));
        vm.cool(receiver);
    }

    /// @dev Measures the first purchase of `level` on a founding fleet, with the mint count written
    /// to the key before the level's first. Each measurement starts from the same state, before
    /// any fleet exists, and the state is put back afterwards, so the order of measurements does
    /// not matter. Every accounting slot the purchase touches, the owed
    /// protocol share included, is written from zero, and every account it touches starts cold.
    function _measureFirstPurchase(KeyfleetPresets.Preset preset, uint256 level) private returns (uint256 used) {
        uint256 snapshot = vm.snapshotState();
        KeyfleetManager fleet = _deploy(preset);
        if (level > 1) {
            uint256 before_ = KeyfleetPresets.fibonacciLevelStart(level) - 1;
            fleetStore.target(address(fleet)).sig("totalMinted()").checked_write(before_);
        }

        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        bytes32[] memory proof = _noProof();
        _coolPurchasePath(fleet, alice);
        uint256 before = gasleft();
        fleet.purchase(alice, 2 * price, block.timestamp, proof);
        used = before - gasleft();
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    /// @dev The execution-gas ceiling covers the first purchase on a founding fleet, with every
    /// account it touches starting cold. A Fibonacci purchase walks the levels up to its own a few
    /// times, so its cost grows slowly with the level; it is measured at levels 1, 30 and 40. Level 1
    /// is the dearer of 1 and 30 only because its purchase writes the mint count from zero, which
    /// the later levels, whose count is written beforehand, do not. The treasury's part is swapped
    /// for REGENT in the purchase, so a purchase that swaps costs more than one that does not: a
    /// Syndicate key, which always swaps, costs more than a Cascade key that only adds to the
    /// reserve. Every sale also schedules its key's automatic presence in the fleet's voting
    /// controller, writing the key's waiting entry, its first checkpoint and the presence revision,
    /// and the collection records its mint time; those writes are a large part of every first
    /// purchase. The costliest first purchase is the founding Accelerant fleet's key 1, and the
    /// ceiling is that figure plus twenty percent, rounded up to the nearest
    /// thousand. Measured against stand-in USDC, pools and VRF coordinator, so it is a regression
    /// bound on the fleet's own work, not the figure to publish: the figures to publish are
    /// measured on a fork of Base. The level-completing Cascade purchase, which also swaps, is
    /// measured alongside it.
    function test_purchaseGasStaysUnderTheCeiling() public {
        uint256 cascade = _measureFirstPurchase(KeyfleetPresets.Preset.FibonacciCascade, 1);
        uint256 cascade30 = _measureFirstPurchase(KeyfleetPresets.Preset.FibonacciCascade, 30);
        uint256 cascade40 = _measureFirstPurchase(KeyfleetPresets.Preset.FibonacciCascade, 40);
        uint256 syndicate40 = _measureFirstPurchase(KeyfleetPresets.Preset.FibonacciSyndicate, 40);
        uint256 syndicate = _measureFirstPurchase(KeyfleetPresets.Preset.FibonacciSyndicate, 1);
        uint256 accelerant = _measureFirstPurchase(KeyfleetPresets.Preset.FleetTechAccelerant, 1);
        uint256 classic = _measureFirstPurchase(KeyfleetPresets.Preset.FleetTechClassic, 1);

        console2.log("first purchase gas, Cascade level 1:", cascade);
        console2.log("first purchase gas, Cascade level 30:", cascade30);
        console2.log("first purchase gas, Cascade level 40:", cascade40);
        console2.log("first purchase gas, Syndicate level 1:", syndicate);
        console2.log("first purchase gas, Syndicate level 40:", syndicate40);
        console2.log("first purchase gas, Accelerant:", accelerant);
        console2.log("first purchase gas, Classic:", classic);

        uint256[7] memory measured = [cascade, cascade30, cascade40, syndicate, syndicate40, accelerant, classic];
        for (uint256 i = 0; i < measured.length; ++i) {
            assertLt(measured[i], PURCHASE_GAS_CEILING, "every first purchase stays under the ceiling");
        }
        assertGt(cascade40, cascade30, "a higher level costs a little more");
        assertGt(syndicate40, cascade40, "a purchase that swaps costs more than one that reserves");
        assertGt(syndicate, cascade);

        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        _buy(fleet, alice);
        _buy(fleet, bob);
        _buy(fleet, carol);
        _buy(fleet, dave);
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        bytes32[] memory proof = _noProof();
        _coolPurchasePath(fleet, _wallet(9));
        uint256 before = gasleft();
        fleet.purchase(_wallet(9), 2 * price, block.timestamp, proof);
        uint256 completing = before - gasleft();
        vm.stopPrank();

        console2.log("Cascade level-completing purchase gas:", completing);
        assertTrue(fleet.levelCompleted(2));
        assertLt(completing, PURCHASE_GAS_CEILING, "the completing purchase stays under it too");
    }

    // --- 15. fuzz invariant -----------------------------------------------

    /// @dev Invariant: across random purchase and transfer sequences on any preset, the fleet's
    /// USDC balance is always exactly its Cascade reserve plus the protocol share owed to staking,
    /// the treasury's part has all arrived as REGENT, and the REGENT buyer is left holding nothing.
    function testFuzz_usdcBalanceAlwaysEqualsReservePlusOwedShare(uint256 seed) public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset(seed % 4));
        usdc.mint(buyer, 1e30);
        vm.prank(buyer);
        usdc.approve(address(fleet), type(uint256).max);

        for (uint256 i = 0; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address wallet = _wallet(seed % 8);
            uint256 minted = fleet.totalMinted();

            if (minted == 0 || seed % 3 != 0) {
                vm.prank(buyer);
                try fleet.purchase(wallet, type(uint256).max, block.timestamp, _noProof()) returns (uint256) {} catch {}
            } else {
                uint256 tokenId = _key(fleet, ((seed >> 16) % minted) + 1);
                address owner = keys.ownerOf(tokenId);
                vm.prank(owner);
                try keys.transferFrom(owner, wallet, tokenId) {} catch {}
            }

            _assertBalanceInvariant(fleet);
            assertEq(usdc.balanceOf(address(v3Pool)), 0, "no purchase swaps");
        }

        assertGt(fleet.totalMinted(), 0, "the sequence bought at least one key");
    }
}
