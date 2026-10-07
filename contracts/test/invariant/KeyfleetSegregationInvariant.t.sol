// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetShards} from "../../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {IRegentsAutolaunchFactoryV2} from "../../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {MockAutolaunchFactory, MockLaunchToken} from "../mocks/MockAutolaunchFactory.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {KeyfleetFixture} from "../helpers/KeyfleetFixture.sol";

/// @dev Hands each fleet's treasury random batches of calls exactly as a carried-out proposal
/// would, aimed at the fleet's manager, controller, treasury and ledger, at the shared collection,
/// shard record, factory and REGENT buyer, at USDC and REGENT, at Autolaunch and at the fleet's own
/// token once bound, between purchases that each mint to a wallet of their own and, partway through,
/// a launch that sells and is bound. Around every batch it records whether anything protected went
/// down: the manager's owed protocol share, its Cascade reserve outside a level completion, a
/// wallet's credit in the ledger, or the unsettled accrual of a key the treasury does not hold, in
/// USDC, in REGENT and in the bound token.
contract SegregationHandler is Test {
    address internal constant NATIVE = address(0);

    uint256 internal constant MAX_KEYS = 60;

    /// @dev How many calls the menu holds.
    uint256 internal constant MENU = 33;

    KeyfleetManager[2] internal fleets;
    KeyfleetKeys internal immutable keys;
    KeyfleetShards internal immutable shards;
    KeyfleetFactory internal immutable factory;
    KeyfleetRegentBuyer internal immutable regentBuyer;
    IERC20 internal immutable usdc;
    IERC20 internal immutable regent;
    MockAutolaunchFactory internal immutable autolaunch;
    address internal buyer = address(0xB0B0B0);

    /// @notice Set, with the reason, the first time a batch lowered something protected.
    string public breach;

    constructor(
        KeyfleetManager cascade,
        KeyfleetManager accelerant,
        KeyfleetFactory factory_,
        MockAutolaunchFactory autolaunch_
    ) {
        fleets = [cascade, accelerant];
        factory = factory_;
        keys = factory_.KEYS();
        shards = factory_.SHARDS();
        regentBuyer = factory_.REGENT_BUYER();
        usdc = factory_.USDC();
        regent = factory_.REGENT();
        autolaunch = autolaunch_;
    }

    /// @notice The wallet a purchase of key `tokenId` mints to, one per key so that no Fibonacci
    /// holding limit is ever met.
    function holderOf(uint256 tokenId) public pure returns (address) {
        return address(uint160(0xA0000 + tokenId));
    }

    function buy(uint256 fleetSeed) external {
        KeyfleetManager fleet = fleets[fleetSeed % 2];
        if (fleet.totalMinted() >= MAX_KEYS) return;
        uint256 price = fleet.nextPrice();
        MockToken(address(usdc)).mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        fleet.purchase(_holderOfKey(fleet, fleet.totalMinted() + 1), price, block.timestamp, new bytes32[](0));
        vm.stopPrank();
    }

    function fundEth(uint256 fleetSeed, uint256 amount) external {
        vm.deal(address(fleets[fleetSeed % 2].TREASURY()), bound(amount, 0, 10 ether));
    }

    /// @dev Before the fleet has a token: an approved call launches one naming its treasury, the
    /// launch sells and anyone binds it. After: the launch's escrow releases vested tokens to the
    /// treasury.
    function launchOrRelease(uint256 fleetSeed, uint256 amount) external {
        KeyfleetManager fleet = fleets[fleetSeed % 2];
        KeyfleetTreasury treasury = fleet.TREASURY();
        IERC20 token = treasury.launchToken();
        if (address(token) == address(0)) {
            uint256 id = autolaunch.nextLaunchId();
            KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](1);
            calls[0] = _launchCall(treasury);
            vm.prank(address(fleet.VOTES()));
            treasury.executeBatch(calls);
            autolaunch.graduate(id);
            treasury.bindLaunchToken(id);
            token = treasury.launchToken();
        }
        MockLaunchToken(address(token)).mint(address(treasury), bound(amount, 0, 1_000_000e18));
    }

    function approvedBatch(uint256 fleetSeed, uint256[2] calldata seeds, uint256 length) external {
        KeyfleetManager fleet = fleets[fleetSeed % 2];
        uint256 minted = fleet.totalMinted();
        if (minted == 0) return;
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](bound(length, 1, 2));
        for (uint256 i = 0; i < calls.length; ++i) {
            calls[i] = _call(fleet, seeds[i]);
        }

        uint256 owed = fleet.protocolShareOwed();
        uint256 reserve = fleet.cascadeReserve();
        (uint256[] memory credited, uint256[] memory accrued) = _ledger(fleet, minted);

        address treasury = address(fleet.TREASURY());
        vm.prank(address(fleet.VOTES()));
        (bool carriedOut,) = treasury.call(abi.encodeCall(KeyfleetTreasury.executeBatch, (calls)));
        if (!carriedOut) return;

        if (fleet.protocolShareOwed() < owed) _breach("the owed protocol share went down");
        if (fleet.cascadeReserve() < reserve && fleet.totalMinted() == minted) {
            _breach("the Cascade reserve went down without a level completing");
        }
        (uint256[] memory creditedAfter, uint256[] memory accruedAfter) = _ledger(fleet, minted);
        for (uint256 i = 0; i < credited.length; ++i) {
            if (creditedAfter[i] < credited[i]) _breach("a wallet's credit went down");
            if (accruedAfter[i] < accrued[i]) _breach("a key's accrual went down");
        }
    }

    /// @dev Each first holder's credit, and each key's unsettled accrual, zero for a key the
    /// treasury holds, whose owner may move it: in USDC, in REGENT, then in the bound token, if any.
    function _ledger(KeyfleetManager fleet, uint256 minted)
        internal
        view
        returns (uint256[] memory credited, uint256[] memory accrued)
    {
        KeyfleetRewards rewards = fleet.REWARDS();
        address[3] memory assets = [address(usdc), address(regent), address(fleet.TREASURY().launchToken())];
        credited = new uint256[](3 * minted);
        accrued = new uint256[](3 * minted);
        for (uint256 a = 0; a < 3; ++a) {
            if (assets[a] == address(0)) continue;
            for (uint256 i = 0; i < minted; ++i) {
                uint256 tokenId = keys.tokenIdOf(fleet.FLEET_ID(), i + 1);
                credited[a * minted + i] = rewards.credits(assets[a], holderOf(tokenId));
                if (keys.ownerOf(tokenId) != address(fleet.TREASURY())) {
                    accrued[a * minted + i] = rewards.accrued(assets[a], tokenId);
                }
            }
        }
    }

    function _holderOfKey(KeyfleetManager fleet, uint256 keyNumber) internal view returns (address) {
        return holderOf(keys.tokenIdOf(fleet.FLEET_ID(), keyNumber));
    }

    function _breach(string memory reason) internal {
        if (bytes(breach).length == 0) breach = reason;
    }

    /// @dev What one menu call is aimed at and with, drawn from a seed.
    struct Draw {
        KeyfleetManager fleet;
        KeyfleetTreasury treasury;
        KeyfleetRewards rewards;
        uint256 arg;
        uint256 tokenId;
        address someone;
        IERC20 token;
        uint256 amount;
    }

    /// @dev One call from a menu reaching every contract of the fleet, the shared contracts, USDC,
    /// REGENT or the bound token, and Autolaunch, with arguments drawn from `seed`: payments and
    /// advances, raw token moves and approvals, purchases, surplus and the protocol share, key
    /// transfers, every ledger entry point, the controller's, the manager's and the collection's,
    /// the shard record's, the factory's and the REGENT buyer's, the treasury's own, the daily
    /// split and its rate and binding a launch included, and a new launch.
    function _call(KeyfleetManager fleet, uint256 seed) internal view returns (KeyfleetTreasury.Call memory) {
        Draw memory d;
        d.fleet = fleet;
        d.treasury = fleet.TREASURY();
        d.rewards = fleet.REWARDS();
        d.arg = uint256(keccak256(abi.encode(seed)));
        d.tokenId = keys.tokenIdOf(fleet.FLEET_ID(), 1 + d.arg % fleet.totalMinted());
        d.someone = d.arg % 4 == 0 ? holderOf(d.tokenId) : address(uint160(d.arg));
        IERC20 launched = d.treasury.launchToken();
        uint256 tokenPick = (d.arg >> 8) % 3;
        d.token = tokenPick == 2 && address(launched) != address(0) ? launched : tokenPick == 1 ? regent : usdc;
        d.amount = d.arg % (d.token.balanceOf(address(d.treasury)) + 2);
        uint256 pick = seed % MENU;
        if (pick < 9) return _moneyCall(d, pick);
        if (pick < 26) return _contractCall(d, pick);
        return _sharedCall(d, pick);
    }

    function _moneyCall(Draw memory d, uint256 pick) internal view returns (KeyfleetTreasury.Call memory) {
        address treasury = address(d.treasury);
        address[5] memory targets =
            [address(d.fleet), address(d.rewards), address(d.fleet.VOTES()), treasury, address(regentBuyer)];
        address token = address(d.token);
        if (pick == 0) return _c(treasury, 0, abi.encodeCall(d.treasury.pay, (token, d.someone, d.amount)));
        if (pick == 1) return _c(treasury, 0, abi.encodeCall(d.treasury.pay, (NATIVE, d.someone, d.arg % 2 ether)));
        if (pick == 2) {
            return _c(
                treasury, 0, abi.encodeCall(d.treasury.advance, (d.arg % 4, d.someone, token, d.amount, bytes32(d.arg)))
            );
        }
        if (pick == 3) return _c(token, 0, abi.encodeCall(IERC20.transfer, (targets[d.arg % 5], d.amount)));
        if (pick == 4) return _c(token, 0, abi.encodeCall(IERC20.approve, (targets[d.arg % 5], d.amount)));
        if (pick == 5) {
            address from = d.arg % 2 == 0 ? address(d.fleet) : address(d.rewards);
            return _c(token, 0, abi.encodeCall(IERC20.transferFrom, (from, d.someone, d.amount)));
        }
        if (pick == 6) {
            return _c(
                address(d.fleet),
                0,
                abi.encodeCall(d.fleet.purchase, (treasury, d.amount, block.timestamp, new bytes32[](0)))
            );
        }
        if (pick == 7) return _c(address(d.fleet), 0, abi.encodeCall(d.fleet.recognizeSurplus, (token)));
        return _c(address(d.fleet), 0, abi.encodeCall(d.fleet.sendProtocolShare, ()));
    }

    function _contractCall(Draw memory d, uint256 pick) internal view returns (KeyfleetTreasury.Call memory) {
        KeyfleetRewards rewards = d.rewards;
        KeyfleetVotes votes = d.fleet.VOTES();
        uint256[] memory ids = new uint256[](1);
        ids[0] = d.tokenId;
        if (pick == 9) {
            address owner = keys.ownerOf(d.tokenId);
            return _c(
                address(keys),
                0,
                abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, d.someone, d.tokenId)
            );
        }
        if (pick == 10) {
            address[] memory assets = new address[](2);
            (assets[0], assets[1]) = (address(d.token), NATIVE);
            return _c(address(rewards), 0, abi.encodeCall(rewards.claim, (ids, assets)));
        }
        if (pick == 11) {
            return
                _c(
                    address(rewards),
                    0,
                    abi.encodeCall(rewards.credit, (address(d.token), address(d.treasury), d.amount))
                );
        }
        if (pick == 12) {
            return
                _c(
                    address(rewards),
                    0,
                    abi.encodeCall(rewards.allocateToCohort, (address(d.token), d.arg % 3, d.amount))
                );
        }
        if (pick == 13) return _c(address(rewards), 0, abi.encodeCall(rewards.settleKey, (d.tokenId, d.someone)));
        if (pick == 14) return _c(address(rewards), 0, abi.encodeCall(rewards.enrollKey, (d.tokenId + 1, d.arg % 3)));
        if (pick == 15) {
            return _c(address(votes), 0, abi.encodeCall(votes.setEditsRestricted, (d.tokenId, d.arg % 2 == 0)));
        }
        if (pick == 16) return _c(address(votes), 0, abi.encodeCall(votes.onKeyMoved, (d.tokenId)));
        if (pick == 17) {
            return _c(address(votes), 0, abi.encodeCall(votes.execute, (1, new KeyfleetTreasury.Call[](0))));
        }
        if (pick == 18) return _c(address(shards), 0, abi.encodeCall(shards.issue, (ids, d.someone, 30)));
        if (pick == 19) {
            return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.depositProtocolShare, (d.amount)));
        }
        if (pick == 20) {
            return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.returnAdvance, (d.arg % 4, 0)));
        }
        if (pick == 21) return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.runVotedSplit, ()));
        if (pick == 22) {
            return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.setDailySplitBps, (d.arg % 250)));
        }
        if (pick == 23) return _launchCall(d.treasury);
        if (pick == 24) {
            return _c(address(d.treasury), 0, abi.encodeCall(d.treasury.bindLaunchToken, (d.arg % 4)));
        }
        return _c([address(d.fleet), address(rewards), address(votes)][d.arg % 3], d.arg % 1 ether, "");
    }

    /// @dev The manager's own entry points and the shared contracts: the collection's mint, deck,
    /// phase and reveal, the manager's transfer hook, first sale and profile, the REGENT buyer's buy
    /// and callback, and the factory's creations.
    function _sharedCall(Draw memory d, uint256 pick) internal view returns (KeyfleetTreasury.Call memory) {
        if (pick == 26) return _c(address(keys), 0, abi.encodeCall(keys.mint, (d.someone, d.fleet.totalMinted() + 1)));
        if (pick == 27) {
            return _c(
                address(d.fleet), 0, abi.encodeCall(d.fleet.onKeyMoved, (d.tokenId, keys.ownerOf(d.tokenId), d.someone))
            );
        }
        if (pick == 28) return _c(address(d.fleet), 0, abi.encodeCall(d.fleet.sellFirstKey, (d.someone)));
        if (pick == 29) {
            return _c(address(regentBuyer), 0, abi.encodeCall(regentBuyer.buy, (d.amount, address(d.treasury))));
        }
        if (pick == 30) {
            return _c(
                address(regentBuyer),
                0,
                abi.encodeCall(regentBuyer.uniswapV3SwapCallback, (int256(d.amount), int256(d.amount), ""))
            );
        }
        if (pick == 31) {
            KeyfleetManager.Profile memory renamed =
                KeyfleetManager.Profile({name: "Renamed fleet", description: "", imageLink: ""});
            return _c(address(d.fleet), 0, abi.encodeCall(d.fleet.setProfile, (renamed)));
        }
        return _c(
            address(keys),
            0,
            abi.encodeCall(keys.setDeck, (d.fleet.FLEET_ID(), keccak256(abi.encode(d.arg)), 1 + d.arg % 1000))
        );
    }

    /// @dev The call that launches a token naming `treasury` as the launch's treasury.
    function _launchCall(KeyfleetTreasury treasury) internal view returns (KeyfleetTreasury.Call memory) {
        IRegentsAutolaunchFactoryV2.LaunchParams memory params = IRegentsAutolaunchFactoryV2.LaunchParams({
            name: "Fleet Token",
            symbol: "FLEET",
            description: "The fleet's own token.",
            website: "https://keyfleet.ai",
            image: "https://keyfleet.ai/fleet.png",
            treasury: address(treasury)
        });
        return _c(address(autolaunch), 0, abi.encodeCall(IRegentsAutolaunchFactoryV2.launch, (params)));
    }

    function _c(address target, uint256 value, bytes memory data) internal pure returns (KeyfleetTreasury.Call memory) {
        return KeyfleetTreasury.Call(target, value, data);
    }
}

