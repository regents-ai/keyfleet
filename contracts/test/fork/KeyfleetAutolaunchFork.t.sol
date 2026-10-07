// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DeployKeyfleets} from "../../script/DeployKeyfleets.s.sol";
import {KeyfleetStack} from "../../script/KeyfleetStack.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {IRegentLBPStrategyV2} from "../../src/interfaces/IRegentLBPStrategyV2.sol";
import {IRegentRevenueStaking} from "../../src/interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "../../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";

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
    function BID_TICK_SPACING_Q96() external view returns (uint256);
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
/// factory, strategy, auction, escrow, splitter and receiver. It runs only when `BASE_RPC_URL` is
/// set in the environment, and skips itself otherwise; the URL is never printed. The fork is pinned
/// to a block after the factory was deployed, so reruns read from the cache.
///
/// The fleet launches by an approved proposal's call; the launch is refused binding while its
/// auction runs; one bid sells it, and once anyone settles it the treasury holds its share of the
/// raise and anyone binds its token. A USDC payment through the launch's receiver reaches the
/// treasury less Autolaunch's 2% to REGENT staking, and the treasury splits the launch token only
/// from what the escrow has released to it.
contract KeyfleetAutolaunchForkTest is Test {
    uint256 private constant FORK_BLOCK = 52_272_000;
    address private constant BUYER = address(0xB0B0B0);
    address private constant BIDDER = address(0xB1DD3E);
    address private constant PAYER = address(0x9A7E2);
    address private constant KEEPER = address(0x7EE9E2);
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev A bid that sells the whole auction at ten ticks above the floor, as Autolaunch's own
    /// graduation tests place it.
    uint128 private constant BID = 1_084_202_174;

    DeployKeyfleets private script;
    IRegentsAutolaunchFactoryV2 private factory;
    IERC20 private usdc;
    IERC20 private regent;
    Keyfleet private fleet;
    KeyfleetTreasury private treasury;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        script = new DeployKeyfleets();
        IVRFCoordinatorV2Plus coordinator = IVRFCoordinatorV2Plus(script.BASE_VRF_COORDINATOR());
        uint256 subscriptionId = coordinator.createSubscription();
        factory = IRegentsAutolaunchFactoryV2(script.BASE_AUTOLAUNCH_FACTORY());
        usdc = IERC20(script.BASE_USDC());
        regent = IERC20(script.BASE_REGENT());

        fleet = KeyfleetStack.deploy(
            KeyfleetPresets.Preset.FleetTechClassic,
            IERC20Metadata(address(usdc)),
            IRegentRevenueStaking(script.BASE_REGENT_REVENUE_STAKING()),
            IERC20Metadata(address(regent)),
            factory,
            Keyfleet.Metadata("Keyfleet Classic", "KEYFLEET", "https://keyfleet.ai/metadata/classic/"),
            Keyfleet.Randomness({
                coordinator: coordinator, subscriptionId: subscriptionId, keyHash: script.BASE_VRF_KEY_HASH_2_GWEI()
            }),
            keccak256("trait table")
        );
        treasury = fleet.TREASURY();
        deal(address(usdc), BUYER, 1_000e6);
        vm.startPrank(BUYER);
        usdc.approve(address(fleet), type(uint256).max);
        fleet.purchase(BUYER, type(uint256).max, block.timestamp);
        vm.stopPrank();

        // The factory is deployed paused, and only the Regents Safe opens it. On this fork only, the
        // test acts as the Safe to open it, so that a launch can be made at all.
        IAutolaunchSwitch factorySwitch = IAutolaunchSwitch(address(factory));
        assertTrue(factorySwitch.launchesPaused(), "the factory is still paused on Base");
        vm.prank(script.BASE_REGENTS_SAFE());
        factorySwitch.unpauseLaunches();
    }

    function test_aFleetLaunchesSellsBindsAndSplitsItsTokenOnBase() public {
        // 1. The fleet launches by an approved proposal's call, naming its own treasury.
        uint256 launchId = IAutolaunchSwitch(address(factory)).nextLaunchId();
        _execute(_one(address(factory), abi.encodeCall(IRegentsAutolaunchFactoryV2.launch, (_params()))));
        IRegentsAutolaunchFactoryV2.Launch memory launched = factory.launches(launchId);
        assertEq(launched.launcher, address(treasury), "the treasury made the launch");
        assertEq(launched.treasury, address(treasury), "for itself");
        IStrategySettlement strategy = IStrategySettlement(address(factory.strategy()));
        IClearingAuction auction = IClearingAuction(launched.auction);

        // 2. While the auction runs, the launch is not bound; nor ever is one a stranger made naming
        // this treasury.
        vm.expectRevert(abi.encodeWithSelector(KeyfleetTreasury.LaunchNotGraduated.selector, launchId));
        treasury.bindLaunchToken(launchId);
        IRegentsAutolaunchFactoryV2.LaunchParams memory forThisTreasury = _params();
        vm.prank(PAYER);
        (uint256 strangers,,,) = factory.launch(forThisTreasury);
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
        vm.prank(KEEPER);
        strategy.migrate(address(auction));

        IRegentLBPStrategyV2.Distribution memory d = factory.strategy().distribution(address(auction));
        assertEq(uint8(d.lifecycle), uint8(IRegentLBPStrategyV2.Lifecycle.Graduated), "the launch sold");
        assertGe(regent.balanceOf(address(treasury)) - regentBefore, BID / 2, "at least half the raise came home");
        IERC20 token = IERC20(launched.subject);
        assertEq(token.balanceOf(address(treasury)), 0, "nothing of the token is liquid in the treasury yet");

        // 4. Anyone binds it, at 100 tokens.
        vm.prank(KEEPER);
        treasury.bindLaunchToken(launchId);
        assertEq(address(treasury.launchToken()), address(token), "the launched token is bound");
        assertEq(treasury.launchTokenThreshold(), 100e18, "at 100 tokens");
        assertEq(treasury.splitAssets()[3], address(token), "and split last");

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
        vm.prank(KEEPER);
        IVestingEscrow(launched.escrow).release();
        uint256 released = token.balanceOf(address(treasury));
        assertApproxEqAbs(released, escrowed / 2, 1, "half the escrow vested to the treasury");

        vm.prank(KEEPER);
        treasury.runDailySplit();
        uint256 keys = fleet.totalMinted();
        assertEq(
            fleet.REWARDS().splitIndex(address(token)),
            Math.mulDiv(released, treasury.dailySplitBps(), 10_000) / keys,
            "the released tokens were split across the keys"
        );
        assertGt(token.balanceOf(launched.escrow), 0, "the unvested half stayed in the escrow, unsplit");
    }

    /// @dev What the fleet's launch names, with its own treasury as the launch's treasury.
    function _params() private view returns (IRegentsAutolaunchFactoryV2.LaunchParams memory) {
        return IRegentsAutolaunchFactoryV2.LaunchParams({
            name: "Keyfleet Classic",
            symbol: "KFC",
            description: "The token of Keyfleet Classic.",
            website: "https://keyfleet.ai",
            image: "https://keyfleet.ai/classic.png",
            treasury: address(treasury)
        });
    }

    function _one(address target, bytes memory data) private pure returns (KeyfleetTreasury.Call[] memory calls) {
        calls = new KeyfleetTreasury.Call[](1);
        calls[0] = KeyfleetTreasury.Call(target, 0, data);
    }

    /// @dev Key 1's owner proposes `calls` and votes Yes; nobody else is present, so it is approved
    /// once it closes, and carried out.
    function _execute(KeyfleetTreasury.Call[] memory calls) private {
        KeyfleetVotes votes = fleet.VOTES();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.startPrank(BUYER);
        uint256 proposalId = votes.propose(1, keccak256("launch"), uint64(block.timestamp + 1), calls);
        votes.castBallot(proposalId, ids, KeyfleetVotes.Choice.Yes);
        vm.stopPrank();
        vm.warp(votes.proposal(proposalId).closesAt);
        votes.execute(proposalId, calls);
    }
}
