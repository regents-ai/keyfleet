// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetTradingFactory} from "../../src/KeyfleetTradingFactory.sol";
import {KeyfleetTradingManager} from "../../src/KeyfleetTradingManager.sol";
import {KeyfleetTradingTreasury} from "../../src/KeyfleetTradingTreasury.sol";
import {KeyfleetTradingFixture} from "../helpers/KeyfleetTradingFixture.sol";
import {MockRegentRevenueStaking} from "../mocks/MockRegentRevenueStaking.sol";
import {MockToken} from "../mocks/MockToken.sol";

/// @dev Drives one Trading Fleet as its Key holders, its creator, outsiders and its trading wallets
/// would: purchases, Key transfers (Key 1's among them, which moves the fleet's authority), price
/// and step changes, naming a wallet, sending to trading, USDC coming back with a profit or a loss,
/// paybacks of every kind, the close, claims, attempts on the factory-only and collection-only
/// functions, and time passing. Every action is tried by any actor, the creator's mostly by Key 1's
/// holder and the close only rarely, so most runs trade a while first; each one works out beforehand
/// whether it must go through or be refused, checks that it was, and checks every amount it moved.
/// Anything wrong is recorded in `breach`. Ghost totals record each USDC flow into and out of the
/// treasury.
contract TradingHandler is Test {
    uint256 internal constant ACTORS = 6;
    uint256 internal constant BPS = 10_000;

    KeyfleetKeys internal immutable _keys;
    MockToken internal immutable _usdc;
    MockRegentRevenueStaking internal immutable _staking;
    KeyfleetTradingFactory internal immutable _factory;
    KeyfleetTradingManager internal immutable _fleet;
    KeyfleetTradingTreasury internal immutable _treasury;
    KeyfleetRewards internal immutable _rewards;

    address[ACTORS] internal _actors;
    address[2] internal _wallets;

    /// @dev USDC into the treasury: every sale's price, and everything sent back to it.
    uint256 public salesIn;
    uint256 public returnsIn;
    /// @dev USDC out of the treasury: to trading wallets, to staking, and to the ledger.
    uint256 public toWallets;
    uint256 public toStaking;
    uint256 public toLedger;
    /// @dev The amounts of every payback that went through, and what holders claimed.
    uint256 public paidBack;
    uint256 public claimed;
    /// @dev What the trading wallets made trading, and sent back.
    uint256 public walletProfit;
    uint256 public walletReturned;
    /// @dev The close, as the handler saw it, and the totals at that moment.
    bool public closed;
    uint256 public mintedAtClose;
    uint256 public sentAtClose;

    string public breach;

    constructor(
        KeyfleetTradingFactory factory,
        KeyfleetTradingManager fleet,
        MockRegentRevenueStaking staking,
        address[ACTORS] memory actors,
        uint256 firstSale
    ) {
        _factory = factory;
        _keys = factory.KEYS();
        _usdc = MockToken(address(factory.USDC()));
        _staking = staking;
        _fleet = fleet;
        _treasury = fleet.TREASURY();
        _rewards = fleet.REWARDS();
        _actors = actors;
        _wallets = [makeAddr("wallet a"), makeAddr("wallet b")];
        salesIn = firstSale;
    }

    // --- actions ------------------------------------------------------------------

    function buy(uint256 payerSeed, uint256 receiverSeed) external {
        address payer = _actor(payerSeed);
        address to = _actor(receiverSeed);
        uint256 price = _fleet.price();
        uint256 minted = _fleet.totalMinted();
        bool shouldWork = !closed && minted < _fleet.maxKeys();
        _usdc.mint(payer, price);
        vm.prank(payer);
        _usdc.approve(address(_fleet), price);
        uint256 before = _balance();

        vm.prank(payer);
        try _fleet.purchase(to, price, block.timestamp, new bytes32[](0)) returns (uint256 tokenId) {
            if (!shouldWork) _breach("a Key was sold after the close or past the cap");
            if (_balance() != before + price) _breach("a sale paid the treasury other than its price");
            if (_keys.ownerOf(tokenId) != to) _breach("a Key went to someone other than its receiver");
            if (_fleet.totalMinted() != minted + 1) _breach("a sale minted other than one Key");
            if (_fleet.price() != _fleet.raised(price, _fleet.stepBps())) _breach("a sale left the wrong price");
            salesIn += price;
        } catch {
            if (shouldWork) _breach("a sale that should have gone through was refused");
        }
    }

    function transfer(uint256 keySeed, uint256 toSeed) external {
        uint256 tokenId = _keys.tokenIdOf(_fleet.FLEET_ID(), bound(keySeed, 1, _fleet.totalMinted()));
        address from = _keys.ownerOf(tokenId);
        address to = _actor(toSeed);
        if (from == to) return;
        vm.prank(from);
        _keys.transferFrom(from, to, tokenId);
    }

    /// @dev Key 1 itself, which carries the fleet's authority, to any actor.
    function passKeyOne(uint256 toSeed) external {
        uint256 first = _keys.tokenIdOf(_fleet.FLEET_ID(), 1);
        address from = _keys.ownerOf(first);
        address to = _actor(toSeed);
        if (from == to) return;
        vm.prank(from);
        _keys.transferFrom(from, to, first);
        if (_fleet.creator() != to) _breach("the creator did not follow Key 1");
    }

    function setPrice(uint256 callerSeed, uint256 newPrice) external {
        address caller = _caller(callerSeed, 3, 4);
        newPrice = bound(newPrice, _fleet.MIN_PRICE() - 1, _fleet.MAX_PRICE() + 1);
        bool ok = caller == _fleet.creator() && newPrice >= _fleet.MIN_PRICE() && newPrice <= _fleet.MAX_PRICE();
        uint256 before = _fleet.price();
        vm.prank(caller);
        try _fleet.setPrice(newPrice) {
            if (!ok) _breach("a refused price change went through");
            if (_fleet.price() != newPrice) _breach("a price change set another price");
        } catch {
            if (ok) _breach("the creator's price change was refused");
            if (_fleet.price() != before) _breach("a refused price change moved the price");
        }
    }

    function setStep(uint256 callerSeed, uint256 newStep) external {
        address caller = _caller(callerSeed, 3, 4);
        newStep = bound(newStep, 0, _fleet.MAX_STEP_BPS() + 1);
        bool ok = caller == _fleet.creator() && newStep <= _fleet.MAX_STEP_BPS();
        vm.prank(caller);
        try _fleet.setStep(newStep) {
            if (!ok) _breach("a refused step change went through");
            if (_fleet.stepBps() != newStep) _breach("a step change set another step");
        } catch {
            if (ok) _breach("the creator's step change was refused");
        }
    }

    function nameWallet(uint256 callerSeed, uint256 walletSeed) external {
        address caller = _caller(callerSeed, 3, 4);
        address picked = _wallets[walletSeed % 2];
        bool ok = caller == _fleet.creator();
        vm.prank(caller);
        try _treasury.setTradingWallet(picked) {
            if (!ok) _breach("someone other than Key 1's holder named the trading wallet");
            if (_treasury.tradingWallet() != picked) _breach("the wrong trading wallet was named");
        } catch {
            if (ok) _breach("the creator could not name the trading wallet");
        }
    }

    function sendToTrading(uint256 callerSeed, uint256 amount) external {
        address caller = _caller(callerSeed, 3, 4);
        address creatorNow = _fleet.creator();
        address named = _treasury.tradingWallet();
        uint256 balance = _balance();
        amount = bound(amount, 0, balance + 1);
        bool ok = caller == creatorNow && !closed && named != address(0) && amount != 0 && amount <= balance;
        uint256 walletBefore = named == address(0) ? 0 : _usdc.balanceOf(named);
        vm.prank(caller);
        try _treasury.sendToTrading(amount) {
            if (caller != creatorNow) _breach("someone other than Key 1's holder sent USDC to trading");
            if (!ok) _breach("a refused trading send went through");
            if (_usdc.balanceOf(named) != walletBefore + amount) _breach("the wallet got other than the amount");
            if (_balance() != balance - amount) _breach("a trading send took other than the amount");
            toWallets += amount;
        } catch {
            if (ok) _breach("the creator's trading send was refused");
        }
    }

    /// @dev A trading wallet makes `profit` (or nothing) and sends back part of what it holds, or an
    /// outsider sends USDC to the treasury unasked.
    function returnUsdc(uint256 walletSeed, uint256 profit, uint256 amount, bool outsider) external {
        if (outsider) {
            amount = bound(amount, 1, 1_000e6);
            _usdc.mint(address(this), amount);
            _usdc.transfer(address(_treasury), amount);
            returnsIn += amount;
            return;
        }
        address picked = _wallets[walletSeed % 2];
        profit = bound(profit, 0, 5_000e6);
        _usdc.mint(picked, profit);
        walletProfit += profit;
        amount = bound(amount, 0, _usdc.balanceOf(picked));
        vm.prank(picked);
        _usdc.transfer(address(_treasury), amount);
        walletReturned += amount;
        returnsIn += amount;
    }

    /// @dev A trading wallet loses part of what it holds trading.
    function loseTrading(uint256 walletSeed, uint256 amount) external {
        address picked = _wallets[walletSeed % 2];
        amount = bound(amount, 0, _usdc.balanceOf(picked));
        vm.prank(picked);
        _usdc.transfer(address(0xdead), amount);
        walletReturned += amount;
    }

    function payback(uint256 callerSeed, uint256 amount) external {
        address caller = _caller(callerSeed, 3, 4);
        uint256 balance = _balance();
        amount = bound(amount, 0, balance + 10);
        (bool ok, uint256 staked, uint256 perKey, uint256 keys) = _predict(amount, balance);
        ok = ok && caller == _fleet.creator();
        vm.prank(caller);
        try _treasury.payback(amount) {
            _paid(ok, amount, balance, staked, perKey, keys);
        } catch {
            if (ok) _breach("the creator's payback was refused");
        }
    }

    function runDaily(uint256 callerSeed) external {
        address caller = _actor(callerSeed);
        uint256 dueAt = _treasury.nextDailyAt();
        uint256 lastBefore = _treasury.lastDailyAt();
        uint256 balance = _balance();
        uint256 amount = balance * _treasury.DAILY_PAYBACK_BPS() / BPS;
        (bool ok, uint256 staked, uint256 perKey, uint256 keys) = _predict(amount, balance);
        ok = ok && dueAt != 0 && block.timestamp >= dueAt;
        vm.prank(caller);
        try _treasury.runDailyPayback() {
            _paid(ok, amount, balance, staked, perKey, keys);
            if (_treasury.lastDailyAt() != block.timestamp) _breach("a daily run did not record its time");
        } catch {
            if (ok) _breach("a due daily payback was refused");
            if (_treasury.lastDailyAt() != lastBefore) _breach("a refused daily run used up the day");
        }
    }

    function close(uint256 callerSeed) external {
        address caller = _caller(callerSeed, 1, 16);
        bool ok = caller == _fleet.creator() && !closed;
        vm.prank(caller);
        try _treasury.close() {
            if (!ok) _breach("a refused close went through");
            closed = true;
            mintedAtClose = _fleet.totalMinted();
            sentAtClose = toWallets;
        } catch {
            if (ok) _breach("the creator's close was refused");
        }
    }

    function paybackAll(uint256 callerSeed) external {
        address caller = _actor(callerSeed);
        uint256 balance = _balance();
        (bool ok, uint256 staked, uint256 perKey, uint256 keys) = _predict(balance, balance);
        ok = ok && closed;
        vm.prank(caller);
        try _treasury.paybackAll() {
            _paid(ok, balance, balance, staked, perKey, keys);
        } catch {
            if (ok) _breach("paying back everything after the close was refused");
        }
    }

    /// @dev An actor claims for every Key they hold, and their own credit.
    function claim(uint256 actorSeed) external {
        address claimer = _actor(actorSeed);
        uint256 minted = _fleet.totalMinted();
        uint256[] memory held = new uint256[](minted);
        uint256 count;
        uint256 owed = _rewards.credits(address(_usdc), claimer);
        for (uint256 n = 1; n <= minted; ++n) {
            uint256 tokenId = _keys.tokenIdOf(_fleet.FLEET_ID(), n);
            if (_keys.ownerOf(tokenId) != claimer) continue;
            held[count++] = tokenId;
            owed += _rewards.accrued(address(_usdc), tokenId);
        }
        assembly ("memory-safe") {
            mstore(held, count)
        }
        address[] memory assets = new address[](1);
        assets[0] = address(_usdc);
        uint256 before = _usdc.balanceOf(claimer);
        vm.prank(claimer);
        try _rewards.claim(held, assets) returns (uint256[] memory paid) {
            if (owed == 0) _breach("a claim with nothing owed went through");
            if (paid[0] != owed || _usdc.balanceOf(claimer) != before + owed) _breach("a claim paid other than owed");
            claimed += owed;
        } catch {
            if (owed != 0) _breach("a claim with something owed was refused");
        }
    }

    /// @dev Calls only the factory, the collection or the treasury may make, made by an actor.
    function attack(uint256 callerSeed, uint256 which) external {
        address caller = _actor(callerSeed);
        uint256 first = _keys.tokenIdOf(_fleet.FLEET_ID(), 1);
        KeyfleetManager.Profile memory profile;
        profile.name = "Taken";
        KeyfleetManager.Requirements memory anyone;
        vm.prank(caller);
        which %= 5;
        bool went;
        if (which == 0) {
            try _fleet.initialize(profile, anyone) {
                went = true;
            } catch {}
        } else if (which == 1) {
            try _fleet.sellFirstKey(caller) {
                went = true;
            } catch {}
        } else if (which == 2) {
            try _fleet.onKeyMoved(first, caller) {
                went = true;
            } catch {}
        } else if (which == 3) {
            try _rewards.fundSplit(address(_usdc), 1, 1) {
                went = true;
            } catch {}
        } else {
            try _rewards.settleKey(first, caller) {
                went = true;
            } catch {}
        }
        if (went) _breach("a factory-, collection- or treasury-only call went through for an actor");
    }

    function wait(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }

    // --- helpers -----------------------------------------------------------------------

    /// @dev Whether a payback of `amount` out of `balance` must go through, ignoring who calls, and
    /// what it must move.
    function _predict(uint256 amount, uint256 balance)
        internal
        view
        returns (bool ok, uint256 staked, uint256 perKey, uint256 keys)
    {
        keys = _fleet.matureKeys();
        if (amount > balance || keys == 0) return (false, 0, 0, keys);
        if (closed && keys != _fleet.totalMinted()) return (false, 0, 0, keys);
        staked = Math.mulDiv(amount, 100, BPS, Math.Rounding.Ceil);
        perKey = (amount - staked) / keys;
        ok = perKey != 0;
    }

    function _paid(bool ok, uint256 amount, uint256 balance, uint256 staked, uint256 perKey, uint256 keys) internal {
        if (!ok) _breach("a payback that should have been refused went through");
        if (_balance() != balance - staked - perKey * keys) _breach("a payback took the wrong amount");
        if (_staking.totalUsdcReceived() != toStaking + staked) _breach("staking got other than 1% rounded up");
        if (_usdc.allowance(address(_treasury), address(_staking)) != 0) _breach("a payback left an approval");
        if (_treasury.splitInProgress()) _breach("the split flag stayed up");
        toStaking += staked;
        toLedger += perKey * keys;
        paidBack += amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % ACTORS];
    }

    /// @dev Key 1's holder `share` times in `outOf`, otherwise another actor, so the creator's
    /// actions go through as often as wanted and are still tried by everyone else. The seed is
    /// hashed first, as the fuzzer favours small numbers.
    function _caller(uint256 seed, uint256 share, uint256 outOf) internal view returns (address) {
        address creatorNow = _fleet.creator();
        seed = uint256(keccak256(abi.encode(seed)));
        if (seed % outOf < share) return creatorNow;
        address other = _actor(seed / outOf);
        return other == creatorNow ? _actor(seed / outOf + 1) : other;
    }

    function _balance() internal view returns (uint256) {
        return _usdc.balanceOf(address(_treasury));
    }

    function _breach(string memory what) internal {
        if (bytes(breach).length == 0) breach = what;
    }

    function actor(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function wallet(uint256 i) external view returns (address) {
        return _wallets[i];
    }
}

