// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {IRegentLBPStrategy} from "../../src/interfaces/IRegentLBPStrategy.sol";
import {IRegentsAutolaunchFactoryV1} from "../../src/interfaces/IRegentsAutolaunchFactoryV1.sol";
import {KeyfleetAssetRegistry} from "../../src/KeyfleetAssetRegistry.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {MockStaking} from "../KeyfleetDeposits.t.sol";

/// @dev The pinned continuous clearing auction, as far as a bidder drives it.
interface IForkAuction {
    function startBlock() external view returns (uint64);
    function endBlock() external view returns (uint64);
    function checkpoint() external;
    function clearingPrice() external view returns (uint256);
    function submitBid(uint256 maxPriceQ96, uint128 amount, address owner, uint256 prevTickPriceQ96, bytes calldata)
        external
        returns (uint256 bidId);
}

/// @dev The shared strategy's calls this flow needs beyond what the fleet reads.
interface IForkStrategy {
    function MIGRATION_DELAY_BLOCKS() external view returns (uint64);
    function FLOOR_PRICE_Q96() external view returns (uint256);
    function BID_TICK_Q96() external view returns (uint256);
    function migrate(address auction) external;
}

interface IForkPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IForkEscrow {
    function release() external;
}

interface IForkSplitter {
    function recognizeSurplusRevenue(address token) external;
    function regent() external view returns (address);
    function usdc() external view returns (address);
}

