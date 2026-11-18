// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetTradingFactory} from "../../src/KeyfleetTradingFactory.sol";
import {KeyfleetTradingManager} from "../../src/KeyfleetTradingManager.sol";
import {KeyfleetTradingTreasury} from "../../src/KeyfleetTradingTreasury.sol";
import {IKeyfleetFactory} from "../../src/KeyfleetWiring.sol";
import {KeyfleetFixture} from "./KeyfleetFixture.sol";

/// @dev The Keyfleet system of `KeyfleetFixture` with a trading factory added to its collection by
/// the Safe, and the steps the Trading Fleet tests repeat: creating a fleet, buying its Keys and
/// waiting for them to count.
abstract contract KeyfleetTradingFixture is KeyfleetFixture {
    /// @dev The first price, step and daily payback most tests use: 10 USDC, 5% and 1%.
    uint256 internal constant FIRST_PRICE = 10e6;
    uint256 internal constant STEP_BPS = 500;
    uint256 internal constant DAILY_BPS = 100;
    /// @dev The manager's price range, 1 USDC to one trillion, which every fleet shares.
    uint256 internal constant MIN_PRICE = 1e6;
    uint256 internal constant MAX_PRICE = 1e18;

    KeyfleetTradingFactory internal trading;

    /// @dev The fleet `_createTrading` made last, and its treasury and ledger.
    KeyfleetTradingManager internal fleet;
    KeyfleetTradingTreasury internal treasury;
    KeyfleetRewards internal rewards;

    address internal wallet = makeAddr("trading wallet");

    /// @dev The fixture, its founding fleets and phases up to the last, which is open, and the
    /// trading factory added to the collection.
    function _setUpTrading() internal {
        _setUpFixture();
        _openCreation();
        trading = new KeyfleetTradingFactory(IKeyfleetFactory(address(factory)));
        vm.prank(safe);
        keys.addFactory(address(trading));
    }

    /// @dev Terms with no joining requirements, no cap and a deadline of now.
    function _tradingTerms(uint256 firstPrice, uint256 stepBps, uint256 dailyBps, uint256 keyCap)
        internal
        view
        returns (KeyfleetTradingFactory.TradingTerms memory terms)
    {
        terms.profile = _profile("Trading fleet");
        terms.firstPrice = firstPrice;
        terms.stepBps = stepBps;
        terms.dailyPaybackBps = dailyBps;
        terms.keyCap = keyCap;
        terms.deadline = block.timestamp;
    }

    /// @dev Creates a fleet as `creator`, who pays the first price, on the usual terms.
    function _createTrading() internal returns (KeyfleetTradingManager) {
        return _createTrading(_tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 0));
    }

    function _createTrading(KeyfleetTradingFactory.TradingTerms memory terms)
        internal
        returns (KeyfleetTradingManager)
    {
        usdc.mint(creator, terms.firstPrice);
        vm.startPrank(creator);
        usdc.approve(address(trading), terms.firstPrice);
        (uint256 fleetId,) = trading.create(terms);
        vm.stopPrank();
        fleet = KeyfleetTradingManager(keys.managerOf(fleetId));
        treasury = fleet.TREASURY();
        rewards = fleet.REWARDS();
        return fleet;
    }

    /// @dev The token id of Key `keyNumber` of the current fleet.
    function _tkey(uint256 keyNumber) internal view returns (uint256) {
        return keys.tokenIdOf(fleet.FLEET_ID(), keyNumber);
    }

    /// @dev Buys the next Key of the current fleet for `receiver`, as `buyer`, at its price.
    function _tbuy(address receiver) internal returns (uint256 tokenId) {
        uint256 price = fleet.price();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, price, block.timestamp, new bytes32[](0));
        vm.stopPrank();
    }

    /// @dev Key `i` goes to `_wallet(i)`, one Key per wallet.
    function _tbuyMany(uint256 count) internal {
        for (uint256 i = 0; i < count; ++i) {
            _tbuy(_wallet(fleet.totalMinted() + 1));
        }
    }

    /// @dev Waits until every Key of the current fleet sold so far counts.
    function _tcount() internal {
        uint256 countsAt = keys.mintedAt(_tkey(fleet.totalMinted())) + fleet.KEY_MATURITY();
        if (block.timestamp < countsAt) vm.warp(countsAt);
    }

    /// @dev Pays `amount` of USDC back into the current fleet's treasury, as a trading wallet would.
    function _return(uint256 amount) internal {
        usdc.mint(address(treasury), amount);
    }

    /// @dev Claims everything `tokenId` and `holder` are owed in USDC, as `holder`.
    function _claimAll(address holder, uint256 tokenId) internal returns (uint256 paid) {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        vm.prank(holder);
        paid = rewards.claim(_ids(tokenId), assets)[0];
    }
}
