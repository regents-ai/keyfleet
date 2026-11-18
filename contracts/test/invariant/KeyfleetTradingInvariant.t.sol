// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetTradingFactory} from "../../src/KeyfleetTradingFactory.sol";
import {KeyfleetTradingManager} from "../../src/KeyfleetTradingManager.sol";
import {KeyfleetTradingTreasury} from "../../src/KeyfleetTradingTreasury.sol";
import {KeyfleetTradingFixture} from "../helpers/KeyfleetTradingFixture.sol";
import {MockToken} from "../mocks/MockToken.sol";

/// @dev Put over REGENT staking's address with `vm.etch`. It refuses any deposit but the fleet
/// treasury's own, tagged and referenced as the treasury promises, and then does as `mode` says:
/// 0 takes the deposit; 1 first calls back into every treasury function that moves USDC, counting
/// any that goes through, then takes it; 2 refuses, as a paused staking does; 3 takes one unit less;
/// 4 takes it and reports one unit more; 5 takes nothing and reports the whole amount.
contract HostileStaking {
    IERC20 internal immutable USDC;
    KeyfleetTradingTreasury internal immutable TREASURY;

    uint256 public mode;
    /// @dev Everything taken from the treasury since `reset`.
    uint256 public received;
    /// @dev Calls back into the treasury that went through.
    uint256 public reentered;

    constructor(IERC20 usdc_, KeyfleetTradingTreasury treasury_) {
        USDC = usdc_;
        TREASURY = treasury_;
    }

    /// @dev Clears what the code it replaced left in storage.
    function reset() external {
        mode = 0;
        received = 0;
        reentered = 0;
    }

    function setMode(uint256 mode_) external {
        mode = mode_;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256) {
        require(msg.sender == address(TREASURY), "not the treasury");
        require(sourceTag == keccak256("keyfleet.trading_payback"), "wrong tag");
        require(sourceRef == bytes32(uint256(uint160(address(TREASURY.MANAGER())))), "wrong source");
        uint256 m = mode;
        if (m == 2) revert("PAUSED");
        if (m == 1) _reenter();
        if (m == 5) return amount;
        uint256 pulled = m == 3 ? amount - 1 : amount;
        require(USDC.transferFrom(msg.sender, address(this), pulled), "pull");
        received += pulled;
        return m == 4 ? amount + 1 : amount;
    }

    function _reenter() private {
        bytes[5] memory calls = [
            abi.encodeCall(KeyfleetTradingTreasury.paybackAll, ()),
            abi.encodeCall(KeyfleetTradingTreasury.runDailyPayback, ()),
            abi.encodeCall(KeyfleetTradingTreasury.payback, (1e6)),
            abi.encodeCall(KeyfleetTradingTreasury.sendToTrading, (1)),
            abi.encodeCall(KeyfleetTradingTreasury.sendToStaking, ())
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok,) = address(TREASURY).call(calls[i]);
            if (ok) ++reentered;
        }
    }
}

