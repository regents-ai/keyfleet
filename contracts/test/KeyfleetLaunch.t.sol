// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetManager} from "../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../src/KeyfleetRewards.sol";
import {KeyfleetTreasury} from "../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../src/KeyfleetVotes.sol";
import {IRegentsAutolaunchFactoryV2} from "../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {KeyfleetFixture} from "./helpers/KeyfleetFixture.sol";
import {MockLaunchToken} from "./mocks/MockAutolaunchFactory.sol";

/// @dev Plan §9.2, the Autolaunch path: a fleet launches its own token by an approved call to the
/// pinned Autolaunch v2 factory, and once that launch has succeeded anyone may bind its token, once,
/// as the last asset of the daily split, from the next run.
contract KeyfleetLaunchTest is KeyfleetFixture {
    uint256 private constant START = 1_000_000;

    address private stranger = address(0x5743);

    event LaunchTokenBound(uint256 indexed launchId, address indexed token, uint256 threshold);

    function setUp() public {
        _setUpFixture();
        vm.warp(START);
    }

    /// @dev The founding Classic fleet with `count` keys sold, old enough to take part, after its
    /// treasury opening, by when only a renewed key is present.
    function _classic(uint256 count) private returns (KeyfleetManager fleet, KeyfleetTreasury treasury) {
        fleet = _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        treasury = fleet.TREASURY();
        _buyMany(fleet, count);
        _mature();
        _openTreasury(fleet);
    }

    /// @dev A second Classic fleet of the same collection, created openly; its creator holds key 1,
    /// old enough to take part, after its own treasury opening.
    function _otherFleet() private returns (KeyfleetManager fleet, KeyfleetTreasury treasury) {
        fleet = _createOpen(KeyfleetPresets.Preset.FleetTechClassic, 10e6);
        treasury = fleet.TREASURY();
        _mature();
        _openTreasury(fleet);
    }

    function _run(KeyfleetTreasury treasury) private {
        vm.prank(stranger);
        treasury.runDailySplit();
    }

    function _selfCall(KeyfleetTreasury treasury, bytes memory data)
        private
        pure
        returns (KeyfleetTreasury.Call[] memory)
    {
        return _one(address(treasury), 0, data);
    }

    function _perKey(uint256 balance, uint256 keys) private pure returns (uint256) {
        return Math.mulDiv(balance, 50, 10_000) / keys;
    }

    /// @dev Launches the fleet's token, settles the launch as sold, and binds it as a stranger.
    function _launchAndBind(KeyfleetManager fleet) private returns (uint256 launchId, MockLaunchToken token) {
        IERC20 launched;
        (launchId, launched) = _launch(fleet);
        autolaunch.graduate(launchId);
        vm.prank(stranger);
        fleet.TREASURY().bindLaunchToken(launchId);
        token = MockLaunchToken(address(launched));
    }

    /// @dev Proposes `calls`, lets the vote close, and expects carrying them out to revert with
    /// `reason`.
    function _expectExecuteReverts(KeyfleetManager fleet, KeyfleetTreasury.Call[] memory calls, bytes memory reason)
        private
    {
        uint256 proposalId = _approve(fleet, calls);
        KeyfleetVotes votes = fleet.VOTES();
        vm.warp(votes.executableAt(proposalId));
        vm.expectRevert(reason);
        votes.execute(proposalId, calls);
    }

    // --- launching ------------------------------------------------------------------

    /// @dev Invariant: a fleet launches only by an approved call from its treasury, which the factory
    /// records as the launcher, naming that treasury as the launch's treasury. The launch takes
    /// nothing from the treasury.
    function test_aFleetLaunchesByAnApprovedCallNamingItsOwnTreasury() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        uint256 regentBefore = regent.balanceOf(address(treasury));
        uint256 usdcBefore = usdc.balanceOf(address(treasury));

        (uint256 launchId, IERC20 token) = _launch(fleet);

        IRegentsAutolaunchFactoryV2.Launch memory launched = autolaunch.launches(launchId);
        assertEq(launchId, 1, "The factory's first launch");
        assertEq(launched.launcher, address(treasury), "The treasury called the factory");
        assertEq(launched.treasury, address(treasury), "And named itself as the launch's treasury");
        assertEq(launched.subject, address(token), "The launched token");
        assertEq(regent.balanceOf(address(treasury)), regentBefore, "Launching cost the treasury nothing");
        assertEq(usdc.balanceOf(address(treasury)), usdcBefore, "Neither REGENT nor USDC");
        assertEq(address(treasury.launchToken()), address(0), "Launching binds nothing by itself");
    }

    // --- no launch, no TOKEN ----------------------------------------------------------

    /// @dev Invariant: until a launch is bound the daily split shares ETH, REGENT and USDC only, and
    /// no launch id binds anything.
    function test_withoutALaunchThereIsNoLaunchToken() public {
        (, KeyfleetTreasury treasury) = _classic(1);

        assertEq(address(treasury.launchToken()), address(0), "No launch token");
        assertEq(treasury.launchTokenThreshold(), 0, "No threshold");
        assertEq(treasury.launchId(), 0, "No launch");
        assertEq(treasury.splitAssets().length, 3, "ETH, REGENT and USDC only");

        for (uint256 id = 0; id < 3; ++id) {
            vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.NotOwnLaunch.selector, id));
            treasury.bindLaunchToken(id);
        }
    }

    // --- whose launch -------------------------------------------------------------------

    /// @dev Invariant: only a launch this treasury made and named itself the treasury of is bound.
    /// Anyone may call the factory naming the fleet's treasury, and a sold launch costs next to
    /// nothing, so a launch a stranger made is refused even though it pays this treasury; so are a
    /// launch naming another treasury, another fleet's launch, and a launch this treasury made for
    /// another treasury. Each of them sold.
    function test_aLaunchThatIsNotThisTreasurysOwnIsRefused() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        (KeyfleetManager other, KeyfleetTreasury otherTreasury) = _otherFleet();

        vm.prank(stranger);
        (uint256 strangersForThisTreasury,,,) = autolaunch.launch(_launchParams(address(treasury)));
        vm.prank(stranger);
        (uint256 strangersOwn,,,) = autolaunch.launch(_launchParams(stranger));
        (uint256 otherFleets,) = _launch(other);
        uint256 forAnotherTreasury = autolaunch.nextLaunchId();
        _execute(fleet, _launchCall(address(otherTreasury)));

        uint256[4] memory refused = [strangersForThisTreasury, strangersOwn, otherFleets, forAnotherTreasury];
        for (uint256 i = 0; i < refused.length; ++i) {
            autolaunch.graduate(refused[i]);
            vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.NotOwnLaunch.selector, refused[i]));
            treasury.bindLaunchToken(refused[i]);
        }
        assertEq(address(treasury.launchToken()), address(0), "Nothing was bound");

        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.NotOwnLaunch.selector, forAnotherTreasury));
        otherTreasury.bindLaunchToken(forAnotherTreasury);
        otherTreasury.bindLaunchToken(otherFleets);
        assertEq(otherTreasury.launchId(), otherFleets, "The other fleet binds its own launch");
    }

    // --- has it succeeded -------------------------------------------------------------

    /// @dev Invariant: a launch is bound only once the strategy records it as graduated; one still
    /// running and one that failed are refused, and a later launch that sold is bound.
    function test_aLaunchThatHasNotSucceededIsRefused() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        (uint256 running,) = _launch(fleet);
        (uint256 failed,) = _launch(fleet);
        autolaunch.fail(failed);

        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.LaunchNotGraduated.selector, running));
        treasury.bindLaunchToken(running);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.LaunchNotGraduated.selector, failed));
        treasury.bindLaunchToken(failed);

        (uint256 sold, IERC20 token) = _launch(fleet);
        autolaunch.graduate(sold);
        treasury.bindLaunchToken(sold);
        assertEq(address(treasury.launchToken()), address(token), "The launch that sold is bound");
        assertEq(treasury.launchId(), sold);
    }

    // --- once ---------------------------------------------------------------------------

    /// @dev Invariant: anyone may bind the fleet's sold launch, once; the same launch again and a
    /// second sold launch of the same fleet are both refused, and the first stays bound.
    function test_theLaunchTokenIsBoundOnceByAnyone() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        (uint256 first, IERC20 token) = _launch(fleet);
        (uint256 second,) = _launch(fleet);
        autolaunch.graduate(first);
        autolaunch.graduate(second);

        vm.expectEmit(true, true, false, true, address(treasury));
        emit LaunchTokenBound(first, address(token), 100e18);
        vm.prank(stranger);
        treasury.bindLaunchToken(first);

        assertEq(address(treasury.launchToken()), address(token), "The token");
        assertEq(treasury.launchTokenThreshold(), 100e18, "100 tokens of eighteen decimals");
        assertEq(treasury.launchId(), first, "The launch it came from");

        vm.expectRevert(KeyfleetTreasury.LaunchTokenAlreadyBound.selector);
        treasury.bindLaunchToken(first);
        vm.expectRevert(KeyfleetTreasury.LaunchTokenAlreadyBound.selector);
        treasury.bindLaunchToken(second);
        assertEq(treasury.launchId(), first, "The first stays bound");
    }

    /// @dev Invariant: binding runs under the treasury's one lock, so an approved call cannot bind
    /// in the middle of other calls; anyone binds it directly instead.
    function test_bindingSharesTheTreasurysLock() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        (uint256 launchId,) = _launch(fleet);
        autolaunch.graduate(launchId);

        _expectExecuteReverts(
            fleet,
            _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.bindLaunchToken, (launchId))),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(address(treasury.launchToken()), address(0));
    }

    // --- split from the next run --------------------------------------------------------

    /// @dev Invariant: the launch token held before binding is not split; from the run after
    /// binding it is split last, at 100 tokens or more and not below, like every other bound asset.
    function test_theLaunchTokenIsSplitFromTheNextRun() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        (uint256 launchId, IERC20 launched) = _launch(fleet);
        MockLaunchToken token = MockLaunchToken(address(launched));
        token.mint(address(treasury), 100e18 - 1);
        autolaunch.graduate(launchId);

        // The first public run has been due since a day after the first mint.
        _run(treasury);
        assertEq(rewards.splitIndex(address(token)), 0, "Not bound, not split");

        treasury.bindLaunchToken(launchId);
        address[] memory assets = treasury.splitAssets();
        assertEq(assets.length, 4, "ETH, REGENT, USDC and the launch token");
        assertEq(assets[3], address(token), "Split last");

        vm.warp(treasury.nextRunAt());
        _run(treasury);
        assertEq(rewards.splitIndex(address(token)), 0, "Just below its threshold");

        token.mint(address(treasury), 1);
        vm.warp(treasury.nextRunAt());
        _run(treasury);
        assertEq(rewards.splitIndex(address(token)), _perKey(100e18, 2), "At its threshold, from the next run");
        assertEq(
            token.balanceOf(address(rewards)), 2 * _perKey(100e18, 2), "Each key's share reached the fleet's ledger"
        );

        token.mint(address(treasury), 1_000e18);
        uint256 held = token.balanceOf(address(treasury));
        vm.warp(treasury.nextRunAt());
        _run(treasury);
        assertEq(
            rewards.splitIndex(address(token)),
            _perKey(100e18, 2) + _perKey(held, 2),
            "Every later run shares the treasury's own balance only"
        );
    }

    /// @dev Invariant: OUSD and the launch token are never the same asset, so neither is split twice
    /// a run. OUSD cannot be admitted as the bound launch token, and a launch whose token was admitted
    /// as OUSD is not bound. With both, the launch token is split after OUSD.
    function test_ousdAndTheLaunchTokenRefuseEachOther() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(1);
        (, MockLaunchToken token) = _launchAndBind(fleet);
        _expectExecuteReverts(
            fleet,
            _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.admitOusd, (IERC20(address(token))))),
            abi.encodeWithSelector(KeyfleetTreasury.OusdInvalid.selector, address(token))
        );
        MockLaunchToken ousd = new MockLaunchToken("Origin Dollar", "OUSD");
        _execute(fleet, _selfCall(treasury, abi.encodeCall(KeyfleetTreasury.admitOusd, (IERC20(address(ousd))))));
        address[] memory assets = treasury.splitAssets();
        assertEq(assets.length, 5, "ETH, REGENT, USDC, OUSD and the launch token");
        assertEq(assets[3], address(ousd), "OUSD fourth");
        assertEq(assets[4], address(token), "The launch token last");

        (KeyfleetManager other, KeyfleetTreasury otherTreasury) = _otherFleet();
        (uint256 launchId, IERC20 launched) = _launch(other);
        _execute(other, _selfCall(otherTreasury, abi.encodeCall(KeyfleetTreasury.admitOusd, (launched))));
        autolaunch.graduate(launchId);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.LaunchTokenIsOusd.selector, address(launched)));
        otherTreasury.bindLaunchToken(launchId);
    }

    /// @dev Invariant: the ledger takes launch-token funding only from inside the split routine, so
    /// an approved proposal that pays 0.2% of the token to the ledger and funds it reverts.
    function test_anApprovedCallCannotFundASplitOfTheLaunchToken() public {
        (KeyfleetManager fleet, KeyfleetTreasury treasury) = _classic(2);
        KeyfleetRewards rewards = fleet.REWARDS();
        (, MockLaunchToken token) = _launchAndBind(fleet);
        token.mint(address(treasury), 1_000e18);

        KeyfleetTreasury.Call[] memory calls = new KeyfleetTreasury.Call[](2);
        calls[0] = KeyfleetTreasury.Call(
            address(treasury),
            0,
            abi.encodeCall(KeyfleetTreasury.pay, (address(token), address(rewards), uint32(2_000)))
        );
        calls[1] = KeyfleetTreasury.Call(
            address(rewards), 0, abi.encodeCall(KeyfleetRewards.fundSplit, (address(token), 1e18, 2))
        );
        _expectExecuteReverts(fleet, calls, abi.encodeWithSelector(KeyfleetRewards.NotSplitting.selector));

        assertEq(rewards.splitIndex(address(token)), 0, "Nothing was funded");
        assertEq(token.balanceOf(address(treasury)), 1_000e18, "Nothing left the treasury");
    }
}