/// @dev Segregation (plan §4.8): no batch of calls a proposal could carry out, against any of the
/// fleet's four contracts, the shared collection, shard record, factory or REGENT buyer, Autolaunch
/// or the fleet's own token, lowers the manager's owed protocol share or Cascade reserve or what
/// the ledger owes any holder, and the manager and the ledger always hold at least what they have
/// booked, in USDC, in REGENT and in the bound token.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract KeyfleetSegregationInvariantTest is KeyfleetFixture {
    SegregationHandler internal handler;
    KeyfleetManager internal cascade;
    KeyfleetManager internal accelerant;

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        cascade = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        accelerant = _deploy(KeyfleetPresets.Preset.FleetTechAccelerant);
        handler = new SegregationHandler(cascade, accelerant, factory, autolaunch);
        targetContract(address(handler));
    }

    function invariant_noBatchLowersAnythingProtected() public view {
        assertEq(handler.breach(), "");
    }

    function invariant_theManagerAndTheLedgerHoldWhatTheyBooked() public view {
        KeyfleetManager[2] memory fleets = [cascade, accelerant];
        for (uint256 f = 0; f < 2; ++f) {
            KeyfleetManager fleet = fleets[f];
            KeyfleetRewards rewards = fleet.REWARDS();
            assertGe(usdc.balanceOf(address(fleet)), fleet.cascadeReserve() + fleet.protocolShareOwed());
            assertGe(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)));
            assertGe(regent.balanceOf(address(rewards)), rewards.backed(address(regent)));
            IERC20 launched = fleet.TREASURY().launchToken();
            if (address(launched) != address(0)) {
                assertGe(launched.balanceOf(address(rewards)), rewards.backed(address(launched)));
            }
        }
    }
}
