// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {IRegentLBPStrategyV2} from "../../src/interfaces/IRegentLBPStrategyV2.sol";
import {IRegentsAutolaunchFactoryV2} from "../../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {KeyfleetForkFixture} from "./KeyfleetBaseFork.t.sol";

/// @notice The factory's launch switch, which only the Regents Safe flips, and its next launch id.
interface IAutolaunchSwitch {
    function nextLaunchId() external view returns (uint256);
    function launchesPaused() external view returns (bool);
    function unpauseLaunches() external;
}

/// @notice The bid side of the launch's continuous clearing auction.
interface IClearingAuction {
    function submitBid(uint256 maxPrice, uint128 amount, address owner, uint256 prevTickPrice, bytes calldata hookData)
        external
        payable
        returns (uint256 bidId);
    function floorPrice() external view returns (uint256);
    function startBlock() external view returns (uint64);
    function endBlock() external view returns (uint64);
}

/// @notice Permit2's allowance, through which the auction takes a bid's REGENT.
interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice The strategy's settlement call, which anyone may make once the auction has ended.
interface IStrategySettlement {
    function migrate(address auction) external;
    // forge-lint: disable-next-line(mixed-case-function)
    function BID_TICK_SPACING_Q96() external view returns (uint256);
    // forge-lint: disable-next-line(mixed-case-function)
    function MIGRATION_DELAY_BLOCKS() external view returns (uint64);
}

/// @notice The launch's vesting escrow, which pays only the launch's treasury.
interface IVestingEscrow {
    function release() external;
}

/// @notice The launch's canonical payment receiver.
interface IPaymentReceiver {
    function pay(address token, uint256 amount, bytes32 paymentRef) external;
}