/// @notice The whole post-launch path of one fleet against a running Autolaunch lab: the keys vote
/// a launch through the lab's own factory, one bidder graduates it, and then launch income reaches
/// the fleet the two ways it does after graduation: SUBJECT the escrow releases, and USDC and
/// REGENT the launch's splitter recognizes and pays on. Each is recognized by the fleet and split
/// between the budget and the keys, keys claim, and a Pay vote spends budget.
/// @dev Runs only when `KEYFLEET_FORK_RPC_URL` names a Base-shaped chain with the Autolaunch graph
/// deployed and `KEYFLEET_FORK_FACTORY` names its factory; without them the test skips. Everything
/// happens on a local fork of that chain, so nothing is written to the chain itself. `deal` funds
/// ordinary wallets with USDC and REGENT, and `prank` acts as ordinary holders, a bidder, a payer and
/// the stand-in Safe this test deploys its own registry with; no lab role is taken over.
contract KeyfleetLaunchIncomeForkTest is Test {
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant REGENT = 0x6f89bcA4eA5931EdFCB09786267b251DeE752b07;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint64 private constant VOTING_WINDOW = 24 hours;
    uint128 private constant RAISE = 1_000e18;
    uint128 private constant BID = 4_000e18;

    address private safe = makeAddr("fleet-registry-safe");
    address private regentTreasury = makeAddr("regent-treasury");
    address private buyer = makeAddr("keyfleet-fork-buyer");
    address private alice = makeAddr("keyfleet-fork-alice");
    address private bidder = makeAddr("keyfleet-fork-bidder");
    address private payer = makeAddr("keyfleet-fork-payer");
    address private contributor = makeAddr("keyfleet-fork-contributor");

    Keyfleet private fleet;
    KeyfleetVotes private votes;
    KeyfleetRewards private rewards;
    KeyfleetAssetRegistry private registry;
    IForkStrategy private strategy;

    event LaunchIncomeSplit(
        address indexed asset, address indexed caller, uint256 gross, uint256 fee, uint256 toBudget, uint256 toKeys
    );

    function test_launchIncomeReachesTheKeysAndTheBudget() public {
        string memory rpc = vm.envOr("KEYFLEET_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        IRegentsAutolaunchFactoryV1 factory = IRegentsAutolaunchFactoryV1(vm.envAddress("KEYFLEET_FORK_FACTORY"));
        strategy = IForkStrategy(address(factory.strategy()));
        assertFalse(factory.launchesPaused(), "the lab's factory is not taking launches");

        registry = new KeyfleetAssetRegistry(safe, USDC);
        fleet = new Keyfleet(
            KeyfleetPresets.Preset.FibonacciSyndicate,
            IERC20(USDC),
            regentTreasury,
            registry,
            new MockStaking(IERC20(USDC)),
            factory,
            VOTING_WINDOW,
            Keyfleet.Metadata("Keyfleet Fork", "KFF", "https://keys.regents.sh/fork/")
        );
        votes = fleet.VOTES();
        rewards = fleet.REWARDS();

        _buyKeys(KeyfleetPresets.FIBONACCI_AUTOLAUNCH_MIN_KEYS);
        address auction = _launch();
        _bidAndGraduate(auction);

        Keyfleet.LaunchRecord memory record = fleet.launchRecord();
        _admit(REGENT);
        _admit(record.subject);
        _admit(USDC);

        IForkSplitter splitter = IForkSplitter(record.splitter);
        assertEq(splitter.regent(), REGENT, "the lab's REGENT is Base REGENT");
        assertEq(splitter.usdc(), USDC, "the lab's USDC is Base USDC");

        // 1. A month of vesting: the escrow releases SUBJECT to the fleet.
        vm.warp(block.timestamp + 30 days);
        IForkEscrow(record.escrow).release();
        _recognizeAndCheckSplit(record.subject);

        // 2. USDC and REGENT paid to the launch's splitter: with nothing staked, all but the
        // splitter's 2% is paid on to the fleet as the launch's treasury.
        _payThroughSplitter(splitter, USDC, 10_000e6);
        _recognizeAndCheckSplit(USDC);
        _payThroughSplitter(splitter, REGENT, 5_000e18);
        _recognizeAndCheckSplit(REGENT);

        _claimAndCompareLevels(record.subject);
        _payFromBudget(record.subject);
    }

    // --- stages ------------------------------------------------------------

    /// @dev Key 1 to `alice`; every later key to its own wallet, which makes `alice` its delegate.
    function _buyKeys(uint256 count) private {
        for (uint256 i = 0; i < count; ++i) {
            uint256 tokenId = fleet.totalMinted() + 1;
            address holder = _holder(tokenId);
            uint256 price = fleet.nextPrice();
            deal(USDC, buyer, price);
            vm.startPrank(buyer);
            IERC20(USDC).approve(address(fleet), price);
            fleet.purchase(holder, address(0), price, block.timestamp);
            vm.stopPrank();
            if (holder != alice) {
                vm.prank(holder);
                votes.setVotingDelegate(alice);
            }
        }
    }

    function _launch() private returns (address auction) {
        Keyfleet.LaunchEnvelope memory envelope = Keyfleet.LaunchEnvelope({
            name: "Keyfleet Fork Token",
            symbol: "KFFT",
            description: "The token a fork-test fleet voted to launch.",
            website: "https://regents.sh/fork",
            image: "ipfs://fork-image",
            requiredRegentRaised: RAISE,
            narrativeDigest: keccak256("fork narrative"),
            executionExpiry: uint64(block.timestamp) + VOTING_WINDOW + 7 days
        });
        vm.prank(alice);
        uint256 proposalId = votes.proposeAutolaunch(1, envelope);
        _passAll(proposalId);
        votes.execute(proposalId);
        auction = fleet.launchRecord().auction;
    }

    /// @dev One bid from an ordinary wallet, the way a connected wallet makes it: approve Permit2,
    /// allow the auction through Permit2, and bid on the tick grid above the live clearing price.
    function _bidAndGraduate(address auction) private {
        IForkAuction cca = IForkAuction(auction);
        vm.roll(cca.startBlock());
        cca.checkpoint();
        uint256 tick = strategy.BID_TICK_Q96();
        uint256 base = cca.clearingPrice();
        if (base < strategy.FLOOR_PRICE_Q96()) base = strategy.FLOOR_PRICE_Q96();
        uint256 price = base - (base % tick) + 11 * tick;

        deal(REGENT, bidder, BID);
        vm.startPrank(bidder);
        IERC20(REGENT).approve(PERMIT2, BID);
        IForkPermit2(PERMIT2).approve(REGENT, auction, uint160(BID), uint48(block.timestamp + 1 days));
        cca.submitBid(price, BID, bidder, strategy.FLOOR_PRICE_Q96(), "");
        vm.stopPrank();

        vm.roll(uint256(cca.endBlock()) + strategy.MIGRATION_DELAY_BLOCKS());
        strategy.migrate(auction);
        assertEq(uint256(fleet.syncLaunch()), uint256(Keyfleet.LaunchState.Graduated), "the launch graduated");
        assertEq(
            uint256(fleet.launchDistribution().lifecycle),
            uint256(IRegentLBPStrategy.Lifecycle.Graduated),
            "as the strategy reports it"
        );
    }

    /// @dev Recognizes the fleet's whole surplus in `asset` and checks the split to the unit: the
    /// fee, the budget and the keys' part are the gross, and the ledger holds what it owes.
    function _recognizeAndCheckSplit(address asset) private {
        uint256 gross = fleet.surplus(asset);
        assertGt(gross, 0, "income arrived");
        uint256 fee = (gross * 200) / 10_000;
        uint256 toBudget = ((gross - fee) * fleet.BUDGET_BPS()) / 10_000;
        uint256 toKeys = gross - fee - toBudget;
        uint256 budgetBefore = fleet.freeCapital(asset);
        uint256 backedBefore = rewards.isRewardAsset(asset) ? rewards.backed(asset) : 0;

        vm.expectEmit(true, true, true, true, address(fleet));
        emit LaunchIncomeSplit(asset, address(this), gross, fee, toBudget, toKeys);
        fleet.recognizeSurplus(asset);

        assertEq(fleet.freeCapital(asset) - budgetBefore, toBudget, "the budget's part");
        assertEq(rewards.backed(asset) - backedBefore, toKeys, "the keys' part");
        assertGe(IERC20(asset).balanceOf(address(rewards)), rewards.backed(asset), "the ledger is backed");
        assertEq(fleet.surplus(asset), 0, "nothing is left unaccounted");
        console2.log("recognized", gross, "units of", asset);
    }

    /// @dev A level-1 key and a level-7 key claim their SUBJECT; the first receives seventeen times
    /// the second.
    function _claimAndCompareLevels(address subject) private {
        uint256 early = _claim(subject, 1);
        uint256 late = _claim(subject, KeyfleetPresets.FIBONACCI_AUTOLAUNCH_MIN_KEYS);
        assertGt(late, 0, "the level-7 key was paid");
        assertApproxEqRel(early, 17 * late, 1e13, "a level-1 key receives seventeen times a level-7 key");
    }

    function _claim(address asset, uint256 tokenId) private returns (uint256 paid) {
        address holder = _holder(tokenId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256 before = IERC20(asset).balanceOf(holder);
        vm.prank(holder);
        paid = rewards.claim(asset, ids, address(0));
        assertEq(IERC20(asset).balanceOf(holder) - before, paid, "the holder received the claim");
    }

    /// @dev The keys vote to pay a contributor the whole period cap of the SUBJECT budget.
    function _payFromBudget(address subject) private {
        uint256 amount = (fleet.freeCapital(subject) * fleet.PAY_CAP_BPS()) / 10_000;
        vm.prank(alice);
        uint256 proposalId =
            votes.proposePay(1, subject, amount, contributor, "Pay the contributor", keccak256("fork invoice"));
        _passAll(proposalId);
        votes.execute(proposalId);
        assertEq(IERC20(subject).balanceOf(contributor), amount, "the contributor was paid from the budget");
        (, uint256 cap, uint256 spent) = fleet.payPeriod(subject);
        assertEq(spent, cap, "the whole period cap is spent");
    }

    // --- helpers -------------------------------------------------------------

    /// @dev An ordinary payer sends `amount` to the splitter and anyone recognizes it there.
    function _payThroughSplitter(IForkSplitter splitter, address token, uint256 amount) private {
        deal(token, payer, amount);
        vm.prank(payer);
        assertTrue(IERC20(token).transfer(address(splitter), amount));
        splitter.recognizeSurplusRevenue(token);
        assertEq(fleet.surplus(token), amount - (amount * 200) / 10_000, "the splitter paid on all but its 2%");
    }

    function _passAll(uint256 proposalId) private {
        uint256 keys = votes.proposal(proposalId).snapshotMinted;
        uint256[] memory ids = new uint256[](keys);
        for (uint256 i = 0; i < keys; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(alice);
        votes.vote(proposalId, ids, true);
        vm.warp(votes.proposal(proposalId).closesAt);
    }

    function _admit(address token) private {
        vm.startPrank(safe);
        registry.setFactoryTokenAllowed(token, true);
        registry.setFleetTokenAllowed(address(fleet), token, true);
        vm.stopPrank();
    }

    function _holder(uint256 tokenId) private view returns (address) {
        return tokenId == 1 ? alice : address(uint160(0x100000 + tokenId));
    }
}
