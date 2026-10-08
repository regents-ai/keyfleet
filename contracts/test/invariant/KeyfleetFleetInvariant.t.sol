// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetShards} from "../../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {IRegentLBPStrategyV2} from "../../src/interfaces/IRegentLBPStrategyV2.sol";
import {IRegentsAutolaunchFactoryV2} from "../../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockAutolaunchFactory, MockLaunchToken} from "../mocks/MockAutolaunchFactory.sol";
import {MockRegent} from "../mocks/MockRegent.sol";
import {KeyfleetFixture} from "../helpers/KeyfleetFixture.sol";

/// @dev Drives the founding Cascade and Accelerant fleets through everything that moves money or
/// keys across each fleet's manager, controller, treasury and ledger and the shared collection and
/// shard record: purchases (whose treasury part arrives as REGENT), key transfers (each settling the
/// ledger and telling the controller), shards issued to agents, money sent to the treasury and to
/// the manager, public daily splits as time passes, and approved batches made through the
/// controller's address that run the split early, change its rate, admit OUSD, launch a token
/// through Autolaunch or pay money out. Launches sell or fail as the sequence goes on, anyone may try to bind any of
/// them, and launched tokens reach the treasury before and after binding. Claims are made by
/// holders, former holders and agents. Around each step it records, as `breach`, the first thing
/// that went differently from the rules.
contract FleetHandler is Test {
    address internal constant NATIVE = address(0);
    uint256 internal constant MAX_KEYS = 30;
    uint256 internal constant ACTORS = 16;
    uint256 internal constant AGENTS = 3;
    uint256 internal constant MAX_LAUNCHES = 6;

    KeyfleetManager[2] internal fleets;
    KeyfleetKeys internal immutable keys;
    KeyfleetShards internal immutable shards;
    MockToken internal immutable usdc;
    MockRegent internal immutable regent;
    MockToken internal immutable ousd;
    MockAutolaunchFactory internal immutable autolaunch;
    address internal buyer = address(0xB0B0B0);

    /// @notice Per fleet, the last launch its treasury made, zero before any.
    mapping(uint256 fleet => uint256 launchId) public lastLaunch;

    /// @notice Per fleet and asset, everything the split has sent the ledger and everything claims
    /// have paid out.
    mapping(uint256 fleet => mapping(address asset => uint256 amount)) public allocated;
    mapping(uint256 fleet => mapping(address asset => uint256 amount)) public claimed;

    /// @notice Set, with the reason, the first time a step went differently from the rules.
    string public breach;

    constructor(
        KeyfleetManager cascade,
        KeyfleetManager accelerant,
        KeyfleetShards shards_,
        MockToken usdc_,
        MockRegent regent_,
        MockToken ousd_,
        MockAutolaunchFactory autolaunch_
    ) {
        fleets = [cascade, accelerant];
        keys = cascade.KEYS();
        shards = shards_;
        usdc = usdc_;
        regent = regent_;
        ousd = ousd_;
        autolaunch = autolaunch_;
    }

    function actor(uint256 i) public pure returns (address) {
        return address(uint160(0xA11CE00 + i));
    }

    function agent(uint256 i) public pure returns (address) {
        return address(uint160(0xA6E0700 + i));
    }

    function fleet(uint256 i) external view returns (KeyfleetManager) {
        return fleets[i];
    }

    // --- keys ------------------------------------------------------------

    /// @dev Buys one to three keys, each to an actor. Every USDC of each price stays in the manager
    /// (the protocol share, the Cascade reserve and the treasury's booked part) or reaches the ledger
    /// (the Accelerant rebate and the Cascade repayment); the treasury's USDC and REGENT do not move.
    function buy(uint256 fleetSeed, uint256 actorSeed, uint256 count) external {
        KeyfleetManager f = fleets[fleetSeed % 2];
        count = bound(count, 1, 3);
        for (uint256 i = 0; i < count; ++i) {
            uint256 keyNumber = f.totalMinted() + 1;
            if (keyNumber > MAX_KEYS) return;
            address to = actor((actorSeed % ACTORS + i) % ACTORS);
            uint256 price = f.nextPrice();
            address treasury = address(f.TREASURY());
            uint256[4] memory before = [
                usdc.balanceOf(address(f)),
                usdc.balanceOf(address(f.REWARDS())),
                usdc.balanceOf(treasury),
                regent.balanceOf(treasury)
            ];
            usdc.mint(buyer, price);
            vm.startPrank(buyer);
            usdc.approve(address(f), price);
            f.purchase(to, price, block.timestamp, new bytes32[](0));
            vm.stopPrank();
            if (usdc.balanceOf(treasury) != before[2]) _breach("a purchase paid the treasury USDC");
            if (regent.balanceOf(treasury) != before[3]) _breach("a purchase swapped for the treasury");
            if (usdc.balanceOf(address(f)) + usdc.balanceOf(address(f.REWARDS())) != before[0] + before[1] + price) {
                _breach("a purchase's USDC left the manager and the ledger");
            }
        }
    }

    /// @dev Runs the next piece once it is due. The fleet at the head of the queue hands over
    /// exactly its piece, and its treasury gets exactly the REGENT that buys at the stand-in
    /// market's one REGENT per USDC, and no USDC.
    function convert() external {
        KeyfleetRegentBuyer regentBuyer = fleets[0].REGENT_BUYER();
        if (regentBuyer.queueLength() == 0) return;
        uint256 opensAt = regentBuyer.nextPieceAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);
        KeyfleetManager f = KeyfleetManager(regentBuyer.nextInQueue());
        address treasury = address(f.TREASURY());
        uint256 pending = f.pendingConversion();
        uint256[3] memory before = [usdc.balanceOf(address(f)), usdc.balanceOf(treasury), regent.balanceOf(treasury)];
        regentBuyer.convert();
        uint256 piece = pending - f.pendingConversion();
        if (piece == 0 || piece > regentBuyer.PIECE_USDC()) _breach("a piece was empty or over its size");
        if (before[0] - usdc.balanceOf(address(f)) != piece) _breach("the manager paid other than its piece");
        if (usdc.balanceOf(treasury) != before[1]) _breach("a piece paid the treasury USDC");
        if (regent.balanceOf(treasury) - before[2] != piece * 1e12) {
            _breach("a piece's REGENT did not reach the treasury at the market price");
        }
    }

    function transfer(uint256 fleetSeed, uint256 tokenSeed, uint256 actorSeed) external {
        KeyfleetManager f = fleets[fleetSeed % 2];
        uint256 minted = f.totalMinted();
        if (minted == 0) return;
        uint256 keyNumber = 1 + tokenSeed % minted;
        uint256 tokenId = keys.tokenIdOf(f.FLEET_ID(), keyNumber);
        address from = keys.ownerOf(tokenId);
        address to = actor(actorSeed % ACTORS);
        if (to == from) to = actor((actorSeed % ACTORS + 1) % ACTORS);
        vm.prank(from);
        keys.transferFrom(from, to, tokenId);
    }

    function issueShard(uint256 fleetSeed, uint256 tokenSeed, uint256 agentSeed, uint16 days_) external {
        KeyfleetManager f = fleets[fleetSeed % 2];
        uint256 minted = f.totalMinted();
        if (minted == 0) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = keys.tokenIdOf(f.FLEET_ID(), 1 + tokenSeed % minted);
        vm.prank(keys.ownerOf(ids[0]));
        shards.issue(ids, agent(agentSeed % AGENTS), uint16(bound(days_, 1, 3)));
    }

    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }

    // --- money in and out of the treasury ------------------------------------

    function fund(uint256 fleetSeed, uint256 assetSeed, uint256 amount) external {
        KeyfleetManager f = fleets[fleetSeed % 2];
        address treasury = address(f.TREASURY());
        uint256 pick = assetSeed % 5;
        if (pick == 0) {
            vm.deal(treasury, treasury.balance + bound(amount, 0, 3 ether));
        } else if (pick == 1) {
            regent.mint(treasury, bound(amount, 0, 5_000e18));
        } else if (pick == 2) {
            usdc.mint(treasury, bound(amount, 0, 5_000e6));
        } else if (pick == 3) {
            ousd.mint(treasury, bound(amount, 0, 5_000e6));
        } else {
            usdc.mint(address(f), bound(amount, 0, 5_000e6));
            f.recognizeSurplus(address(usdc));
        }
    }

    /// @dev An approved payment out of the treasury, to someone outside the fleet, of a share of
    /// its ETH, REGENT, USDC or bound launch token, which takes exactly that share of the balance.
    function pay(uint256 fleetSeed, uint256 assetSeed, uint256 share) external {
        KeyfleetManager f = fleets[fleetSeed % 2];
        KeyfleetTreasury treasury = f.TREASURY();
        address[4] memory assets = [NATIVE, address(regent), address(usdc), address(treasury.launchToken())];
        uint256 pick = assetSeed % 4;
        if (pick == 3 && assets[3] == address(0)) return;
        address asset = assets[pick];
        uint32 sharePpm = uint32(bound(share, 1, 990_000));
        uint256 balance = _balanceOf(asset, address(treasury));
        uint256 amount = balance * sharePpm / 1_000_000;
        if (amount == 0) return;
        address outsider = address(uint160(0xD00D00 + assetSeed % 4));
        _batch(f, abi.encodeCall(KeyfleetTreasury.pay, (asset, outsider, sharePpm)));
        if (_balanceOf(asset, address(treasury)) != balance - amount) {
            _breach("a payment did not take exactly its share");
        }
    }

    // --- the daily split ----------------------------------------------------

    /// @dev Anyone's run: it goes through exactly when a day has passed since the last run, or since
    /// the first mint, and splits exactly the formula on the treasury's own balances among the
    /// mature keys.
    function runDailySplit(uint256 fleetSeed) external {
        uint256 index = fleetSeed % 2;
        KeyfleetTreasury treasury = fleets[index].TREASURY();
        uint256 opensAt = treasury.nextRunAt();
        bool due = opensAt != 0 && block.timestamp >= opensAt;
        Snapshot memory before = _snapshot(fleets[index]);
        vm.prank(address(0x7EE9E2));
        (bool ran,) = address(treasury).call(abi.encodeCall(KeyfleetTreasury.runDailySplit, ()));
        if (ran != due) _breach(ran ? "a public run went through before it was due" : "a due public run was refused");
        if (ran) _checkSplit(index, before);
    }

    /// @dev An approved proposal's run, at any time.
    function runVotedSplit(uint256 fleetSeed) external {
        uint256 index = fleetSeed % 2;
        if (fleets[index].totalMinted() == 0) return;
        Snapshot memory before = _snapshot(fleets[index]);
        _batch(fleets[index], abi.encodeCall(KeyfleetTreasury.runVotedSplit, ()));
        _checkSplit(index, before);
    }

    function setRate(uint256 fleetSeed, uint256 bps) external {
        KeyfleetManager f = fleets[fleetSeed % 2];
        bps = bound(bps, 0, 250);
        bool valid = bps >= 10 && bps <= 200;
        bool set = _tryBatch(f, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (bps)));
        if (set != valid) _breach("a rate was accepted or refused against the 10 to 200 rule");
        if (set && f.TREASURY().dailySplitBps() != bps) _breach("an accepted rate was not set");
    }

    function admitOusd(uint256 fleetSeed) external {
        KeyfleetManager f = fleets[fleetSeed % 2];
        bool fresh = address(f.TREASURY().ousd()) == address(0);
        bool admitted = _tryBatch(f, abi.encodeCall(KeyfleetTreasury.admitOusd, (IERC20(address(ousd)))));
        if (admitted != fresh) _breach("OUSD was admitted twice or refused the first time");
    }

    // --- the fleet's launch ------------------------------------------------------

    /// @dev An approved proposal's call launches a token through Autolaunch, naming this fleet's
    /// treasury as the launch's treasury, or one time in four the other fleet's.
    function launch(uint256 fleetSeed, uint256 namesSeed) external {
        if (autolaunch.nextLaunchId() > MAX_LAUNCHES) return;
        uint256 index = fleetSeed % 2;
        address named = address(fleets[namesSeed % 4 == 1 ? 1 - index : index].TREASURY());
        IRegentsAutolaunchFactoryV2.LaunchParams memory params = IRegentsAutolaunchFactoryV2.LaunchParams({
            name: "Fleet Token",
            symbol: "FLEET",
            description: "The fleet's own token.",
            website: "https://keyfleet.ai",
            image: "https://keyfleet.ai/fleet.png",
            treasury: named
        });
        lastLaunch[index] = autolaunch.nextLaunchId();
        _batchTo(fleets[index], address(autolaunch), abi.encodeCall(IRegentsAutolaunchFactoryV2.launch, (params)));
    }

    /// @dev An active launch's auction ends, usually the fleet's last launch: it sells, or one time
    /// in three it fails. Either is final.
    function settleLaunch(uint256 fleetSeed, uint256 idSeed) external {
        uint256 id = _launchId(fleetSeed, idSeed);
        if (id == 0 || _lifecycle(id) != IRegentLBPStrategyV2.Lifecycle.Active) return;
        if ((idSeed >> 2) % 3 == 1) autolaunch.fail(id);
        else autolaunch.graduate(id);
    }

    /// @dev A sold launch's escrow releases vested tokens, usually the fleet's last launch, paying
    /// them to the launch's treasury, bound or not, as `release()` does.
    function releaseVested(uint256 fleetSeed, uint256 idSeed, uint256 amount) external {
        uint256 id = _launchId(fleetSeed, idSeed);
        if (id == 0 || _lifecycle(id) != IRegentLBPStrategyV2.Lifecycle.Graduated) return;
        IRegentsAutolaunchFactoryV2.Launch memory launched = autolaunch.launches(id);
        MockLaunchToken(launched.subject).mint(launched.treasury, bound(amount, 100e18, 1_000_000e18));
    }

    /// @dev Anyone tries to bind a launch to either fleet: usually the fleet's last launch,
    /// otherwise any id, launched or not. It binds exactly when the fleet has none bound, its
    /// treasury both made the launch and is named as its treasury, and the launch sold; and then it
    /// binds that launch's token with its threshold.
    function bindLaunchToken(uint256 fleetSeed, uint256 idSeed) external {
        KeyfleetTreasury treasury = fleets[fleetSeed % 2].TREASURY();
        uint256 id = _launchId(fleetSeed, idSeed);
        IRegentsAutolaunchFactoryV2.Launch memory launched = autolaunch.launches(id);
        bool due = address(treasury.launchToken()) == address(0) && launched.launcher == address(treasury)
            && launched.treasury == address(treasury) && _lifecycle(id) == IRegentLBPStrategyV2.Lifecycle.Graduated;
        vm.prank(address(0x5EED));
        (bool bound_,) = address(treasury).call(abi.encodeCall(KeyfleetTreasury.bindLaunchToken, (id)));
        if (bound_ != due) {
            _breach(bound_ ? "a launch was bound against the rules" : "a launch due to bind was refused");
        }
        if (
            bound_
                && (address(treasury.launchToken()) != launched.subject
                    || treasury.launchId() != id
                    || treasury.launchTokenThreshold() != 100e18)
        ) _breach("a bound launch did not record its token, id and threshold");
    }

    // --- claims ---------------------------------------------------------------

    /// @dev A holder, a former holder or an agent presses claim for some keys and assets. Each key's
    /// holder is paid what the key accrued plus their credit, the caller its own credit, and
    /// nobody else anything.
    function claim(uint256 fleetSeed, uint256 callerSeed, uint256 keyMask, uint256 assetMask, bool asAgent) external {
        uint256 index = fleetSeed % 2;
        KeyfleetManager f = fleets[index];
        Claim memory c;
        c.caller = asAgent ? agent(callerSeed % AGENTS) : _holderOrFormer(f, callerSeed);
        c.ids = _claimable(f, c.caller, keyMask);
        c.assets = _pickAssets(f.REWARDS(), assetMask);
        if (c.assets.length == 0) return;
        c.payees = _payees(c.caller, c.ids);
        c.expected = new uint256[](c.assets.length);
        c.balances = new uint256[](c.assets.length);
        uint256 total;
        for (uint256 a = 0; a < c.assets.length; ++a) {
            c.expected[a] = _owed(f, c.assets[a], c.payees, c.ids);
            c.balances[a] = _sumBalances(c.assets[a], c.payees);
            total += c.expected[a];
        }

        KeyfleetRewards rewards = f.REWARDS();
        vm.prank(c.caller);
        (bool ok, bytes memory returned) =
            address(rewards).call(abi.encodeCall(KeyfleetRewards.claim, (c.ids, c.assets)));
        if (ok != (total > 0)) {
            _breach(ok ? "a claim with nothing owed went through" : "a claim with money owed was refused");
        } else if (ok) {
            _checkClaim(index, c, abi.decode(returned, (uint256[])));
        }
    }

    // --- internals --------------------------------------------------------

    /// @dev Mostly a key's holder; one time in four any actor, who may be a former holder.
    function _holderOrFormer(KeyfleetManager f, uint256 seed) internal view returns (address) {
        uint256 minted = f.totalMinted();
        if (minted == 0 || seed % 4 == 0) return actor(seed % ACTORS);
        return keys.ownerOf(keys.tokenIdOf(f.FLEET_ID(), 1 + (seed >> 2) % minted));
    }

    struct Claim {
        address caller;
        uint256[] ids;
        address[] assets;
        address[] payees;
        uint256[] expected;
        uint256[] balances;
    }

    function _checkClaim(uint256 index, Claim memory c, uint256[] memory paid) internal {
        for (uint256 a = 0; a < c.assets.length; ++a) {
            if (paid[a] != c.expected[a]) _breach("a claim paid other than what was owed");
            if (_sumBalances(c.assets[a], c.payees) - c.balances[a] != c.expected[a]) {
                _breach("a claim's payees were not paid exactly what was owed");
            }
            claimed[index][c.assets[a]] += paid[a];
        }
    }

    struct Snapshot {
        uint256 keys;
        uint256 bps;
        address[] assets;
        uint256[] thresholds;
        uint256[] balances;
        uint256[] indexes;
    }

    function _snapshot(KeyfleetManager f) internal view returns (Snapshot memory s) {
        KeyfleetTreasury treasury = f.TREASURY();
        KeyfleetRewards rewards = f.REWARDS();
        s.keys = f.matureKeys();
        s.bps = treasury.dailySplitBps();
        s.assets = treasury.splitAssets();
        s.thresholds = new uint256[](s.assets.length);
        s.balances = new uint256[](s.assets.length);
        s.indexes = new uint256[](s.assets.length);
        s.thresholds[0] = treasury.ETH_THRESHOLD();
        s.thresholds[1] = treasury.REGENT_THRESHOLD();
        s.thresholds[2] = treasury.USDC_THRESHOLD();
        for (uint256 i = 3; i < s.assets.length; ++i) {
            s.thresholds[i] = s.assets[i] == address(ousd) ? treasury.ousdThreshold() : treasury.launchTokenThreshold();
        }
        for (uint256 i = 0; i < s.assets.length; ++i) {
            s.balances[i] = _balanceOf(s.assets[i], address(treasury));
            s.indexes[i] = rewards.splitIndex(s.assets[i]);
        }
    }

    function _checkSplit(uint256 index, Snapshot memory before) internal {
        KeyfleetManager f = fleets[index];
        KeyfleetTreasury treasury = f.TREASURY();
        KeyfleetRewards rewards = f.REWARDS();
        if (treasury.lastRunAt() != block.timestamp) _breach("a run did not record when it ran");
        for (uint256 i = 0; i < before.assets.length; ++i) {
            address asset = before.assets[i];
            uint256 perKey = before.keys == 0 || before.balances[i] < before.thresholds[i]
                ? 0
                : Math.mulDiv(before.balances[i], before.bps, 10_000) / before.keys;
            if (rewards.splitIndex(asset) - before.indexes[i] != perKey) {
                _breach("a key's share differed from the formula on the treasury's own balance");
            }
            if (_balanceOf(asset, address(treasury)) != before.balances[i] - perKey * before.keys) {
                _breach("the treasury did not keep exactly its balance less the shares");
            }
            allocated[index][asset] += perKey * before.keys;
        }
    }

    function _batch(KeyfleetManager f, bytes memory data) internal {
        _batchTo(f, address(f.TREASURY()), data);
    }

    function _batchTo(KeyfleetManager f, address target, bytes memory data) internal {
        KeyfleetTreasury treasury = f.TREASURY();
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](1);
        calls[0] = KeyfleetTreasury.Call(target, 0, data);
        vm.prank(address(f.VOTES()));
        treasury.executeBatch(calls);
    }

    /// @dev Three times in four the fleet's last launch, otherwise any id up to one past the last
    /// launch.
    function _launchId(uint256 fleetSeed, uint256 idSeed) internal view returns (uint256) {
        if (idSeed % 4 != 1) return lastLaunch[fleetSeed % 2];
        return (idSeed >> 2) % (autolaunch.nextLaunchId() + 1);
    }

    function _lifecycle(uint256 id) internal view returns (IRegentLBPStrategyV2.Lifecycle) {
        return autolaunch.strategy().distribution(autolaunch.launches(id).auction).lifecycle;
    }

    function _tryBatch(KeyfleetManager f, bytes memory data) internal returns (bool) {
        KeyfleetTreasury treasury = f.TREASURY();
        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](1);
        calls[0] = KeyfleetTreasury.Call(address(treasury), 0, data);
        vm.prank(address(f.VOTES()));
        (bool ok,) = address(treasury).call(abi.encodeCall(KeyfleetTreasury.executeBatch, (calls)));
        return ok;
    }

    /// @dev The keys in `mask` the caller may claim for: those it holds, or holds an active shard of.
    function _claimable(KeyfleetManager f, address caller, uint256 mask) internal view returns (uint256[] memory ids) {
        uint256 minted = f.totalMinted();
        ids = new uint256[](minted);
        uint256 count;
        for (uint256 k = 1; k <= minted; ++k) {
            if ((mask >> (k % 256)) & 1 == 0) continue;
            uint256 tokenId = keys.tokenIdOf(f.FLEET_ID(), k);
            if (keys.ownerOf(tokenId) == caller || shards.isActive(tokenId, caller)) ids[count++] = tokenId;
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    function _pickAssets(KeyfleetRewards rewards, uint256 mask) internal view returns (address[] memory assets) {
        address[] memory all = rewards.rewardAssets();
        assets = new address[](all.length);
        uint256 count;
        for (uint256 i = 0; i < all.length; ++i) {
            if ((mask >> i) & 1 == 1) assets[count++] = all[i];
        }
        assembly ("memory-safe") {
            mstore(assets, count)
        }
    }

    function _payees(address caller, uint256[] memory ids) internal view returns (address[] memory list) {
        list = new address[](ids.length + 1);
        list[0] = caller;
        uint256 count = 1;
        for (uint256 i = 0; i < ids.length; ++i) {
            address holder = keys.ownerOf(ids[i]);
            bool listed;
            for (uint256 p = 0; p < count; ++p) {
                if (list[p] == holder) listed = true;
            }
            if (!listed) list[count++] = holder;
        }
        assembly ("memory-safe") {
            mstore(list, count)
        }
    }

    function _owed(KeyfleetManager f, address asset, address[] memory payees, uint256[] memory ids)
        internal
        view
        returns (uint256 amount)
    {
        KeyfleetRewards rewards = f.REWARDS();
        for (uint256 p = 0; p < payees.length; ++p) {
            amount += rewards.credits(asset, payees[p]);
        }
        for (uint256 i = 0; i < ids.length; ++i) {
            amount += rewards.accrued(asset, ids[i]);
        }
    }

    function _sumBalances(address asset, address[] memory accounts) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < accounts.length; ++i) {
            sum += _balanceOf(asset, accounts[i]);
        }
    }

    function _balanceOf(address asset, address account) internal view returns (uint256) {
        return asset == NATIVE ? account.balance : IERC20(asset).balanceOf(account);
    }

    function _breach(string memory reason) internal {
        if (bytes(breach).length == 0) breach = reason;
    }
}

