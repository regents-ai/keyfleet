// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";

/// @dev A token with any number of decimals, standing in for OUSD.
contract DecimalsToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Origin Dollar", "OUSD") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A token whose transfers can be made to revert, or to burn every unit of gas they are given.
contract MisbehavingToken is DecimalsToken {
    bool public refusing;
    bool public burning;

    constructor() DecimalsToken(18) {}

    function setRefusing(bool value) external {
        refusing = value;
    }

    function setBurning(bool value) external {
        burning = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!refusing, "PAUSED");
        if (burning) {
            while (true) {}
        }
        super._update(from, to, value);
    }
}

/// @dev A token that buys a key from inside its own transfer to the ledger, so the key is minted
/// after the treasury counted the keys and before the ledger is funded.
contract MintingToken is DecimalsToken {
    KeyfleetManager private _fleet;

    constructor() DecimalsToken(18) {}

    function arm(KeyfleetManager fleet, IERC20 usdc) external {
        _fleet = fleet;
        usdc.approve(address(fleet), type(uint256).max);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(_fleet) != address(0) && to == address(_fleet.REWARDS())) {
            KeyfleetManager fleet = _fleet;
            _fleet = KeyfleetManager(address(0));
            fleet.purchase(address(0xBEEF), type(uint256).max, block.timestamp, new bytes32[](0));
        }
    }
}

