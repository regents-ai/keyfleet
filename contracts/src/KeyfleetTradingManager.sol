// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {KeyfleetManager} from "./KeyfleetManager.sol";
import {KeyfleetRewards} from "./KeyfleetRewards.sol";
import {KeyfleetTradingTreasury} from "./KeyfleetTradingTreasury.sol";
import {IKeyfleetTradingFactory, KeyfleetTradingWiring, TradingWiring} from "./KeyfleetTradingWiring.sol";
import {KeyfleetWiring} from "./KeyfleetWiring.sol";

/// @notice One Trading Fleet's sale and profile: the price of its next Key and the step each sale
/// raises it by, who may buy, the optional cap on its Keys, and its name, description and image.
/// @dev Deployed by the trading factory with the fleet's treasury and reward ledger, all three bound
/// to each other for ever. The Keys live in the shared `KeyfleetKeys` collection; this contract is
/// the fleet's registered manager there, the only account that mints its Keys, and the collection
/// tells it about every move of one of them.
///
/// The creator is whoever holds the fleet's Key 1 at the moment of each call, read from the
/// collection, never stored: when Key 1 changes hands, the fleet's authority goes with it. Only the
/// creator may change the price, the step and the profile. The step is in hundredths of a percent,
/// from 0 to 100%. Keys sell in order, each for the price at that moment, all of which goes to the
/// fleet's treasury in the purchase: nothing is taken and nothing is converted. After every sale the
/// price rises by the step, rounded down, and never above `MAX_PRICE`.
///
/// Every Key is enrolled in the fleet's ledger as it is minted, and is settled to its outgoing owner
/// before every transfer, so a Key's share of a payback belongs to whoever held it when the payback
/// ran. A Key counts for paybacks `KEY_MATURITY` (2 days) after its mint; Keys count in mint order.
/// Sales end for good once the fleet's treasury is closed. There is no administrator, no upgrade
/// path, no pause and no burn.
contract KeyfleetTradingManager is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The lowest price, in atomic USDC: 1 USDC.
    uint256 public constant MIN_PRICE = 1e6;
    /// @notice The highest price, in atomic USDC: one trillion USDC, more than all USDC in existence.
    /// A price at or below it times any step stays far below 2^256, and at or above `MIN_PRICE` any
    /// step above zero raises it by at least 100 atomic units.
    uint256 public constant MAX_PRICE = 1e18;
    /// @notice The largest step, in hundredths of a percent: 100%.
    uint256 public constant MAX_STEP_BPS = 10_000;
    /// @notice Hundredths of a percent in a whole.
    uint256 public constant BPS = 10_000;
    /// @notice How long after its mint a Key starts to count for paybacks, as on every fleet.
    uint256 public constant KEY_MATURITY = 2 days;
    /// @notice The longest fleet name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 100;
    /// @notice The longest fleet description, in bytes.
    uint256 public constant MAX_DESCRIPTION_BYTES = 2000;
    /// @notice The longest fleet image link, in bytes.
    uint256 public constant MAX_IMAGE_LINK_BYTES = 512;
    /// @notice The gas a joining requirement's `balanceOf` may use. A contract that needs more counts
    /// as not met.
    uint256 public constant REQUIREMENT_READ_GAS = 100_000;

    /// @notice The trading factory that deployed this fleet.
    address public immutable FACTORY;
    /// @notice This fleet's number in the collection.
    uint256 public immutable FLEET_ID;
    /// @notice The shared key collection.
    KeyfleetKeys public immutable KEYS;
    /// @notice The USDC every Key is paid in.
    IERC20 public immutable USDC;
    /// @notice This fleet's treasury, which receives every purchase.
    KeyfleetTradingTreasury public immutable TREASURY;
    /// @notice This fleet's reward ledger.
    KeyfleetRewards public immutable REWARDS;
    /// @notice The most Keys this fleet sells, Key 1 included, as the creator set it; zero for none
    /// beyond the collection's own limit. It never changes.
    uint256 public immutable KEY_CAP;

    /// @notice Keys minted so far. Key numbers are `1..totalMinted`.
    uint256 public totalMinted;
    /// @notice When Key 1 was minted; zero until then.
    uint64 public firstMintAt;
    /// @notice The USDC price of the next Key.
    uint256 public price;
    /// @notice How much each sale raises the price, in hundredths of a percent.
    uint256 public stepBps;
    /// @notice Whether the factory has written the profile and the requirements.
    bool public initialized;

    KeyfleetManager.Profile private _profile;
    KeyfleetManager.Requirements private _requirements;

    /// @notice Only the trading factory may do this.
    error OnlyFactory();
    /// @notice Only the shared collection may do this.
    error OnlyKeys();
    /// @notice Only the holder of the fleet's Key 1 may do this.
    error OnlyCreator(address caller);
    /// @notice The factory already wrote the profile and the requirements.
    error AlreadyInitialized();
    /// @notice The purchase deadline had already passed.
    error Expired(uint256 deadline);
    /// @notice The price exceeded the maximum the buyer authorized.
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    /// @notice Every Key this fleet can mint has been minted.
    error SoldOut();
    /// @notice The fleet is closed, so its sales have ended.
    error SalesEnded();
    /// @notice A price outside `MIN_PRICE` to `MAX_PRICE`.
    error PriceInvalid(uint256 price);
    /// @notice A step above `MAX_STEP_BPS`.
    error StepInvalid(uint256 stepBps);
    /// @notice A Key cap above the collection's highest key number.
    error KeyCapInvalid(uint256 keyCap);
    /// @notice The receiving wallet meets none of the fleet's joining requirements.
    error RequirementNotMet(address account);
    /// @notice A name outside 1 to 100 bytes, a description over 2,000 or an image link over 512.
    error ProfileInvalid();
    /// @notice An NFT or token requirement that holds no code, or a token amount that does not
    /// match its token.
    error RequirementsInvalid();
    /// @notice The collection reported a Key of another fleet.
    error ForeignKey(uint256 tokenId);
    /// @notice Key 1 has already been sold.
    error FirstKeySold();

    /// @notice A Key was bought for `price` USDC, all of it paid to the fleet's treasury.
    /// @param buyer Who paid the USDC.
    /// @param receiver The address the Key was minted to.
    event Purchased(uint256 indexed tokenId, address indexed buyer, address indexed receiver, uint256 price);
    /// @notice The creator set the price of the next Key.
    event PriceSet(uint256 price);
    /// @notice The creator set how much each sale raises the price, in hundredths of a percent.
    event StepSet(uint256 stepBps);
    /// @notice The fleet's name, description or image link was set.
    event ProfileChanged(string name, string description, string imageLink);
    /// @notice The fleet's joining requirements were set, once, at creation.
    event RequirementsSet(bytes32 merkleRoot, address nft, address token, uint256 tokenMin);

    /// @notice Binds this manager to its fleet, from the wiring the trading factory holds while
    /// deploying it, and starts the sale at the creator's first price and step. A first price, step
    /// or Key cap out of range stops the deploy, and with it the fleet's creation.
    constructor() {
        (IKeyfleetTradingFactory factory, TradingWiring memory wiring) = KeyfleetTradingWiring.read();
        KeyfleetWiring.requireSelf(wiring.manager);
        FACTORY = address(factory);
        FLEET_ID = wiring.fleetId;
        KEYS = factory.KEYS();
        USDC = factory.USDC();
        TREASURY = KeyfleetTradingTreasury(wiring.treasury);
        REWARDS = KeyfleetRewards(wiring.rewards);
        if (wiring.keyCap > KEYS.MAX_KEY_NUMBER()) revert KeyCapInvalid(wiring.keyCap);
        KEY_CAP = wiring.keyCap;
        _checkPrice(wiring.firstPrice);
        price = wiring.firstPrice;
        _checkStep(wiring.stepBps);
        stepBps = wiring.stepBps;
    }

    modifier onlyFactory() {
        if (msg.sender != FACTORY) revert OnlyFactory();
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != creator()) revert OnlyCreator(msg.sender);
        _;
    }

    // --- views -----------------------------------------------------------

    /// @notice Who runs the fleet: the holder of its Key 1 right now. Reverts before Key 1 exists.
    function creator() public view returns (address) {
        return KEYS.ownerOf(KEYS.tokenIdOf(FLEET_ID, 1));
    }

    /// @notice The most Keys this fleet will ever mint: its cap, or the collection's limit.
    function maxKeys() public view returns (uint256) {
        return KEY_CAP == 0 ? KEYS.MAX_KEY_NUMBER() : KEY_CAP;
    }

    /// @notice The price after a sale at `current`: raised by `stepBps_` hundredths of a percent,
    /// rounded down, and never above `MAX_PRICE`.
    function raised(uint256 current, uint256 stepBps_) public pure returns (uint256) {
        uint256 next = current + (current * stepBps_) / BPS;
        return next > MAX_PRICE ? MAX_PRICE : next;
    }

    /// @notice The fleet's name, description and image link.
    function profile() external view returns (KeyfleetManager.Profile memory) {
        return _profile;
    }

    /// @notice The fleet's joining requirements.
    function requirements() external view returns (KeyfleetManager.Requirements memory) {
        return _requirements;
    }

    /// @notice Whether `account` may receive a Key bought here, with `proof` for the address list.
    /// @dev The same rule as every fleet's: each part is off when zero, and with every part off
    /// anyone may. A buyer qualifies by meeting any one part that is on. The NFT and token checks
    /// are read-only calls; one that reverts or answers nonsense counts as not met.
    function meetsRequirements(address account, bytes32[] calldata proof) public view returns (bool) {
        KeyfleetManager.Requirements memory req = _requirements;
        bool any;
        if (req.merkleRoot != bytes32(0)) {
            any = true;
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account))));
            if (MerkleProof.verifyCalldata(proof, req.merkleRoot, leaf)) return true;
        }
        if (req.nft != address(0)) {
            any = true;
            if (_balanceOf(req.nft, account) > 0) return true;
        }
        if (req.token != address(0)) {
            any = true;
            if (_balanceOf(req.token, account) >= req.tokenMin) return true;
        }
        return !any;
    }

    /// @notice Keys of this fleet that have waited out `KEY_MATURITY` since their mint, which are
    /// exactly Keys 1 to the number returned, since Keys are minted in order. Only these share in a
    /// payback; the fleet's ledger and treasury read this.
    /// @dev A binary search over the Keys' mint times, at most 32 reads of the collection.
    function matureKeys() external view returns (uint256 mature) {
        uint256 high = totalMinted;
        while (mature < high) {
            uint256 middle = (mature + high + 1) / 2;
            uint256 mintedAt = KEYS.mintedAt(KEYS.tokenIdOf(FLEET_ID, middle));
            if (mintedAt != 0 && mintedAt + KEY_MATURITY <= block.timestamp) mature = middle;
            else high = middle - 1;
        }
    }

    // --- factory ---------------------------------------------------------

    /// @notice Writes the fleet's profile and joining requirements, once, during its creation.
    function initialize(KeyfleetManager.Profile calldata profile_, KeyfleetManager.Requirements calldata requirements_)
        external
        onlyFactory
    {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        if (
            (requirements_.nft != address(0) && requirements_.nft.code.length == 0)
                || (requirements_.token != address(0) && requirements_.token.code.length == 0)
                || ((requirements_.token == address(0)) != (requirements_.tokenMin == 0))
        ) revert RequirementsInvalid();
        _requirements = requirements_;
        emit RequirementsSet(requirements_.merkleRoot, requirements_.nft, requirements_.token, requirements_.tokenMin);
        _setProfile(profile_);
    }

    /// @notice Sells Key 1 to the fleet's creator at the first price, which the factory has just
    /// paid from the creator into the treasury.
    /// @dev The creator's own Key is not checked against the joining requirements.
    function sellFirstKey(address creator_) external nonReentrant onlyFactory returns (uint256 tokenId) {
        if (totalMinted != 0) revert FirstKeySold();
        uint256 keyNumber;
        (tokenId, keyNumber) = _book(creator_, creator_, price);
        KEYS.mint(creator_, keyNumber);
    }

    // --- purchase --------------------------------------------------------

    /// @notice Buys the next Key with USDC, paid straight to the fleet's treasury.
    /// @dev The caller must have approved this contract for the price. The receiving wallet must
    /// meet one of the fleet's joining requirements, if it has any. The price is read and paid in
    /// this call, so a price the creator changes in the same block never takes more than
    /// `maxPrice`. Everything is booked before the USDC moves, and the Key is minted last, which
    /// runs the receiver's `onERC721Received`. Locked, so a receiver cannot buy again from inside.
    /// @param receiver Address to mint to; zero mints to the caller.
    /// @param maxPrice Highest USDC price the caller authorizes.
    /// @param deadline Last block timestamp at which this purchase may execute.
    /// @param proof The receiver's Merkle proof when the fleet has an address list; empty otherwise.
    /// @return tokenId The minted Key.
    function purchase(address receiver, uint256 maxPrice, uint256 deadline, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        if (TREASURY.closedAt() != 0) revert SalesEnded();
        uint256 gross = price;
        if (gross > maxPrice) revert PriceAboveMax(gross, maxPrice);
        address to = receiver == address(0) ? msg.sender : receiver;
        if (!meetsRequirements(to, proof)) revert RequirementNotMet(to);
        uint256 keyNumber;
        (tokenId, keyNumber) = _book(msg.sender, to, gross);
        USDC.safeTransferFrom(msg.sender, address(TREASURY), gross);
        KEYS.mint(to, keyNumber);
    }

    // --- the creator -----------------------------------------------------

    /// @notice Sets the price of the next Key, from `MIN_PRICE` to `MAX_PRICE`. Only the creator.
    function setPrice(uint256 newPrice) external onlyCreator {
        _checkPrice(newPrice);
        price = newPrice;
        emit PriceSet(newPrice);
    }

    /// @notice Sets how much each sale raises the price, from 0 to `MAX_STEP_BPS` hundredths of a
    /// percent. Only the creator.
    function setStep(uint256 newStepBps) external onlyCreator {
        _checkStep(newStepBps);
        stepBps = newStepBps;
        emit StepSet(newStepBps);
    }

    /// @notice Sets the fleet's name, description and image link, and asks marketplaces to fetch the
    /// metadata of every Key of the fleet again. Only the creator.
    function setProfile(KeyfleetManager.Profile calldata profile_) external onlyCreator {
        _setProfile(profile_);
        KEYS.refreshFleet();
    }

    // --- the collection --------------------------------------------------

    /// @notice A Key of this fleet is moving from `from`. Only the collection calls this, before
    /// ownership changes.
    /// @dev Settles the Key's rewards to the outgoing owner. Not locked: it may run inside this
    /// fleet's own purchase, when a receiver passes a Key on from its mint hook, and it makes no
    /// token transfer and calls only this fleet's own ledger.
    function onKeyMoved(uint256 tokenId, address from) external {
        if (msg.sender != address(KEYS)) revert OnlyKeys();
        if (KEYS.fleetOf(tokenId) != FLEET_ID) revert ForeignKey(tokenId);
        REWARDS.settleKey(tokenId, from);
    }

    // --- internals -------------------------------------------------------

    /// @dev Books the next Key: its number, the first mint's time, the price raised by the step, and
    /// its enrolment in the ledger's cohort 0. The caller then takes the USDC and mints.
    function _book(address buyer, address to, uint256 gross) private returns (uint256 tokenId, uint256 keyNumber) {
        keyNumber = totalMinted + 1;
        if (keyNumber > maxKeys()) revert SoldOut();
        totalMinted = keyNumber;
        if (keyNumber == 1) firstMintAt = uint64(block.timestamp);
        price = raised(gross, stepBps);
        tokenId = KEYS.tokenIdOf(FLEET_ID, keyNumber);
        REWARDS.enrollKey(tokenId, 0);
        emit Purchased(tokenId, buyer, to, gross);
    }

    function _checkPrice(uint256 newPrice) private pure {
        if (newPrice < MIN_PRICE || newPrice > MAX_PRICE) revert PriceInvalid(newPrice);
    }

    function _checkStep(uint256 newStepBps) private pure {
        if (newStepBps > MAX_STEP_BPS) revert StepInvalid(newStepBps);
    }

    function _setProfile(KeyfleetManager.Profile calldata profile_) private {
        uint256 nameLength = bytes(profile_.name).length;
        if (
            nameLength == 0 || nameLength > MAX_NAME_BYTES || bytes(profile_.description).length > MAX_DESCRIPTION_BYTES
                || bytes(profile_.imageLink).length > MAX_IMAGE_LINK_BYTES
        ) revert ProfileInvalid();
        _profile = profile_;
        emit ProfileChanged(profile_.name, profile_.description, profile_.imageLink);
    }

    /// @dev `token.balanceOf(account)` with at most `REQUIREMENT_READ_GAS` gas and only the first
    /// 32 bytes of the answer copied. A call that fails or answers with fewer than 32 bytes reads as
    /// zero.
    function _balanceOf(address token, address account) private view returns (uint256 held) {
        bytes4 selector = IERC20.balanceOf.selector;
        uint256 gasAllowed = REQUIREMENT_READ_GAS;
        assembly ("memory-safe") {
            let input := mload(0x40)
            mstore(input, selector)
            mstore(add(input, 4), and(account, 0xffffffffffffffffffffffffffffffffffffffff))
            let ok := staticcall(gasAllowed, token, input, 36, 0, 32)
            if and(ok, gt(returndatasize(), 31)) { held := mload(0) }
        }
    }
}