/// @dev Drives one Trading Fleet as its Key holders, its creator, outsiders, its trading wallets and
/// a hostile REGENT staking would: purchases one or many at a time, Key transfers (Key 1's among
/// them, to staking too, which moves the fleet's authority), price and step changes, naming
/// wallets, sending to trading, USDC coming back with a profit or a loss, paybacks of every kind,
/// staking that pauses, misbehaves or calls back in, sending what is owed to staking, the close,
/// claims, attempts on the factory-only and collection-only functions, and time passing.
///
/// It keeps its own model of the fleet, never asking the contracts what they should have done:
/// each Key's mint time and holder, each holder's named wallet, the USDC that flowed in and out, what
/// is owed to staking, and what each Key has earned since it last changed hands or was claimed and
/// what each holder was credited. Before every action it works out from the model whether the action
/// must go through or be refused and what it must move, then checks that it did. Anything wrong is
/// recorded in `breach`.
contract TradingHandler is Test {
    uint256 internal constant ACTORS = 6;
    uint256 internal constant MATURITY = 2 days;

    KeyfleetKeys internal immutable _keys;
    MockToken internal immutable _usdc;
    HostileStaking internal immutable _staking;
    KeyfleetTradingManager internal immutable _fleet;
    KeyfleetTradingTreasury internal immutable _treasury;
    KeyfleetRewards internal immutable _rewards;
    uint256 internal immutable _cap;
    uint256 internal immutable _dailyBps;

    address[ACTORS] internal _actors;
    address[2] internal _wallets;

    // --- the model -------------------------------------------------------------------

    /// @dev Keys sold; each Key's mint time and holder.
    uint256 public minted;
    mapping(uint256 keyNumber => uint256) internal _mintedAt;
    mapping(uint256 keyNumber => address) public holderOf;
    /// @dev What each Key has earned since it last moved or was claimed, and each holder's credit.
    mapping(uint256 keyNumber => uint256) public unsettled;
    mapping(address holder => uint256) public credit;
    /// @dev The trading wallet each holder of Key 1 named.
    mapping(address holder => address) internal _walletOf;
    /// @dev The price and step the fleet should be at.
    uint256 internal _price;
    uint256 internal _step;

    /// @dev USDC into the treasury: every sale's price, and everything sent back to it.
    uint256 public salesIn;
    uint256 public returnsIn;
    /// @dev USDC out of the treasury: to trading wallets, to the ledger and to staking.
    uint256 public toWallets;
    uint256 public toLedger;
    uint256 public sentToStaking;
    /// @dev What paybacks have set aside for staking and not yet sent.
    uint256 public owedToStaking;
    /// @dev The amounts of every payback that went through, how many went through, and what holders
    /// claimed.
    uint256 public paidBack;
    uint256 public paybacks;
    uint256 public claimed;
    /// @dev What the trading wallets made trading, and sent back or lost.
    uint256 public walletProfit;
    uint256 public walletReturned;
    bool public closed;
    uint256 public mintedAtClose;
    uint256 public sentAtClose;

    string public breach;

    constructor(
        KeyfleetTradingFactory factory,
        KeyfleetTradingManager fleet,
        HostileStaking staking,
        address[ACTORS] memory actors,
        address creator,
        uint256 firstPrice,
        uint256 stepBps,
        uint256 cap
    ) {
        _keys = factory.KEYS();
        _usdc = MockToken(address(factory.USDC()));
        _staking = staking;
        _fleet = fleet;
        _treasury = fleet.TREASURY();
        _rewards = fleet.REWARDS();
        _cap = cap;
        _dailyBps = _treasury.DAILY_PAYBACK_BPS();
        _actors = actors;
        _wallets = [makeAddr("wallet a"), makeAddr("wallet b")];
        minted = 1;
        _mintedAt[1] = block.timestamp;
        holderOf[1] = creator;
        salesIn = firstPrice;
        _step = stepBps;
        _price = _raised(firstPrice);
    }

    // --- sales and Keys --------------------------------------------------------------

    function buy(uint256 payerSeed, uint256 receiverSeed) external {
        _buy(_actor(payerSeed), _actor(receiverSeed));
    }

    /// @dev One payer buys up to 20 Keys in a row, in the same second.
    function buyMany(uint256 payerSeed, uint256 receiverSeed, uint256 count) external {
        count = bound(count, 1, 20);
        for (uint256 i = 0; i < count; ++i) {
            _buy(_actor(payerSeed), _actor(receiverSeed % ACTORS + i));
        }
    }

    function _buy(address payer, address to) internal {
        uint256 price = _price;
        bool shouldWork = !closed && minted < _cap;
        _usdc.mint(payer, price);
        vm.prank(payer);
        _usdc.approve(address(_fleet), price);
        uint256 before = _balance();

        vm.prank(payer);
        try _fleet.purchase(to, price, block.timestamp, new bytes32[](0)) returns (uint256 tokenId) {
            if (!shouldWork) _breach("a Key was sold after the close or past the cap");
            uint256 keyNumber = ++minted;
            if (tokenId != _keys.tokenIdOf(_fleet.FLEET_ID(), keyNumber)) _breach("a sale minted out of order");
            if (_balance() != before + price) _breach("a sale paid the treasury other than its price");
            if (_keys.ownerOf(tokenId) != to) _breach("a Key went to someone other than its receiver");
            _mintedAt[keyNumber] = block.timestamp;
            holderOf[keyNumber] = to;
            salesIn += price;
            _price = _raised(price);
            if (_fleet.price() != _price) _breach("a sale left the wrong price");
        } catch {
            if (shouldWork) _breach("a sale that should have gone through was refused");
        }
    }

    function transfer(uint256 keySeed, uint256 toSeed) external {
        _move(bound(keySeed, 1, minted), _actor(toSeed));
    }

    /// @dev Key 1 itself, which carries the fleet's authority, to any actor or to staking.
    function passKeyOne(uint256 toSeed) external {
        address to = toSeed % (ACTORS + 1) == ACTORS ? address(_staking) : _actor(toSeed);
        _move(1, to);
        if (_fleet.creator() != to) _breach("the creator did not follow Key 1");
    }

    /// @dev Moves Key `keyNumber`, settling what it has earned to its outgoing holder.
    function _move(uint256 keyNumber, address to) internal {
        address from = holderOf[keyNumber];
        if (from == to) return;
        uint256 tokenId = _keys.tokenIdOf(_fleet.FLEET_ID(), keyNumber);
        vm.prank(from);
        _keys.transferFrom(from, to, tokenId);
        credit[from] += unsettled[keyNumber];
        unsettled[keyNumber] = 0;
        holderOf[keyNumber] = to;
    }

    // --- the creator -----------------------------------------------------------------

    function setPrice(uint256 callerSeed, uint256 newPrice) external {
        address caller = _caller(callerSeed, 3, 4);
        newPrice = bound(newPrice, 1e6 - 1, 1e18 + 1);
        bool ok = caller == holderOf[1] && newPrice >= 1e6 && newPrice <= 1e18;
        vm.prank(caller);
        try _fleet.setPrice(newPrice) {
            if (!ok) _breach("a refused price change went through");
            _price = newPrice;
        } catch {
            if (ok) _breach("the creator's price change was refused");
        }
        if (_fleet.price() != _price) _breach("the price is not what was set");
    }

    function setStep(uint256 callerSeed, uint256 newStep) external {
        address caller = _caller(callerSeed, 3, 4);
        newStep = bound(newStep, 0, 10_001);
        bool ok = caller == holderOf[1] && newStep <= 10_000;
        vm.prank(caller);
        try _fleet.setStep(newStep) {
            if (!ok) _breach("a refused step change went through");
            _step = newStep;
        } catch {
            if (ok) _breach("the creator's step change was refused");
        }
        if (_fleet.stepBps() != _step) _breach("the step is not what was set");
    }

    function nameWallet(uint256 callerSeed, uint256 walletSeed) external {
        address caller = _caller(callerSeed, 3, 4);
        address picked = _wallets[walletSeed % 2];
        bool ok = caller == holderOf[1];
        vm.prank(caller);
        try _treasury.setTradingWallet(picked) {
            if (!ok) _breach("someone other than Key 1's holder named a trading wallet");
            _walletOf[caller] = picked;
        } catch {
            if (ok) _breach("the creator could not name a trading wallet");
        }
        if (_treasury.tradingWallet() != _walletOf[holderOf[1]]) _breach("the trading wallet is not the holder's own");
    }

    function sendToTrading(uint256 callerSeed, uint256 amount) external {
        address caller = _caller(callerSeed, 3, 4);
        address named = _walletOf[caller];
        uint256 own = _own();
        amount = bound(amount, 0, own + 1);
        bool ok = caller == holderOf[1] && !closed && named != address(0) && amount != 0 && amount <= own;
        uint256 walletBefore = named == address(0) ? 0 : _usdc.balanceOf(named);
        vm.prank(caller);
        try _treasury.sendToTrading(amount) {
            if (!ok) _breach("a refused trading send went through");
            if (_usdc.balanceOf(named) != walletBefore + amount) {
                _breach("the holder's wallet got other than the amount");
            }
            toWallets += amount;
        } catch {
            if (ok) _breach("the creator's trading send was refused");
        }
        _checkBooks();
    }

    function payback(uint256 callerSeed, uint256 amount) external {
        address caller = _caller(callerSeed, 3, 4);
        amount = bound(amount, 0, _own() + 10);
        (bool ok, uint256 forStaking, uint256 perKey, uint256 counting) = _expect(amount);
        ok = ok && caller == holderOf[1];
        vm.prank(caller);
        try _treasury.payback(amount) {
            _paid(ok, amount, forStaking, perKey, counting);
        } catch {
            if (ok) _breach("the creator's payback was refused");
        }
        _checkBooks();
    }

    function close(uint256 callerSeed) external {
        address caller = _caller(callerSeed, 1, 16);
        bool ok = caller == holderOf[1] && !closed;
        vm.prank(caller);
        try _treasury.close() {
            if (!ok) _breach("a refused close went through");
            closed = true;
            mintedAtClose = minted;
            sentAtClose = toWallets;
        } catch {
            if (ok) _breach("the creator's close was refused");
        }
    }

    // --- anyone ----------------------------------------------------------------------

    function runDaily(uint256 callerSeed) external {
        address caller = _actor(callerSeed);
        uint256 dueAt = _lastDailyOrFirstMint() + 1 days;
        uint256 amount = _own() * _dailyBps / 10_000;
        (bool ok, uint256 forStaking, uint256 perKey, uint256 counting) = _expect(amount);
        ok = ok && block.timestamp >= dueAt;
        uint256 lastBefore = _treasury.lastDailyAt();
        vm.prank(caller);
        try _treasury.runDailyPayback() {
            _paid(ok, amount, forStaking, perKey, counting);
            _lastDaily = block.timestamp;
            if (_treasury.lastDailyAt() != block.timestamp) _breach("a daily run did not record its time");
        } catch {
            if (ok) _breach("a due daily payback was refused");
            if (_treasury.lastDailyAt() != lastBefore) _breach("a refused daily run used up the day");
        }
        _checkBooks();
    }

    function paybackAll(uint256 callerSeed) external {
        address caller = _actor(callerSeed);
        uint256 own = _own();
        (bool ok, uint256 forStaking, uint256 perKey, uint256 counting) = _expect(own);
        ok = ok && closed;
        vm.prank(caller);
        try _treasury.paybackAll() {
            _paid(ok, own, forStaking, perKey, counting);
        } catch {
            if (ok) _breach("paying back everything after the close was refused");
        }
        _checkBooks();
    }

    /// @dev Staking changes how it behaves, and stays that way until it changes again.
    function setStakingMode(uint256 modeSeed) external {
        _staking.setMode(modeSeed % 6);
    }

    /// @dev Anyone sends what is owed to staking, which goes through only when something is owed
    /// and staking takes it honestly.
    function sendToStaking(uint256 callerSeed) external {
        address caller = _actor(callerSeed);
        uint256 owed = owedToStaking;
        uint256 mode = _staking.mode();
        bool ok = owed != 0 && (mode == 0 || mode == 1);
        uint256 receivedBefore = _staking.received();
        vm.prank(caller);
        try _treasury.sendToStaking() {
            if (!ok) _breach("a send to staking that should have been refused went through");
            if (_staking.received() != receivedBefore + owed) _breach("staking got other than what was owed");
            sentToStaking += owed;
            owedToStaking = 0;
        } catch {
            if (ok) _breach("a send to staking that should have gone through was refused");
        }
        if (_staking.reentered() != 0) _breach("staking called back into the treasury and got through");
        if (_usdc.allowance(address(_treasury), address(_staking)) != 0) _breach("an approval to staking was left");
        _checkBooks();
    }

    /// @dev An actor claims for every Key they hold, and their own credit.
    function claim(uint256 actorSeed) external {
        address claimer = _actor(actorSeed);
        uint256[] memory held = new uint256[](minted);
        uint256 count;
        uint256 owed = credit[claimer];
        for (uint256 n = 1; n <= minted; ++n) {
            if (holderOf[n] != claimer) continue;
            held[count++] = _keys.tokenIdOf(_fleet.FLEET_ID(), n);
            owed += unsettled[n];
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
            credit[claimer] = 0;
            for (uint256 n = 1; n <= minted; ++n) {
                if (holderOf[n] == claimer) unsettled[n] = 0;
            }
        } catch {
            if (owed != 0) _breach("a claim with something owed was refused");
        }
    }

    // --- the trading wallets and outsiders --------------------------------------------

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

    // --- the model's own working ------------------------------------------------------

    uint256 internal _lastDaily;

    /// @dev Whether Key `keyNumber` counts now, by its own mint time as the model saw it.
    function _counts(uint256 keyNumber) internal view returns (bool) {
        return _mintedAt[keyNumber] + MATURITY <= block.timestamp;
    }

    /// @dev Keys that count now, by a plain count over every Key's own mint time.
    function counting() public view returns (uint256 count) {
        for (uint256 n = 1; n <= minted; ++n) {
            if (_counts(n)) ++count;
        }
    }

    /// @dev The price after a sale at `current`: up by the step, rounded down, at most 1e18.
    function _raised(uint256 current) internal view returns (uint256) {
        uint256 next = current + current * _step / 10_000;
        return next > 1e18 ? 1e18 : next;
    }

    /// @dev The treasury's USDC by the model's flows, and the fleet's own part of it.
    function modelBalance() public view returns (uint256) {
        return salesIn + returnsIn - toWallets - toLedger - sentToStaking;
    }

    function _own() internal view returns (uint256) {
        return modelBalance() - owedToStaking;
    }

    function _lastDailyOrFirstMint() internal view returns (uint256) {
        return _lastDaily > _mintedAt[1] ? _lastDaily : _mintedAt[1];
    }

    /// @dev Whether a payback of `amount` must go through, ignoring who calls, and what it must
    /// set aside for staking and give each counting Key: 1% rounded up, and the rest in whole
    /// units per Key.
    function _expect(uint256 amount)
        internal
        view
        returns (bool ok, uint256 forStaking, uint256 perKey, uint256 count)
    {
        count = counting();
        if (amount > _own() || count == 0) return (false, 0, 0, count);
        if (closed && count != minted) return (false, 0, 0, count);
        forStaking = (amount + 99) / 100;
        perKey = (amount - forStaking) / count;
        ok = perKey != 0;
    }

    function _paid(bool ok, uint256 amount, uint256 forStaking, uint256 perKey, uint256 count) internal {
        if (!ok) _breach("a payback that should have been refused went through");
        if (_fleet.matureKeys() != count) _breach("the fleet counted other Keys than a plain count");
        for (uint256 n = 1; n <= minted; ++n) {
            if (_counts(n)) unsettled[n] += perKey;
        }
        owedToStaking += forStaking;
        toLedger += perKey * count;
        paidBack += amount;
        ++paybacks;
        if (_treasury.splitInProgress()) _breach("the split flag stayed up");
    }

    /// @dev The treasury holds what the model says, owes staking what it says, and never less USDC
    /// than it owes.
    function _checkBooks() internal {
        if (_balance() != modelBalance()) _breach("the treasury holds other than the model");
        if (_treasury.stakingOwed() != owedToStaking) _breach("the treasury owes staking other than the model");
        if (_balance() < _treasury.stakingOwed()) _breach("the treasury holds less than it owes staking");
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % ACTORS];
    }

    /// @dev Key 1's holder `share` times in `outOf`, otherwise another actor, so the creator's
    /// actions go through as often as wanted and are still tried by everyone else. The seed is
    /// hashed first, as the fuzzer favours small numbers.
    function _caller(uint256 seed, uint256 share, uint256 outOf) internal view returns (address) {
        address creatorNow = holderOf[1];
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

/// @dev One Trading Fleet with a cap of 200 Keys and three sold to start, run through every action
/// of `TradingHandler` by six actors, two trading wallets and a hostile REGENT staking, against the
/// handler's own model. A run reaches at most about 25 buying calls of up to 20 Keys each, so the
/// cap is met in some runs and not most; fleets of thousands of Keys are left to the gas test and
/// the maturity fuzz, as every check here walks every Key after every call.
/// The everyday run is short; `FOUNDRY_PROFILE=deep` runs it at 256 runs × depth 100.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: deep.invariant.runs = 256
/// forge-config: deep.invariant.depth = 100
/// forge-config: deep.invariant.fail-on-revert = true
contract KeyfleetTradingInvariantTest is KeyfleetTradingFixture {
    uint256 internal constant ACTORS = 6;
    uint256 internal constant CAP = 200;
    TradingHandler internal handler;
    HostileStaking internal hostile;

    function setUp() public {
        _setUpTrading();
        address[ACTORS] memory actors;
        actors[0] = creator;
        for (uint256 i = 1; i < ACTORS; ++i) {
            actors[i] = _wallet(i);
        }
        _createTrading(_tradingTerms(FIRST_PRICE, STEP_BPS, DAILY_BPS, CAP));
        vm.etch(address(staking), address(new HostileStaking(IERC20(address(usdc)), treasury)).code);
        hostile = HostileStaking(address(staking));
        hostile.reset();
        handler = new TradingHandler(trading, fleet, hostile, actors, creator, FIRST_PRICE, STEP_BPS, CAP);
        for (uint256 i = 1; i <= 3; ++i) {
            handler.buy(i, i);
        }

        bytes4[] memory selectors = new bytes4[](24);
        selectors[0] = TradingHandler.buy.selector;
        selectors[1] = TradingHandler.buyMany.selector;
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
        selectors[16] = TradingHandler.setStakingMode.selector;
        selectors[17] = TradingHandler.sendToStaking.selector;
        selectors[18] = TradingHandler.sendToStaking.selector;
        selectors[19] = TradingHandler.claim.selector;
        selectors[20] = TradingHandler.attack.selector;
        selectors[21] = TradingHandler.wait.selector;
        selectors[22] = TradingHandler.wait.selector;
        selectors[23] = TradingHandler.buy.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_noActionBrokeARule() public view {
        assertEq(handler.breach(), "");
    }

    /// @dev USDC in (sales and returns) = USDC out (trading wallets, ledger, staking) + what the
    /// treasury holds, which is never less than what it owes staking; staking got exactly what was
    /// sent it.
    function invariant_everyUsdcIntoTheTreasuryIsAccountedFor() public view {
        uint256 held = usdc.balanceOf(address(treasury));
        assertEq(
            handler.salesIn() + handler.returnsIn(),
            handler.toWallets() + handler.toLedger() + handler.sentToStaking() + held
        );
        assertEq(held, handler.modelBalance());
        assertEq(treasury.stakingOwed(), handler.owedToStaking());
        assertGe(held, treasury.stakingOwed());
        assertEq(hostile.received(), handler.sentToStaking());
        assertEq(usdc.balanceOf(address(fleet)), 0);
        assertEq(usdc.balanceOf(address(trading)), 0);
    }

    /// @dev Every Key: its holder and what it has earned since it last moved or was claimed are the
    /// model's. Every holder, staking included: their credit is the model's. The ledger owes
    /// exactly that and holds at least that much.
    function invariant_everyKeyAndHolderIsOwedWhatTheModelSays() public view {
        uint256 minted = handler.minted();
        assertEq(fleet.totalMinted(), minted);
        assertEq(fleet.matureKeys(), handler.counting());
        uint256 owed;
        for (uint256 n = 1; n <= minted; ++n) {
            uint256 tokenId = _tkey(n);
            assertEq(keys.ownerOf(tokenId), handler.holderOf(n));
            uint256 accrued = rewards.accrued(address(usdc), tokenId);
            assertEq(accrued, handler.unsettled(n));
            owed += accrued;
        }
        for (uint256 i = 0; i < ACTORS; ++i) {
            address holder = handler.actor(i);
            uint256 credited = rewards.credits(address(usdc), holder);
            assertEq(credited, handler.credit(holder));
            owed += credited;
        }
        uint256 stakingCredit = rewards.credits(address(usdc), address(hostile));
        assertEq(stakingCredit, handler.credit(address(hostile)));
        owed += stakingCredit;
        uint256 backed = rewards.backed(address(usdc));
        assertEq(owed, backed);
        assertLe(backed, usdc.balanceOf(address(rewards)));
        assertEq(handler.toLedger(), backed + handler.claimed());
    }

    /// @dev Keys are credited at most 99% of all paybacks, and staking is owed or has been sent at
    /// least 1% and at most one unit more per payback.
    function invariant_keysGetAtMostNinetyNinePercent() public view {
        uint256 forStaking = handler.sentToStaking() + handler.owedToStaking();
        assertLe(handler.toLedger() * 100, handler.paidBack() * 99);
        assertGe(forStaking * 100, handler.paidBack());
        assertLe(forStaking * 100, handler.paidBack() + 99 * handler.paybacks());
    }

    /// @dev The trading wallets hold only what Key 1's holders sent them, plus their trading
    /// result, less what they sent back or lost.
    function invariant_onlyKeyOnesHolderFundsTrading() public view {
        uint256 held = usdc.balanceOf(handler.wallet(0)) + usdc.balanceOf(handler.wallet(1));
        assertEq(held, handler.toWallets() + handler.walletProfit() - handler.walletReturned());
        assertEq(usdc.allowance(address(treasury), address(hostile)), 0);
        assertFalse(treasury.splitInProgress());
    }

    /// @dev Once closed, no Key is minted and nothing goes to trading.
    function invariant_afterTheCloseNoMintAndNoTradingSend() public view {
        assertEq(treasury.closedAt() != 0, handler.closed());
        if (!handler.closed()) return;
        assertEq(fleet.totalMinted(), handler.mintedAtClose());
        assertEq(handler.toWallets(), handler.sentAtClose());
    }

    /// @dev The creator is always Key 1's holder; the price and step stay in range; the cap holds.
    function invariant_authorityAndPriceStayInBounds() public view {
        assertEq(fleet.creator(), keys.ownerOf(_tkey(1)));
        assertGe(fleet.price(), fleet.MIN_PRICE());
        assertLe(fleet.price(), fleet.MAX_PRICE());
        assertLe(fleet.stepBps(), fleet.MAX_STEP_BPS());
        assertLe(fleet.totalMinted(), CAP);
    }
}
