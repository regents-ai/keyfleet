// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetDeployer, KeyfleetRewardsDeployer} from "./KeyfleetDeployers.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {KeyfleetManager} from "./KeyfleetManager.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";
import {KeyfleetShards} from "./KeyfleetShards.sol";
import {KeyfleetTradingManagerDeployer, KeyfleetTradingTreasuryDeployer} from "./KeyfleetTradingDeployers.sol";
import {KeyfleetTradingManager} from "./KeyfleetTradingManager.sol";
import {IKeyfleetTradingFactory, TradingWiring} from "./KeyfleetTradingWiring.sol";
import {FleetWiring, IKeyfleetFactory} from "./KeyfleetWiring.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";

/// @notice Creates Trading Fleets in the Keyfleet collection: each one a `KeyfleetTradingManager`,
/// a `KeyfleetTradingTreasury` and a `KeyfleetRewards` ledger, bound to each other and to the
/// collection for ever.
/// @dev Constructed with the existing `KeyfleetFactory`, from which it reads the collection, the
/// shared shard record, USDC and REGENT revenue staking; it has no other setting, no owner and no
/// administrator. The Regents Safe lets it register fleets with `KeyfleetKeys.addFactory`.
///
/// Its constructor deploys its three deployers, each serving only this factory. A fleet's three
/// contracts are full deploys made with CREATE2 and salt = the fleet number, so the factory knows
/// their addresses before deploying any. While it deploys them it holds the fleet's wiring in
/// transient storage; each constructor reads the wiring back, keeps it as immutables and refuses to
/// deploy anywhere but its own predicted address. The ledger is `KeyfleetRewards` exactly as on
/// every fleet, deployed by its own instance of the same `KeyfleetRewardsDeployer`; it reads the
/// wiring through `wiring`, in the shape every fleet's contracts read.
///
/// Once the collection's last phase has opened, anyone may create a Trading Fleet on their own
/// terms and buy its Key 1 at the first price in the same transaction, paid into the new treasury.
/// The collection has five fixed fleet types and no Trading type, so every Trading Fleet is
/// registered as `FleetTechAccelerant` and takes that type's next number; the collection's
/// `FleetRegistered` event names this factory, which is how a Trading Fleet is told apart. The
/// factory holds no money and has no upgrade path and no pause.
///
/// A Trading Fleet is registered without a deck, and the default is that it never gets one. The
/// collection lets its keeper record a deck for any fleet, and nothing here can refuse it. A deck
/// is the keeper's choice, and a costly one: from then on every Key minted asks VRF for a draw that
/// the Safe's subscription pays for, and anyone may ask one for each Key minted before. A creator
/// can mint Keys at no cost, buying each and sending its price straight back out to their own
/// trading wallet, so with a deck they can make the Safe pay for as many draws as they like.
contract KeyfleetTradingFactory is IKeyfleetTradingFactory, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice What the creator of a Trading Fleet chooses. The new fleet's contracts check each
    /// term as they are deployed: the manager the profile, requirements, first price, step and cap,
    /// the treasury the daily payback.
    /// @param profile The fleet's name, description and image link.
    /// @param requirements Who may buy its Keys; all zero for anyone.
    /// @param firstPrice The USDC price of Key 1, from the manager's `MIN_PRICE` to `MAX_PRICE`.
    /// @param stepBps How much each sale raises the price, from 0 to 10,000 hundredths of a percent.
    /// @param dailyPaybackBps The guaranteed daily payback, from 10 to 200 hundredths of a percent.
    /// @param keyCap The most Keys the fleet sells, Key 1 included; zero for the collection's limit.
    /// @param deadline Last block timestamp at which the creation may execute.
    struct TradingTerms {
        KeyfleetManager.Profile profile;
        KeyfleetManager.Requirements requirements;
        uint256 firstPrice;
        uint256 stepBps;
        uint256 dailyPaybackBps;
        uint256 keyCap;
        uint256 deadline;
    }

    /// @notice The type every Trading Fleet is registered under.
    KeyfleetPresets.Preset public constant PRESET = KeyfleetPresets.Preset.FleetTechAccelerant;

    /// @notice The one Keyfleet collection.
    KeyfleetKeys public immutable KEYS;
    /// @notice The shared shard record, which every fleet's ledger reads.
    KeyfleetShards public immutable SHARDS;
    /// @notice The USDC every Key is paid in.
    IERC20 public immutable USDC;
    /// @notice REGENT revenue staking, which is owed 1% of every payback.
    IRegentRevenueStaking public immutable REGENT_STAKING;
    /// @notice Deploys each Trading Fleet's manager.
    KeyfleetDeployer public immutable MANAGER_DEPLOYER;
    /// @notice Deploys each Trading Fleet's treasury.
    KeyfleetDeployer public immutable TREASURY_DEPLOYER;
    /// @notice Deploys each Trading Fleet's reward ledger.
    KeyfleetDeployer public immutable REWARDS_DEPLOYER;

    /// @dev Transient: the first of the eight words of the wiring being deployed, in `TradingWiring`
    /// order. All zero outside a creation.
    uint256 private constant WIRING_SLOT = uint256(keccak256("keyfleet.trading_factory.wiring"));

    /// @notice Anyone may create a fleet only once the collection's last phase has opened.
    error CreationClosed(uint8 phase);
    /// @notice The creation deadline had already passed.
    error Expired(uint256 deadline);

    /// @notice A Trading Fleet was created and its Key 1 sold to `creator`.
    /// @param fleetId Its number in the collection.
    /// @param creator Who created it and bought Key 1.
    /// @param typeNumber Its number among the collection's `FleetTechAccelerant` fleets, a count it
    /// shares with them.
    /// @param keyCap The most Keys it sells; zero for the collection's limit.
    event TradingFleetCreated(
        uint256 indexed fleetId,
        address indexed creator,
        uint256 typeNumber,
        address manager,
        address treasury,
        address rewards,
        uint256 firstPrice,
        uint256 stepBps,
        uint256 dailyPaybackBps,
        uint256 keyCap,
        KeyfleetManager.Profile profile,
        KeyfleetManager.Requirements requirements
    );

    /// @notice Reads its bindings from the existing factory and deploys its three deployers.
    /// @param fleets The existing `KeyfleetFactory`, whose collection, shard record, USDC and REGENT
    /// revenue staking every Trading Fleet is given.
    constructor(IKeyfleetFactory fleets) {
        KEYS = fleets.KEYS();
        SHARDS = fleets.SHARDS();
        USDC = fleets.USDC();
        REGENT_STAKING = fleets.REGENT_STAKING();
        IKeyfleetFactory self = IKeyfleetFactory(address(this));
        MANAGER_DEPLOYER = new KeyfleetTradingManagerDeployer(self);
        TREASURY_DEPLOYER = new KeyfleetTradingTreasuryDeployer(self);
        REWARDS_DEPLOYER = new KeyfleetRewardsDeployer(self);
    }

    /// @notice The wiring of the Trading Fleet being deployed right now; all zero at every other
    /// moment.
    function tradingWiring() public view returns (TradingWiring memory w) {
        w.fleetId = _tload(0);
        w.manager = address(uint160(_tload(1)));
        w.treasury = address(uint160(_tload(2)));
        w.rewards = address(uint160(_tload(3)));
        w.firstPrice = _tload(4);
        w.stepBps = _tload(5);
        w.dailyPaybackBps = _tload(6);
        w.keyCap = _tload(7);
    }

    /// @notice The same wiring in the shape every fleet's `KeyfleetRewards` reads: the fleet, its
    /// type, its first price, no Accelerant step, its manager, no voting controller, its treasury
    /// and its ledger. All zero outside a creation.
    function wiring() external view returns (FleetWiring memory w) {
        w.fleetId = _tload(0);
        if (w.fleetId == 0) return w;
        w.preset = PRESET;
        w.startPrice = _tload(4);
        w.manager = address(uint160(_tload(1)));
        w.treasury = address(uint160(_tload(2)));
        w.rewards = address(uint160(_tload(3)));
    }

    /// @notice Where the three contracts of fleet `fleetId` are, or will be, deployed.
    function predict(uint256 fleetId) public view returns (address manager, address treasury, address rewards) {
        manager = MANAGER_DEPLOYER.predict(fleetId);
        treasury = TREASURY_DEPLOYER.predict(fleetId);
        rewards = REWARDS_DEPLOYER.predict(fleetId);
    }

    /// @notice Creates a Trading Fleet on the caller's terms and sells its Key 1 to the caller at the
    /// first price, once the collection's last phase has opened.
    /// @dev The creator must have approved this factory for the first price, which goes straight to
    /// the new treasury. The fleet is registered without a deck and keeps none unless the keeper
    /// records one. Locked, so the creator's `onERC721Received` cannot create another fleet from
    /// inside this one.
    function create(TradingTerms calldata terms) external nonReentrant returns (uint256 fleetId, uint256 tokenId) {
        uint8 phase = KEYS.phase();
        if (phase != KEYS.FINAL_PHASE() || block.timestamp < KEYS.phaseOpensAt()) revert CreationClosed(phase);
        if (block.timestamp > terms.deadline) revert Expired(terms.deadline);

        TradingWiring memory w;
        w.firstPrice = terms.firstPrice;
        w.stepBps = terms.stepBps;
        w.dailyPaybackBps = terms.dailyPaybackBps;
        w.keyCap = terms.keyCap;
        w.fleetId = fleetId = KEYS.nextFleetId(PRESET);
        (w.manager, w.treasury, w.rewards) = predict(fleetId);
        (uint256 registered, uint256 typeNumber) = KEYS.registerFleet(PRESET, w.manager, bytes32(0), 0);
        // The collection and this factory use the same public id rule.
        assert(registered == fleetId);

        _storeWiring(w);
        MANAGER_DEPLOYER.deploy(fleetId);
        TREASURY_DEPLOYER.deploy(fleetId);
        REWARDS_DEPLOYER.deploy(fleetId);
        TradingWiring memory cleared;
        _storeWiring(cleared);

        KeyfleetTradingManager manager = KeyfleetTradingManager(w.manager);
        manager.initialize(terms.profile, terms.requirements);
        _announce(w, typeNumber, terms);
        USDC.safeTransferFrom(msg.sender, w.treasury, w.firstPrice);
        tokenId = manager.sellFirstKey(msg.sender);
    }

    function _announce(TradingWiring memory w, uint256 typeNumber, TradingTerms calldata terms) private {
        emit TradingFleetCreated(
            w.fleetId,
            msg.sender,
            typeNumber,
            w.manager,
            w.treasury,
            w.rewards,
            w.firstPrice,
            w.stepBps,
            w.dailyPaybackBps,
            w.keyCap,
            terms.profile,
            terms.requirements
        );
    }

    function _storeWiring(TradingWiring memory w) private {
        _tstore(0, w.fleetId);
        _tstore(1, uint160(w.manager));
        _tstore(2, uint160(w.treasury));
        _tstore(3, uint160(w.rewards));
        _tstore(4, w.firstPrice);
        _tstore(5, w.stepBps);
        _tstore(6, w.dailyPaybackBps);
        _tstore(7, w.keyCap);
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
