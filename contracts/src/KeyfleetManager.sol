// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "./KeyfleetRegentBuyer.sol";
import {KeyfleetRewards} from "./KeyfleetRewards.sol";
import {KeyfleetTreasury} from "./KeyfleetTreasury.sol";
import {KeyfleetVotes} from "./KeyfleetVotes.sol";
import {FleetWiring, IKeyfleetFactory, KeyfleetWiring} from "./KeyfleetWiring.sol";

/// @notice One fleet's sale, money and profile: its key prices, its primary purchases, the Cascade
/// reserve, the owed protocol share, its name, description and image, and who may buy its keys.
/// @dev Deployed by the factory with the fleet's three other contracts, all four bound to each other
/// for ever. The keys themselves live in the shared `KeyfleetKeys` collection; this contract is the
/// only account that mints this fleet's keys there, and the collection tells it about every move of
/// one of them.
///
/// Every price comes from `KeyfleetPresets`, scaled from the fleet's starting price, and is paid in
/// USDC. Of every purchase, 10% is set aside here as the protocol share for REGENT revenue staking.
/// The treasury's part is turned into REGENT at the market price by the shared
/// `KeyfleetRegentBuyer` in the same purchase, paid straight to the fleet's treasury: the whole
/// remaining 90% on Classic, Syndicate and an Accelerant first key, 20% on later Accelerant keys,
/// and a Cascade level's leftover reserve when the level completes. The Accelerant rebate and the
/// Cascade repayment stay USDC, paid into the fleet's `KeyfleetRewards` ledger.
///
/// A fleet anyone creates may set joining requirements at creation, which never change: a buyer
/// qualifies by meeting any one of them, checked against the wallet receiving the key when it is
/// bought here. Resales are never checked.
///
/// The fleet's name, description and image link are kept here and change only by a call from the
/// fleet's own treasury, so only through an approved proposal of its keys. There is no
/// administrator, no upgrade path, no pause and no burn.
contract KeyfleetManager is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice A fleet's public profile.
    /// @param name 1 to 100 bytes.
    /// @param description Up to 2,000 bytes.
    /// @param imageLink Up to 512 bytes, stored as given.
    struct Profile {
        string name;
        string description;
        string imageLink;
    }

    /// @notice Who may buy a key from the fleet. Each part is off when zero; with every part off,
    /// anyone may. A buyer qualifies by meeting any one part that is on.
    /// @param merkleRoot Root of an OpenZeppelin standard Merkle tree of addresses.
    /// @param nft An ERC-721 collection: holding at least one of its tokens qualifies.
    /// @param token An ERC-20 token: holding at least `tokenMin` of it qualifies.
    /// @param tokenMin The least of `token` that qualifies; zero exactly when `token` is.
    struct Requirements {
        bytes32 merkleRoot;
        address nft;
        address token;
        uint256 tokenMin;
    }

    /// @notice The longest fleet name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 100;
    /// @notice The longest fleet description, in bytes.
    uint256 public constant MAX_DESCRIPTION_BYTES = 2000;
    /// @notice The longest fleet image link, in bytes.
    uint256 public constant MAX_IMAGE_LINK_BYTES = 512;
    /// @notice The gas a joining requirement's `balanceOf` may use. A contract that needs more counts
    /// as not met, so no requirement can spend the gas a buyer brought for another requirement.
    uint256 public constant REQUIREMENT_READ_GAS = 100_000;

    /// @notice The factory that deployed this fleet.
    address public immutable FACTORY;
    /// @notice This fleet's number in the collection.
    uint256 public immutable FLEET_ID;
    /// @notice This fleet's type. It can never change.
    KeyfleetPresets.Preset public immutable PRESET;
    /// @notice The USDC price of key 1, from which every later price is scaled.
    uint256 public immutable START_PRICE;
    /// @notice The shared key collection.
    KeyfleetKeys public immutable KEYS;
    /// @notice The USDC every key is paid in.
    IERC20 public immutable USDC;
    /// @notice The shared buyer that turns the treasury's part of each purchase into REGENT.
    KeyfleetRegentBuyer public immutable REGENT_BUYER;
    /// @notice This fleet's voting controller.
    KeyfleetVotes public immutable VOTES;
    /// @notice This fleet's treasury.
    KeyfleetTreasury public immutable TREASURY;
    /// @notice This fleet's reward ledger.
    KeyfleetRewards public immutable REWARDS;

    /// @notice Primary keys minted so far. Key numbers are `1..totalMinted`.
    uint256 public totalMinted;
    /// @notice When the first key was sold; zero until then.
    uint64 public firstMintAt;
    /// @notice Accelerant only: the USDC price of the next primary mint.
    uint256 public currentPrice;
    /// @notice Cascade only: USDC held back for the next level completion.
    uint256 public cascadeReserve;
    /// @notice USDC set aside as the protocol share and not yet deposited into staking.
    uint256 public protocolShareOwed;
    /// @notice Whether the factory has written the profile and the requirements.
    bool public initialized;
    /// @notice Fibonacci only: keys of one level an address currently holds.
    mapping(address account => mapping(uint256 level => uint256 held)) public heldPerLevel;
    /// @notice Cascade only: gross USDC paid for all primary keys of a level.
    mapping(uint256 level => uint256 gross) public levelGrossPaid;
    /// @notice Cascade only: whether a level has been fully minted and its reserve released.
    mapping(uint256 level => bool completed) public levelCompleted;

    Profile private _profile;
    Requirements private _requirements;

    /// @notice Only the factory may do this.
    error OnlyFactory();
    /// @notice Only the shared collection may do this.
    error OnlyKeys();
    /// @notice Only this fleet's treasury, carrying out a proposal, may do this.
    error OnlyTreasury();
    /// @notice The factory already wrote the profile and the requirements.
    error AlreadyInitialized();
    /// @notice The purchase deadline had already passed.
    error Expired(uint256 deadline);
    /// @notice The next price exceeded the maximum the buyer authorized.
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    /// @notice Every key this fleet can sell has been sold.
    error SoldOut();
    /// @notice The recipient already holds as many keys of this level as the preset allows.
    error HoldingLimitExceeded(address account, uint256 level, uint256 limit);
    /// @notice Levels exist only on the two Fibonacci presets.
    error NotFibonacciPreset();
    /// @notice A supply limit exists only on the two Fleet.Tech presets.
    error NotFleetTechPreset();
    /// @notice A protocol-share send with nothing owed.
    error ZeroAmount();
    /// @notice The receiving wallet meets none of the fleet's joining requirements.
    error RequirementNotMet(address account);
    /// @notice A name outside 1 to 100 bytes, a description over 2,000 or an image link over 512.
    error ProfileInvalid();
    /// @notice An NFT or token requirement that holds no code, or a token amount that does not
    /// match its token.
    error RequirementsInvalid();
    /// @notice The collection reported a key of another fleet.
    error ForeignKey(uint256 tokenId);
    /// @notice Key 1 has already been sold.
    error FirstKeySold();

    /// @notice A primary key was bought. The four split parts always sum to `gross`.
    /// @param tokenId The key that was minted.
    /// @param buyer Who paid the USDC.
    /// @param receiver The address the key was minted to.
    /// @param gross The USDC price paid.
    /// @param protocol USDC set aside for REGENT staking in `protocolShareOwed`.
    /// @param capital USDC turned into REGENT for this fleet's treasury.
    /// @param reserve USDC added to the Cascade completion reserve.
    /// @param rebate USDC credited to the holder of the preceding key in the ledger.
    event Purchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed receiver,
        uint256 gross,
        uint256 protocol,
        uint256 capital,
        uint256 reserve,
        uint256 rebate
    );
    /// @notice A Cascade level was fully minted and its reserve was released.
    /// @param surplus USDC released and turned into REGENT for this fleet's treasury.
    event LevelCompleted(uint256 indexed level, uint256 reimbursement, uint256 surplus);
    /// @notice USDC was turned into REGENT for this fleet's treasury.
    event RegentBought(uint256 usdcIn, uint256 regentOut);
    /// @notice The whole owed protocol share was deposited into REGENT revenue staking.
    event ProtocolShareSent(address indexed caller, uint256 amount);
    /// @notice A token's unaccounted balance was sent to this fleet's treasury.
    event ForwardedToTreasury(address indexed asset, address indexed caller, uint256 amount);
    /// @notice The fleet's name, description or image link was set.
    event ProfileChanged(string name, string description, string imageLink);
    /// @notice The fleet's joining requirements were set, once, at creation.
    event RequirementsSet(bytes32 merkleRoot, address nft, address token, uint256 tokenMin);

    /// @notice Binds this manager to its fleet, from the wiring the factory holds while deploying it.
    constructor() {
        (IKeyfleetFactory factory, FleetWiring memory wiring) = KeyfleetWiring.read();
        KeyfleetWiring.requireSelf(wiring.manager);
        FACTORY = address(factory);
        FLEET_ID = wiring.fleetId;
        PRESET = wiring.preset;
        START_PRICE = wiring.startPrice;
        KEYS = factory.KEYS();
        USDC = factory.USDC();
        REGENT_BUYER = factory.REGENT_BUYER();
        VOTES = KeyfleetVotes(wiring.votes);
        TREASURY = KeyfleetTreasury(payable(wiring.treasury));
        REWARDS = KeyfleetRewards(wiring.rewards);
        if (wiring.preset == KeyfleetPresets.Preset.FleetTechAccelerant) currentPrice = wiring.startPrice;
    }

    modifier onlyFactory() {
        if (msg.sender != FACTORY) revert OnlyFactory();
        _;
    }

    // --- views -----------------------------------------------------------

    /// @notice The fleet's name, description and image link.
    function profile() external view returns (Profile memory) {
        return _profile;
    }

    /// @notice The fleet's joining requirements.
    function requirements() external view returns (Requirements memory) {
        return _requirements;
    }

    /// @notice Whether `account` may receive a key bought here, with `proof` for the address list.
    /// @dev The NFT and token checks are read-only calls; one that reverts or answers nonsense
    /// counts as not met.
    function meetsRequirements(address account, bytes32[] calldata proof) public view returns (bool) {
        Requirements memory req = _requirements;
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

    /// @notice Primary keys this Fleet.Tech fleet will ever mint: 1,024 on Classic, 2,000 on
    /// Accelerant. Reverts on the two Fibonacci presets, which have no last level.
    function maxSupply() public view returns (uint256) {
        if (PRESET == KeyfleetPresets.Preset.FleetTechClassic) return KeyfleetPresets.CLASSIC_SUPPLY;
        if (PRESET == KeyfleetPresets.Preset.FleetTechAccelerant) return KeyfleetPresets.MAX_ACCELERANT_KEYS;
        revert NotFleetTechPreset();
    }

    /// @notice Primary keys this Fleet.Tech fleet still has to sell.
    function remainingSupply() external view returns (uint256) {
        return maxSupply() - totalMinted;
    }

    /// @notice USDC price of the next primary key. Reverts once a Fleet.Tech fleet is sold out.
    function nextPrice() public view returns (uint256) {
        uint256 minted = totalMinted;
        if (_isFibonacci()) {
            return KeyfleetPresets.fibonacciLevelPrice(KeyfleetPresets.fibonacciLevelOf(minted + 1), START_PRICE);
        }
        if (minted >= maxSupply()) revert SoldOut();
        if (PRESET == KeyfleetPresets.Preset.FleetTechAccelerant) return currentPrice;
        return KeyfleetPresets.classicPrice(minted + 1, START_PRICE);
    }

    /// @notice How the next purchase would be divided.
    function quote() external view returns (KeyfleetPresets.PurchaseSplit memory) {
        return KeyfleetPresets.splitPurchase(PRESET, nextPrice(), _hasPredecessor(totalMinted));
    }

    /// @notice Fibonacci level of a key number. Reverts on the two Fleet.Tech presets.
    function levelOf(uint256 keyNumber) public view returns (uint256) {
        if (!_isFibonacci()) revert NotFibonacciPreset();
        return KeyfleetPresets.fibonacciLevelOf(keyNumber);
    }

    /// @notice Keys of one level a single address may hold. Reverts on the two Fleet.Tech presets.
    function holdingLimit(uint256 level) public view returns (uint256) {
        if (!_isFibonacci()) revert NotFibonacciPreset();
        return KeyfleetPresets.fibonacciHoldingLimit(level);
    }

    /// @notice Balance of an asset this manager has already recorded a purpose for: for USDC the
    /// Cascade reserve plus the owed protocol share, and nothing for any other token.
    function accountedBalance(address asset) public view returns (uint256) {
        if (asset == address(USDC)) return cascadeReserve + protocolShareOwed;
        return 0;
    }

    /// @notice Balance of an asset that arrived here outside a purchase.
    function surplus(address asset) public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) - accountedBalance(asset);
    }

    // --- factory ---------------------------------------------------------

    /// @notice Writes the fleet's profile and joining requirements, once, during its creation.
    function initialize(Profile calldata profile_, Requirements calldata requirements_) external onlyFactory {
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

    /// @notice Sells key 1 to the fleet's creator, whose USDC the factory has just sent here.
    /// @dev The creator's own key is not checked against the joining requirements.
    function sellFirstKey(address creator) external onlyFactory nonReentrant returns (uint256 tokenId) {
        if (totalMinted != 0) revert FirstKeySold();
        tokenId = _sell(creator, creator, nextPrice());
    }

    // --- purchase --------------------------------------------------------

    /// @notice Buys the next primary key with USDC.
    /// @dev The caller must have approved this contract for the gross price. The receiving wallet
    /// must meet one of the fleet's joining requirements, if it has any. Locked, so neither a
    /// receiver contract nor the REGENT pool's hook can buy again from inside the purchase.
    /// @param receiver Address to mint to; zero mints to the caller.
    /// @param maxPrice Highest gross USDC price the caller authorizes.
    /// @param deadline Last block timestamp at which this purchase may execute.
    /// @param proof The receiver's Merkle proof when the fleet has an address list; empty otherwise.
    /// @return tokenId The minted key.
    function purchase(address receiver, uint256 maxPrice, uint256 deadline, bytes32[] calldata proof)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        uint256 gross = nextPrice();
        if (gross > maxPrice) revert PriceAboveMax(gross, maxPrice);
        address to = receiver == address(0) ? msg.sender : receiver;
        if (!meetsRequirements(to, proof)) revert RequirementNotMet(to);
        USDC.safeTransferFrom(msg.sender, address(this), gross);
        tokenId = _sell(msg.sender, to, gross);
    }

    // --- the collection --------------------------------------------------

    /// @notice A key of this fleet is being minted or is moving. Only the collection calls this,
    /// before ownership changes.
    /// @dev Settles the key's rewards to the outgoing owner and clears its presence, then enforces
    /// the Fibonacci holding limit on the incoming owner. Not locked: it runs inside this fleet's own
    /// purchases, makes no token transfer and calls only this fleet's own ledger and controller.
    function onKeyMoved(uint256 tokenId, address from, address to) external {
        if (msg.sender != address(KEYS)) revert OnlyKeys();
        if (KEYS.fleetOf(tokenId) != FLEET_ID) revert ForeignKey(tokenId);
        if (from != address(0)) {
            REWARDS.settleKey(tokenId, from);
            VOTES.onKeyMoved(tokenId);
        }
        if (_isFibonacci()) {
            uint256 level = KeyfleetPresets.fibonacciLevelOf(KEYS.keyNumberOf(tokenId));
            if (from != address(0)) heldPerLevel[from][level] -= 1;
            uint256 held = heldPerLevel[to][level] + 1;
            uint256 limit = KeyfleetPresets.fibonacciHoldingLimit(level);
            if (held > limit) revert HoldingLimitExceeded(to, level, limit);
            heldPerLevel[to][level] = held;
        }
    }

    // --- profile ---------------------------------------------------------

    /// @notice Sets the fleet's name, description and image link. Only an approved proposal's call
    /// from the fleet's treasury reaches it.
    function setProfile(Profile calldata profile_) external {
        if (msg.sender != address(TREASURY)) revert OnlyTreasury();
        _setProfile(profile_);
        KEYS.refreshFleet();
    }

    // --- money ---------------------------------------------------------

    /// @notice Sends an asset's unaccounted balance whole to the fleet's treasury, unswapped.
    /// @dev Permissionless: it moves only what nobody has a claim on. A balance of zero returns zero.
    function recognizeSurplus(address asset) external nonReentrant returns (uint256 amount) {
        amount = surplus(asset);
        if (amount == 0) return 0;
        emit ForwardedToTreasury(asset, msg.sender, amount);
        IERC20(asset).safeTransfer(address(TREASURY), amount);
    }

    /// @notice Deposits the whole owed protocol share into REGENT revenue staking, through the
    /// fleet's treasury. Anyone may call it.
    function sendProtocolShare() external nonReentrant returns (uint256 amount) {
        amount = protocolShareOwed;
        if (amount == 0) revert ZeroAmount();
        protocolShareOwed = 0;
        emit ProtocolShareSent(msg.sender, amount);
        USDC.safeTransfer(address(TREASURY), amount);
        TREASURY.depositProtocolShare(amount);
    }

    // --- internals -------------------------------------------------------

    /// @dev Sells the next key for `gross` USDC, already held here. Everything is booked first: the
    /// price step, the split, the rebate, a Cascade level completion and the key's enrolment. Then
    /// the treasury's part is turned into REGENT, which runs the REGENT pool's hook, and last the key
    /// is minted, which runs the receiver's `onERC721Received` and asks for the key's random word.
    function _sell(address buyer, address to, uint256 gross) private returns (uint256 tokenId) {
        uint256 minted = totalMinted;
        uint256 keyNumber = minted + 1;
        if (keyNumber > KEYS.MAX_KEY_NUMBER()) revert SoldOut();
        totalMinted = keyNumber;
        if (minted == 0) firstMintAt = uint64(block.timestamp);
        tokenId = KEYS.tokenIdOf(FLEET_ID, keyNumber);

        bool hasPredecessor = _hasPredecessor(minted);
        KeyfleetPresets.PurchaseSplit memory split = KeyfleetPresets.splitPurchase(PRESET, gross, hasPredecessor);
        protocolShareOwed += split.protocol;
        uint256 toTreasury = split.capital;

        uint256 level;
        if (_isFibonacci()) {
            level = KeyfleetPresets.fibonacciLevelOf(keyNumber);
            if (PRESET == KeyfleetPresets.Preset.FibonacciCascade) {
                cascadeReserve += split.reserve;
                levelGrossPaid[level] += gross;
            }
        } else if (PRESET == KeyfleetPresets.Preset.FleetTechAccelerant) {
            if (hasPredecessor) {
                address predecessor = KEYS.ownerOf(tokenId - 1);
                USDC.safeTransfer(address(REWARDS), split.rebate);
                REWARDS.credit(address(USDC), predecessor, split.rebate);
            }
            currentPrice = KeyfleetPresets.accelerantNextPrice(gross);
        }

        REWARDS.enrollKey(tokenId, level);
        emit Purchased(tokenId, buyer, to, gross, split.protocol, split.capital, split.reserve, split.rebate);

        if (PRESET == KeyfleetPresets.Preset.FibonacciCascade && keyNumber == KeyfleetPresets.fibonacciLevelEnd(level))
        {
            toTreasury = _completeLevel(level);
        }

        if (toTreasury != 0) _buyRegent(toTreasury);
        KEYS.mint(to, keyNumber);
    }

    /// @dev Releases a completed Cascade level's reserve: it first repays the preceding level's whole
    /// original gross cost to whoever holds those keys, in USDC through the ledger, and returns the
    /// rest for the treasury. Level 1 has no predecessor. The reserve always covers the repayment: a
    /// level has at least 1.5 times the keys of the one before at no less than 1.2 times the price,
    /// and 90% of every purchase is reserved.
    function _completeLevel(uint256 level) private returns (uint256 released) {
        levelCompleted[level] = true;
        uint256 reserve = cascadeReserve;
        cascadeReserve = 0;

        uint256 reimbursement;
        if (level > 1) {
            reimbursement = levelGrossPaid[level - 1];
            USDC.safeTransfer(address(REWARDS), reimbursement);
            REWARDS.allocateToCohort(address(USDC), level - 1, reimbursement);
        }
        released = reserve - reimbursement;
        emit LevelCompleted(level, reimbursement, released);
    }

    /// @dev Turns `amount` USDC into REGENT for the treasury. The buyer pulls exactly `amount`.
    function _buyRegent(uint256 amount) private {
        USDC.forceApprove(address(REGENT_BUYER), amount);
        uint256 regentOut = REGENT_BUYER.buy(amount, address(TREASURY));
        emit RegentBought(amount, regentOut);
    }

    function _setProfile(Profile calldata profile_) private {
        uint256 nameLength = bytes(profile_.name).length;
        if (
            nameLength == 0 || nameLength > MAX_NAME_BYTES || bytes(profile_.description).length > MAX_DESCRIPTION_BYTES
                || bytes(profile_.imageLink).length > MAX_IMAGE_LINK_BYTES
        ) revert ProfileInvalid();
        _profile = profile_;
        emit ProfileChanged(profile_.name, profile_.description, profile_.imageLink);
    }

    /// @dev `account`'s balance of `token` by a read-only call; zero when the call reverts or does
    /// not answer one word.
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

    function _isFibonacci() private view returns (bool) {
        return PRESET == KeyfleetPresets.Preset.FibonacciSyndicate || PRESET == KeyfleetPresets.Preset.FibonacciCascade;
    }

    /// @dev Only an Accelerant purchase after the first one pays a rebate.
    function _hasPredecessor(uint256 minted) private view returns (bool) {
        return PRESET == KeyfleetPresets.Preset.FleetTechAccelerant && minted > 0;
    }
}