/// @dev Plan §4.10, the daily split, as Sean's rules of 6 October set it: one public run a day for
/// every bound asset, voted extra runs, a 10 to 200 bps rate, thresholds on the free balance, and
/// funding only from inside the split routine. The treasury's part of every purchase arrives as
/// REGENT, so REGENT is the asset purchases feed into the split; USDC reaches it only when someone
/// pays the treasury in USDC.
contract KeyfleetSplitTest is KeyfleetFixture {
    address private constant NATIVE = address(0);
    uint256 private constant START = 1_000_000;
    /// @dev The measured cost plus twenty percent, rounded up to the nearest thousand.
    uint256 private constant TRANSFER_GAS_CEILING = 435_000;
    uint256 private constant CLAIM_GAS_CEILING = 1_904_000;
    uint256 private constant REPEAT_CLAIM_GAS_CEILING = 694_000;

    /// @dev Whoever runs the public split: anyone may.
    address private runner = address(0x7EE9E2);

    event DailySplitRun(bool indexed voted, uint256 keys, uint256 bps);
    event SplitAllocated(address indexed asset, uint256 balance, uint256 perKey, uint256 keys);
    event SplitSkipped(address indexed asset, uint256 balance);
    event SplitTransferFailed(address indexed asset, uint256 amount);

    function setUp() public {
        _setUpFixture();
        vm.warp(START);
    }

    // --- helpers ---------------------------------------------------------

    /// @dev The founding Classic fleet, with `count` keys sold.
    function _classic(uint256 count) private returns (KeyfleetManager fleet, KeyfleetTreasury treasury) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        treasury = fleet.TREASURY();
        _buyMany(fleet, count);
    }

    /// @dev Sets the treasury's balance of every bound asset exactly.
    function _hold(KeyfleetTreasury treasury, uint256 eth, uint256 regentAmount, uint256 usdcAmount) private {
        vm.deal(address(treasury), eth);
        deal(address(regent), address(treasury), regentAmount);
        deal(address(usdc), address(treasury), usdcAmount);
    }

    function _run(KeyfleetTreasury treasury) private {
        vm.prank(runner);
        treasury.runDailySplit();
    }

    function _selfCall(KeyfleetTreasury treasury, bytes memory data)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory calls)
    {
        calls = new KeyfleetTreasury.Call[](1);
        calls[0] = KeyfleetTreasury.Call(address(treasury), 0, data);
    }

    function _votedRun(KeyfleetManager fleet) private {
        _execute(fleet, _selfCall(fleet.TREASURY(), abi.encodeCall(KeyfleetTreasury.runVotedSplit, ())));
    }

    function _perKey(uint256 balance, uint256 bps, uint256 count) private pure returns (uint256) {
        return Math.mulDiv(balance, bps, 10_000) / count;
    }

    function _admit(KeyfleetManager fleet, IERC20 token) private {
        _execute(fleet, _selfCall(fleet.TREASURY(), abi.encodeCall(KeyfleetTreasury.admitOusd, (token))));
    }

    // --- 1. the rate ---------------------------------------------------------

    /// @dev Invariant: the rate is 50 bps until an approved proposal sets another between 10 and 200
    /// bps; 9, 201 and 0 are refused and only an approved call reaches the setter.
    function test_theRateIsTenToTwoHundredBpsAndOnlyAVoteSetsIt() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        assertEq(treasury.dailySplitBps(), 50, "half a percent by default");

        uint256[3] memory accepted = [uint256(10), 200, 50];
        for (uint256 i = 0; i < 3; ++i) {
            _execute(fleet, _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (accepted[i]))));
            assertEq(treasury.dailySplitBps(), accepted[i]);
        }

        uint256[3] memory refused = [uint256(9), 201, 0];
        for (uint256 i = 0; i < 3; ++i) {
            KeyfleetTreasury.Call[] memory calls =
                _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (refused[i])));
            uint256 proposalId = _approve(fleet, calls);
            vm.warp(block.timestamp + 1);
            KeyfleetVotes votes = fleet.VOTES();
            vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.SplitRateOutOfRange.selector, refused[i]));
            votes.execute(proposalId, calls);
        }
        assertEq(treasury.dailySplitBps(), 50);

        vm.expectRevert(KeyfleetTreasury.OnlySelf.selector);
        treasury.setDailySplitBps(100);
        vm.expectRevert(KeyfleetTreasury.OnlySelf.selector);
        treasury.runVotedSplit();
        vm.expectRevert(KeyfleetTreasury.OnlySelf.selector);
        treasury.admitOusd(IERC20(address(regent)));
    }

    /// @dev Invariant: a new rate applies from the very next run, voted or public, with nothing
    /// pending in between.
    function test_aRateChangeAppliesFromTheNextRun() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        _hold(treasury, 10 ether, 0, 0);
        vm.warp(START + 1 days);
        _run(treasury);
        assertEq(rewards.splitIndex(NATIVE), _perKey(10 ether, 50, 2), "the first run at 50 bps");

        _execute(fleet, _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (200))));
        uint256 before = address(treasury).balance;
        _votedRun(fleet);
        assertEq(
            rewards.splitIndex(NATIVE), _perKey(10 ether, 50, 2) + _perKey(before, 200, 2), "the next run at 200 bps"
        );
    }

    // --- 2. thresholds, decimals and the formula --------------------------------

    /// @dev Invariant: each bound asset is split only when the treasury's balance of it is at least
    /// its threshold: 0.05 ETH, 100 REGENT, 100 USDC. Equality qualifies.
    function test_thresholdsJustBelowEqualAndAbove() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        uint256[3] memory deltas = [type(uint256).max, 0, 1]; // below, equal, above
        uint256 day = START;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 eth = deltas[i] == type(uint256).max ? 0.05 ether - 1 : 0.05 ether + deltas[i];
            uint256 reg = deltas[i] == type(uint256).max ? 100e18 - 1 : 100e18 + deltas[i];
            uint256 usd = deltas[i] == type(uint256).max ? 100e6 - 1 : 100e6 + deltas[i];
            _hold(treasury, eth, reg, usd);
            day += 1 days;
            vm.warp(day);
            uint256[3] memory before =
                [rewards.splitIndex(NATIVE), rewards.splitIndex(address(regent)), rewards.splitIndex(address(usdc))];
            if (i == 0) {
                vm.expectEmit(true, false, false, true, address(treasury));
                emit SplitSkipped(NATIVE, eth);
                vm.expectEmit(true, false, false, true, address(treasury));
                emit SplitSkipped(address(regent), reg);
                vm.expectEmit(true, false, false, true, address(treasury));
                emit SplitSkipped(address(usdc), usd);
            }
            _run(treasury);
            uint256 expectedEth = i == 0 ? 0 : _perKey(eth, 50, 2);
            uint256 expectedReg = i == 0 ? 0 : _perKey(reg, 50, 2);
            uint256 expectedUsd = i == 0 ? 0 : _perKey(usd, 50, 2);
            assertEq(rewards.splitIndex(NATIVE) - before[0], expectedEth, "ETH");
            assertEq(rewards.splitIndex(address(regent)) - before[1], expectedReg, "REGENT");
            assertEq(rewards.splitIndex(address(usdc)) - before[2], expectedUsd, "USDC");
        }
    }

    /// @dev Invariant: the REGENT that purchases buy for the treasury is split once it reaches 100
    /// REGENT, and not before. Classic keys are bought until one more would take the treasury to
    /// 100 REGENT: that day REGENT is skipped. The next key takes it over, and the next day's run
    /// splits it, with no USDC to split because purchases bring the treasury none; a holder then
    /// claims its key's REGENT.
    function test_regentFromPurchasesIsSplitFromItsThreshold() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetTreasury treasury = fleet.TREASURY();
        KeyfleetRewards rewards = fleet.REWARDS();
        while (regent.balanceOf(address(treasury)) + _regentFor(fleet.quote().capital) < 100e18) {
            _buy(fleet, _wallet(fleet.totalMinted() + 1));
        }
        uint256 below = regent.balanceOf(address(treasury));
        assertGt(below, 0, "the purchases bought REGENT for the treasury");
        assertEq(usdc.balanceOf(address(treasury)), 0, "and brought it no USDC");

        vm.warp(START + 1 days);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit SplitSkipped(address(regent), below);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit SplitSkipped(address(usdc), 0);
        _run(treasury);
        assertEq(rewards.splitIndex(address(regent)), 0, "just below 100 REGENT nothing is split");

        _buy(fleet, _wallet(fleet.totalMinted() + 1));
        uint256 count = fleet.totalMinted();
        uint256 balance = regent.balanceOf(address(treasury));
        assertGe(balance, 100e18, "one more key takes it to the threshold");
        uint256 perKey = _perKey(balance, 50, count);

        vm.warp(START + 2 days);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit SplitAllocated(address(regent), balance, perKey, count);
        _run(treasury);
        assertEq(rewards.splitIndex(address(regent)), perKey, "the REGENT from purchases is split");
        assertEq(regent.balanceOf(address(rewards)), perKey * count, "the ledger got every key's share");
        assertEq(regent.balanceOf(address(treasury)), balance - perKey * count, "the treasury kept the rest");

        address holder = _wallet(1);
        uint256[] memory first = _ids(_key(fleet, 1));
        address[] memory assets = new address[](1);
        assets[0] = address(regent);
        vm.prank(holder);
        rewards.claim(first, assets);
        assertEq(regent.balanceOf(holder), perKey, "the holder of key 1 claimed its REGENT");
    }

    /// @dev Invariant: on Cascade only a completed level's leftover reserve becomes the treasury's
    /// REGENT, so the split's REGENT base is exactly the REGENT those completions bought, and the
    /// USDC still held as reserve or owed share in the manager is never split.
    function test_cascadeSplitsOnlyTheRegentItsCompletedLevelsBought() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FibonacciCascade);
        KeyfleetTreasury treasury = fleet.TREASURY();
        KeyfleetRewards rewards = fleet.REWARDS();
        _buyMany(fleet, 33); // levels 1 to 5 complete; keys 32 and 33 start the level 6 reserve.
        // Leftovers after repaying the level before: 18, 12.4, 28.8, 52.416 and 104.3712 USDC.
        uint256 released = 18_000_000 + 12_400_000 + 28_800_000 + 52_416_000 + 104_371_200;
        assertEq(regent.balanceOf(address(treasury)), _regentFor(released), "REGENT came only from completions");
        assertGt(fleet.cascadeReserve(), 0, "level 6 has a reserve");
        assertEq(usdc.balanceOf(address(treasury)), 0, "and the treasury holds no USDC");

        vm.warp(START + 1 days);
        uint256 perKey = _perKey(_regentFor(released), 50, 33);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit SplitAllocated(address(regent), _regentFor(released), perKey, 33);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit SplitSkipped(address(usdc), 0);
        _run(treasury);
        assertEq(rewards.splitIndex(address(regent)), perKey);
        assertEq(rewards.splitIndex(address(usdc)), 0, "the manager's USDC is never split");
        assertEq(usdc.balanceOf(address(fleet)), fleet.cascadeReserve() + fleet.protocolShareOwed());
    }

    /// @dev Invariant: OUSD is split only once a proposal admits it, once, by a threshold of 100
    /// whole units read from its decimals when admitted.
    function test_ousdIsAdmittedOnceWithAThresholdByItsDecimals() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        DecimalsToken six = new DecimalsToken(6);
        assertEq(treasury.splitAssets().length, 3, "ETH, REGENT and USDC until OUSD is admitted");

        IERC20[3] memory invalid = [IERC20(address(0)), IERC20(address(usdc)), IERC20(address(regent))];
        for (uint256 i = 0; i < 3; ++i) {
            KeyfleetTreasury.Call[] memory calls =
                _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.admitOusd, (invalid[i])));
            uint256 proposalId = _approve(fleet, calls);
            vm.warp(block.timestamp + 1);
            KeyfleetVotes votes = fleet.VOTES();
            vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.OusdInvalid.selector, address(invalid[i])));
            votes.execute(proposalId, calls);
        }

        _admit(fleet, six);
        assertEq(address(treasury.ousd()), address(six));
        assertEq(treasury.ousdThreshold(), 100e6, "100 units of a six-decimal token");
        address[] memory assets = treasury.splitAssets();
        assertEq(assets.length, 4);
        assertEq(assets[3], address(six));

        KeyfleetTreasury.Call[] memory again =
            _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.admitOusd, (new DecimalsToken(18))));
        uint256 againId = _approve(fleet, again);
        vm.warp(block.timestamp + 1);
        KeyfleetVotes againVotes = fleet.VOTES();
        vm.expectRevert(KeyfleetTreasury.OusdAlreadyAdmitted.selector);
        againVotes.execute(againId, again);

        KeyfleetManager other = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, KeyfleetPresets.MIN_START_USDC);
        _admit(other, new DecimalsToken(18));
        assertEq(other.TREASURY().ousdThreshold(), 100e18, "100 units of an eighteen-decimal token");

        six.mint(address(treasury), 100e6 - 1);
        vm.warp(START + 1 days);
        _run(treasury);
        assertEq(fleet.REWARDS().splitIndex(address(six)), 0, "just below its threshold");
        six.mint(address(treasury), 1);
        vm.warp(block.timestamp + 1 days);
        _run(treasury);
        assertEq(fleet.REWARDS().splitIndex(address(six)), _perKey(100e6, 50, 1), "and at it");
    }

    /// @dev Invariant: each key gets the whole-unit floor of the cut over the keys; the rounding
    /// dust stays in the treasury, and the ledger reserves exactly what it received.
    function test_dustIsKeptByTheTreasury() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(3);
        KeyfleetRewards rewards = fleet.REWARDS();
        _hold(treasury, 1 ether, 0, 0);
        vm.warp(START + 1 days);
        _run(treasury);

        uint256 perKey = _perKey(1 ether, 50, 3);
        assertEq(perKey, 1_666_666_666_666_666);
        assertEq(rewards.splitIndex(NATIVE), perKey);
        assertEq(address(rewards).balance, 3 * perKey, "the ledger got exactly three shares");
        assertEq(rewards.backed(NATIVE), 3 * perKey, "and reserves all of it");
        assertEq(address(treasury).balance, 1 ether - 3 * perKey, "the dust stayed in the treasury");
        assertEq(1 ether - 3 * perKey - (1 ether - 5e15), 2, "two wei of dust");
    }

    /// @dev Invariant: when the cut is smaller than the number of keys, no key would get a whole
    /// unit, so the asset is skipped and nothing moves.
    function test_moreKeysThanUnitsInTheCutIsSkipped() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(6);
        DecimalsToken whole = new DecimalsToken(0);
        _admit(fleet, whole);
        whole.mint(address(treasury), 1_000); // a cut of 5 units for 6 keys
        vm.warp(START + 1 days);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit SplitSkipped(address(whole), 1_000);
        _run(treasury);
        assertEq(whole.balanceOf(address(treasury)), 1_000);
        assertEq(fleet.REWARDS().splitIndex(address(whole)), 0);
    }

    /// @dev Invariant: with no key minted the split cannot run at all, so no asset is ever split
    /// over zero keys.
    function test_noKeysMeansNoSplit() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetTreasury treasury = fleet.TREASURY();
        _hold(treasury, 1 ether, 1_000e18, 1_000e6);
        assertEq(treasury.nextRunAt(), 0);
        vm.warp(START + 10 days);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.SplitNotDue.selector, 0));
        treasury.runDailySplit();
    }

    /// @dev Invariant: only the bound assets are split; any other token the treasury holds is not.
    function test_aTokenThatIsNotBoundIsNeverSplit() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        DecimalsToken stray = new DecimalsToken(18);
        stray.mint(address(treasury), 1_000_000e18);
        vm.warp(START + 1 days);
        _run(treasury);
        assertEq(stray.balanceOf(address(treasury)), 1_000_000e18);
        assertEq(fleet.REWARDS().splitIndex(address(stray)), 0);
    }

    // --- 3. timing ---------------------------------------------------------------

    /// @dev Invariant: the first public run opens exactly a day after the first mint, each later one
    /// exactly a day after the last run, and not a second before.
    function test_thePublicRunOpensExactlyADayAfterTheLast() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        assertEq(fleet.firstMintAt(), START);
        assertEq(treasury.nextRunAt(), START + 1 days);

        vm.warp(START + 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.SplitNotDue.selector, START + 1 days));
        treasury.runDailySplit();

        vm.warp(START + 1 days);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit DailySplitRun(false, 1, 50);
        _run(treasury);
        assertEq(treasury.lastRunAt(), START + 1 days);
        assertEq(treasury.nextRunAt(), START + 2 days);

        vm.warp(START + 2 days - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.SplitNotDue.selector, START + 2 days));
        treasury.runDailySplit();
        vm.warp(START + 2 days);
        _run(treasury);
    }

    /// @dev Invariant: an approved proposal may run the split again inside the day, at the same
    /// rate and by the same formula, and that run restarts the public timer.
    function test_aVotedRunMayRunInsideTheDay() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        _hold(treasury, 4 ether, 0, 0);
        vm.warp(START + 1 days);
        _run(treasury);
        uint256 afterFirst = address(treasury).balance;

        KeyfleetTreasury.Call[] memory calls = _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.runVotedSplit, ()));
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(block.timestamp + 1);
        KeyfleetVotes votes = fleet.VOTES();
        vm.expectEmit(true, false, false, true, address(treasury));
        emit DailySplitRun(true, 2, 50);
        votes.execute(proposalId, calls);
        assertEq(rewards.splitIndex(NATIVE), _perKey(4 ether, 50, 2) + _perKey(afterFirst, 50, 2));
        assertEq(treasury.lastRunAt(), block.timestamp, "a voted run sets the last run too");

        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.SplitNotDue.selector, block.timestamp + 1));
        treasury.runDailySplit();
    }

    /// @dev Invariant: days nobody ran the split are not made up: after three idle days one run
    /// splits once, and the next has to wait a whole day again.
    function test_skippedDaysAreNotBackfilled() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        _hold(treasury, 4 ether, 0, 0);
        vm.warp(START + 4 days);
        _run(treasury);
        assertEq(fleet.REWARDS().splitIndex(NATIVE), _perKey(4 ether, 50, 2), "one day's split, not four");
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.SplitNotDue.selector, START + 5 days));
        treasury.runDailySplit();
    }

    // --- 4. funding, failures and the lock ---------------------------------------

    /// @dev Invariant: a key minted while a token is on its way to the ledger cannot share an
    /// allocation worked out before it existed: the whole run reverts and nothing moves, the
    /// REGENT that purchase bought included.
    function test_aKeyMintedDuringFundingCannotShareTheAllocation() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        MintingToken minting = new MintingToken();
        _admit(fleet, minting);
        minting.mint(address(treasury), 1_000e18);
        usdc.mint(address(minting), 1_000e6);
        minting.arm(fleet, usdc);
        vm.deal(address(treasury), 1 ether);
        uint256 regentHeld = regent.balanceOf(address(treasury));

        vm.warp(START + 1 days);
        vm.prank(runner);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetRewards.KeyCountChanged.selector, 2, 3));
        treasury.runDailySplit();
        assertEq(fleet.totalMinted(), 2, "the mint was rolled back with the run");
        assertEq(minting.balanceOf(address(treasury)), 1_000e18);
        assertEq(address(treasury).balance, 1 ether);
        assertEq(regent.balanceOf(address(treasury)), regentHeld, "and so was the REGENT it bought");
        assertEq(treasury.lastRunAt(), 0);
    }

    /// @dev Invariant: a bound token that refuses to move is skipped and the others are split.
    function test_oneFailedAssetDoesNotStopTheOthers() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        MisbehavingToken paused = new MisbehavingToken();
        _admit(fleet, paused);
        paused.mint(address(treasury), 1_000e18);
        paused.setRefusing(true);
        _hold(treasury, 1 ether, 1_000e18, 1_000e6);

        vm.warp(START + 1 days);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit SplitTransferFailed(address(paused), 2 * _perKey(1_000e18, 50, 2));
        _run(treasury);
        assertEq(rewards.splitIndex(address(paused)), 0, "the refusing token was skipped");
        assertEq(rewards.splitIndex(NATIVE), _perKey(1 ether, 50, 2), "and ETH was split");
        assertEq(rewards.splitIndex(address(regent)), _perKey(1_000e18, 50, 2), "and REGENT");
        assertEq(rewards.splitIndex(address(usdc)), _perKey(1_000e6, 50, 2), "and USDC");
    }

    /// @dev Invariant: a token that runs its transfer out of gas reverts the run rather than being
    /// skipped, so a caller cannot starve one asset of its day by sending too little gas.
    function test_aTransferThatRunsOutOfGasRevertsTheRun() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        MisbehavingToken burner = new MisbehavingToken();
        _admit(fleet, burner);
        burner.mint(address(treasury), 1_000e18);
        burner.setBurning(true);
        vm.warp(START + 1 days);

        vm.prank(runner);
        vm.expectRevert(KeyfleetTreasury.SplitOutOfGas.selector);
        treasury.runDailySplit{gas: 5_000_000}();
        assertEq(treasury.lastRunAt(), 0);
    }

    /// @dev Invariant: the public run takes the treasury's one lock, so it cannot run inside an
    /// approved batch; the voted run is made from inside the batch, under its lock.
    function test_theSplitSharesTheTreasurysLock() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        vm.warp(START + 1 days);
        KeyfleetTreasury.Call[] memory calls = _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.runDailySplit, ()));
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(block.timestamp + 1);
        KeyfleetVotes votes = fleet.VOTES();
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        votes.execute(proposalId, calls);
        _votedRun(fleet);
        assertEq(treasury.lastRunAt(), block.timestamp);
    }

    /// @dev Invariant: what the split moved to the ledger is no longer free capital, so a payment of
    /// the whole balance before the split fails after it, and the ledger's balance never counts
    /// towards the next split.
    function test_theSplitLeavesLessFreeCapitalAndNeverCountsTheLedger() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        _hold(treasury, 0, 0, 1_000e6);
        vm.warp(START + 1 days);
        _run(treasury);
        uint256 free = usdc.balanceOf(address(treasury));
        assertEq(free, 1_000e6 - 2 * _perKey(1_000e6, 50, 2));

        KeyfleetTreasury.Call[] memory whole = _selfCall(
            treasury, abi.encodeCall(KeyfleetTreasury.pay, (address(usdc), address(0xD00D), uint256(1_000e6)))
        );
        uint256 proposalId = _approve(fleet, whole);
        vm.warp(block.timestamp + 1);
        KeyfleetVotes votes = fleet.VOTES();
        vm.expectRevert();
        votes.execute(proposalId, whole);

        vm.warp(START + 2 days);
        vm.expectEmit(true, false, false, true, address(treasury));
        emit SplitAllocated(address(usdc), free, _perKey(free, 50, 2), 2);
        _run(treasury);
        assertGt(usdc.balanceOf(address(rewards)), 0, "the ledger's own balance was not in the base");
    }

    // --- 5. claims end to end, and gas -------------------------------------------

    /// @dev An agent holding an active shard of a key presses claim; the key's holder is paid.
    function test_anAgentClaimsForTheHolder() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        uint256 k1 = _key(fleet, 1);
        address holder = keys.ownerOf(k1);
        address agent = address(0xA6E47);
        vm.prank(holder);
        shards.issue(_ids(k1), agent, 30);
        _hold(treasury, 1 ether, 0, 0);
        vm.warp(START + 1 days);
        _run(treasury);

        address[] memory assets = new address[](1);
        KeyfleetRewards rewards = fleet.REWARDS();
        vm.prank(agent);
        rewards.claim(_ids(k1), assets);
        assertEq(holder.balance, _perKey(1 ether, 50, 1), "the holder was paid");
        assertEq(agent.balance, 0, "the agent was not");
    }

    /// @dev Gas: moving a key with a split pending in all five bound assets, every slot cold and the
    /// outgoing owner's credits moving from zero, and one wallet claiming ten keys in all five.
    function test_gasOfATransferAndATenKeyClaimWithAllBoundAssets() public {
        KeyfleetManager fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        KeyfleetTreasury treasury = fleet.TREASURY();
        KeyfleetRewards rewards = fleet.REWARDS();
        address holder = address(0x401DE7);
        for (uint256 i = 0; i < 11; ++i) {
            _buy(fleet, holder);
        }
        DecimalsToken ousd = new DecimalsToken(18);
        _admit(fleet, ousd);
        ousd.mint(address(treasury), 1_000e18);
        (uint256 launchId, IERC20 launched) = _launch(fleet);
        autolaunch.graduate(launchId);
        treasury.bindLaunchToken(launchId);
        deal(address(launched), address(treasury), 1_000e18);
        _hold(treasury, 10 ether, 1_000e18, 1_000e6);
        vm.warp(START + 1 days);
        _run(treasury);
        assertEq(rewards.rewardAssets().length, 5, "all five bound assets were split");

        uint256 k1 = _key(fleet, 1);
        uint256 k11 = _key(fleet, 11);
        vm.cool(address(keys));
        vm.cool(address(fleet));
        vm.cool(address(rewards));
        vm.cool(address(fleet.VOTES()));
        vm.prank(holder);
        uint256 before = gasleft();
        keys.transferFrom(holder, address(0xD00D), k11);
        uint256 transferGas = before - gasleft();
        console2.log("transfer with five split assets pending (cold):", transferGas);
        assertLt(transferGas, TRANSFER_GAS_CEILING);

        address[] memory assets = treasury.splitAssets();
        vm.cool(address(keys));
        vm.cool(address(rewards));
        vm.cool(address(shards));
        vm.prank(holder);
        before = gasleft();
        uint256[] memory paid = rewards.claim(_range(k1, 10), assets);
        uint256 claimGas = before - gasleft();
        console2.log("ten-key claim in five assets (cold):", claimGas);
        assertLt(claimGas, CLAIM_GAS_CEILING);
        assertEq(paid[0], 11 * _perKey(10 ether, 50, 11), "ten keys' ETH and the eleventh's, settled when it moved");

        // The first claim writes each key's fresh per-asset watermark; a later claim rewrites them.
        vm.warp(START + 2 days);
        _run(treasury);
        vm.cool(address(keys));
        vm.cool(address(rewards));
        vm.cool(address(shards));
        vm.prank(holder);
        before = gasleft();
        rewards.claim(_range(k1, 10), assets);
        uint256 repeatGas = before - gasleft();
        console2.log("the next day's ten-key claim in five assets (cold):", repeatGas);
        assertLt(repeatGas, REPEAT_CLAIM_GAS_CEILING);
    }
}
