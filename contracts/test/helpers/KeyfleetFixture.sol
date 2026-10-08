// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetShards} from "../../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetSystem} from "../../script/KeyfleetSystem.sol";
import {IRegentsAutolaunchFactoryV2} from "../../src/interfaces/IRegentsAutolaunchFactoryV2.sol";
import {V4PoolKey} from "../../src/interfaces/IUniswapV4PoolManager.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockAutolaunchFactory} from "../mocks/MockAutolaunchFactory.sol";
import {MockClubPass} from "../mocks/MockClubPass.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockRegent} from "../mocks/MockRegent.sol";
import {MockRegentRevenueStaking} from "../mocks/MockRegentRevenueStaking.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockVRFCoordinatorV2Plus} from "../mocks/MockVRFCoordinatorV2Plus.sol";
import {MockWeth} from "../mocks/MockWeth.sol";

/// @dev A full piece for the REGENT buyer, its `PIECE_USDC`, which `KeyfleetRegentBuyerTest` checks.
uint256 constant FULL_PIECE = 250e6;

/// @dev The whole Keyfleet system on stand-in USDC, WETH, REGENT, Uniswap pools, VRF, staking and
/// Autolaunch, with the steps the tests repeat: creating fleets, buying keys, passing and carrying
/// out a proposal's calls, and launching a fleet's token.
///
/// The stand-in market turns 1 USDC into 1 REGENT: one atomic USDC (six decimals) buys 4e8 wei of
/// WETH, and one wei of WETH buys 2,500 atomic REGENT, so `_regentFor(usdc) == usdc * 1e12`.
abstract contract KeyfleetFixture is Test {
    /// @dev WETH out per atomic USDC in, and back, scaled by 1e18.
    uint256 internal constant WETH_PER_USDC = 4e8 * 1e18;
    uint256 internal constant USDC_PER_WETH = 1e18 / 4e8;
    /// @dev REGENT out per wei of WETH in, and back, scaled by 1e18.
    uint256 internal constant REGENT_PER_WETH = 2500e18;
    uint256 internal constant WETH_PER_REGENT = 1e18 / 2500;
    /// @dev The REGENT pool's dynamic fee flag and tick spacing on Base.
    uint24 internal constant DYNAMIC_FEE = 0x800000;
    int24 internal constant TICK_SPACING = 200;
    /// @dev Every founding fleet's stand-in deck size.
    uint256 internal constant DECK_SIZE = 1000;

    MockToken internal usdc;
    MockWeth internal weth;
    MockRegent internal regent;
    MockUniswapV3Pool internal v3Pool;
    MockPoolManager internal poolManager;
    MockVRFCoordinatorV2Plus internal vrf;
    uint256 internal vrfSubscription;
    MockRegentRevenueStaking internal staking;
    MockAutolaunchFactory internal autolaunch;
    MockClubPass internal clubPass;

    KeyfleetFactory internal factory;
    KeyfleetKeys internal keys;
    KeyfleetShards internal shards;
    KeyfleetRegentBuyer internal regentBuyer;

    address internal safe = makeAddr("safe");
    address internal keeper = makeAddr("keeper");
    address internal buyer = address(0xB0B0B0);
    address internal creator = makeAddr("creator");

    function _setUpFixture() internal {
        usdc = new MockToken("USD Coin", "USDC");
        weth = new MockWeth();
        regent = new MockRegent();
        v3Pool = new MockUniswapV3Pool(address(usdc), address(weth), WETH_PER_USDC, USDC_PER_WETH);
        poolManager = new MockPoolManager(address(weth), REGENT_PER_WETH, WETH_PER_REGENT);
        weth.mint(address(v3Pool), 1e36);
        regent.mint(address(poolManager), 1e45);
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        staking = new MockRegentRevenueStaking(usdc);
        autolaunch = new MockAutolaunchFactory();
        // Placed, not created, so every address the fixture creates is the same as without it.
        clubPass = MockClubPass(makeAddr("regents club pass"));
        deployCodeTo("MockClubPass.sol:MockClubPass", address(clubPass));

        factory = KeyfleetSystem.deploy(_bindings());
        keys = factory.KEYS();
        shards = factory.SHARDS();
        regentBuyer = factory.REGENT_BUYER();
        vrf.addConsumer(vrfSubscription, address(keys));
    }

    function _bindings() internal view returns (KeyfleetSystem.Bindings memory) {
        return KeyfleetSystem.Bindings({
            safe: safe,
            keeper: keeper,
            staking: staking,
            autolaunch: autolaunch,
            clubPass: clubPass,
            collection: KeyfleetKeys.Collection({
                name: "Keyfleet",
                symbol: "KEYFLEET",
                baseTokenURI: "https://keyfleet.ai/keys/",
                contractURI: "https://keyfleet.ai/collection.json"
            }),
            randomness: KeyfleetKeys.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: vrfSubscription,
                keyHash: keccak256("key hash")
            }),
            traitTableHash: keccak256("trait table"),
            route: KeyfleetRegentBuyer.Route({
                usdc: address(usdc),
                weth: address(weth),
                regent: address(regent),
                v3Pool: address(v3Pool),
                poolManager: address(poolManager),
                v4Pool: V4PoolKey({
                    currency0: address(weth),
                    currency1: address(regent),
                    fee: DYNAMIC_FEE,
                    tickSpacing: TICK_SPACING,
                    hooks: address(0)
                })
            })
        });
    }

    // --- fleets ------------------------------------------------------------

    /// @dev The founding fleet of `preset`, with its sales open: creates the five founding fleets in
    /// order the first time, as the Safe, and moves the collection to phase 2.
    function _deploy(KeyfleetPresets.Preset preset) internal returns (KeyfleetManager fleet) {
        if (keys.fleetCount() == 0) {
            for (uint256 id = 1; id <= keys.FOUNDING_FLEETS(); ++id) {
                _createFounding(keys.foundingPreset(id));
            }
        }
        while (keys.phase() < 2) {
            _advancePhase();
        }
        for (uint256 id = 1; id <= keys.FOUNDING_FLEETS(); ++id) {
            if (keys.foundingPreset(id) == preset) return KeyfleetManager(keys.managerOf(id));
        }
        revert("no founding fleet");
    }

    /// @dev Moves the collection to its next phase as the Safe, opening a second from now, and waits
    /// for that second.
    function _advancePhase() internal {
        vm.prank(safe);
        keys.advancePhase(uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 1);
    }

    /// @dev Creates the next founding fleet as the Safe, with a stand-in deck: one card per key on
    /// the Regents Club, `DECK_SIZE` cards on the others.
    function _createFounding(KeyfleetPresets.Preset preset) internal returns (KeyfleetManager fleet) {
        uint256 id = keys.fleetCount() + 1;
        uint256 deckSize = preset == KeyfleetPresets.Preset.RegentsClub ? KeyfleetPresets.CLUB_SUPPLY : DECK_SIZE;
        vm.prank(safe);
        factory.createFoundingFleet(preset, _deckHash(id), deckSize, _profile("Founding fleet"));
        fleet = KeyfleetManager(keys.managerOf(id));
    }

    /// @dev Moves the collection to phase 3, creating the founding fleets first if needed.
    function _openCreation() internal {
        if (keys.fleetCount() == 0) _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        while (keys.phase() < keys.FINAL_PHASE()) {
            _advancePhase();
        }
    }

    /// @dev Creates an open fleet as `creator`, who buys its key 1, with no joining requirements.
    function _createOpen(KeyfleetPresets.Preset preset, uint256 startPrice) internal returns (KeyfleetManager fleet) {
        KeyfleetManager.Requirements memory anyone;
        return _createOpen(preset, startPrice, anyone);
    }

    /// @dev Creates an open fleet as `creator`, who buys its key 1, with `requirements`.
    function _createOpen(
        KeyfleetPresets.Preset preset,
        uint256 startPrice,
        KeyfleetManager.Requirements memory requirements
    ) internal returns (KeyfleetManager fleet) {
        _openCreation();
        usdc.mint(creator, startPrice);
        vm.startPrank(creator);
        usdc.approve(address(factory), startPrice);
        (uint256 id,) = factory.createFleet(_terms(preset, startPrice, requirements));
        vm.stopPrank();
        fleet = KeyfleetManager(keys.managerOf(id));
    }

    /// @dev An open fleet's terms; an Accelerant fleet takes the founding fleet's 5% step.
    function _terms(KeyfleetPresets.Preset preset, uint256 startPrice, KeyfleetManager.Requirements memory requirements)
        internal
        view
        returns (KeyfleetFactory.FleetTerms memory)
    {
        return KeyfleetFactory.FleetTerms({
            preset: preset,
            startPrice: startPrice,
            accelerantStepPercent: preset == KeyfleetPresets.Preset.FleetTechAccelerant
                ? KeyfleetPresets.MAX_ACCELERANT_STEP_PERCENT
                : 0,
            profile: _profile("Open fleet"),
            requirements: requirements,
            deadline: block.timestamp
        });
    }

    function _profile(string memory name) internal pure returns (KeyfleetManager.Profile memory) {
        return KeyfleetManager.Profile({
            name: name, description: "A fleet of keys.", imageLink: "https://media.regents.sh/ipfs/fleet"
        });
    }

    function _deckHash(uint256 fleetId) internal pure returns (bytes32) {
        return keccak256(abi.encode("deck", fleetId));
    }

    // --- keys --------------------------------------------------------------

    /// @dev The token id of key `keyNumber` of `fleet`.
    function _key(KeyfleetManager fleet, uint256 keyNumber) internal view returns (uint256) {
        return keys.tokenIdOf(fleet.FLEET_ID(), keyNumber);
    }

    function _buy(KeyfleetManager fleet, address receiver) internal returns (uint256 tokenId) {
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, price, block.timestamp, new bytes32[](0));
        vm.stopPrank();
    }

    /// @dev Key `i` goes to `_wallet(i)`, one key per wallet.
    function _buyMany(KeyfleetManager fleet, uint256 count) internal {
        for (uint256 i = 0; i < count; ++i) {
            _buy(fleet, _wallet(fleet.totalMinted() + 1));
        }
    }

    /// @dev Waits out the key maturity, so every key bought or moved so far may be renewed, vote,
    /// propose and cancel. Tests call it right after their purchases, before any key takes part.
    /// Every fleet's controller has the same maturity, so it is read from fleet 1's.
    function _mature() internal {
        vm.warp(block.timestamp + KeyfleetManager(keys.managerOf(1)).VOTES().KEY_MATURITY());
    }

    /// @dev Waits until every key `fleet` has sold is mature, so the next daily split covers them
    /// all. A time already past it is left as it is.
    function _joinSplit(KeyfleetManager fleet) internal {
        uint256 minted = fleet.totalMinted();
        if (minted == 0) return;
        uint256 joinsAt = keys.mintedAt(keys.tokenIdOf(fleet.FLEET_ID(), minted)) + fleet.VOTES().KEY_MATURITY();
        if (block.timestamp < joinsAt) vm.warp(joinsAt);
    }

    /// @dev Waits out the automatic presence every key sold so far began at its maturity, so from
    /// here on a key is present only once it is renewed. Tests call it right after `_mature`.
    function _lapse() internal {
        vm.warp(block.timestamp + KeyfleetManager(keys.managerOf(1)).VOTES().PRESENCE_WINDOW());
    }

    /// @dev Waits until `fleet`'s treasury opening is over, so its proposals may carry calls that
    /// move money. A time already past it is left as it is.
    function _openTreasury(KeyfleetManager fleet) internal {
        uint256 opensAt = fleet.VOTES().treasuryOpensAt();
        if (block.timestamp < opensAt) vm.warp(opensAt);
    }

    function _wallet(uint256 index) internal pure returns (address) {
        return address(uint160(0x100000 + index));
    }

    /// @dev Runs full pieces, each as soon as it may, until no fleet has USDC booked for its
    /// treasury, so every treasury holds the REGENT of every purchase so far.
    function _convertAll() internal {
        while (regentBuyer.queueLength() != 0) {
            uint256 opensAt = regentBuyer.nextPieceAt();
            if (block.timestamp < opensAt) vm.warp(opensAt);
            regentBuyer.convert(FULL_PIECE);
        }
    }

    /// @dev The REGENT the stand-in market gives for `usdcAmount`.
    function _regentFor(uint256 usdcAmount) internal pure returns (uint256) {
        return usdcAmount * 1e12;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _range(uint256 first, uint256 count) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    // --- proposals ---------------------------------------------------------

    function _one(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (KeyfleetTreasury.Call[] memory calls)
    {
        calls = new KeyfleetTreasury.Call[](1);
        calls[0] = KeyfleetTreasury.Call(target, value, data);
    }

    /// @dev Proposes `calls` with key 1, as its owner, and votes it Yes; nobody else is present, so
    /// it is approved once it closes, 24 hours later. It does not wait itself: the caller has made
    /// key 1 mature (`_mature`) and ended the other keys' automatic presence (`_lapse`), or, for
    /// calls that move money, waited out the treasury opening (`_openTreasury`), which does both
    /// for keys bought when sales opened.
    function _approve(KeyfleetManager fleet, KeyfleetTreasury.Call[] memory calls)
        internal
        returns (uint256 proposalId)
    {
        KeyfleetVotes votes = fleet.VOTES();
        uint256 first = _key(fleet, 1);
        address author = keys.ownerOf(first);
        vm.startPrank(author);
        proposalId = votes.propose(first, keccak256("narrative"), calls);
        votes.castBallot(proposalId, _ids(first), KeyfleetVotes.Choice.Yes);
        vm.stopPrank();
    }

    /// @dev Passes `calls` and carries them out as soon as it may: at closing, or a day later for a
    /// batch that moves money.
    function _execute(KeyfleetManager fleet, KeyfleetTreasury.Call[] memory calls) internal {
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(fleet.VOTES().executableAt(proposalId));
        fleet.VOTES().execute(proposalId, calls);
    }

    /// @dev What a launch names, with `treasury` as the launch's treasury.
    function _launchParams(address treasury) internal pure returns (IRegentsAutolaunchFactoryV2.LaunchParams memory) {
        return IRegentsAutolaunchFactoryV2.LaunchParams({
            name: "Fleet Token",
            symbol: "FLEET",
            description: "The fleet's own token.",
            website: "https://keyfleet.ai",
            image: "https://keyfleet.ai/fleet.png",
            treasury: treasury
        });
    }

    /// @dev The approved call that launches the fleet's token, naming `treasury`.
    function _launchCall(address treasury) internal view returns (KeyfleetTreasury.Call[] memory) {
        return
            _one(address(autolaunch), 0, abi.encodeCall(IRegentsAutolaunchFactoryV2.launch, (_launchParams(treasury))));
    }

    /// @dev Launches the fleet's token by an approved call naming its own treasury; the launch is
    /// active until the test settles it.
    function _launch(KeyfleetManager fleet) internal returns (uint256 launchId, IERC20 token) {
        launchId = autolaunch.nextLaunchId();
        _execute(fleet, _launchCall(address(fleet.TREASURY())));
        token = IERC20(autolaunch.launches(launchId).subject);
    }
}
