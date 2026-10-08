// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetClubClaims} from "./KeyfleetClubClaims.sol";
import {KeyfleetDeployer} from "./KeyfleetDeployers.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {KeyfleetManager} from "./KeyfleetManager.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "./KeyfleetRegentBuyer.sol";
import {KeyfleetShards} from "./KeyfleetShards.sol";
import {FleetWiring, IKeyfleetFactory} from "./KeyfleetWiring.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";
import {IRegentsAutolaunchFactoryV2} from "./interfaces/IRegentsAutolaunchFactoryV2.sol";

/// @notice Creates Keyfleet fleets: each one a `KeyfleetManager`, `KeyfleetVotes`,
/// `KeyfleetTreasury` and `KeyfleetRewards`, bound to each other and to the one shared
/// `KeyfleetKeys` collection for ever.
/// @dev The factory's constructor deploys the collection, the shared `KeyfleetShards`, the shared
/// `KeyfleetRegentBuyer` and the Regents Club's `KeyfleetClubClaims`, so their links are fixed at
/// birth. The four per-fleet contracts are
/// full deploys, not clones, made through four deployers with CREATE2 and salt = the fleet number,
/// so the factory knows all four addresses before deploying any. While it deploys them it holds the
/// fleet's wiring in transient storage; each constructor reads the wiring back, keeps it as
/// immutables and refuses to deploy anywhere but its own predicted address. The wiring is cleared
/// before any other code runs, so it is all zero at every other moment.
///
/// The Regents Safe creates the five founding fleets, in order, each with its card deck and its
/// type's standard starting price, with sales closed until the Safe opens them phase by phase. The
/// fifth, the Regents Club, has no price: the Safe gives its keys, one per Regents Club Pass. Once
/// the collection reaches its last phase anyone may create a fleet: they choose its type, starting
/// price, profile and joining requirements, and buy its key 1 in the same transaction. The factory
/// holds no money and has no administrator, no upgrade path and no pause.
contract KeyfleetFactory is IKeyfleetFactory, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Everything fixed when the factory is deployed.
    /// @param safe The Regents Safe: creates the founding fleets and runs the collection.
    /// @param keeper The collection's first keeper.
    /// @param staking REGENT revenue staking, where every fleet's protocol share is deposited.
    /// @param autolaunch The Autolaunch Revstake v2 factory whose launches a treasury may bind.
    /// @param clubPass The Regents Club Pass collection, whose Pass N names who receives Regents Club key N.
    /// @param collection The collection's name, symbol, metadata base and collection metadata address.
    /// @param randomness The collection's VRF coordinator, subscription and gas lane.
    /// @param traitTableHash `keccak256` of the published trait-table file.
    /// @param route The REGENT buyer's fixed route; its USDC and REGENT are every fleet's.
    /// @param managerDeployer Deploys each fleet's manager; must name this factory.
    /// @param votesDeployer Deploys each fleet's voting controller; must name this factory.
    /// @param treasuryDeployer Deploys each fleet's treasury; must name this factory.
    /// @param rewardsDeployer Deploys each fleet's reward ledger; must name this factory.
    struct Config {
        address safe;
        address keeper;
        IRegentRevenueStaking staking;
        IRegentsAutolaunchFactoryV2 autolaunch;
        IERC721 clubPass;
        KeyfleetKeys.Collection collection;
        KeyfleetKeys.Randomness randomness;
        bytes32 traitTableHash;
        KeyfleetRegentBuyer.Route route;
        KeyfleetDeployer managerDeployer;
        KeyfleetDeployer votesDeployer;
        KeyfleetDeployer treasuryDeployer;
        KeyfleetDeployer rewardsDeployer;
    }

    /// @notice What the creator of an open fleet chooses.
    /// @param preset The fleet's type.
    /// @param startPrice The USDC price of key 1, in whole cents, from 10 to 1,000,000 USDC.
    /// @param accelerantStepPercent On Accelerant, how many percent each primary mint costs more
    /// than the one before, a whole number from 1 to 5; zero on every other type.
    /// @param profile The fleet's name, description and image link.
    /// @param requirements Who may buy its keys; all zero for anyone.
    /// @param deadline Last block timestamp at which the creation may execute.
    struct FleetTerms {
        KeyfleetPresets.Preset preset;
        uint256 startPrice;
        uint256 accelerantStepPercent;
        KeyfleetManager.Profile profile;
        KeyfleetManager.Requirements requirements;
        uint256 deadline;
    }

    /// @notice The Regents Safe.
    address public immutable SAFE;
    /// @notice The one Keyfleet collection.
    KeyfleetKeys public immutable KEYS;
    /// @notice The shared shard record.
    KeyfleetShards public immutable SHARDS;
    /// @notice The shared REGENT buyer.
    KeyfleetRegentBuyer public immutable REGENT_BUYER;
    /// @notice The USDC every key is paid in.
    IERC20 public immutable USDC;
    /// @notice REGENT, which every treasury receives.
    IERC20 public immutable REGENT;
    /// @notice REGENT revenue staking.
    IRegentRevenueStaking public immutable REGENT_STAKING;
    /// @notice The Autolaunch Revstake v2 factory.
    IRegentsAutolaunchFactoryV2 public immutable AUTOLAUNCH;
    /// @notice The Regents Club Pass collection.
    IERC721 public immutable CLUB_PASS;
    /// @notice Holds each Regents Club key given there until the holder of its Pass claims it.
    KeyfleetClubClaims public immutable CLUB_CLAIMS;
    /// @notice Deploys each fleet's manager.
    KeyfleetDeployer public immutable MANAGER_DEPLOYER;
    /// @notice Deploys each fleet's voting controller.
    KeyfleetDeployer public immutable VOTES_DEPLOYER;
    /// @notice Deploys each fleet's treasury.
    KeyfleetDeployer public immutable TREASURY_DEPLOYER;
    /// @notice Deploys each fleet's reward ledger.
    KeyfleetDeployer public immutable REWARDS_DEPLOYER;

    /// @dev Transient: the first of the eight words of the wiring being deployed, in `FleetWiring`
    /// order. All zero outside a creation.
    uint256 private constant WIRING_SLOT = uint256(keccak256("keyfleet.factory.wiring"));

    /// @notice A staking or Autolaunch address holds no code.
    error BindingMissing(address binding);
    /// @notice The route's USDC does not report six decimals, which every price is written in.
    error UsdcDecimalsWrong(uint8 decimals);
    /// @notice A deployer serves another factory.
    error DeployerMismatch(address deployer);
    /// @notice Only the Safe may create a founding fleet.
    error OnlySafe(address caller);
    /// @notice Anyone may create a fleet only once the collection's last phase has opened.
    error CreationClosed(uint8 phase);
    /// @notice The creation deadline had already passed.
    error Expired(uint256 deadline);
    /// @notice A starting price outside 10 to 1,000,000 USDC, or not in whole cents.
    error StartPriceInvalid(uint256 startPrice);
    /// @notice An Accelerant step outside 1 to 5 percent, or a step given for another type.
    error AccelerantStepInvalid(KeyfleetPresets.Preset preset, uint256 accelerantStepPercent);
    /// @notice The Regents Club type belongs to the fifth founding fleet only.
    error RegentsClubIsFounding();

    /// @notice A fleet was created.
    /// @param fleetId Its number in the collection.
    /// @param preset Its type.
    /// @param typeNumber Its number among fleets of its type.
    /// @param creator The Safe for a founding fleet; otherwise the creator, who bought key 1.
    /// @param startPrice The USDC price of key 1; zero for the Regents Club, which is never sold.
    /// @param accelerantStepPercent Its Accelerant step in whole percent; zero on other types.
    event FleetCreated(
        uint256 indexed fleetId,
        KeyfleetPresets.Preset indexed preset,
        uint256 typeNumber,
        address indexed creator,
        uint256 startPrice,
        uint256 accelerantStepPercent,
        address manager,
        address votes,
        address treasury,
        address rewards
    );

    /// @notice Deploys the collection, the shard record and the REGENT buyer, and fixes the bindings
    /// every fleet is given.
    constructor(Config memory config) {
        if (address(config.staking).code.length == 0) revert BindingMissing(address(config.staking));
        if (address(config.autolaunch).code.length == 0) revert BindingMissing(address(config.autolaunch));
        if (address(config.clubPass).code.length == 0) revert BindingMissing(address(config.clubPass));
        uint8 usdcDecimals = IERC20Metadata(config.route.usdc).decimals();
        if (usdcDecimals != KeyfleetPresets.USDC_DECIMALS) revert UsdcDecimalsWrong(usdcDecimals);
        _requireDeployer(config.managerDeployer);
        _requireDeployer(config.votesDeployer);
        _requireDeployer(config.treasuryDeployer);
        _requireDeployer(config.rewardsDeployer);

        SAFE = config.safe;
        KeyfleetKeys keys =
            new KeyfleetKeys(config.safe, config.keeper, config.collection, config.randomness, config.traitTableHash);
        KEYS = keys;
        SHARDS = new KeyfleetShards(keys);
        REGENT_BUYER = new KeyfleetRegentBuyer(config.route, keys);
        USDC = IERC20(config.route.usdc);
        REGENT = IERC20(config.route.regent);
        REGENT_STAKING = config.staking;
        AUTOLAUNCH = config.autolaunch;
        CLUB_PASS = config.clubPass;
        CLUB_CLAIMS = new KeyfleetClubClaims(keys, config.clubPass);
        MANAGER_DEPLOYER = config.managerDeployer;
        VOTES_DEPLOYER = config.votesDeployer;
        TREASURY_DEPLOYER = config.treasuryDeployer;
        REWARDS_DEPLOYER = config.rewardsDeployer;
    }

    /// @notice The wiring of the fleet being deployed right now; all zero at every other moment.
    function wiring() external view returns (FleetWiring memory w) {
        w.fleetId = _tload(0);
        w.preset = KeyfleetPresets.Preset(_tload(1));
        w.startPrice = _tload(2);
        w.accelerantStepPercent = _tload(3);
        w.manager = address(uint160(_tload(4)));
        w.votes = address(uint160(_tload(5)));
        w.treasury = address(uint160(_tload(6)));
        w.rewards = address(uint160(_tload(7)));
    }

    /// @notice Where the four contracts of fleet `fleetId` are, or will be, deployed.
    function predict(uint256 fleetId)
        public
        view
        returns (address manager, address votes, address treasury, address rewards)
    {
        manager = MANAGER_DEPLOYER.predict(fleetId);
        votes = VOTES_DEPLOYER.predict(fleetId);
        treasury = TREASURY_DEPLOYER.predict(fleetId);
        rewards = REWARDS_DEPLOYER.predict(fleetId);
    }

    /// @notice Creates the next founding fleet: fleet 1 Classic, 2 Syndicate, 3 Accelerant,
    /// 4 Cascade, each with its deck, a starting price of 10 USDC, a 5% step for the Accelerant
    /// fleet and no joining requirements, then 5 Regents Club with its deck and no price. Its
    /// sales stay closed until the Safe opens them.
    /// @dev Only the Safe. The collection refuses a sixth, one out of order and one without a deck.
    function createFoundingFleet(
        KeyfleetPresets.Preset preset,
        bytes32 deckHash,
        uint256 deckSize,
        KeyfleetManager.Profile calldata profile
    ) external nonReentrant returns (uint256 fleetId) {
        if (msg.sender != SAFE) revert OnlySafe(msg.sender);
        KeyfleetManager.Requirements memory anyone;
        FleetWiring memory w;
        w.preset = preset;
        if (preset != KeyfleetPresets.Preset.RegentsClub) w.startPrice = KeyfleetPresets.Q_USDC;
        if (preset == KeyfleetPresets.Preset.FleetTechAccelerant) {
            w.accelerantStepPercent = KeyfleetPresets.MAX_ACCELERANT_STEP_PERCENT;
        }
        (fleetId,) = _create(w, deckHash, deckSize, profile, anyone, msg.sender);
    }

    /// @notice Creates a fleet on the creator's terms and sells its key 1 to the creator, once the
    /// collection's last phase has opened.
    /// @dev The creator must have approved this factory for the starting price, which it passes to
    /// the new manager for key 1. The fleet is registered without a deck; the keeper records it
    /// later, and key 1 waits for its draw until then. Locked, so the creator's
    /// `onERC721Received` cannot create another fleet from inside this one.
    function createFleet(FleetTerms calldata terms) external nonReentrant returns (uint256 fleetId, uint256 tokenId) {
        uint8 phase = KEYS.phase();
        if (phase != KEYS.FINAL_PHASE() || block.timestamp < KEYS.phaseOpensAt()) revert CreationClosed(phase);
        if (block.timestamp > terms.deadline) revert Expired(terms.deadline);
        if (terms.preset == KeyfleetPresets.Preset.RegentsClub) revert RegentsClubIsFounding();
        uint256 startPrice = terms.startPrice;
        if (
            startPrice < KeyfleetPresets.MIN_START_USDC || startPrice > KeyfleetPresets.MAX_START_USDC
                || startPrice % KeyfleetPresets.CENT_USDC != 0
        ) revert StartPriceInvalid(startPrice);
        uint256 step = terms.accelerantStepPercent;
        bool accelerant = terms.preset == KeyfleetPresets.Preset.FleetTechAccelerant;
        if (accelerant
                ? step < KeyfleetPresets.MIN_ACCELERANT_STEP_PERCENT
                    || step > KeyfleetPresets.MAX_ACCELERANT_STEP_PERCENT
                : step != 0) revert AccelerantStepInvalid(terms.preset, step);

        FleetWiring memory w;
        w.preset = terms.preset;
        w.startPrice = startPrice;
        w.accelerantStepPercent = step;
        KeyfleetManager manager;
        (fleetId, manager) = _create(w, bytes32(0), 0, terms.profile, terms.requirements, msg.sender);
        USDC.safeTransferFrom(msg.sender, address(manager), manager.nextPrice());
        tokenId = manager.sellFirstKey(msg.sender);
    }

    /// @dev Registers the fleet, deploys its four contracts with the wiring held only during the
    /// deploys, and writes its profile and requirements. `w` comes with the fleet's type, starting
    /// price and Accelerant step; this fills in the rest.
    function _create(
        FleetWiring memory w,
        bytes32 deckHash,
        uint256 deckSize,
        KeyfleetManager.Profile calldata profile,
        KeyfleetManager.Requirements memory requirements,
        address creator
    ) private returns (uint256 fleetId, KeyfleetManager manager) {
        w.fleetId = fleetId = KEYS.fleetCount() + 1;
        (w.manager, w.votes, w.treasury, w.rewards) = predict(fleetId);
        (uint256 registered, uint256 typeNumber) = KEYS.registerFleet(w.preset, w.manager, deckHash, deckSize);
        // The collection numbers fleets in order and only factories register them, inside `_create`.
        assert(registered == fleetId);

        _storeWiring(w);
        MANAGER_DEPLOYER.deploy(fleetId);
        VOTES_DEPLOYER.deploy(fleetId);
        TREASURY_DEPLOYER.deploy(fleetId);
        REWARDS_DEPLOYER.deploy(fleetId);
        FleetWiring memory cleared;
        _storeWiring(cleared);

        manager = KeyfleetManager(w.manager);
        manager.initialize(profile, requirements);
        _announce(w, typeNumber, creator);
    }

    function _announce(FleetWiring memory w, uint256 typeNumber, address creator) private {
        emit FleetCreated(
            w.fleetId,
            w.preset,
            typeNumber,
            creator,
            w.startPrice,
            w.accelerantStepPercent,
            w.manager,
            w.votes,
            w.treasury,
            w.rewards
        );
    }

    function _storeWiring(FleetWiring memory w) private {
        _tstore(0, w.fleetId);
        _tstore(1, uint256(w.preset));
        _tstore(2, w.startPrice);
        _tstore(3, w.accelerantStepPercent);
        _tstore(4, uint160(w.manager));
        _tstore(5, uint160(w.votes));
        _tstore(6, uint160(w.treasury));
        _tstore(7, uint160(w.rewards));
    }

    function _requireDeployer(KeyfleetDeployer deployer) private view {
        if (address(deployer.FACTORY()) != address(this)) revert DeployerMismatch(address(deployer));
    }

    function _tstore(uint256 word, uint256 value) private {
        uint256 slot = WIRING_SLOT + word;
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(uint256 word) private view returns (uint256 value) {
        uint256 slot = WIRING_SLOT + word;
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