/// @dev One Trading Fleet with a cap of 60 Keys, three Keys sold to start, run through every
/// action of `TradingHandler` by six actors and two trading wallets.
/// The everyday run is short; `FOUNDRY_PROFILE=deep` runs it at 256 runs × depth 100.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: deep.invariant.runs = 256
/// forge-config: deep.invariant.depth = 100
/// forge-config: deep.invariant.fail-on-revert = true
contract KeyfleetTradingInvariantTest is KeyfleetTradingFixture {
    uint256 internal constant ACTORS = 6;
    TradingHandler internal handler;

    function setUp() public {
        _setUpTrading();
        address[ACTORS] memory actors;
        actors[0] = creator;
        for (uint256 i = 1; i < ACTORS; ++i) {
            actors[i] = _wallet(i);
        }
        _createTrading(_tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, 60));
        handler = new TradingHandler(trading, fleet, staking, actors, FIRST_PRICE);
        for (uint256 i = 1; i <= 3; ++i) {
            handler.buy(i, i);
        }

        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = TradingHandler.buy.selector;
        selectors[1] = TradingHandler.buy.selector;
        selectors[2] = TradingHandler.transfer.selector;
        selectors[3] = TradingHandler.passKeyOne.selector;
        selectors[4] = TradingHandler.setPrice.selector;
        selectors[5] = TradingHandler.setStep.selector;
        selectors[6] = TradingHandler.nameWallet.selector;
        selectors[7] = TradingHandler.sendToTrading.selector;
        selectors[8] = TradingHandler.sendToTrading.selector;
        selectors[9] = TradingHandler.returnUsdc.selector;
        selectors[10] = TradingHandler.loseTrading.selector;
        selectors[11] = TradingHandler.payback.selector;
        selectors[12] = TradingHandler.payback.selector;
        selectors[13] = TradingHandler.runDaily.selector;
        selectors[14] = TradingHandler.close.selector;
        selectors[15] = TradingHandler.paybackAll.selector;
        selectors[16] = TradingHandler.claim.selector;
        selectors[17] = TradingHandler.attack.selector;
        selectors[18] = TradingHandler.wait.selector;
        selectors[19] = TradingHandler.wait.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_noActionBrokeARule() public view {
        assertEq(handler.breach(), "");
    }

    /// @dev USDC in (sales and returns) = USDC out (trading wallets, staking, ledger) + what the
    /// treasury holds.
    function invariant_everyUsdcIntoTheTreasuryIsAccountedFor() public view {
        assertEq(
            handler.salesIn() + handler.returnsIn(),
            handler.toWallets() + handler.toStaking() + handler.toLedger() + usdc.balanceOf(address(treasury))
        );
        assertEq(handler.toStaking(), staking.totalUsdcReceived());
        assertEq(usdc.balanceOf(address(fleet)), 0);
        assertEq(usdc.balanceOf(address(trading)), 0);
    }

    /// @dev What the ledger owes every Key and every past holder is exactly what it has set aside,
    /// and it holds that much.
    function invariant_theLedgerNeverOwesMoreThanItHolds() public view {
        uint256 owed;
        for (uint256 n = 1; n <= fleet.totalMinted(); ++n) {
            owed += rewards.accrued(address(usdc), _tkey(n));
        }
        for (uint256 i = 0; i < ACTORS; ++i) {
            owed += rewards.credits(address(usdc), handler.actor(i));
        }
        uint256 backed = rewards.backed(address(usdc));
        assertEq(owed, backed);
        assertLe(backed, usdc.balanceOf(address(rewards)));
        assertEq(handler.toLedger(), backed + handler.claimed());
    }

    /// @dev Keys are credited at most 99% of all paybacks, and staking gets at least 1%.
    function invariant_keysGetAtMostNinetyNinePercent() public view {
        assertLe(handler.toLedger() * 100, handler.paidBack() * 99);
        assertGe(handler.toStaking() * 100, handler.paidBack());
    }

    /// @dev The trading wallets hold only what Key 1's holder sent them, plus their trading result,
    /// less what they sent back or lost.
    function invariant_onlyKeyOnesHolderFundsTrading() public view {
        uint256 held = usdc.balanceOf(handler.wallet(0)) + usdc.balanceOf(handler.wallet(1));
        assertEq(held, handler.toWallets() + handler.walletProfit() - handler.walletReturned());
        assertEq(usdc.allowance(address(treasury), address(staking)), 0);
        assertFalse(treasury.splitInProgress());
    }

    /// @dev Once closed, no Key is minted and nothing goes to trading.
    function invariant_afterTheCloseNoMintAndNoTradingSend() public view {
        assertEq(treasury.closedAt() != 0, handler.closed());
        if (!handler.closed()) return;
        assertEq(fleet.totalMinted(), handler.mintedAtClose());
        assertEq(handler.toWallets(), handler.sentAtClose());
    }

    /// @dev The creator is always Key 1's holder; the price and step stay in range.
    function invariant_authorityAndPriceStayInBounds() public view {
        assertEq(fleet.creator(), keys.ownerOf(_tkey(1)));
        assertGe(fleet.price(), fleet.MIN_PRICE());
        assertLe(fleet.price(), fleet.MAX_PRICE());
        assertLe(fleet.stepBps(), fleet.MAX_STEP_BPS());
        assertLe(fleet.totalMinted(), 60);
    }
}