/// @dev A whole Autolaunch v2 launch of a fleet's token on a fork of Base, through the real pinned
/// factory, strategy, auction, escrow, splitter and receiver, by Classic #1 of the system deployed
/// from the committed Base manifest. It runs only when `BASE_RPC_URL` is set in the environment,
/// and skips itself otherwise; the URL is never printed. The fork is pinned to a block after the
/// Autolaunch factory was deployed and before it was opened, so reruns read from the cache.
///
/// The fleet launches by an approved proposal's call; the launch is refused binding while its
/// auction runs; one bid sells it, and once anyone settles it the treasury holds its share of the
/// raise and anyone binds its token. A USDC payment through the launch's receiver reaches the
/// treasury less Autolaunch's 2% to REGENT staking, and the treasury splits the launch token only
/// from what the escrow has released to it.
contract KeyfleetAutolaunchForkTest is KeyfleetForkFixture {
    uint256 private constant FORK_BLOCK = 52_272_000;
    address private constant BUYER = address(0xB0B0B0);
    address private constant BIDDER = address(0xB1DD3E);
    address private constant PAYER = address(0x9A7E2);
    address private constant ANYONE = address(0x7EE9E2);
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev A bid that sells the whole auction at ten ticks above the floor, as Autolaunch's own
    /// graduation tests place it.
    uint128 private constant BID = 1_084_202_174;

    IRegentsAutolaunchFactoryV2 private autolaunch;
    KeyfleetManager private classic;
    KeyfleetTreasury private treasury;

    function setUp() public {
        if (!_setUpFork(FORK_BLOCK)) return;
        autolaunch = IRegentsAutolaunchFactoryV2(script.BASE_AUTOLAUNCH_FACTORY());
        _found(1);
        _advancePhase();
        classic = _fleet(1);
        treasury = classic.TREASURY();
        _buy(classic, BUYER);
        _openTreasury(classic);

        // The factory is deployed paused, and only the Regents Safe opens it. On this fork only, the
        // test acts as the Safe to open it, so that a launch can be made at all.
        IAutolaunchSwitch factorySwitch = IAutolaunchSwitch(address(autolaunch));
        assertTrue(factorySwitch.launchesPaused(), "the factory is still paused at the fork block");
        vm.prank(script.BASE_REGENTS_SAFE());
        factorySwitch.unpauseLaunches();
    }

    function test_aFleetLaunchesSellsBindsAndSplitsItsTokenOnBase() public {
        // 1. The fleet launches by an approved proposal's call, naming its own treasury.
        uint256 launchId = IAutolaunchSwitch(address(autolaunch)).nextLaunchId();
        _execute(
            classic,
            _one(
                KeyfleetTreasury.Call(
                    address(autolaunch), 0, abi.encodeCall(IRegentsAutolaunchFactoryV2.launch, (_params()))
                )
            )
        );
        IRegentsAutolaunchFactoryV2.Launch memory launched = autolaunch.launches(launchId);
        assertEq(launched.launcher, address(treasury), "the treasury made the launch");
        assertEq(launched.treasury, address(treasury), "for itself");
        IStrategySettlement strategy = IStrategySettlement(address(autolaunch.strategy()));
        IClearingAuction auction = IClearingAuction(launched.auction);

        // 2. While the auction runs, the launch is not bound; nor ever is one a stranger made naming
        // this treasury.
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.LaunchNotGraduated.selector, launchId));
        treasury.bindLaunchToken(launchId);
        IRegentsAutolaunchFactoryV2.LaunchParams memory forThisTreasury = _params();
        vm.prank(PAYER);
        (uint256 strangers,,,) = autolaunch.launch(forThisTreasury);
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.NotOwnLaunch.selector, strangers));
        treasury.bindLaunchToken(strangers);

        // 3. One bid sells the auction; once it has ended anyone settles it.
        vm.roll(auction.startBlock());
        deal(address(regent), BIDDER, BID);
        vm.startPrank(BIDDER);
        regent.approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(address(regent), address(auction), BID, type(uint48).max);
        auction.submitBid(
            auction.floorPrice() + 10 * strategy.BID_TICK_SPACING_Q96(), BID, BIDDER, auction.floorPrice(), ""
        );
        vm.stopPrank();
        vm.roll(uint256(auction.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
        uint256 regentBefore = regent.balanceOf(address(treasury));
        vm.prank(ANYONE);
        strategy.migrate(address(auction));

        IRegentLBPStrategyV2.Distribution memory d = autolaunch.strategy().distribution(address(auction));
        assertEq(uint8(d.lifecycle), uint8(IRegentLBPStrategyV2.Lifecycle.Graduated), "the launch sold");
        assertGe(regent.balanceOf(address(treasury)) - regentBefore, BID / 2, "at least half the raise came home");
        IERC20 token = IERC20(launched.subject);
        assertEq(token.balanceOf(address(treasury)), 0, "nothing of the token is liquid in the treasury yet");

        // 4. Anyone binds it, at 100 tokens.
        vm.prank(ANYONE);
        treasury.bindLaunchToken(launchId);
        assertEq(address(treasury.launchToken()), address(token), "the launched token is bound");
        assertEq(treasury.launchTokenThreshold(), 100e18, "at 100 tokens");
        address[] memory splitAssets = treasury.splitAssets();
        assertEq(splitAssets.length, 4, "ETH, REGENT, USDC and the launch token");
        assertEq(splitAssets[3], address(token), "split last");

        // 5. A payment through the launch's receiver reaches the treasury, less 2% to REGENT staking.
        uint256 treasuryUsdc = usdc.balanceOf(address(treasury));
        uint256 stakingUsdc = usdc.balanceOf(script.BASE_REGENT_REVENUE_STAKING());
        deal(address(usdc), PAYER, 1_000e6);
        vm.startPrank(PAYER);
        usdc.approve(d.receiver, 1_000e6);
        IPaymentReceiver(d.receiver).pay(address(usdc), 1_000e6, keccak256("an order"));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(treasury)) - treasuryUsdc, 980e6, "98% to the treasury, nobody staked");
        assertEq(
            usdc.balanceOf(script.BASE_REGENT_REVENUE_STAKING()) - stakingUsdc, 20e6, "2% to REGENT revenue staking"
        );

        // 6. Half a year on, the escrow releases half its tokens to the treasury, and only those
        // are split.
        uint256 escrowed = token.balanceOf(launched.escrow);
        vm.warp(block.timestamp + 365 days / 2);
        vm.prank(ANYONE);
        IVestingEscrow(launched.escrow).release();
        uint256 released = token.balanceOf(address(treasury));
        assertApproxEqAbs(released, escrowed / 2, 1, "half the escrow vested to the treasury");

        vm.prank(ANYONE);
        treasury.runDailySplit();
        assertEq(
            classic.REWARDS().splitIndex(address(token)),
            Math.mulDiv(released, treasury.dailySplitBps(), 10_000) / classic.totalMinted(),
            "the released tokens were split across the keys"
        );
        assertGt(token.balanceOf(launched.escrow), 0, "the unvested half stayed in the escrow, unsplit");
    }

    /// @dev What the fleet's launch names, with its own treasury as the launch's treasury.
    function _params() private view returns (IRegentsAutolaunchFactoryV2.LaunchParams memory) {
        return IRegentsAutolaunchFactoryV2.LaunchParams({
            name: "Keyfleet Classic",
            symbol: "KFC",
            description: "The token of Keyfleet Classic #1.",
            website: "https://keyfleet.ai",
            image: "https://keyfleet.ai/classic.png",
            treasury: address(treasury)
        });
    }
}