/// @dev The fleet-wide invariants of plan §4.6 and §4.8 over each fleet's four contracts, with Sean's daily
/// split rules of 6 October: the ledger always holds what it owes in every asset; in every asset
/// only the split pays, what it holds is exactly what the keys and wallets are owed, which is
/// exactly what was allocated less what was claimed, launched tokens included; the rate stays
/// between 10 and 200 bps; the funding flag is down outside a run; an unadmitted OUSD or a launched
/// token other than the fleet's bound one is never split; a bound launch is the fleet's own sold
/// launch; and agents are never paid. The handler's own checks, which must never have been
/// breached, cover run timing, the split formula over the mature keys on the treasury's own
/// balance, exact claims, which launches bind, every purchase's USDC staying with the manager and
/// the ledger, and every piece's REGENT reaching the treasury.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract KeyfleetFleetInvariantTest is KeyfleetFixture {
    address private constant NATIVE = address(0);

    FleetHandler internal handler;
    MockToken internal ousd;

    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        ousd = new MockToken("Origin Dollar", "OUSD");
        handler = new FleetHandler(
            _deploy(KeyfleetPresets.Preset.FibonacciCascade),
            _deploy(KeyfleetPresets.Preset.FleetTechAccelerant),
            shards,
            usdc,
            regent,
            ousd,
            autolaunch
        );
        targetContract(address(handler));
    }

    function invariant_noStepBrokeTheRules() public view {
        assertEq(handler.breach(), "");
    }

    /// @dev In ETH, REGENT, OUSD and every launched token the split is the only way in: the
    /// ledger's balance is exactly its backing, which is exactly every key's unsettled share plus
    /// every wallet's credit, and exactly what the split allocated less what claims paid.
    function invariant_splitAssetsAreOwedExactlyWhatTheLedgerHolds() public view {
        address[] memory assets = _splitOnlyAssets();
        for (uint256 f = 0; f < 2; ++f) {
            KeyfleetManager fleet = handler.fleet(f);
            KeyfleetRewards rewards = fleet.REWARDS();
            for (uint256 a = 0; a < assets.length; ++a) {
                address asset = assets[a];
                uint256 backed = rewards.backed(asset);
                assertEq(_balanceOf(asset, address(rewards)), backed, "the ledger holds exactly its backing");
                assertEq(_owedToAll(fleet, asset), backed, "which is exactly what keys and wallets are owed");
                assertEq(
                    handler.allocated(f, asset) - handler.claimed(f, asset),
                    backed,
                    "which is what was allocated less what was claimed"
                );
            }
        }
    }

    /// @dev USDC also comes in through the cohort lane, whose per-key remainder below one unit
    /// stays in the ledger: backing covers everything owed, short of it by under a unit per key.
    function invariant_usdcBackingCoversWhatIsOwed() public view {
        for (uint256 f = 0; f < 2; ++f) {
            KeyfleetManager fleet = handler.fleet(f);
            KeyfleetRewards rewards = fleet.REWARDS();
            uint256 backed = rewards.backed(address(usdc));
            uint256 owed = _owedToAll(fleet, address(usdc));
            assertGe(usdc.balanceOf(address(rewards)), backed, "the ledger holds its USDC backing");
            assertGe(backed, owed, "backing covers every key and wallet");
            assertLe(backed - owed, fleet.totalMinted(), "short of it by under a unit per key");
        }
    }

    function invariant_theRateStaysInRangeAndTheFlagIsDown() public view {
        for (uint256 f = 0; f < 2; ++f) {
            KeyfleetTreasury treasury = handler.fleet(f).TREASURY();
            uint256 bps = treasury.dailySplitBps();
            assertGe(bps, 10);
            assertLe(bps, 200);
            assertFalse(treasury.splitInProgress(), "the funding flag is up only inside a run");
            assertLe(treasury.lastRunAt(), block.timestamp);
        }
    }

    function invariant_anUnadmittedOrUnboundTokenIsNeverSplit() public view {
        uint256 launches = autolaunch.nextLaunchId() - 1;
        for (uint256 f = 0; f < 2; ++f) {
            KeyfleetManager fleet = handler.fleet(f);
            KeyfleetTreasury treasury = fleet.TREASURY();
            if (address(treasury.ousd()) == address(0)) {
                assertEq(fleet.REWARDS().splitIndex(address(ousd)), 0);
            }
            for (uint256 id = 1; id <= launches; ++id) {
                address token = autolaunch.launches(id).subject;
                if (token != address(treasury.launchToken())) {
                    assertEq(fleet.REWARDS().splitIndex(token), 0, "a launched token the fleet has not bound");
                }
            }
        }
    }

    /// @dev A bound launch was made by the fleet's own treasury, names it, and sold.
    function invariant_aBoundLaunchIsTheFleetsOwnSoldLaunch() public view {
        for (uint256 f = 0; f < 2; ++f) {
            KeyfleetTreasury treasury = handler.fleet(f).TREASURY();
            if (address(treasury.launchToken()) == address(0)) continue;
            IRegentsAutolaunchFactoryV2.Launch memory launched = autolaunch.launches(treasury.launchId());
            assertEq(launched.subject, address(treasury.launchToken()));
            assertEq(launched.launcher, address(treasury));
            assertEq(launched.treasury, address(treasury));
            assertEq(
                uint256(autolaunch.strategy().distribution(launched.auction).lifecycle),
                uint256(IRegentLBPStrategyV2.Lifecycle.Graduated)
            );
        }
    }

    /// @dev Agents press claim but are never paid and never owed.
    function invariant_agentsAreNeverPaid() public view {
        address[] memory split = _splitOnlyAssets();
        address[] memory assets = new address[](split.length + 1);
        assets[0] = address(usdc);
        for (uint256 a = 0; a < split.length; ++a) {
            assets[a + 1] = split[a];
        }
        for (uint256 i = 0; i < 3; ++i) {
            address wallet = handler.agent(i);
            for (uint256 a = 0; a < assets.length; ++a) {
                assertEq(_balanceOf(assets[a], wallet), 0, "an agent's balance");
                for (uint256 f = 0; f < 2; ++f) {
                    assertEq(handler.fleet(f).REWARDS().credits(assets[a], wallet), 0, "an agent's credit");
                }
            }
        }
    }

    /// @dev ETH, REGENT, OUSD and every token launched so far, by either fleet.
    function _splitOnlyAssets() private view returns (address[] memory assets) {
        uint256 launches = autolaunch.nextLaunchId() - 1;
        assets = new address[](3 + launches);
        (assets[0], assets[1], assets[2]) = (NATIVE, address(regent), address(ousd));
        for (uint256 id = 1; id <= launches; ++id) {
            assets[2 + id] = autolaunch.launches(id).subject;
        }
    }

    /// @dev Every key's unsettled amount plus every actor's credit; only actors ever hold keys.
    function _owedToAll(KeyfleetManager fleet, address asset) private view returns (uint256 owed) {
        KeyfleetRewards rewards = fleet.REWARDS();
        uint256 minted = fleet.totalMinted();
        for (uint256 k = 1; k <= minted; ++k) {
            owed += rewards.accrued(asset, _key(fleet, k));
        }
        for (uint256 i = 0; i < 16; ++i) {
            owed += rewards.credits(asset, handler.actor(i));
        }
    }

    function _balanceOf(address asset, address account) private view returns (uint256) {
        return asset == NATIVE ? account.balance : IERC20(asset).balanceOf(account);
    }
}
