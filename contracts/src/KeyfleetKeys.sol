// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {KeyfleetPresets} from "./KeyfleetPresets.sol";
import {IVRFCoordinatorV2Plus} from "./vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "./vendor/chainlink/libraries/VRFV2PlusClient.sol";

/// @notice What the collection tells a fleet's manager when one of its keys moves.
interface IKeyfleetKeyHook {
    function onKeyMoved(uint256 tokenId, address from) external;
}

/// @notice The one Keyfleet collection: every key of every fleet, the fleet registry, the phases
/// that open sales, each fleet's card deck fingerprint and each key's reveal.
/// @dev An ordinary OpenZeppelin ERC721. Token id `fleet * 10^10 + key` is key number `key` of
/// fleet `fleet`; fleets are numbered from 1 and never reused, keys from 1 within their fleet.
///
/// Only a registered fleet manager mints, and only into its own fleet: the fleet is looked up from
/// the caller, never taken from an argument. Every transfer first calls the key's own fleet
/// manager, which settles the key's rewards and clears its presence. Every mint and every transfer
/// bumps the key's ownership epoch, and a mint records when the key was minted.
///
/// Sales open in phases the Regents Safe moves forward, one step at a time and never back: phase 1
/// opens fleet 1, phase 2 fleets 2 to 4, and phase 3 lets anyone create a fleet, which sells from
/// the moment it is created. `mint` is the only way a key comes to exist, and it refuses a fleet
/// whose sales have not opened.
///
/// Every fleet's cards come from a pre-made deck, of which only the fingerprint and the size are
/// kept here. The four founding fleets are registered with theirs. A fleet anyone creates is
/// registered without one, and the keeper, a Regents wallet the Safe names, records its deck once.
/// A key's Chainlink VRF request is sent only once its fleet has a deck, so no seed of a fleet
/// exists before its deck is fixed, and nobody can choose a deck after seeing the seeds. A key's
/// seed is written once from the one answer to its one accepted request.
///
/// `tokenURI` is one fixed base followed by the token id, and reverts for an id that has not been
/// minted. Resales carry an ERC-2981 royalty of 2.5% to the Regents Safe. There is no upgrade path,
/// no pause and no burn, and the Safe can neither mint nor move any key.
contract KeyfleetKeys is IERC4906, IERC2981, ERC721, ReentrancyGuardTransient {
    /// @notice The collection's fixed identity.
    /// @param name ERC721 collection name.
    /// @param symbol ERC721 collection symbol.
    /// @param baseTokenURI What every `tokenURI` starts with, followed by the token id.
    /// @param contractURI The collection's ERC-7572 metadata address.
    struct Collection {
        string name;
        string symbol;
        string baseTokenURI;
        string contractURI;
    }

    /// @notice Where every key's traits come from, fixed for ever.
    /// @param coordinator The Chainlink VRF v2.5 coordinator, the only address that can answer.
    /// @param subscriptionId The VRF subscription that pays for every request.
    /// @param keyHash The VRF gas lane.
    struct Randomness {
        IVRFCoordinatorV2Plus coordinator;
        uint256 subscriptionId;
        bytes32 keyHash;
    }

    /// @notice One registered fleet.
    /// @param manager The fleet's `KeyfleetManager`, the only account that mints its keys.
    /// @param preset The fleet's type.
    /// @param typeNumber Its number among fleets of its type, from 1.
    /// @param deckSize How many cards its deck holds; zero until its deck is recorded.
    /// @param deckHash `keccak256` of its deck file, byte for byte; zero until its deck is recorded.
    struct Fleet {
        address manager;
        KeyfleetPresets.Preset preset;
        uint32 typeNumber;
        uint32 deckSize;
        bytes32 deckHash;
    }

    /// @notice A key's ownership record.
    /// @param epoch Its ownership epoch: 1 at mint, plus one on every transfer.
    /// @param mintedAt When it was minted. Transfers never change it.
    struct Holding {
        uint64 epoch;
        uint64 mintedAt;
    }

    /// @notice A key's token id is its fleet times this, plus its key number.
    uint256 public constant TOKEN_ID_STRIDE = 10_000_000_000;
    /// @notice The highest key number a fleet mints.
    uint256 public constant MAX_KEY_NUMBER = type(uint32).max;
    /// @notice The most fleets the collection numbers, so every token id stays below 10^19 and fits
    /// in 64 bits.
    uint256 public constant MAX_FLEETS = 999_999_999;
    /// @notice The founding fleets, created by the Safe before phase 3.
    uint256 public constant FOUNDING_FLEETS = 4;
    /// @notice The last phase: anyone may create a fleet.
    uint8 public constant FINAL_PHASE = 3;
    /// @notice The resale royalty, in basis points: 2.5%.
    uint256 public constant ROYALTY_BPS = 250;

    /// @notice Domain tag of every key seed.
    bytes32 public constant TRAIT_SEED_TAG = keccak256("keyfleet.trait-seed");
    /// @notice Blocks the coordinator waits before answering.
    uint16 public constant REVEAL_CONFIRMATIONS = 3;
    /// @notice Gas the coordinator gives `rawFulfillRandomWords`. Only the gas used is charged.
    uint32 public constant REVEAL_CALLBACK_GAS_LIMIT = 100_000;
    /// @notice Random words asked for per key.
    uint32 public constant REVEAL_WORDS = 1;

    /// @dev ERC-4906 interface id.
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    /// @notice The Regents Safe: moves phases, names the keeper, adds factories, and receives the
    /// resale royalty.
    address public immutable SAFE;
    /// @notice The one Chainlink VRF v2.5 coordinator that answers.
    IVRFCoordinatorV2Plus public immutable VRF_COORDINATOR;
    /// @notice The VRF subscription every request is paid from, in ETH.
    uint256 public immutable VRF_SUBSCRIPTION_ID;
    /// @notice The VRF gas lane every request names.
    bytes32 public immutable VRF_KEY_HASH;
    /// @notice `keccak256` of the published trait-table file every key's traits are drawn from.
    bytes32 public immutable TRAIT_TABLE_HASH;

    /// @notice The current phase, 0 to 3.
    uint8 public phase;
    /// @notice The Regents wallet that records decks for fleets anyone creates and asks for card
    /// refreshes.
    address public keeper;
    /// @notice Fleets registered so far. Fleet ids are `1..fleetCount`.
    uint256 public fleetCount;
    /// @notice Whether an account may register fleets: the factory that deployed this collection,
    /// and any the Safe adds.
    mapping(address factory => bool allowed) public isFactory;
    /// @notice The fleet a manager mints for; zero for an account that is no fleet's manager.
    mapping(address manager => uint256 fleetId) public fleetOfManager;
    /// @notice Fleets registered of each type.
    mapping(KeyfleetPresets.Preset preset => uint256 count) public typeCount;
    /// @notice When a fleet's sales opened: fleet 1 at phase 1, fleets 2 to 4 at phase 2, any later
    /// fleet at its registration. Zero until they open, and for a fleet that does not exist.
    mapping(uint256 fleetId => uint64 openedAt) public salesOpenedAt;
    /// @notice A key's trait seed, zero until the coordinator answers. Written once.
    mapping(uint256 tokenId => bytes32 seed) public revealSeed;
    /// @notice When the coordinator accepted the request for a key, zero if it never has.
    mapping(uint256 tokenId => uint64 requestedAt) public revealRequestedAt;

    mapping(uint256 fleetId => Fleet fleet) private _fleets;
    mapping(uint256 tokenId => Holding holding) private _holdings;
    mapping(uint256 requestId => uint256 tokenId) private _requestToken;
    string private _baseTokenURI;
    string private _contractURI;

    /// @notice An address argument was zero.
    error ZeroAddress();
    /// @notice The VRF coordinator holds no code.
    error CoordinatorMissing(address coordinator);
    /// @notice No trait table was named.
    error TraitTableHashZero();
    /// @notice Only the Regents Safe may do this.
    error OnlySafe(address caller);
    /// @notice Only a factory may register a fleet.
    error OnlyFactory(address caller);
    /// @notice Only a registered fleet manager may do this.
    error OnlyManager(address caller);
    /// @notice Only the keeper may record a deck.
    error OnlyKeeper(address caller);
    /// @notice Only the key's owner or the keeper may ask for a key's metadata to be refreshed.
    error NotOwnerOrKeeper(uint256 tokenId, address caller);
    /// @notice The phase is already the last.
    error NoNextPhase();
    /// @notice The fleets a phase opens do not all exist yet.
    error FleetsMissing(uint256 needed, uint256 registered);
    /// @notice Before phase 3 only the founding fleets may be registered, in order, each with its deck.
    error NotFoundingFleet(uint256 fleetId, KeyfleetPresets.Preset preset);
    /// @notice A fleet registered in phase 3 gets its deck from the keeper, not at registration.
    error DeckGivenAtCreation();
    /// @notice The collection numbers no more fleets.
    error TooManyFleets();
    /// @notice The account already manages a fleet.
    error ManagerTaken(address manager);
    /// @notice No fleet has this id.
    error UnknownFleet(uint256 fleetId);
    /// @notice The fleet's sales have not opened.
    error SalesClosed(uint256 fleetId);
    /// @notice A key number outside 1 to `MAX_KEY_NUMBER`.
    error KeyNumberOutOfRange(uint256 keyNumber);
    /// @notice The fleet already has its deck.
    error DeckAlreadySet(uint256 fleetId);
    /// @notice A deck needs both its fingerprint and its size.
    error DeckInvalid();
    /// @notice The fleet has no deck yet, so its keys wait for their draw.
    error DeckNotSet(uint256 fleetId);
    /// @notice A factory address holds no code.
    error FactoryMissing(address factory);
    /// @notice Only the VRF coordinator may deliver random words.
    error OnlyCoordinator(address caller);
    /// @notice The key already has its seed.
    error AlreadyRevealed(uint256 tokenId);
    /// @notice The coordinator has already accepted a request for this key.
    error RevealAlreadyRequested(uint256 tokenId);

    /// @notice A fleet was registered.
    event FleetRegistered(
        uint256 indexed fleetId,
        KeyfleetPresets.Preset indexed preset,
        uint256 typeNumber,
        address indexed manager,
        address factory
    );
    /// @notice A fleet's deck fingerprint was recorded. It never changes afterwards.
    event DeckSet(uint256 indexed fleetId, bytes32 deckHash, uint256 deckSize);
    /// @notice The Safe moved the collection to a new phase.
    event PhaseAdvanced(uint8 phase);
    /// @notice The Safe named a new keeper.
    event KeeperSet(address indexed keeper);
    /// @notice The Safe allowed another factory to register fleets.
    event FactoryAdded(address indexed factory);
    /// @notice A key changed hands. The mint is epoch 1 and every transfer adds one.
    event OwnershipEpoch(uint256 indexed tokenId, uint64 epoch, address indexed from, address indexed to);
    /// @notice The coordinator accepted a request for a key's random word.
    event RevealRequested(uint256 indexed tokenId, uint256 indexed requestId);
    /// @notice The coordinator refused a request for a key's random word; the key waits for
    /// `requestReveal`.
    event RevealRequestFailed(uint256 indexed tokenId);
    /// @notice A key's seed was written. It never changes afterwards.
    /// @param seed `keccak256(abi.encode(TRAIT_SEED_TAG, block.chainid, address(this), tokenId, word))`.
    event KeyRevealed(
        uint256 indexed tokenId, uint256 indexed fleetId, uint256 keyNumber, uint256 indexed requestId, bytes32 seed
    );

    modifier onlySafe() {
        if (msg.sender != SAFE) revert OnlySafe(msg.sender);
        _;
    }

    /// @notice Deploys the collection. The deploying account is its first factory.
    /// @param safe The Regents Safe.
    /// @param keeper_ The first keeper.
    /// @param collection The name, symbol, metadata base and collection metadata address.
    /// @param randomness The VRF coordinator, subscription and gas lane.
    /// @param traitTableHash `keccak256` of the published trait-table file. Not zero.
    constructor(
        address safe,
        address keeper_,
        Collection memory collection,
        Randomness memory randomness,
        bytes32 traitTableHash
    ) ERC721(collection.name, collection.symbol) {
        if (safe == address(0) || keeper_ == address(0)) revert ZeroAddress();
        // A coordinator without code would make a request revert past its `catch`.
        if (address(randomness.coordinator).code.length == 0) {
            revert CoordinatorMissing(address(randomness.coordinator));
        }
        if (traitTableHash == bytes32(0)) revert TraitTableHashZero();
        SAFE = safe;
        VRF_COORDINATOR = randomness.coordinator;
        VRF_SUBSCRIPTION_ID = randomness.subscriptionId;
        VRF_KEY_HASH = randomness.keyHash;
        TRAIT_TABLE_HASH = traitTableHash;
        _baseTokenURI = collection.baseTokenURI;
        _contractURI = collection.contractURI;
        keeper = keeper_;
        isFactory[msg.sender] = true;
        emit KeeperSet(keeper_);
        emit FactoryAdded(msg.sender);
    }

    // --- views -----------------------------------------------------------

    /// @notice Ownership epoch of a key: 1 at mint, plus one on every transfer. Zero for a key that
    /// does not exist.
    function ownershipEpoch(uint256 tokenId) external view returns (uint64) {
        return _holdings[tokenId].epoch;
    }

    /// @notice When a key was minted. Zero for a key that does not exist.
    function mintedAt(uint256 tokenId) external view returns (uint64) {
        return _holdings[tokenId].mintedAt;
    }

    /// @notice The token id of key `keyNumber` of fleet `fleetId`.
    function tokenIdOf(uint256 fleetId, uint256 keyNumber) public pure returns (uint256) {
        return fleetId * TOKEN_ID_STRIDE + keyNumber;
    }

    /// @notice The fleet a token id belongs to.
    function fleetOf(uint256 tokenId) public pure returns (uint256) {
        return tokenId / TOKEN_ID_STRIDE;
    }

    /// @notice A token id's key number within its fleet.
    function keyNumberOf(uint256 tokenId) public pure returns (uint256) {
        return tokenId % TOKEN_ID_STRIDE;
    }

    /// @notice The type each founding fleet must be: 1 Classic, 2 Syndicate, 3 Accelerant, 4 Cascade.
    function foundingPreset(uint256 fleetId) public pure returns (KeyfleetPresets.Preset) {
        if (fleetId == 1) return KeyfleetPresets.Preset.FleetTechClassic;
        if (fleetId == 2) return KeyfleetPresets.Preset.FibonacciSyndicate;
        if (fleetId == 3) return KeyfleetPresets.Preset.FleetTechAccelerant;
        if (fleetId == 4) return KeyfleetPresets.Preset.FibonacciCascade;
        revert UnknownFleet(fleetId);
    }

    /// @notice A registered fleet's record.
    function fleet(uint256 fleetId) public view returns (Fleet memory) {
        _requireFleet(fleetId);
        return _fleets[fleetId];
    }

    /// @notice A fleet's manager.
    function managerOf(uint256 fleetId) external view returns (address) {
        return fleet(fleetId).manager;
    }

    /// @notice A fleet's deck fingerprint and size; both zero until recorded.
    function deckOf(uint256 fleetId) external view returns (bytes32 deckHash, uint256 deckSize) {
        Fleet memory stored = fleet(fleetId);
        return (stored.deckHash, stored.deckSize);
    }

    /// @notice Whether a fleet's keys may be minted now: once `salesOpenedAt` is set.
    function salesOpen(uint256 fleetId) public view returns (bool) {
        return salesOpenedAt[fleetId] != 0;
    }

    /// @notice The metadata base every `tokenURI` starts with.
    function baseTokenURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    /// @notice ERC-7572: where the collection's own metadata is.
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice ERC-2981: 2.5% of every sale, to the Regents Safe, for every key.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        return (SAFE, (salePrice * ROYALTY_BPS) / 10_000);
    }

    /// @notice ERC-165, ERC-721, ERC-4906 and ERC-2981.
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == ERC4906_INTERFACE_ID || interfaceId == type(IERC2981).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // --- the Safe ----------------------------------------------------------

    /// @notice Moves to the next phase. Phase 1 needs fleet 1 and phase 2 needs fleets 1 to 4.
    function advancePhase() external onlySafe {
        uint8 current = phase;
        if (current >= FINAL_PHASE) revert NoNextPhase();
        uint8 next = current + 1;
        uint256 needed = next == 1 ? 1 : next == 2 ? FOUNDING_FLEETS : 0;
        if (fleetCount < needed) revert FleetsMissing(needed, fleetCount);
        phase = next;
        if (next == 1) salesOpenedAt[1] = uint64(block.timestamp);
        if (next == 2) {
            for (uint256 fleetId = 2; fleetId <= FOUNDING_FLEETS; ++fleetId) {
                salesOpenedAt[fleetId] = uint64(block.timestamp);
            }
        }
        emit PhaseAdvanced(next);
    }

    /// @notice Names a new keeper.
    function setKeeper(address keeper_) external onlySafe {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Allows another factory to register new fleets. Existing fleets never change.
    function addFactory(address factory) external onlySafe {
        if (factory.code.length == 0) revert FactoryMissing(factory);
        isFactory[factory] = true;
        emit FactoryAdded(factory);
    }

    // --- factories ---------------------------------------------------------

    /// @notice Registers a new fleet whose manager will be at `manager`.
    /// @dev Before phase 3 only the four founding fleets may be registered, in order, each with its
    /// deck. In phase 3 a fleet is registered without a deck, which the keeper records later.
    /// @return fleetId The new fleet's id.
    /// @return typeNumber Its number among fleets of its type.
    function registerFleet(KeyfleetPresets.Preset preset, address manager, bytes32 deckHash, uint256 deckSize)
        external
        returns (uint256 fleetId, uint256 typeNumber)
    {
        if (!isFactory[msg.sender]) revert OnlyFactory(msg.sender);
        if (manager == address(0)) revert ZeroAddress();
        if (fleetOfManager[manager] != 0) revert ManagerTaken(manager);
        fleetId = fleetCount + 1;
        if (fleetId > MAX_FLEETS) revert TooManyFleets();
        bool hasDeck = deckHash != bytes32(0) || deckSize != 0;
        if (phase < FINAL_PHASE) {
            if (fleetId > FOUNDING_FLEETS || preset != foundingPreset(fleetId)) {
                revert NotFoundingFleet(fleetId, preset);
            }
            _requireDeck(deckHash, deckSize);
        } else if (hasDeck) {
            revert DeckGivenAtCreation();
        }

        fleetCount = fleetId;
        typeNumber = ++typeCount[preset];
        _fleets[fleetId] = Fleet({
            manager: manager,
            preset: preset,
            typeNumber: uint32(typeNumber),
            deckSize: uint32(deckSize),
            deckHash: deckHash
        });
        fleetOfManager[manager] = fleetId;
        if (phase == FINAL_PHASE) salesOpenedAt[fleetId] = uint64(block.timestamp);
        emit FleetRegistered(fleetId, preset, typeNumber, manager, msg.sender);
        if (hasDeck) emit DeckSet(fleetId, deckHash, deckSize);
    }

    // --- keeper ------------------------------------------------------------

    /// @notice Records the deck of a fleet that has none, once.
    /// @dev A fleet without a deck has never asked for a key's random word, so no seed of it exists
    /// and the deck cannot have been built from one. Its keys minted so far are asked for with
    /// `requestReveal` afterwards.
    function setDeck(uint256 fleetId, bytes32 deckHash, uint256 deckSize) external {
        if (msg.sender != keeper) revert OnlyKeeper(msg.sender);
        _requireFleet(fleetId);
        Fleet storage stored = _fleets[fleetId];
        if (stored.deckHash != bytes32(0)) revert DeckAlreadySet(fleetId);
        _requireDeck(deckHash, deckSize);
        stored.deckHash = deckHash;
        stored.deckSize = uint32(deckSize);
        emit DeckSet(fleetId, deckHash, deckSize);
    }

    /// @notice Tells marketplaces to fetch a key's metadata again, once its permanent card is
    /// published. The key's owner or the keeper may call.
    function refreshMetadata(uint256 tokenId) external {
        address owner = _requireOwned(tokenId);
        if (msg.sender != owner && msg.sender != keeper) revert NotOwnerOrKeeper(tokenId, msg.sender);
        emit MetadataUpdate(tokenId);
    }

    // --- managers ----------------------------------------------------------

    /// @notice Mints key `keyNumber` of the caller's fleet to `to`, then asks for its random word if
    /// the fleet has its deck.
    /// @dev Only a registered manager, only into its own fleet, only once its sales are open.
    /// Locked together with `requestReveal`, so a receiver cannot mint again or add a request from
    /// inside `onERC721Received`.
    function mint(address to, uint256 keyNumber) external nonReentrant returns (uint256 tokenId) {
        uint256 fleetId = fleetOfManager[msg.sender];
        if (fleetId == 0) revert OnlyManager(msg.sender);
        if (!salesOpen(fleetId)) revert SalesClosed(fleetId);
        if (keyNumber == 0 || keyNumber > MAX_KEY_NUMBER) revert KeyNumberOutOfRange(keyNumber);
        tokenId = tokenIdOf(fleetId, keyNumber);
        _safeMint(to, tokenId);
        if (_fleets[fleetId].deckHash != bytes32(0)) _requestReveal(tokenId);
    }

    /// @notice Tells marketplaces to fetch the metadata of every key of the caller's fleet again,
    /// after its name, description or image changed.
    function refreshFleet() external {
        uint256 fleetId = fleetOfManager[msg.sender];
        if (fleetId == 0) revert OnlyManager(msg.sender);
        emit BatchMetadataUpdate(tokenIdOf(fleetId, 1), tokenIdOf(fleetId, MAX_KEY_NUMBER));
    }

    // --- reveals -----------------------------------------------------------

    /// @notice Asks the coordinator for a key's random word.
    /// @dev Open to anyone, for a minted key whose fleet has its deck and whose request the
    /// coordinator has never accepted: it was minted before the deck was recorded, or every request
    /// for it was refused. Once a request is accepted the key waits for that answer. A refused
    /// request emits `RevealRequestFailed` and does not revert.
    function requestReveal(uint256 tokenId) external nonReentrant {
        _requireOwned(tokenId);
        if (revealSeed[tokenId] != bytes32(0)) revert AlreadyRevealed(tokenId);
        if (revealRequestedAt[tokenId] != 0) revert RevealAlreadyRequested(tokenId);
        uint256 fleetId = fleetOf(tokenId);
        if (_fleets[fleetId].deckHash == bytes32(0)) revert DeckNotSet(fleetId);
        _requestReveal(tokenId);
    }

    /// @notice The coordinator's answer to a request.
    /// @dev Only the coordinator may call, and for it this never reverts. An unknown request, an
    /// empty answer, or an answer for a key that already has its seed is ignored.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(VRF_COORDINATOR)) revert OnlyCoordinator(msg.sender);
        uint256 tokenId = _requestToken[requestId];
        if (tokenId == 0 || randomWords.length == 0 || revealSeed[tokenId] != bytes32(0)) return;

        bytes32 seed = keccak256(abi.encode(TRAIT_SEED_TAG, block.chainid, address(this), tokenId, randomWords[0]));
        revealSeed[tokenId] = seed;
        emit KeyRevealed(tokenId, fleetOf(tokenId), keyNumberOf(tokenId), requestId, seed);
        emit MetadataUpdate(tokenId);
    }

    // --- internals -------------------------------------------------------

    /// @dev Requests one random word, paid in ETH from the subscription. Never reverts.
    function _requestReveal(uint256 tokenId) private {
        try VRF_COORDINATOR.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: VRF_KEY_HASH,
                subId: VRF_SUBSCRIPTION_ID,
                requestConfirmations: REVEAL_CONFIRMATIONS,
                callbackGasLimit: REVEAL_CALLBACK_GAS_LIMIT,
                numWords: REVEAL_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        ) returns (
            uint256 requestId
        ) {
            _requestToken[requestId] = tokenId;
            revealRequestedAt[tokenId] = uint64(block.timestamp);
            emit RevealRequested(tokenId, requestId);
        } catch {
            emit RevealRequestFailed(tokenId);
        }
    }

    /// @dev Checks the caller may move the key, then, on a transfer, tells the key's own fleet
    /// manager, then bumps the ownership epoch, and on a mint records the mint time, all before
    /// ownership changes, so a caller without approval is refused with ERC-721's own error before
    /// any fleet bookkeeping runs. A mint has nothing to settle or clear, so the manager hears only
    /// of transfers. There is no burn, so `to` is never zero.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (auth != address(0)) _checkAuthorized(from, auth, tokenId);
        if (from != address(0)) IKeyfleetKeyHook(_fleets[fleetOf(tokenId)].manager).onKeyMoved(tokenId, from);

        Holding storage holding = _holdings[tokenId];
        uint64 epoch = holding.epoch + 1;
        holding.epoch = epoch;
        if (from == address(0)) holding.mintedAt = uint64(block.timestamp);
        emit OwnershipEpoch(tokenId, epoch, from, to);

        return super._update(to, tokenId, address(0));
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _requireFleet(uint256 fleetId) private view {
        if (fleetId == 0 || fleetId > fleetCount) revert UnknownFleet(fleetId);
    }

    function _requireDeck(bytes32 deckHash, uint256 deckSize) private pure {
        if (deckHash == bytes32(0) || deckSize == 0 || deckSize > MAX_KEY_NUMBER) revert DeckInvalid();
    }
}
