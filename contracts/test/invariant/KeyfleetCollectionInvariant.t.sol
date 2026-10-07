// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KeyfleetFactory} from "../../src/KeyfleetFactory.sol";
import {KeyfleetKeys} from "../../src/KeyfleetKeys.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetPresence} from "../../src/KeyfleetPresence.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetRegentBuyer} from "../../src/KeyfleetRegentBuyer.sol";
import {KeyfleetRewards} from "../../src/KeyfleetRewards.sol";
import {KeyfleetShards} from "../../src/KeyfleetShards.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {FleetWiring} from "../../src/KeyfleetWiring.sol";
import {KeyfleetFixture} from "../helpers/KeyfleetFixture.sol";
import {MockRegent} from "../mocks/MockRegent.sol";
import {MockRegentRevenueStaking} from "../mocks/MockRegentRevenueStaking.sol";
import {MockToken} from "../mocks/MockToken.sol";
import {MockVRFCoordinatorV2Plus} from "../mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev The shared contracts and the stand-in market around the collection, handed to the handler
/// in one piece.
struct CollectionSetting {
    KeyfleetFactory factory;
    MockVRFCoordinatorV2Plus vrf;
    uint256 vrfSubscription;
    MockRegentRevenueStaking staking;
    IERC20 weth;
    address v3Pool;
    address poolManager;
    address safe;
    address keeper;
}

/// @dev Drives every fleet on one collection side by side, as key holders, agents, outsiders, the
/// Safe, the keeper and the randomness coordinator would: purchases, transfers, shards, presence,
/// proposals, ballots, carrying out, claims, daily splits, the protocol share, stray tokens, direct
/// REGENT buys, decks, reveals, phases and new open fleets, plus attempts on every privileged and
/// key-taking function by the wrong caller or with another fleet's key. Each action checks its own
/// outcome exactly, and around each action the handler records whether any other fleet changed,
/// whether the phase moved other than one step by the Safe, and whether any epoch went down or any
/// seed changed.
contract CollectionHandler is Test {
    uint256 internal constant ACTORS = 10;
    uint256 internal constant AGENTS = 3;
    uint256 internal constant OUTSIDERS = 2;
    uint256 internal constant FIRST_OPEN_FLEET = 5;
    uint256 internal constant MAX_FLEETS = 6;
    uint256 internal constant MAX_KEYS = 24;
    uint256 internal constant MAX_PROPOSALS = 3;
    uint256 internal constant ATTACKS = 46;

    /// @dev What a proposal carries out: nothing, a new profile, a voted split or a new daily rate
    /// for its own fleet, or a call on another fleet's manager or ledger that must be refused.
    enum Kind {
        Nothing,
        Profile,
        VotedSplit,
        SplitRate,
        ForeignProfile,
        ForeignCredit
    }

    /// @dev What the handler knows a fleet to be, independent of the contracts.
    struct FleetRecord {
        address manager;
        KeyfleetPresets.Preset preset;
        uint32 typeNumber;
        uint32 deckSize;
        bytes32 deckHash;
        uint256 startPrice;
        uint256 accelerantStepPercent;
        address creator;
        uint256 firstPricePaid;
        address nftRequirement;
        bytes32 profileHash;
        bytes32 requirementsHash;
    }

    /// @dev The books around one sale.
    struct Books {
        uint256 managerUsdc;
        uint256 rewardsUsdc;
        uint256 backed;
        uint256 treasuryUsdc;
        uint256 treasuryRegent;
        uint256 poolUsdc;
        uint256 owed;
        address predecessor;
        uint256 predecessorCredit;
        uint64 vrfNonce;
    }

    /// @dev How one sale's USDC should split.
    struct Split {
        uint256 protocol;
        uint256 toLedger;
        uint256 swapped;
        uint256 rebate;
    }

    struct Proposed {
        Kind kind;
        uint256 param;
    }

    /// @dev One attempt's target fleet, caller and keys.
    struct Attempt {
        uint256 pick;
        uint256 fleetId;
        KeyfleetManager manager;
        address caller;
        uint256 ownKey;
        address ownOwner;
        uint256 foreignKey;
        address foreignOwner;
        uint256 openProposal;
    }

    KeyfleetFactory internal immutable factory;
    KeyfleetKeys internal immutable keys;
    KeyfleetShards internal immutable shards;
    KeyfleetRegentBuyer internal immutable regentBuyer;
    MockToken internal immutable usdc;
    MockRegent internal immutable regent;
    IERC20 internal immutable weth;
    MockVRFCoordinatorV2Plus internal immutable vrf;
    uint256 internal immutable vrfSubscription;
    MockRegentRevenueStaking internal immutable staking;
    address internal immutable safe;
    address internal immutable keeper;
    address internal immutable v3Pool;
    address internal immutable poolManager;

    /// @dev The actors, then the agents, then the outsiders, then the creators of fleets 5 and 6.
    address[] internal _accounts;
    mapping(address account => uint256 privateKey) internal _pkOf;

    /// @notice Set, with the reason, the first time an action broke a rule.
    string public breach;
    uint256 public ghostMinted;
    uint256 public ghostSwapped;
    uint256 public ghostShareSent;
    uint256 public ghostFleetCount;
    uint8 public ghostPhase;
    mapping(KeyfleetPresets.Preset preset => uint256 count) public ghostTypeCount;
    mapping(uint256 tokenId => uint64 epoch) public ghostEpoch;
    mapping(uint256 tokenId => bytes32 seed) public ghostSeed;

    mapping(uint256 fleetId => FleetRecord) internal _records;
    mapping(uint256 fleetId => uint256 reserve) internal _reserve;
    mapping(uint256 fleetId => mapping(uint256 level => uint256 gross)) internal _levelGross;
    mapping(uint256 fleetId => mapping(uint256 proposalId => Proposed)) internal _proposed;
    /// @dev Every proposal made, as its fleet and its id.
    uint256[2][] internal _proposals;
    uint256[] internal _pending;
    mapping(uint256 requestId => uint256 tokenId) internal _requestToken;
    bool internal _phaseStepped;
    uint256 internal _acting;
    uint8 internal _phaseBefore;
    bytes32[] internal _before;

    constructor(CollectionSetting memory s) {
        factory = s.factory;
        keys = s.factory.KEYS();
        shards = s.factory.SHARDS();
        regentBuyer = s.factory.REGENT_BUYER();
        usdc = MockToken(address(s.factory.USDC()));
        regent = MockRegent(address(s.factory.REGENT()));
        weth = s.weth;
        vrf = s.vrf;
        vrfSubscription = s.vrfSubscription;
        staking = s.staking;
        safe = s.safe;
        keeper = s.keeper;
        v3Pool = s.v3Pool;
        poolManager = s.poolManager;

        for (uint256 i = 0; i < ACTORS; ++i) {
            _addAccount(0xA11CE0 + i);
        }
        for (uint256 i = 0; i < AGENTS; ++i) {
            _addAccount(0xA6E470 + i);
        }
        for (uint256 i = 0; i < OUTSIDERS; ++i) {
            _addAccount(0x0075D0 + i);
        }
        for (uint256 id = FIRST_OPEN_FLEET; id <= MAX_FLEETS; ++id) {
            _addAccount(0xC0EA70 + id);
        }

        ghostPhase = keys.phase();
        ghostFleetCount = keys.fleetCount();
        for (uint256 id = 1; id <= ghostFleetCount; ++id) {
            _recordFounding(id);
        }
    }

    // --- views for the invariants ---------------------------------------

    function accountCount() external view returns (uint256) {
        return _accounts.length;
    }

    function accountAt(uint256 index) external view returns (address) {
        return _accounts[index];
    }

    function recordOf(uint256 fleetId) external view returns (FleetRecord memory) {
        return _records[fleetId];
    }

    function creatorOf(uint256 fleetId) public view returns (address) {
        return _accounts[ACTORS + AGENTS + OUTSIDERS + fleetId - FIRST_OPEN_FLEET];
    }

    /// @notice Everything of fleet `fleetId` that no action in another fleet may change: its presence
    /// queue and every key's presence, its proposals with their tallies and electorates, its ledger's
    /// backing, split indexes and every known wallet's credits, its treasury's balances and split
    /// settings, its manager's books and profile.
    function fingerprint(uint256 fleetId) public view returns (bytes32 h) {
        KeyfleetManager manager = _manager(fleetId);
        h = _governanceFingerprint(manager);
        h = keccak256(abi.encode(h, _moneyFingerprint(manager)));
        KeyfleetRewards rewards = manager.REWARDS();
        for (uint256 i = 0; i < _accounts.length; ++i) {
            address account = _accounts[i];
            h = keccak256(
                abi.encode(h, rewards.credits(address(usdc), account), rewards.credits(address(regent), account))
            );
        }
    }

    function _governanceFingerprint(KeyfleetManager manager) internal view returns (bytes32 h) {
        KeyfleetVotes votes = manager.VOTES();
        uint256 count = votes.proposalCount();
        h = keccak256(abi.encode(votes.presenceRevision(), count));
        for (uint8 place = 1; place <= 3; ++place) {
            (uint64 head, uint64 tail, uint32 listed) = votes.presenceList(KeyfleetPresence.Place(place));
            h = keccak256(abi.encode(h, head, tail, listed));
        }
        for (uint256 id = 1; id <= count; ++id) {
            h = keccak256(abi.encode(h, votes.proposal(id)));
        }
        uint256 minted = manager.totalMinted();
        for (uint256 k = 1; k <= minted; ++k) {
            uint256 tokenId = keys.tokenIdOf(manager.FLEET_ID(), k);
            h = keccak256(abi.encode(h, votes.presentFrom(tokenId), votes.editsRestricted(tokenId)));
        }
    }

    function _moneyFingerprint(KeyfleetManager manager) internal view returns (bytes32) {
        KeyfleetRewards rewards = manager.REWARDS();
        KeyfleetTreasury treasury = manager.TREASURY();
        return keccak256(
            abi.encode(
                rewards.backed(address(usdc)),
                rewards.backed(address(regent)),
                rewards.splitIndex(address(usdc)),
                rewards.splitIndex(address(regent)),
                usdc.balanceOf(address(treasury)),
                regent.balanceOf(address(treasury)),
                address(treasury).balance,
                treasury.dailySplitBps(),
                treasury.lastRunAt(),
                manager.totalMinted(),
                manager.protocolShareOwed(),
                manager.cascadeReserve(),
                keccak256(abi.encode(manager.profile()))
            )
        );
    }

    // --- the step around every action -----------------------------------

    /// @dev Fingerprints every fleet but `acting` (every fleet when it is 0) before and after the
    /// action, then checks the phase, the fleet count, every epoch and every seed.
    modifier step(uint256 acting) {
        _beforeStep(acting);
        _;
        _afterStep();
    }

    function _beforeStep(uint256 acting) internal {
        _acting = acting;
        _phaseBefore = keys.phase();
        uint256 count = keys.fleetCount();
        delete _before;
        _before.push();
        for (uint256 id = 1; id <= count; ++id) {
            _before.push(id == acting ? bytes32(0) : fingerprint(id));
        }
    }

    function _afterStep() internal {
        for (uint256 id = 1; id < _before.length; ++id) {
            if (id != _acting && fingerprint(id) != _before[id]) {
                _breach("an action in one fleet changed another fleet");
            }
        }
        uint8 phase = keys.phase();
        if (phase != _phaseBefore && !(_phaseStepped && phase == _phaseBefore + 1)) {
            _breach("the phase moved other than one step by the Safe");
        }
        _phaseStepped = false;
        uint256 count = keys.fleetCount();
        if (count != ghostFleetCount) _breach("the fleet count moved outside a creation");
        for (uint256 id = 1; id <= count; ++id) {
            uint256 minted = _manager(id).totalMinted();
            for (uint256 k = 1; k <= minted; ++k) {
                uint256 tokenId = keys.tokenIdOf(id, k);
                uint64 epoch = keys.ownershipEpoch(tokenId);
                if (epoch < ghostEpoch[tokenId]) _breach("an ownership epoch went down");
                ghostEpoch[tokenId] = epoch;
                if (keys.revealSeed(tokenId) != ghostSeed[tokenId]) {
                    _breach("a seed changed, or appeared outside a fulfilment");
                }
            }
        }
    }

    // --- purchases and new fleets ---------------------------------------

    function buy(uint256 fleetSeed, uint256 actorSeed) external step(_fleetFrom(fleetSeed)) {
        uint256 id = _fleetFrom(fleetSeed);
        if (id == 0) return;
        KeyfleetManager manager = _manager(id);
        uint256 keyNumber = manager.totalMinted() + 1;
        if (keyNumber > MAX_KEYS) return;
        address to = _accounts[actorSeed % ACTORS];
        uint256 price = manager.nextPrice();
        bool open = _salesOpen(id, keys.phase());
        bool meets = _records[id].nftRequirement == address(0) || keys.balanceOf(to) > 0;
        Books memory before = _books(manager, keyNumber);
        usdc.mint(address(this), price);
        usdc.approve(address(manager), price);
        try manager.purchase(to, price, block.timestamp, new bytes32[](0)) returns (uint256 tokenId) {
            if (!open || !meets) _breach("a purchase went through that should have been refused");
            if (tokenId != keys.tokenIdOf(id, keyNumber)) _breach("a purchase minted the wrong key");
            _checkSale(id, keyNumber, price, before, to);
        } catch (bytes memory err) {
            bytes4 expected = meets ? KeyfleetKeys.SalesClosed.selector : KeyfleetManager.RequirementNotMet.selector;
            if ((open && meets) || bytes4(err) != expected) {
                _breach("a purchase was refused other than for closed sales or an unmet requirement");
            }
            usdc.approve(address(manager), 0);
        }
    }

    /// @notice Creates the next open fleet as its creator, who buys key 1 at the starting price: 10
    /// to 100 USDC in whole cents, with an Accelerant step of 1% to 5%, open to anyone or only to
    /// holders of any Keyfleet key.
    function createOpenFleet(uint256 presetSeed, uint256 priceSeed, bool keyHolders) public step(0) {
        uint256 id = keys.fleetCount() + 1;
        if (id > MAX_FLEETS) return;
        KeyfleetFactory.FleetTerms memory terms;
        terms.preset = KeyfleetPresets.Preset(presetSeed % 4);
        terms.startPrice = bound(priceSeed, 1000, 10_000) * 10_000;
        if (terms.preset == KeyfleetPresets.Preset.FleetTechAccelerant) {
            terms.accelerantStepPercent = 1 + (presetSeed / 4) % 5;
        }
        terms.profile = _profileNamed(id);
        if (keyHolders) terms.requirements.nft = address(keys);
        terms.deadline = block.timestamp;
        address creator = creatorOf(id);
        usdc.mint(creator, terms.startPrice);
        vm.prank(creator);
        usdc.approve(address(factory), terms.startPrice);

        Books memory before;
        before.poolUsdc = usdc.balanceOf(v3Pool);
        before.managerUsdc = usdc.balanceOf(creator);
        (, before.vrfNonce) = vrf.consumerConfig(address(keys), vrfSubscription);
        bool creationOpen = keys.phase() == keys.FINAL_PHASE();

        vm.prank(creator);
        try factory.createFleet(terms) returns (uint256 fleetId, uint256 tokenId) {
            if (!creationOpen) _breach("an open fleet was created before phase 3");
            if (fleetId != id || tokenId != keys.tokenIdOf(id, 1)) _breach("a creation numbered its fleet wrongly");
            _checkCreation(id, terms, creator, before);
        } catch (bytes memory err) {
            if (creationOpen || bytes4(err) != KeyfleetFactory.CreationClosed.selector) {
                _breach("a creation was refused other than before phase 3");
            }
            vm.prank(creator);
            usdc.approve(address(factory), 0);
        }
    }

    /// @dev `before.managerUsdc` carries the creator's USDC before the creation; the manager starts
    /// with none.
    function _checkCreation(uint256 id, KeyfleetFactory.FleetTerms memory terms, address creator, Books memory before)
        internal
    {
        (address manager, address votes, address treasury, address rewards) = factory.predict(id);
        if (keys.managerOf(id) != manager) _breach("a fleet's manager is not the predicted one");
        KeyfleetManager created = KeyfleetManager(manager);
        if (
            address(created.VOTES()) != votes || address(created.TREASURY()) != treasury
                || address(created.REWARDS()) != rewards
        ) _breach("a fleet's contracts are not the predicted ones");
        _recordOpen(id, terms, creator, before.managerUsdc - usdc.balanceOf(creator));
        before.managerUsdc = 0;
        _checkSale(id, 1, terms.startPrice, before, creator);
    }

    /// @dev Checks one sale's USDC split exactly (plan 7.3): the protocol share and any Cascade
    /// reserve stay as USDC in the manager, rebates and level reimbursements reach the ledger as
    /// USDC, the rest reaches the treasury as REGENT at the stand-in market's price, and the key is
    /// drawn for exactly when its fleet has a deck.
    function _checkSale(uint256 id, uint256 keyNumber, uint256 gross, Books memory before, address to) internal {
        KeyfleetManager manager = _manager(id);
        Split memory split = _expectedSplit(id, keyNumber, gross);
        Books memory afterwards = _books(manager, keyNumber);
        afterwards.predecessor = before.predecessor;
        afterwards.predecessorCredit =
            before.predecessor == address(0) ? 0 : manager.REWARDS().credits(address(usdc), before.predecessor);

        if (afterwards.owed != before.owed + split.protocol) _breach("a sale did not keep the protocol share as USDC");
        if (manager.cascadeReserve() != _reserve[id]) {
            _breach("the Cascade reserve is not its level's unreleased USDC");
        }
        if (
            afterwards.rewardsUsdc != before.rewardsUsdc + split.toLedger
                || afterwards.backed != before.backed + split.toLedger
        ) {
            _breach("a rebate or reimbursement did not reach the ledger as backed USDC");
        }
        if (afterwards.predecessorCredit != before.predecessorCredit + split.rebate) {
            _breach("a rebate was not credited to the holder of the key before");
        }
        if (afterwards.managerUsdc + split.toLedger + split.swapped != before.managerUsdc + gross) {
            _breach("the manager kept other than the protocol share and the reserve");
        }
        if (afterwards.treasuryUsdc != before.treasuryUsdc) _breach("a sale paid the treasury USDC");
        if (afterwards.treasuryRegent != before.treasuryRegent + split.swapped * 1e12) {
            _breach("the treasury's part of a sale did not arrive as REGENT at the market price");
        }
        if (afterwards.poolUsdc != before.poolUsdc + split.swapped) {
            _breach("the market did not take the swapped USDC");
        }
        ghostSwapped += split.swapped;
        ghostMinted += 1;

        uint256 tokenId = keys.tokenIdOf(id, keyNumber);
        if (keys.ownerOf(tokenId) != to) _breach("a sale minted to the wrong wallet");
        if (keys.ownershipEpoch(tokenId) != 1) _breach("a new key's epoch is not 1");
        if (keys.mintedAt(tokenId) != block.timestamp) _breach("a new key's mint time is not its sale");
        KeyfleetVotes votes = _manager(id).VOTES();
        if (votes.presentFrom(tokenId) != block.timestamp + votes.KEY_MATURITY()) {
            _breach("a new key's automatic presence does not start at its maturity");
        }
        _checkDraw(tokenId, before.vrfNonce, _records[id].deckHash != bytes32(0));
    }

    function _expectedSplit(uint256 id, uint256 keyNumber, uint256 gross) internal returns (Split memory split) {
        KeyfleetPresets.Preset preset = _records[id].preset;
        split.protocol = gross * 1000 / 10_000;
        if (preset == KeyfleetPresets.Preset.FibonacciCascade) {
            uint256 level = _levelOf(keyNumber);
            _levelGross[id][level] += gross;
            uint256 reserve = _reserve[id] + gross - split.protocol;
            if (keyNumber == _levelEnd(level)) {
                split.toLedger = level > 1 ? _levelGross[id][level - 1] : 0;
                split.swapped = reserve - split.toLedger;
                reserve = 0;
            }
            _reserve[id] = reserve;
        } else if (preset == KeyfleetPresets.Preset.FleetTechAccelerant && keyNumber > 1) {
            split.swapped = gross * 2000 / 10_000;
            split.rebate = gross - split.protocol - split.swapped;
            split.toLedger = split.rebate;
        } else {
            split.swapped = gross - split.protocol;
        }
    }

    function _books(KeyfleetManager manager, uint256 keyNumber) internal view returns (Books memory b) {
        b.managerUsdc = usdc.balanceOf(address(manager));
        b.rewardsUsdc = usdc.balanceOf(address(manager.REWARDS()));
        b.backed = manager.REWARDS().backed(address(usdc));
        b.treasuryUsdc = usdc.balanceOf(address(manager.TREASURY()));
        b.treasuryRegent = regent.balanceOf(address(manager.TREASURY()));
        b.poolUsdc = usdc.balanceOf(v3Pool);
        b.owed = manager.protocolShareOwed();
        if (manager.PRESET() == KeyfleetPresets.Preset.FleetTechAccelerant && keyNumber > 1) {
            b.predecessor = keys.ownerOf(keys.tokenIdOf(manager.FLEET_ID(), keyNumber - 1));
            b.predecessorCredit = manager.REWARDS().credits(address(usdc), b.predecessor);
        }
        (, b.vrfNonce) = vrf.consumerConfig(address(keys), vrfSubscription);
    }

    /// @dev A draw was requested for `tokenId` exactly when `drawn`, and is remembered for
    /// fulfilment.
    function _checkDraw(uint256 tokenId, uint64 nonceBefore, bool drawn) internal {
        (, uint64 nonce) = vrf.consumerConfig(address(keys), vrfSubscription);
        if (!drawn) {
            if (nonce != nonceBefore || keys.revealRequestedAt(tokenId) != 0) {
                _breach("a key of a fleet without a deck was drawn for");
            }
            return;
        }
        if (nonce != nonceBefore + 1 || keys.revealRequestedAt(tokenId) != block.timestamp) {
            _breach("a key of a fleet with a deck was not drawn for");
            return;
        }
        (uint256 requestId,) = vrf.computeRequestId(keys.VRF_KEY_HASH(), address(keys), vrfSubscription, nonce);
        _pending.push(requestId);
        _requestToken[requestId] = tokenId;
    }

    // --- keys and shards ------------------------------------------------

    function transfer(uint256 fleetSeed, uint256 keySeed, uint256 toSeed) external step(_fleetFrom(fleetSeed)) {
        (uint256 id, uint256 tokenId, address from) = _pickKey(fleetSeed, keySeed);
        if (tokenId == 0) return;
        KeyfleetManager manager = _manager(id);
        address to = _accountOtherThan(toSeed, from);
        uint64 epoch = keys.ownershipEpoch(tokenId);
        uint64 mintedAt = keys.mintedAt(tokenId);
        uint64 startsAt = mintedAt + manager.VOTES().KEY_MATURITY();
        vm.prank(from);
        keys.transferFrom(from, to, tokenId);
        if (keys.ownershipEpoch(tokenId) != epoch + 1) _breach("a move did not raise the key's epoch by one");
        if (keys.mintedAt(tokenId) != mintedAt) _breach("a move changed the key's mint time");
        if (block.timestamp < startsAt && manager.VOTES().presentFrom(tokenId) != startsAt) {
            _breach("a move before a key's automatic start cancelled it");
        }
        for (uint256 i = 0; i < AGENTS; ++i) {
            if (shards.isActive(tokenId, _agent(i))) _breach("a shard outlived its key's move");
        }
        if (manager.VOTES().isActive(tokenId)) _breach("a moved key stayed present");
    }

    function issueShard(uint256 fleetSeed, uint256 keySeed, uint256 agentSeed, uint16 days_)
        external
        step(_fleetFrom(fleetSeed))
    {
        (, uint256 tokenId, address owner) = _pickKey(fleetSeed, keySeed);
        if (tokenId == 0) return;
        address agent = _agent(agentSeed);
        vm.prank(owner);
        shards.issue(_ids(tokenId), agent, uint16(bound(days_, 1, 365)));
        if (!shards.isActive(tokenId, agent)) _breach("an issued shard is not active");
    }

    function refreshMetadata(uint256 fleetSeed, uint256 keySeed, uint256 callerSeed)
        external
        step(_fleetFrom(fleetSeed))
    {
        (, uint256 tokenId, address owner) = _pickKey(fleetSeed, keySeed);
        if (tokenId == 0) return;
        address caller = callerSeed % 3 == 0 ? owner : callerSeed % 3 == 1 ? keeper : _stranger(callerSeed, 0);
        bool allowed = caller == owner || caller == keeper;
        vm.prank(caller);
        try keys.refreshMetadata(tokenId) {
            if (!allowed) _breach("a stranger refreshed a key's metadata");
        } catch (bytes memory err) {
            if (allowed || bytes4(err) != KeyfleetKeys.NotOwnerOrKeeper.selector) {
                _breach("a metadata refresh was refused other than to a stranger");
            }
        }
    }

    // --- presence and votes ---------------------------------------------

    function present(uint256 fleetSeed, uint256 keySeed, uint256 callerSeed, bool bySig)
        external
        step(_fleetFrom(fleetSeed))
    {
        (uint256 id, uint256 tokenId, address owner) = _pickKey(fleetSeed, keySeed);
        if (tokenId == 0) return;
        KeyfleetVotes votes = _manager(id).VOTES();
        address caller = callerSeed % 2 == 0 ? owner : _agent(callerSeed);
        bool allowed = caller == owner || shards.isActive(tokenId, caller);
        bool mature = _isMature(tokenId);
        bool ok;
        bytes memory err;
        if (bySig) {
            uint256 deadline = block.timestamp + 1 hours;
            bytes memory signature = _presentSignature(votes, tokenId, caller, deadline);
            (ok, err) = address(votes)
                .call(abi.encodeCall(KeyfleetVotes.presentBySig, (_ids(tokenId), caller, deadline, signature)));
        } else {
            vm.prank(caller);
            (ok, err) = address(votes).call(abi.encodeCall(KeyfleetVotes.present, (_ids(tokenId))));
        }
        if (ok != (allowed && mature)) _breach("presence was granted or refused wrongly");
        if (
            !ok
                && bytes4(err)
                    != (allowed ? KeyfleetVotes.KeyTooNew.selector : KeyfleetVotes.NotAuthorizedForKey.selector)
        ) {
            _breach("presence was refused for the wrong reason");
        }
        if (ok && (!votes.isActive(tokenId) || votes.presentFrom(tokenId) != block.timestamp)) {
            _breach("a key presented is not present");
        }
    }

    function propose(uint256 fleetSeed, uint256 keySeed, uint256 kindSeed, uint256 paramSeed)
        external
        step(_fleetFrom(fleetSeed))
    {
        (uint256 id, uint256 tokenId, address author) = _pickKey(fleetSeed, keySeed);
        if (tokenId == 0) return;
        KeyfleetVotes votes = _manager(id).VOTES();
        if (votes.proposalCount() >= MAX_PROPOSALS) return;
        uint256 count = keys.fleetCount();
        Kind kind = Kind(kindSeed % 6);
        if (kind >= Kind.ForeignProfile && count < 2) kind = Kind.Nothing;
        uint256 param = paramSeed;
        if (kind == Kind.SplitRate) param = bound(paramSeed, 10, 200);
        if (kind >= Kind.ForeignProfile) param = 1 + (id + paramSeed % (count - 1)) % count;
        KeyfleetTreasury.Call[] memory calls = _calls(id, kind, param);
        bool mature = _isMature(tokenId);
        bool held = block.timestamp < votes.treasuryOpensAt() && _movesMoney(kind);
        vm.prank(author);
        try votes.propose(tokenId, keccak256(abi.encode(kind, param)), calls) returns (uint256 proposalId) {
            if (!mature) _breach("a key younger than its maturity proposed");
            if (held) _breach("a proposal moving money opened during the fleet's opening");
            _checkOpening(id, votes, proposalId);
            _proposed[id][proposalId] = Proposed(kind, param);
            _proposals.push([id, proposalId]);
        } catch (bytes memory err) {
            bytes4 expected = held ? KeyfleetVotes.TreasuryOpening.selector : KeyfleetVotes.KeyTooNew.selector;
            if ((mature && !held) || bytes4(err) != expected) _breach("a proposal was refused wrongly");
        }
    }

    /// @dev Every key a proposal counted as present at its opening was minted at least
    /// `KEY_MATURITY` before, and `e0` is exactly the number of the fleet's keys present then.
    function _checkOpening(uint256 id, KeyfleetVotes votes, uint256 proposalId) internal {
        uint256 minted = _manager(id).totalMinted();
        uint256 presentKeys;
        for (uint256 k = 1; k <= minted; ++k) {
            uint256 tokenId = keys.tokenIdOf(id, k);
            if (votes.isActive(tokenId)) ++presentKeys;
            if (votes.wasActiveAtOpening(proposalId, tokenId) && !_isMature(tokenId)) {
                _breach("an opening counted a key younger than its maturity");
            }
        }
        if (votes.proposal(proposalId).e0 != presentKeys) _breach("an opening's e0 is not the keys present then");
    }

    /// @dev `voterSeed` picks both the voter (an agent one time in three, else the owner) and the
    /// choice.
    function castBallot(uint256 pairSeed, uint256 keySeed, uint256 voterSeed, bool bySig)
        external
        step(_proposalFleet(pairSeed))
    {
        (uint256 id, uint256 proposalId) = _pickProposal(pairSeed);
        if (id == 0) return;
        uint256 tokenId = keys.tokenIdOf(id, 1 + keySeed % _manager(id).totalMinted());
        _checkBallot(_manager(id).VOTES(), proposalId, tokenId, voterSeed, bySig);
    }

    function _checkBallot(KeyfleetVotes votes, uint256 proposalId, uint256 tokenId, uint256 voterSeed, bool bySig)
        internal
    {
        address owner = keys.ownerOf(tokenId);
        address voter = voterSeed % 3 == 0 ? _agent(voterSeed / 3) : owner;
        KeyfleetVotes.Choice choice = KeyfleetVotes.Choice(1 + (voterSeed / 3) % 3);
        bool allowed = voter == owner || shards.mayGovern(tokenId, voter);
        bool mature = _isMature(tokenId);
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        bool open = !stored.cancelled && block.timestamp < stored.closesAt;
        (bool ok, bytes memory err) = _ballot(votes, proposalId, tokenId, choice, voter, bySig);
        if (ok != (open && allowed && mature)) _breach("a ballot was taken or refused wrongly");
        if (!ok) {
            bytes4 expected = !open
                ? KeyfleetVotes.BallotsClosed.selector
                : allowed ? KeyfleetVotes.KeyTooNew.selector : KeyfleetVotes.NotAuthorizedForKey.selector;
            if (bytes4(err) != expected) _breach("a ballot was refused for the wrong reason");
        } else if (votes.ballotOf(proposalId, tokenId) != choice) {
            _breach("a ballot was not recorded");
        }
    }

    /// @notice Every key's owner votes Yes on one proposal, as a fleet agreeing on it would; while
    /// ballots are open each mature key's ballot is taken and a key younger than its maturity is
    /// refused, and afterwards each is refused as closed. Once every key counted voted Yes, with
    /// `carryOut` the fleet waits for the ballots to close and carries the proposal out.
    function rally(uint256 pairSeed, bool carryOut) external step(_proposalFleet(pairSeed)) {
        (uint256 id, uint256 proposalId) = _pickProposal(pairSeed);
        if (id == 0) return;
        KeyfleetVotes votes = _manager(id).VOTES();
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        bool open = !stored.cancelled && block.timestamp < stored.closesAt;
        uint256 minted = _manager(id).totalMinted();
        bool everyCountedKeyVoted = true;
        for (uint256 k = 1; k <= minted; ++k) {
            uint256 tokenId = keys.tokenIdOf(id, k);
            bool mature = _isMature(tokenId);
            vm.prank(keys.ownerOf(tokenId));
            try votes.castBallot(proposalId, _ids(tokenId), KeyfleetVotes.Choice.Yes) {
                if (!open || !mature) _breach("a ballot was taken after ballots closed or from a new key");
            } catch (bytes memory err) {
                bytes4 expected = open ? KeyfleetVotes.KeyTooNew.selector : KeyfleetVotes.BallotsClosed.selector;
                if ((open && mature) || bytes4(err) != expected) {
                    _breach("an owner's ballot was refused other than as closed or too new");
                }
                if (open && votes.wasActiveAtOpening(proposalId, tokenId)) everyCountedKeyVoted = false;
            }
        }
        stored = votes.proposal(proposalId);
        if (open && everyCountedKeyVoted && stored.yes != uint256(stored.e0) + stored.late) {
            _breach("a proposal every key voted for does not count every key as Yes");
        }
        if (!open || !carryOut || !everyCountedKeyVoted) return;
        vm.warp(stored.closesAt);
        if (_movesMoney(_proposed[id][proposalId].kind)) {
            if (votes.status(proposalId) != KeyfleetVotes.Status.Waiting) {
                _breach("a money proposal every key voted for is not waiting at closing");
            }
            _checkExecute(id, proposalId);
            vm.warp(votes.executableAt(proposalId));
        }
        if (votes.status(proposalId) != KeyfleetVotes.Status.Approved) {
            _breach("a proposal every key voted for was not approved");
        }
        _checkExecute(id, proposalId);
    }

    function cancel(uint256 pairSeed) external step(_proposalFleet(pairSeed)) {
        (uint256 id, uint256 proposalId) = _pickProposal(pairSeed);
        if (id == 0) return;
        KeyfleetVotes votes = _manager(id).VOTES();
        KeyfleetVotes.Status status = votes.status(proposalId);
        address author = keys.ownerOf(votes.proposal(proposalId).authorKey);
        bool cancellable = status == KeyfleetVotes.Status.Open || status == KeyfleetVotes.Status.Waiting
            || status == KeyfleetVotes.Status.Approved;
        vm.prank(author);
        try votes.cancel(proposalId) {
            if (!cancellable) _breach("a proposal was cancelled that was past cancelling");
        } catch (bytes memory err) {
            if (cancellable || bytes4(err) != KeyfleetVotes.NotCancellable.selector) {
                _breach("a cancel was refused wrongly");
            }
        }
    }

    function execute(uint256 pairSeed) external step(_proposalFleet(pairSeed)) {
        (uint256 id, uint256 proposalId) = _pickProposal(pairSeed);
        if (id == 0) return;
        _checkExecute(id, proposalId);
    }

    /// @dev Anyone may carry out a proposal; it goes through exactly when it is approved and calls
    /// only its own fleet, and a call on another fleet's manager or ledger is refused by it. A
    /// proposal may be carried out from its closing, or a day after it when it moves money, for 48
    /// hours, and at no other time.
    function _checkExecute(uint256 id, uint256 proposalId) internal {
        KeyfleetVotes votes = _manager(id).VOTES();
        Proposed memory p = _proposed[id][proposalId];
        KeyfleetVotes.Proposal memory stored = votes.proposal(proposalId);
        uint64 executableAt = votes.executableAt(proposalId);
        if (executableAt != stored.closesAt + (_movesMoney(p.kind) ? 1 days : 0)) {
            _breach("a proposal's carry-out time is not its closing plus the money wait");
        }
        if (stored.executionExpiry != executableAt + 48 hours) _breach("a carry-out window is not 48 hours");
        bool approved = votes.status(proposalId) == KeyfleetVotes.Status.Approved;
        bool foreign = p.kind >= Kind.ForeignProfile;
        try votes.execute(proposalId, _calls(id, p.kind, p.param)) {
            if (!approved || foreign) _breach("a proposal was carried out that should not have been");
            if (block.timestamp < executableAt || block.timestamp >= stored.executionExpiry) {
                _breach("a proposal was carried out outside its window");
            }
            if (p.kind == Kind.Profile) _records[id].profileHash = keccak256(abi.encode(_renamed(p.param)));
            if (votes.status(proposalId) != KeyfleetVotes.Status.Executed) {
                _breach("a carried-out proposal is not Executed");
            }
        } catch (bytes memory err) {
            bytes4 expected = !approved
                ? KeyfleetVotes.NotApproved.selector
                : p.kind == Kind.ForeignProfile
                    ? KeyfleetManager.OnlyTreasury.selector
                    : KeyfleetRewards.OnlyManager.selector;
            if ((approved && !foreign) || bytes4(err) != expected) {
                _breach("carrying out a proposal failed other than as expected");
            }
        }
    }

    // --- money ------------------------------------------------------------

    function claim(uint256 fleetSeed, uint256 keySeed, uint256 callerSeed) external step(_fleetFrom(fleetSeed)) {
        (uint256 id, uint256 tokenId, address holder) = _pickKey(fleetSeed, keySeed);
        if (tokenId == 0) return;
        KeyfleetRewards rewards = _manager(id).REWARDS();
        address caller = callerSeed % 3 == 0 ? _agent(callerSeed) : holder;
        bool allowed = caller == holder || shards.isActive(tokenId, caller);
        uint256[2] memory owed = [
            _claimable(rewards, address(usdc), tokenId, holder, caller),
            _claimable(rewards, address(regent), tokenId, holder, caller)
        ];
        uint256[2] memory held = [_heldBy(usdc, holder, caller), _heldBy(regent, holder, caller)];
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(usdc), address(regent));
        vm.prank(caller);
        try rewards.claim(_ids(tokenId), assets) {
            if (!allowed || owed[0] + owed[1] == 0) _breach("a claim went through that should have been refused");
            if (
                _heldBy(usdc, holder, caller) != held[0] + owed[0]
                    || _heldBy(regent, holder, caller) != held[1] + owed[1]
            ) _breach("a claim did not pay exactly what was owed");
        } catch (bytes memory err) {
            bytes4 expected =
                allowed ? KeyfleetRewards.NothingToClaim.selector : KeyfleetRewards.NotKeyHolderOrAgent.selector;
            if ((allowed && owed[0] + owed[1] != 0) || bytes4(err) != expected) {
                _breach("a claim was refused wrongly");
            }
        }
    }

    function runDailySplit(uint256 fleetSeed, uint256 callerSeed) external step(_fleetFrom(fleetSeed)) {
        uint256 id = _fleetFrom(fleetSeed);
        if (id == 0) return;
        KeyfleetTreasury treasury = _manager(id).TREASURY();
        uint256 opensAt = treasury.nextRunAt();
        bool due = opensAt != 0 && block.timestamp >= opensAt;
        vm.prank(_stranger(callerSeed, 0));
        try treasury.runDailySplit() {
            if (!due) _breach("a daily split ran before it was due");
            if (treasury.lastRunAt() != block.timestamp) _breach("a daily split did not record its run");
        } catch (bytes memory err) {
            if (due || bytes4(err) != KeyfleetTreasury.SplitNotDue.selector) _breach("a due daily split was refused");
        }
    }

    function sendProtocolShare(uint256 fleetSeed, uint256 callerSeed) external step(_fleetFrom(fleetSeed)) {
        uint256 id = _fleetFrom(fleetSeed);
        if (id == 0) return;
        KeyfleetManager manager = _manager(id);
        uint256 owed = manager.protocolShareOwed();
        uint256 received = staking.totalUsdcReceived();
        uint256 treasuryUsdc = usdc.balanceOf(address(manager.TREASURY()));
        vm.prank(_stranger(callerSeed, 0));
        try manager.sendProtocolShare() returns (uint256 sent) {
            if (owed == 0 || sent != owed) _breach("the protocol share sent is not what was owed");
            if (staking.totalUsdcReceived() != received + owed) _breach("staking did not receive the protocol share");
            if (manager.protocolShareOwed() != 0) _breach("the protocol share is still owed after sending");
            if (usdc.balanceOf(address(manager.TREASURY())) != treasuryUsdc) {
                _breach("the protocol share stayed in the treasury");
            }
            ghostShareSent += owed;
        } catch (bytes memory err) {
            if (owed != 0 || bytes4(err) != KeyfleetManager.ZeroAmount.selector) {
                _breach("sending the protocol share was refused wrongly");
            }
        }
    }

    /// @notice A stray USDC or REGENT transfer to a manager, forwarded unswapped to the fleet's
    /// treasury by anyone.
    function sendStray(uint256 fleetSeed, bool inRegent, uint256 amount, uint256 callerSeed)
        external
        step(_fleetFrom(fleetSeed))
    {
        uint256 id = _fleetFrom(fleetSeed);
        if (id == 0) return;
        KeyfleetManager manager = _manager(id);
        address treasury = address(manager.TREASURY());
        IERC20 asset = inRegent ? IERC20(address(regent)) : IERC20(address(usdc));
        amount = inRegent ? bound(amount, 1, 1000e18) : bound(amount, 1, 1000e6);
        if (inRegent) regent.mint(address(manager), amount);
        else usdc.mint(address(manager), amount);
        uint256 treasuryBefore = asset.balanceOf(treasury);
        vm.prank(_stranger(callerSeed, 0));
        uint256 forwarded = manager.recognizeSurplus(address(asset));
        if (forwarded != amount || asset.balanceOf(treasury) != treasuryBefore + amount) {
            _breach("a stray transfer did not reach the treasury unswapped");
        }
        if (asset.balanceOf(address(manager)) != manager.accountedBalance(address(asset))) {
            _breach("a manager kept a stray transfer");
        }
    }

    /// @notice An outsider buys REGENT through the shared buyer with its own USDC.
    function buyRegentDirect(uint256 outsiderSeed, uint256 amount) external step(0) {
        address outsider = _accounts[ACTORS + AGENTS + outsiderSeed % OUTSIDERS];
        amount = bound(amount, 1, 10_000e6);
        usdc.mint(outsider, amount);
        uint256 before = regent.balanceOf(outsider);
        vm.startPrank(outsider);
        usdc.approve(address(regentBuyer), amount);
        uint256 out = regentBuyer.buy(amount, outsider);
        vm.stopPrank();
        if (out != amount * 1e12 || regent.balanceOf(outsider) != before + out) {
            _breach("a direct REGENT buy did not pay the market price");
        }
        if (usdc.allowance(outsider, address(regentBuyer)) != 0) _breach("a direct buy left an allowance");
        ghostSwapped += amount;
    }

    // --- the collection ---------------------------------------------------

    function recordDeck(uint256 fleetSeed, uint256 callerSeed, bytes32 deckHash, uint256 deckSize)
        external
        step(_fleetFrom(fleetSeed))
    {
        uint256 id = _fleetFrom(fleetSeed);
        if (id == 0) return;
        address caller = callerSeed % 3 == 0 ? _stranger(callerSeed, 0) : keeper;
        deckSize = bound(deckSize, 0, 1000);
        bytes4 expected;
        if (caller != keeper) expected = KeyfleetKeys.OnlyKeeper.selector;
        else if (_records[id].deckHash != bytes32(0)) expected = KeyfleetKeys.DeckAlreadySet.selector;
        else if (deckHash == bytes32(0) || deckSize == 0) expected = KeyfleetKeys.DeckInvalid.selector;
        vm.prank(caller);
        try keys.setDeck(id, deckHash, deckSize) {
            if (expected != bytes4(0)) _breach("a deck was recorded that should have been refused");
            _records[id].deckHash = deckHash;
            _records[id].deckSize = uint32(deckSize);
        } catch (bytes memory err) {
            if (bytes4(err) != expected || expected == bytes4(0)) _breach("a deck was refused wrongly");
        }
    }

    function requestReveal(uint256 fleetSeed, uint256 keySeed, uint256 callerSeed)
        external
        step(_fleetFrom(fleetSeed))
    {
        (uint256 id, uint256 tokenId,) = _pickKey(fleetSeed, keySeed);
        if (tokenId == 0) return;
        bytes4 expected;
        if (keys.revealSeed(tokenId) != bytes32(0)) expected = KeyfleetKeys.AlreadyRevealed.selector;
        else if (keys.revealRequestedAt(tokenId) != 0) expected = KeyfleetKeys.RevealAlreadyRequested.selector;
        else if (_records[id].deckHash == bytes32(0)) expected = KeyfleetKeys.DeckNotSet.selector;
        (, uint64 nonce) = vrf.consumerConfig(address(keys), vrfSubscription);
        vm.prank(_stranger(callerSeed, 0));
        try keys.requestReveal(tokenId) {
            if (expected != bytes4(0)) _breach("a reveal was requested that should have been refused");
            _checkDraw(tokenId, nonce, true);
        } catch (bytes memory err) {
            if (bytes4(err) != expected || expected == bytes4(0)) _breach("a reveal request was refused wrongly");
        }
    }

    function fulfil(uint256 pendingSeed, uint256 word) external step(_fleetOfPending(pendingSeed)) {
        if (_pending.length == 0) return;
        uint256 index = pendingSeed % _pending.length;
        uint256 requestId = _pending[index];
        _pending[index] = _pending[_pending.length - 1];
        _pending.pop();
        uint256 tokenId = _requestToken[requestId];
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vrf.fulfill(requestId, words);
        bytes32 seed = keccak256(abi.encode(keys.TRAIT_SEED_TAG(), block.chainid, address(keys), tokenId, word));
        if (keys.revealSeed(tokenId) != seed) _breach("a fulfilment did not set the seed from its word");
        ghostSeed[tokenId] = seed;
    }

    function advancePhase(uint256 callerSeed) external step(0) {
        address caller = callerSeed % 3 == 0 ? _stranger(callerSeed, 0) : safe;
        uint8 phase = keys.phase();
        uint256 needed = phase == 0 ? 1 : phase == 1 ? 4 : 0;
        bytes4 expected;
        if (caller != safe) expected = KeyfleetKeys.OnlySafe.selector;
        else if (phase >= keys.FINAL_PHASE()) expected = KeyfleetKeys.NoNextPhase.selector;
        else if (keys.fleetCount() < needed) expected = KeyfleetKeys.FleetsMissing.selector;
        vm.prank(caller);
        try keys.advancePhase() {
            if (expected != bytes4(0)) _breach("the phase moved when it should not have");
            _phaseStepped = true;
            ghostPhase = phase + 1;
        } catch (bytes memory err) {
            if (bytes4(err) != expected || expected == bytes4(0)) _breach("a phase step was refused wrongly");
        }
    }

    function wait(uint256 secs) external step(0) {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
        vm.roll(block.number + 1);
    }

    // --- attempts by the wrong caller or with another fleet's key ---------

    function attack(uint256 pick, uint256 fleetSeed, uint256 callerSeed, uint256 keySeed) external step(0) {
        uint256 id = _fleetFrom(fleetSeed);
        if (id == 0) return;
        Attempt memory a;
        a.pick = pick % ATTACKS;
        a.fleetId = id;
        a.manager = _manager(id);
        a.caller = _stranger(callerSeed, id);
        uint256 minted = a.manager.totalMinted();
        if (minted != 0) {
            a.ownKey = keys.tokenIdOf(id, 1 + keySeed % minted);
            a.ownOwner = keys.ownerOf(a.ownKey);
        }
        (a.foreignKey, a.foreignOwner) = _foreignKey(id, keySeed);
        a.openProposal = _openProposal(a.manager.VOTES());
        if (a.pick < 12) _attackCollection(a);
        else if (a.pick < 20) _attackManagerAndFactory(a);
        else if (a.pick < 29) _attackVotes(a);
        else if (a.pick < 37) _attackTreasury(a);
        else _attackLedgerAndShards(a);
    }

    function _attackCollection(Attempt memory a) internal {
        address k = address(keys);
        bool safeCalls = a.caller == safe;
        if (a.pick == 0 && !safeCalls) {
            _attempt(a, k, abi.encodeCall(KeyfleetKeys.advancePhase, ()), KeyfleetKeys.OnlySafe.selector);
        } else if (a.pick == 1 && !safeCalls) {
            _attempt(a, k, abi.encodeCall(KeyfleetKeys.setKeeper, (a.caller)), KeyfleetKeys.OnlySafe.selector);
        } else if (a.pick == 2 && !safeCalls) {
            _attempt(a, k, abi.encodeCall(KeyfleetKeys.addFactory, (address(factory))), KeyfleetKeys.OnlySafe.selector);
        } else if (a.pick == 3) {
            bytes memory data = abi.encodeCall(
                KeyfleetKeys.registerFleet, (KeyfleetPresets.Preset.FleetTechClassic, a.caller, bytes32(0), 0)
            );
            _attempt(a, k, data, KeyfleetKeys.OnlyFactory.selector);
        } else if (a.pick == 4 && a.caller != keeper) {
            bytes memory data = abi.encodeCall(KeyfleetKeys.setDeck, (a.fleetId, keccak256("deck"), 1));
            _attempt(a, k, data, KeyfleetKeys.OnlyKeeper.selector);
        } else if (a.pick == 5 && keys.fleetOfManager(a.caller) == 0) {
            _attempt(a, k, abi.encodeCall(KeyfleetKeys.mint, (a.caller, 1)), KeyfleetKeys.OnlyManager.selector);
        } else if (a.pick == 6 && keys.fleetOfManager(a.caller) == 0) {
            _attempt(a, k, abi.encodeCall(KeyfleetKeys.refreshFleet, ()), KeyfleetKeys.OnlyManager.selector);
        } else if (a.pick == 7) {
            bytes memory data = abi.encodeCall(KeyfleetKeys.rawFulfillRandomWords, (1, new uint256[](1)));
            _attempt(a, k, data, KeyfleetKeys.OnlyCoordinator.selector);
        } else if (a.pick == 8 && a.ownKey != 0 && a.caller != a.ownOwner && a.caller != keeper) {
            bytes memory data = abi.encodeCall(KeyfleetKeys.refreshMetadata, (a.ownKey));
            _attempt(a, k, data, KeyfleetKeys.NotOwnerOrKeeper.selector);
        } else if (a.pick >= 9 && a.pick <= 10 && a.ownKey != 0 && a.caller != a.ownOwner) {
            // Nobody but the owner moves a key, the Safe included, and the approval check comes
            // before any fleet bookkeeping.
            address taker = a.pick == 9 ? a.caller : safe;
            a.caller = taker;
            bytes memory data =
                abi.encodeWithSignature("transferFrom(address,address,uint256)", a.ownOwner, taker, a.ownKey);
            if (taker != a.ownOwner) _attempt(a, k, data, IERC721Errors.ERC721InsufficientApproval.selector);
        } else if (a.pick == 11 && keys.phase() < keys.FINAL_PHASE()) {
            KeyfleetFactory.FleetTerms memory terms;
            terms.startPrice = 10e6;
            terms.profile = _renamed(0);
            terms.deadline = block.timestamp;
            bytes memory data = abi.encodeCall(KeyfleetFactory.createFleet, (terms));
            _attempt(a, address(factory), data, KeyfleetFactory.CreationClosed.selector);
        }
    }

    function _attackManagerAndFactory(Attempt memory a) internal {
        address m = address(a.manager);
        KeyfleetManager.Requirements memory anyone;
        if (a.pick == 12 && a.caller != safe) {
            bytes memory data = abi.encodeCall(
                KeyfleetFactory.createFoundingFleet,
                (KeyfleetPresets.Preset.FleetTechClassic, keccak256("deck"), 1, _renamed(0))
            );
            _attempt(a, address(factory), data, KeyfleetFactory.OnlySafe.selector);
        } else if (a.pick == 13) {
            bytes memory data = abi.encodeCall(KeyfleetManager.initialize, (_renamed(0), anyone));
            _attempt(a, m, data, KeyfleetManager.OnlyFactory.selector);
        } else if (a.pick == 14) {
            _attempt(
                a, m, abi.encodeCall(KeyfleetManager.sellFirstKey, (a.caller)), KeyfleetManager.OnlyFactory.selector
            );
        } else if (a.pick == 15 && a.ownKey != 0) {
            bytes memory data = abi.encodeCall(KeyfleetManager.onKeyMoved, (a.ownKey, a.ownOwner));
            _attempt(a, m, data, KeyfleetManager.OnlyKeys.selector);
        } else if (a.pick == 16 && a.foreignKey != 0) {
            a.caller = address(keys);
            bytes memory data = abi.encodeCall(KeyfleetManager.onKeyMoved, (a.foreignKey, a.foreignOwner));
            _attempt(a, m, data, KeyfleetManager.ForeignKey.selector);
        } else if (a.pick == 17) {
            _attempt(
                a, m, abi.encodeCall(KeyfleetManager.setProfile, (_renamed(1))), KeyfleetManager.OnlyTreasury.selector
            );
        } else if (a.pick == 18) {
            // Another fleet's treasury is a stranger too.
            a.caller = address(_manager(_otherFleet(a.fleetId)).TREASURY());
            if (a.caller == address(a.manager.TREASURY())) return;
            _attempt(
                a, m, abi.encodeCall(KeyfleetManager.setProfile, (_renamed(2))), KeyfleetManager.OnlyTreasury.selector
            );
        } else if (a.pick == 19) {
            bytes memory data = abi.encodeCall(KeyfleetRegentBuyer.uniswapV3SwapCallback, (int256(1), int256(1), ""));
            if (a.caller == safe) a.caller = v3Pool;
            _attempt(a, address(regentBuyer), data, KeyfleetRegentBuyer.UnexpectedCallback.selector);
        }
    }

    function _attackVotes(Attempt memory a) internal {
        KeyfleetVotes votes = a.manager.VOTES();
        address v = address(votes);
        if (a.pick == 20) {
            if (a.ownKey == 0) return;
            _attempt(a, v, abi.encodeCall(KeyfleetVotes.onKeyMoved, (a.ownKey)), KeyfleetVotes.OnlyManager.selector);
        } else if (a.pick == 21) {
            if (a.ownKey == 0) return;
            bytes memory data = abi.encodeCall(KeyfleetVotes.setEditsRestricted, (a.ownKey, true));
            _attempt(a, v, data, KeyfleetVotes.OnlyTreasury.selector);
        } else if (a.pick == 22) {
            if (a.foreignKey == 0) return;
            a.caller = address(a.manager.TREASURY());
            bytes memory data = abi.encodeCall(KeyfleetVotes.setEditsRestricted, (a.foreignKey, true));
            _attempt(a, v, data, KeyfleetVotes.ForeignKey.selector);
        } else if (a.pick == 23) {
            if (a.foreignKey == 0) return;
            a.caller = a.foreignOwner;
            _attempt(
                a, v, abi.encodeCall(KeyfleetVotes.present, (_ids(a.foreignKey))), KeyfleetVotes.ForeignKey.selector
            );
        } else if (a.pick == 24) {
            if (a.foreignKey == 0) return;
            a.caller = a.foreignOwner;
            bytes memory data =
                abi.encodeCall(KeyfleetVotes.propose, (a.foreignKey, bytes32(0), new KeyfleetTreasury.Call[](0)));
            _attempt(a, v, data, KeyfleetVotes.ForeignKey.selector);
        } else if (a.pick == 25) {
            if (a.foreignKey == 0 || a.openProposal == 0) return;
            a.caller = a.foreignOwner;
            bytes memory data = abi.encodeCall(
                KeyfleetVotes.castBallot, (a.openProposal, _ids(a.foreignKey), KeyfleetVotes.Choice.Yes)
            );
            _attempt(a, v, data, KeyfleetVotes.ForeignKey.selector);
        } else if (a.pick == 26) {
            if (a.foreignKey == 0) return;
            uint256 deadline = block.timestamp + 1 hours;
            bytes memory signature = _presentSignature(votes, a.foreignKey, a.foreignOwner, deadline);
            bytes memory data =
                abi.encodeCall(KeyfleetVotes.presentBySig, (_ids(a.foreignKey), a.foreignOwner, deadline, signature));
            _attempt(a, v, data, KeyfleetVotes.ForeignKey.selector);
        } else if (a.pick == 27) {
            if (a.foreignKey == 0 || a.openProposal == 0) return;
            uint256 deadline = block.timestamp + 1 hours;
            KeyfleetVotes.Choice yes = KeyfleetVotes.Choice.Yes;
            bytes memory signature =
                _ballotSignature(votes, a.openProposal, a.foreignKey, yes, a.foreignOwner, deadline);
            bytes memory data = abi.encodeCall(
                KeyfleetVotes.castBallotBySig,
                (a.openProposal, _ids(a.foreignKey), yes, a.foreignOwner, deadline, signature)
            );
            _attempt(a, v, data, KeyfleetVotes.ForeignKey.selector);
        } else if (a.pick == 28) {
            if (a.ownKey == 0 || a.caller == a.ownOwner || shards.isActive(a.ownKey, a.caller)) return;
            bytes memory data = abi.encodeCall(KeyfleetVotes.present, (_ids(a.ownKey)));
            _attempt(a, v, data, KeyfleetVotes.NotAuthorizedForKey.selector);
        }
    }

    function _attackTreasury(Attempt memory a) internal {
        KeyfleetTreasury treasury = a.manager.TREASURY();
        address t = address(treasury);
        bytes4 onlySelf = KeyfleetTreasury.OnlySelf.selector;
        if (a.pick == 29) {
            bytes memory data = abi.encodeCall(KeyfleetTreasury.executeBatch, (new KeyfleetTreasury.Call[](0)));
            _attempt(a, t, data, KeyfleetTreasury.OnlyVotes.selector);
        } else if (a.pick == 30) {
            // Another fleet's controller is a stranger too.
            a.caller = address(_manager(_otherFleet(a.fleetId)).VOTES());
            if (a.caller == address(a.manager.VOTES())) return;
            bytes memory data = abi.encodeCall(KeyfleetTreasury.executeBatch, (new KeyfleetTreasury.Call[](0)));
            _attempt(a, t, data, KeyfleetTreasury.OnlyVotes.selector);
        } else if (a.pick == 31) {
            bytes memory data = abi.encodeCall(KeyfleetTreasury.depositProtocolShare, (1));
            _attempt(a, t, data, KeyfleetTreasury.OnlyManager.selector);
        } else if (a.pick == 32) {
            _attempt(a, t, abi.encodeCall(KeyfleetTreasury.pay, (address(usdc), a.caller, 1)), onlySelf);
        } else if (a.pick == 33) {
            bytes memory data = abi.encodeCall(KeyfleetTreasury.advance, (99, a.caller, address(regent), 1, bytes32(0)));
            _attempt(a, t, data, onlySelf);
        } else if (a.pick == 34) {
            _attempt(a, t, abi.encodeCall(KeyfleetTreasury.runVotedSplit, ()), onlySelf);
        } else if (a.pick == 35) {
            _attempt(a, t, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (100)), onlySelf);
        } else if (a.pick == 36) {
            bytes memory data = a.caller == address(this)
                ? abi.encodeCall(KeyfleetTreasury.admitOusd, (weth))
                : abi.encodeCall(KeyfleetTreasury.approveSignatureHash, (keccak256("order")));
            _attempt(a, t, data, onlySelf);
        }
    }

    function _attackLedgerAndShards(Attempt memory a) internal {
        KeyfleetRewards rewards = a.manager.REWARDS();
        address r = address(rewards);
        bytes4 onlyManager = KeyfleetRewards.OnlyManager.selector;
        if (a.pick == 37) {
            _attempt(a, r, abi.encodeCall(KeyfleetRewards.enrollKey, (a.ownKey + 1, 0)), onlyManager);
        } else if (a.pick == 38) {
            // Another fleet's manager is a stranger too.
            a.caller = address(_manager(_otherFleet(a.fleetId)));
            if (a.caller == address(a.manager)) return;
            _attempt(a, r, abi.encodeCall(KeyfleetRewards.credit, (address(usdc), a.caller, 1)), onlyManager);
        } else if (a.pick == 39) {
            _attempt(a, r, abi.encodeCall(KeyfleetRewards.allocateToCohort, (address(usdc), 0, 1)), onlyManager);
        } else if (a.pick == 40) {
            if (a.ownKey == 0) return;
            _attempt(a, r, abi.encodeCall(KeyfleetRewards.settleKey, (a.ownKey, a.caller)), onlyManager);
        } else if (a.pick == 41) {
            bytes memory data = abi.encodeCall(KeyfleetRewards.fundSplit, (address(usdc), 1, 1));
            _attempt(a, r, data, KeyfleetRewards.OnlyTreasury.selector);
        } else if (a.pick == 42) {
            // The treasury itself, outside a split.
            a.caller = address(a.manager.TREASURY());
            bytes memory data = a.ownKey % 2 == 0
                ? abi.encodeCall(KeyfleetRewards.fundSplit, (address(usdc), 1, 1))
                : abi.encodeCall(KeyfleetRewards.fundSplitNative, (1, 1));
            _attempt(a, r, data, KeyfleetRewards.NotSplitting.selector);
        } else if (a.pick == 43) {
            if (a.foreignKey == 0) return;
            a.caller = a.foreignOwner;
            address[] memory assets = new address[](1);
            assets[0] = address(usdc);
            _attempt(
                a,
                r,
                abi.encodeCall(KeyfleetRewards.claim, (_ids(a.foreignKey), assets)),
                KeyfleetRewards.ForeignKey.selector
            );
        } else if (a.pick == 44) {
            if (a.ownKey == 0 || a.caller == a.ownOwner || shards.isActive(a.ownKey, a.caller)) return;
            address[] memory assets = new address[](1);
            assets[0] = address(usdc);
            bytes memory data = abi.encodeCall(KeyfleetRewards.claim, (_ids(a.ownKey), assets));
            _attempt(a, r, data, KeyfleetRewards.NotKeyHolderOrAgent.selector);
        } else if (a.pick == 45) {
            if (a.ownKey == 0 || a.caller == a.ownOwner) return;
            address wallet = a.caller == _agent(0) ? _agent(1) : _agent(0);
            bytes memory data = a.ownKey % 2 == 0
                ? abi.encodeCall(KeyfleetShards.issue, (_ids(a.ownKey), wallet, 30))
                : abi.encodeCall(KeyfleetShards.setAgentVoting, (_ids(a.ownKey), false));
            _attempt(a, address(shards), data, KeyfleetShards.NotKeyOwner.selector);
            bytes memory unlock = abi.encodeCall(KeyfleetRegentBuyer.unlockCallback, (""));
            a.caller = poolManager;
            _attempt(a, address(regentBuyer), unlock, KeyfleetRegentBuyer.UnexpectedCallback.selector);
        }
    }

    /// @dev Calls `target` as the attempt's caller and records a breach unless it reverts with
    /// `expected`.
    function _attempt(Attempt memory a, address target, bytes memory data, bytes4 expected) internal {
        vm.prank(a.caller);
        (bool ok, bytes memory err) = target.call(data);
        if (ok || err.length < 4 || bytes4(err) != expected) {
            _breach(string.concat("attempt ", vm.toString(a.pick), " was not refused as expected"));
        }
    }

    // --- helpers -----------------------------------------------------------

    function _addAccount(uint256 privateKey) internal {
        address account = vm.addr(privateKey);
        _accounts.push(account);
        _pkOf[account] = privateKey;
    }

    function _agent(uint256 seed) internal view returns (address) {
        return _accounts[ACTORS + seed % AGENTS];
    }

    /// @dev Someone with no role on fleet `fleetId`: a wallet, the Safe, the keeper, the handler, or
    /// one of another fleet's four contracts.
    function _stranger(uint256 seed, uint256 fleetId) internal view returns (address) {
        uint256 wallets = _accounts.length;
        uint256 pick = seed % (wallets + 7);
        if (pick < wallets) return _accounts[pick];
        if (pick == wallets) return safe;
        if (pick == wallets + 1) return keeper;
        if (pick == wallets + 2) return address(this);
        uint256 other = _otherFleet(fleetId == 0 ? 1 : fleetId);
        if (other == fleetId || fleetId == 0) return _accounts[seed % wallets];
        KeyfleetManager manager = _manager(other);
        if (pick == wallets + 3) return address(manager);
        if (pick == wallets + 4) return address(manager.VOTES());
        if (pick == wallets + 5) return address(manager.TREASURY());
        return address(manager.REWARDS());
    }

    function _otherFleet(uint256 fleetId) internal view returns (uint256) {
        uint256 count = keys.fleetCount();
        return fleetId % count + 1;
    }

    /// @dev A proposal made so far in any fleet, as its fleet and its id; (0, 0) when there is none.
    function _pickProposal(uint256 seed) internal view returns (uint256 id, uint256 proposalId) {
        if (_proposals.length == 0) return (0, 0);
        uint256[2] memory pair = _proposals[seed % _proposals.length];
        return (pair[0], pair[1]);
    }

    function _proposalFleet(uint256 seed) internal view returns (uint256 id) {
        (id,) = _pickProposal(seed);
    }

    function _fleetFrom(uint256 seed) internal view returns (uint256) {
        uint256 count = keys.fleetCount();
        return count == 0 ? 0 : 1 + seed % count;
    }

    function _fleetOfPending(uint256 seed) internal view returns (uint256) {
        if (_pending.length == 0) return 0;
        return keys.fleetOf(_requestToken[_pending[seed % _pending.length]]);
    }

    function _manager(uint256 fleetId) internal view returns (KeyfleetManager) {
        return KeyfleetManager(keys.managerOf(fleetId));
    }

    /// @dev A minted key of the fleet drawn from `fleetSeed`, and its owner; token id 0 when the
    /// fleet has none.
    function _pickKey(uint256 fleetSeed, uint256 keySeed)
        internal
        view
        returns (uint256 id, uint256 tokenId, address owner)
    {
        id = _fleetFrom(fleetSeed);
        if (id == 0) return (0, 0, address(0));
        uint256 minted = _manager(id).totalMinted();
        if (minted == 0) return (id, 0, address(0));
        tokenId = keys.tokenIdOf(id, 1 + keySeed % minted);
        owner = keys.ownerOf(tokenId);
    }

    /// @dev A minted key of a fleet other than `fleetId`, and its owner; 0 when there is none.
    function _foreignKey(uint256 fleetId, uint256 seed) internal view returns (uint256 tokenId, address owner) {
        uint256 count = keys.fleetCount();
        for (uint256 step_ = 1; step_ < count; ++step_) {
            uint256 other = (fleetId - 1 + step_ + seed % count) % count + 1;
            if (other == fleetId) continue;
            uint256 minted = _manager(other).totalMinted();
            if (minted == 0) continue;
            tokenId = keys.tokenIdOf(other, 1 + seed % minted);
            return (tokenId, keys.ownerOf(tokenId));
        }
    }

    function _openProposal(KeyfleetVotes votes) internal view returns (uint256) {
        uint256 count = votes.proposalCount();
        for (uint256 id = count; id >= 1; --id) {
            KeyfleetVotes.Proposal memory stored = votes.proposal(id);
            if (!stored.cancelled && block.timestamp < stored.closesAt) return id;
        }
        return 0;
    }

    /// @dev Whether a key was minted at least `KEY_MATURITY` ago.
    function _isMature(uint256 tokenId) internal view returns (bool) {
        return block.timestamp >= keys.mintedAt(tokenId) + _manager(keys.fleetOf(tokenId)).VOTES().KEY_MATURITY();
    }

    /// @dev An actor other than `not`, chosen by `seed`.
    function _accountOtherThan(uint256 seed, address not) internal view returns (address actor) {
        actor = _accounts[seed % ACTORS];
        if (actor == not) actor = _accounts[(seed % ACTORS + 1) % ACTORS];
    }

    function _salesOpen(uint256 fleetId, uint8 phase) internal pure returns (bool) {
        if (fleetId == 1) return phase >= 1;
        if (fleetId <= 4) return phase >= 2;
        return true;
    }

    function _calls(uint256 id, Kind kind, uint256 param) internal view returns (KeyfleetTreasury.Call[] memory calls) {
        if (kind == Kind.Nothing) return calls;
        calls = new KeyfleetTreasury.Call[](1);
        KeyfleetManager manager = _manager(id);
        if (kind == Kind.Profile) {
            calls[0] = KeyfleetTreasury.Call(
                address(manager), 0, abi.encodeCall(KeyfleetManager.setProfile, (_renamed(param)))
            );
        } else if (kind == Kind.VotedSplit) {
            calls[0] = KeyfleetTreasury.Call(
                address(manager.TREASURY()), 0, abi.encodeCall(KeyfleetTreasury.runVotedSplit, ())
            );
        } else if (kind == Kind.SplitRate) {
            calls[0] = KeyfleetTreasury.Call(
                address(manager.TREASURY()), 0, abi.encodeCall(KeyfleetTreasury.setDailySplitBps, (param))
            );
        } else if (kind == Kind.ForeignProfile) {
            calls[0] = KeyfleetTreasury.Call(
                address(_manager(param)), 0, abi.encodeCall(KeyfleetManager.setProfile, (_renamed(param)))
            );
        } else {
            bytes memory data = abi.encodeCall(KeyfleetRewards.credit, (address(usdc), address(manager.TREASURY()), 1));
            calls[0] = KeyfleetTreasury.Call(address(_manager(param).REWARDS()), 0, data);
        }
    }

    /// @dev Whether a kind moves money: anything but nothing, a profile or a split rate.
    function _movesMoney(Kind kind) internal pure returns (bool) {
        return kind != Kind.Nothing && kind != Kind.Profile && kind != Kind.SplitRate;
    }

    function _renamed(uint256 param) internal pure returns (KeyfleetManager.Profile memory) {
        string[4] memory names = ["Northern fleet", "Harbour fleet", "Night fleet", "Signal fleet"];
        return KeyfleetManager.Profile({
            name: names[param % 4], description: "Renamed by vote.", imageLink: "https://media.regents.sh/ipfs/renamed"
        });
    }

    function _profileNamed(uint256 id) internal pure returns (KeyfleetManager.Profile memory) {
        return KeyfleetManager.Profile({
            name: id == 5 ? "Open fleet five" : "Open fleet six",
            description: "A fleet of keys.",
            imageLink: "https://media.regents.sh/ipfs/open"
        });
    }

    function _claimable(KeyfleetRewards rewards, address asset, uint256 tokenId, address holder, address caller)
        internal
        view
        returns (uint256 amount)
    {
        amount = rewards.credits(asset, holder) + rewards.accrued(asset, tokenId);
        if (caller != holder) amount += rewards.credits(asset, caller);
    }

    function _heldBy(IERC20 asset, address holder, address caller) internal view returns (uint256 amount) {
        amount = asset.balanceOf(holder);
        if (caller != holder) amount += asset.balanceOf(caller);
    }

    function _ballot(
        KeyfleetVotes votes,
        uint256 proposalId,
        uint256 tokenId,
        KeyfleetVotes.Choice choice,
        address voter,
        bool bySig
    ) internal returns (bool ok, bytes memory err) {
        if (!bySig) {
            vm.prank(voter);
            return address(votes).call(abi.encodeCall(KeyfleetVotes.castBallot, (proposalId, _ids(tokenId), choice)));
        }
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _ballotSignature(votes, proposalId, tokenId, choice, voter, deadline);
        return address(votes)
            .call(
                abi.encodeCall(
                    KeyfleetVotes.castBallotBySig, (proposalId, _ids(tokenId), choice, voter, deadline, signature)
                )
            );
    }

    function _presentSignature(KeyfleetVotes votes, uint256 tokenId, address signer, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(votes.PRESENT_TYPEHASH(), address(votes.MANAGER())),
                _keyState(tokenId),
                abi.encode(signer, votes.nonces(signer), deadline)
            )
        );
        return _sign(votes, signer, structHash);
    }

    function _ballotSignature(
        KeyfleetVotes votes,
        uint256 proposalId,
        uint256 tokenId,
        KeyfleetVotes.Choice choice,
        address signer,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(votes.BALLOT_TYPEHASH(), proposalId, votes.proposal(proposalId).proposalHash),
                _keyState(tokenId),
                abi.encode(choice, signer, votes.nonces(signer), deadline)
            )
        );
        return _sign(votes, signer, structHash);
    }

    function _keyState(uint256 tokenId) internal view returns (bytes memory) {
        uint64[] memory epochs = new uint64[](1);
        uint64[] memory revisions = new uint64[](1);
        epochs[0] = keys.ownershipEpoch(tokenId);
        revisions[0] = shards.delegationRevision(tokenId);
        return abi.encode(
            keccak256(abi.encodePacked(_ids(tokenId))),
            keccak256(abi.encodePacked(epochs)),
            keccak256(abi.encodePacked(revisions))
        );
    }

    function _sign(KeyfleetVotes votes, address signer, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("KeyfleetVotes"),
                keccak256("1"),
                block.chainid,
                address(votes)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(_pkOf[signer], keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _ids(uint256 tokenId) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    /// @dev Fibonacci levels hold 2, 3, 5, 8, 13, ... keys.
    function _levelOf(uint256 keyNumber) internal pure returns (uint256 level) {
        (uint256 size, uint256 next, uint256 end) = (2, 3, 2);
        level = 1;
        while (keyNumber > end) {
            (size, next) = (next, size + next);
            end += size;
            ++level;
        }
    }

    function _levelEnd(uint256 level) internal pure returns (uint256 end) {
        (uint256 size, uint256 next) = (2, 3);
        end = 2;
        for (uint256 i = 1; i < level; ++i) {
            (size, next) = (next, size + next);
            end += size;
        }
    }

    function _recordFounding(uint256 id) internal {
        KeyfleetKeys.Fleet memory stored = keys.fleet(id);
        KeyfleetManager.Requirements memory anyone;
        uint256 typeNumber = ++ghostTypeCount[stored.preset];
        _records[id] = FleetRecord({
            manager: stored.manager,
            preset: stored.preset,
            typeNumber: uint32(typeNumber),
            deckSize: stored.deckSize,
            deckHash: stored.deckHash,
            startPrice: 10e6,
            accelerantStepPercent: stored.preset == KeyfleetPresets.Preset.FleetTechAccelerant ? 5 : 0,
            creator: address(0),
            firstPricePaid: 0,
            nftRequirement: address(0),
            profileHash: keccak256(abi.encode(KeyfleetManager(stored.manager).profile())),
            requirementsHash: keccak256(abi.encode(anyone))
        });
    }

    function _recordOpen(uint256 id, KeyfleetFactory.FleetTerms memory terms, address creator, uint256 paid) internal {
        ghostFleetCount = id;
        uint256 typeNumber = ++ghostTypeCount[terms.preset];
        (address manager,,,) = factory.predict(id);
        _records[id] = FleetRecord({
            manager: manager,
            preset: terms.preset,
            typeNumber: uint32(typeNumber),
            deckSize: 0,
            deckHash: bytes32(0),
            startPrice: terms.startPrice,
            accelerantStepPercent: terms.accelerantStepPercent,
            creator: creator,
            firstPricePaid: paid,
            nftRequirement: terms.requirements.nft,
            profileHash: keccak256(abi.encode(terms.profile)),
            requirementsHash: keccak256(abi.encode(terms.requirements))
        });
    }

    function _breach(string memory reason) internal {
        if (bytes(breach).length == 0) breach = reason;
    }
}

/// @dev The collection-wide invariants (design §10.8, items 1 to 8 and 10 to 13; item 9 is the
/// other suites in this folder), checked after every action of the handler.
abstract contract KeyfleetCollectionInvariantBase is KeyfleetFixture {
    CollectionHandler internal handler;

    function _startHandler() internal {
        handler = new CollectionHandler(
            CollectionSetting({
                factory: factory,
                vrf: vrf,
                vrfSubscription: vrfSubscription,
                staking: staking,
                weth: IERC20(address(weth)),
                v3Pool: address(v3Pool),
                poolManager: address(poolManager),
                safe: safe,
                keeper: keeper
            })
        );
    }

    function _manager(uint256 fleetId) internal view returns (KeyfleetManager) {
        return KeyfleetManager(keys.managerOf(fleetId));
    }

    /// @dev Every rule the handler checks around and inside each action: 5, no action in one fleet
    /// changes another's presence, tallies, electorates, backing, credits, treasury, holding counts
    /// or profile; 3, the phase only rises one step by the Safe; 6, a shard ends when its key moves;
    /// 11, each sale splits exactly; and every privileged or key-taking call by the wrong caller or
    /// with another fleet's key is refused with its own error.
    function invariant_noActionBrokeARule() public view {
        assertEq(handler.breach(), "");
    }

    /// @dev 1. Every key belongs to exactly one fleet, and no key exists past its fleet's count, at
    /// number 0, or in a fleet not yet created.
    function invariant_everyKeyBelongsToExactlyOneFleet() public view {
        uint256 count = keys.fleetCount();
        for (uint256 id = 1; id <= count; ++id) {
            uint256 minted = _manager(id).totalMinted();
            for (uint256 k = 1; k <= minted; ++k) {
                uint256 tokenId = keys.tokenIdOf(id, k);
                assertEq(keys.fleetOf(tokenId), id, "a key's fleet is the one it was sold in");
                assertEq(keys.keyNumberOf(tokenId), k, "a key's number is the one it was sold as");
                assertTrue(keys.ownerOf(tokenId) != address(0), "every sold key exists");
            }
            _assertNoKey(keys.tokenIdOf(id, minted + 1));
            _assertNoKey(keys.tokenIdOf(id, 0));
        }
        _assertNoKey(keys.tokenIdOf(count + 1, 1));
    }

    function _assertNoKey(uint256 tokenId) internal view {
        try keys.ownerOf(tokenId) returns (address) {
            assertTrue(false, "no key exists past a fleet's count");
        } catch {}
    }

    /// @dev 2. The fleets' counts add up to every key the collection minted, and to every key the
    /// known wallets hold.
    function invariant_theFleetCountsAddUpToTheCollection() public view {
        uint256 total;
        for (uint256 id = 1; id <= keys.fleetCount(); ++id) {
            total += _manager(id).totalMinted();
        }
        uint256 held;
        for (uint256 i = 0; i < handler.accountCount(); ++i) {
            held += keys.balanceOf(handler.accountAt(i));
        }
        assertEq(total, handler.ghostMinted(), "the fleets' counts add up to the keys minted");
        assertEq(held, total, "the known wallets hold every key minted");
    }

    /// @dev 3. A fleet with closed sales has sold nothing, the phase is the one the Safe stepped
    /// to, and no open fleet exists before phase 3.
    function invariant_phasesGateSalesAndCreation() public view {
        uint8 phase = keys.phase();
        assertEq(phase, handler.ghostPhase(), "the phase is the one the Safe stepped to");
        uint256 count = keys.fleetCount();
        if (phase < keys.FINAL_PHASE()) assertLe(count, keys.FOUNDING_FLEETS(), "no open fleet before phase 3");
        for (uint256 id = 1; id <= count; ++id) {
            bool open = id == 1 ? phase >= 1 : id <= 4 ? phase >= 2 : true;
            assertEq(keys.salesOpen(id), open, "sales open by phase");
            if (!open) assertEq(_manager(id).totalMinted(), 0, "a fleet with closed sales has sold nothing");
        }
    }

    /// @dev 4. Registry entries never change but for a deck recorded once, type numbers count up
    /// per type, and fleet numbers only grow.
    function invariant_theRegistryNeverChanges() public view {
        uint256 count = keys.fleetCount();
        assertEq(count, handler.ghostFleetCount(), "fleet numbers only grow, one per creation");
        for (uint256 id = 1; id <= count; ++id) {
            KeyfleetKeys.Fleet memory stored = keys.fleet(id);
            CollectionHandler.FleetRecord memory record = handler.recordOf(id);
            assertEq(stored.manager, record.manager, "a fleet's manager never changes");
            assertEq(uint8(stored.preset), uint8(record.preset), "a fleet's type never changes");
            assertEq(stored.typeNumber, record.typeNumber, "a fleet's type number never changes");
            assertEq(stored.deckHash, record.deckHash, "a fleet's deck is only ever the one recorded");
            assertEq(stored.deckSize, record.deckSize, "a fleet's deck size is only ever the one recorded");
            assertEq(keys.fleetOfManager(stored.manager), id, "a manager maps back to its fleet");
        }
        for (uint8 p = 0; p < 4; ++p) {
            KeyfleetPresets.Preset preset = KeyfleetPresets.Preset(p);
            assertEq(keys.typeCount(preset), handler.ghostTypeCount(preset), "type numbers count up per type");
        }
    }

    /// @dev 6. Every sold key has an epoch of at least 1, never below the highest seen.
    function invariant_everySoldKeyHasAnEpoch() public view {
        for (uint256 id = 1; id <= keys.fleetCount(); ++id) {
            uint256 minted = _manager(id).totalMinted();
            for (uint256 k = 1; k <= minted; ++k) {
                uint256 tokenId = keys.tokenIdOf(id, k);
                uint64 epoch = keys.ownershipEpoch(tokenId);
                assertGe(epoch, 1, "a sold key has an epoch");
                assertEq(epoch, handler.ghostEpoch(tokenId), "epochs only rise, and only as seen");
            }
        }
    }

    /// @dev 7. The collection, the factory and the REGENT buyer hold no tokens or ETH, and no
    /// approval is left behind by a sale, a swap, a deposit or a creation.
    function invariant_theSharedContractsHoldNothing() public view {
        address[3] memory shared = [address(keys), address(factory), address(regentBuyer)];
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(usdc.balanceOf(shared[i]), 0, "a shared contract holds no USDC");
            assertEq(weth.balanceOf(shared[i]), 0, "a shared contract holds no WETH");
            assertEq(regent.balanceOf(shared[i]), 0, "a shared contract holds no REGENT");
            assertEq(shared[i].balance, 0, "a shared contract holds no ETH");
        }
        assertEq(usdc.allowance(address(regentBuyer), address(v3Pool)), 0, "the buyer leaves no USDC approval");
        assertEq(weth.allowance(address(regentBuyer), address(poolManager)), 0, "the buyer leaves no WETH approval");
        for (uint256 id = 1; id <= keys.fleetCount(); ++id) {
            KeyfleetManager manager = _manager(id);
            assertEq(usdc.allowance(address(manager), address(regentBuyer)), 0, "a sale leaves no approval");
            assertEq(usdc.allowance(address(manager.TREASURY()), address(staking)), 0, "a deposit leaves no approval");
            if (id >= 5) {
                assertEq(usdc.allowance(handler.creatorOf(id), address(factory)), 0, "a creation leaves no approval");
            }
            uint256 minted = manager.totalMinted();
            for (uint256 k = 1; k <= minted; ++k) {
                assertEq(keys.getApproved(keys.tokenIdOf(id, k)), address(0), "no key is approved to anyone");
            }
        }
    }

    /// @dev 8. Each fleet's four contracts point at each other, at the shared contracts and at
    /// nothing else, at the addresses the factory predicts; no address serves two fleets; and no
    /// wiring is left outside a creation.
    function invariant_eachFleetsContractsPointAtEachOther() public view {
        uint256 count = keys.fleetCount();
        for (uint256 id = 1; id <= count; ++id) {
            _assertWired(id);
            for (uint256 other = 1; other < id; ++other) {
                assertTrue(keys.managerOf(other) != keys.managerOf(id), "no manager serves two fleets");
                assertTrue(_manager(other).TREASURY() != _manager(id).TREASURY(), "no treasury serves two fleets");
            }
        }
        FleetWiring memory w = factory.wiring();
        assertEq(w.fleetId + w.startPrice + w.accelerantStepPercent, 0, "no wiring outside a creation");
        assertEq(w.manager, address(0), "no wiring outside a creation");
    }

    function _assertWired(uint256 id) internal view {
        KeyfleetManager manager = _manager(id);
        (address m, address v, address t, address r) = factory.predict(id);
        assertEq(address(manager), m, "the manager is at its predicted address");
        assertEq(address(manager.VOTES()), v, "the manager's controller is the fleet's");
        assertEq(address(manager.TREASURY()), t, "the manager's treasury is the fleet's");
        assertEq(address(manager.REWARDS()), r, "the manager's ledger is the fleet's");
        assertEq(manager.FLEET_ID(), id, "the manager knows its fleet");
        assertEq(manager.FACTORY(), address(factory), "the manager's factory");
        assertEq(address(manager.KEYS()), address(keys), "the manager's collection");
        assertEq(address(manager.USDC()), address(usdc), "the manager's USDC");
        assertEq(address(manager.REGENT_BUYER()), address(regentBuyer), "the manager's REGENT buyer");

        KeyfleetVotes votes = KeyfleetVotes(v);
        assertEq(address(votes.MANAGER()), m, "the controller's manager is the fleet's");
        assertEq(address(votes.TREASURY()), t, "the controller's treasury is the fleet's");
        assertEq(address(votes.KEYS()), address(keys), "the controller's collection");
        assertEq(address(votes.SHARDS()), address(shards), "the controller's shard record");
        assertEq(votes.FLEET_ID(), id, "the controller knows its fleet");

        KeyfleetTreasury treasury = KeyfleetTreasury(payable(t));
        assertEq(address(treasury.MANAGER()), m, "the treasury's manager is the fleet's");
        assertEq(address(treasury.VOTES()), v, "the treasury's controller is the fleet's");
        assertEq(address(treasury.REWARDS()), r, "the treasury's ledger is the fleet's");
        assertEq(address(treasury.USDC()), address(usdc), "the treasury's USDC");
        assertEq(address(treasury.REGENT()), address(regent), "the treasury's REGENT");
        assertEq(address(treasury.REGENT_STAKING()), address(staking), "the treasury's staking");
        assertEq(address(treasury.AUTOLAUNCH()), address(autolaunch), "the treasury's Autolaunch");

        KeyfleetRewards rewards = KeyfleetRewards(r);
        assertEq(address(rewards.MANAGER()), m, "the ledger's manager is the fleet's");
        assertEq(address(rewards.TREASURY()), t, "the ledger's treasury is the fleet's");
        assertEq(address(rewards.KEYS()), address(keys), "the ledger's collection");
        assertEq(address(rewards.SHARDS()), address(shards), "the ledger's shard record");
        assertEq(rewards.USDC(), address(usdc), "the ledger's USDC");
        assertEq(rewards.FLEET_ID(), id, "the ledger knows its fleet");
    }

    /// @dev 10. A fleet's deck is recorded at most once (item 4 holds it to the record), a key of a
    /// fleet without a deck has no seed and no draw, and every seed came from a draw.
    function invariant_onlyKeysOfAFleetWithADeckAreDrawn() public view {
        for (uint256 id = 1; id <= keys.fleetCount(); ++id) {
            bool hasDeck = handler.recordOf(id).deckHash != bytes32(0);
            uint256 minted = _manager(id).totalMinted();
            for (uint256 k = 1; k <= minted; ++k) {
                uint256 tokenId = keys.tokenIdOf(id, k);
                bytes32 seed = keys.revealSeed(tokenId);
                uint64 requestedAt = keys.revealRequestedAt(tokenId);
                if (!hasDeck) {
                    assertEq(seed, bytes32(0), "a key of a fleet without a deck has no seed");
                    assertEq(requestedAt, 0, "a key of a fleet without a deck has no draw");
                }
                if (seed != bytes32(0)) assertGt(requestedAt, 0, "every seed came from a draw");
            }
        }
    }

    /// @dev 11. Every token is where the books say: all USDC sits with known holders, the market
    /// took exactly the USDC swapped and gave REGENT at its price, each manager holds exactly its
    /// owed share and reserve, staking received exactly the shares sent, and each ledger holds
    /// exactly what it backs.
    function invariant_moneyIsWhereTheBooksSay() public view {
        uint256 known = usdc.balanceOf(address(handler)) + usdc.balanceOf(address(keys))
            + usdc.balanceOf(address(factory)) + usdc.balanceOf(address(regentBuyer)) + usdc.balanceOf(address(v3Pool))
            + usdc.balanceOf(address(poolManager)) + usdc.balanceOf(address(staking));
        for (uint256 i = 0; i < handler.accountCount(); ++i) {
            known += usdc.balanceOf(handler.accountAt(i));
        }
        for (uint256 id = 1; id <= keys.fleetCount(); ++id) {
            KeyfleetManager manager = _manager(id);
            KeyfleetRewards rewards = manager.REWARDS();
            known += usdc.balanceOf(address(manager)) + usdc.balanceOf(address(rewards))
            + usdc.balanceOf(address(manager.TREASURY())) + usdc.balanceOf(address(manager.VOTES()));
            assertEq(
                usdc.balanceOf(address(manager)),
                manager.protocolShareOwed() + manager.cascadeReserve(),
                "a manager holds exactly its owed share and reserve"
            );
            assertEq(regent.balanceOf(address(manager)), 0, "a manager holds no REGENT");
            assertEq(usdc.balanceOf(address(rewards)), rewards.backed(address(usdc)), "a ledger holds what it backs");
            assertEq(
                regent.balanceOf(address(rewards)), rewards.backed(address(regent)), "a ledger holds what it backs"
            );
        }
        assertEq(known, usdc.totalSupply(), "all USDC sits with known holders");
        assertEq(usdc.balanceOf(address(v3Pool)), handler.ghostSwapped(), "the market took exactly the USDC swapped");
        assertEq(
            1e45 - regent.balanceOf(address(poolManager)),
            handler.ghostSwapped() * 1e12,
            "the market gave REGENT at its price"
        );
        assertEq(staking.totalUsdcReceived(), handler.ghostShareSent(), "staking received exactly the shares sent");
    }

    /// @dev 12. Each fleet keeps its starting price; an open fleet's key 1 went to its creator at
    /// that price; and the next price follows the type's curve scaled to it.
    function invariant_pricesFollowEachFleetsCurve() public view {
        for (uint256 id = 1; id <= keys.fleetCount(); ++id) {
            KeyfleetManager manager = _manager(id);
            CollectionHandler.FleetRecord memory record = handler.recordOf(id);
            assertEq(manager.START_PRICE(), record.startPrice, "a fleet keeps its starting price");
            assertEq(manager.ACCELERANT_STEP_PERCENT(), record.accelerantStepPercent, "a fleet keeps its step");
            if (id >= 5) {
                uint256 first = keys.tokenIdOf(id, 1);
                assertEq(record.firstPricePaid, record.startPrice, "the creator paid the starting price for key 1");
                if (keys.ownershipEpoch(first) == 1) {
                    assertEq(keys.ownerOf(first), record.creator, "key 1 is the creator's");
                }
            }
            uint256 keyNumber = manager.totalMinted() + 1;
            assertEq(
                manager.nextPrice(),
                _curvePrice(record.preset, record.startPrice, record.accelerantStepPercent, keyNumber),
                "the curve, scaled"
            );
        }
    }

    function _curvePrice(KeyfleetPresets.Preset preset, uint256 start, uint256 stepPercent, uint256 keyNumber)
        internal
        pure
        returns (uint256 price)
    {
        price = start;
        if (preset == KeyfleetPresets.Preset.FleetTechClassic) {
            // The table at the founding price of 10 USDC, in cents, scaled to `start` and rounded up
            // to a whole cent.
            uint256 cents = KeyfleetPresets.classicPrice(keyNumber, 10e6) / 10_000;
            return (cents * start + 10e6 - 1) / 10e6 * 10_000;
        }
        uint256 steps;
        uint256 numerator;
        if (preset == KeyfleetPresets.Preset.FleetTechAccelerant) {
            (steps, numerator) = (keyNumber - 1, 100 + stepPercent);
        } else {
            (uint256 size, uint256 next, uint256 end) = (2, 3, 2);
            while (keyNumber > end) {
                (size, next) = (next, size + next);
                end += size;
                ++steps;
            }
            numerator = 120;
        }
        for (uint256 i = 0; i < steps; ++i) {
            price = (price * numerator + 99) / 100;
        }
    }

    /// @dev 13. A fleet's profile is only ever the one it was created with or the last one its own
    /// treasury set; its joining requirements never change.
    function invariant_profilesAndRequirementsHold() public view {
        for (uint256 id = 1; id <= keys.fleetCount(); ++id) {
            KeyfleetManager manager = _manager(id);
            CollectionHandler.FleetRecord memory record = handler.recordOf(id);
            assertEq(keccak256(abi.encode(manager.profile())), record.profileHash, "the profile changes only by vote");
            assertEq(
                keccak256(abi.encode(manager.requirements())), record.requirementsHash, "the requirements never change"
            );
        }
    }
}

/// @dev Design §10.8 run with the four founding fleets and two open fleets on one collection in
/// phase 3: open fleet 5 is a Classic fleet at 12.50 USDC open to anyone; open fleet 6 is a Cascade
/// fleet at 25 USDC open only to holders of any Keyfleet key.
/// The everyday run is short; `FOUNDRY_PROFILE=deep` runs it at the design's 256 runs × depth 100.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: deep.invariant.runs = 256
/// forge-config: deep.invariant.depth = 100
/// forge-config: deep.invariant.fail-on-revert = true
contract KeyfleetCollectionInvariantTest is KeyfleetCollectionInvariantBase {
    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        _deploy(KeyfleetPresets.Preset.FleetTechClassic);
        _openCreation();
        _startHandler();
        // Three keys in each fleet to start from, the key-holders-only fleet last. The founding
        // fleets are past their opening by the time the open fleets are created, so proposals that
        // move money are both refused and carried out as the sequence goes on.
        _buyRounds(1, 4);
        vm.warp(block.timestamp + KeyfleetManager(keys.managerOf(1)).VOTES().TREASURY_OPENING());
        handler.createOpenFleet(uint256(KeyfleetPresets.Preset.FleetTechClassic), 1250, false);
        handler.createOpenFleet(uint256(KeyfleetPresets.Preset.FibonacciCascade), 2500, true);
        require(keys.fleetCount() == 6, "six fleets");
        _buyRounds(5, 6);

        bytes4[] memory selectors = new bytes4[](31);
        selectors[0] = CollectionHandler.buy.selector;
        selectors[1] = CollectionHandler.buy.selector;
        selectors[2] = CollectionHandler.transfer.selector;
        selectors[3] = CollectionHandler.issueShard.selector;
        selectors[4] = CollectionHandler.refreshMetadata.selector;
        selectors[5] = CollectionHandler.present.selector;
        selectors[6] = CollectionHandler.propose.selector;
        selectors[7] = CollectionHandler.castBallot.selector;
        selectors[8] = CollectionHandler.cancel.selector;
        selectors[9] = CollectionHandler.execute.selector;
        selectors[10] = CollectionHandler.claim.selector;
        selectors[11] = CollectionHandler.runDailySplit.selector;
        selectors[12] = CollectionHandler.sendProtocolShare.selector;
        selectors[13] = CollectionHandler.sendStray.selector;
        selectors[14] = CollectionHandler.buyRegentDirect.selector;
        selectors[15] = CollectionHandler.recordDeck.selector;
        selectors[16] = CollectionHandler.requestReveal.selector;
        selectors[17] = CollectionHandler.fulfil.selector;
        selectors[18] = CollectionHandler.advancePhase.selector;
        selectors[19] = CollectionHandler.wait.selector;
        selectors[20] = CollectionHandler.attack.selector;
        selectors[21] = CollectionHandler.attack.selector;
        selectors[22] = CollectionHandler.rally.selector;
        selectors[23] = CollectionHandler.execute.selector;
        selectors[24] = CollectionHandler.propose.selector;
        selectors[25] = CollectionHandler.wait.selector;
        selectors[26] = CollectionHandler.wait.selector;
        selectors[27] = CollectionHandler.claim.selector;
        selectors[28] = CollectionHandler.rally.selector;
        selectors[29] = CollectionHandler.attack.selector;
        selectors[30] = CollectionHandler.attack.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _buyRounds(uint256 firstFleet, uint256 lastFleet) private {
        for (uint256 round = 0; round < 3; ++round) {
            for (uint256 id = firstFleet; id <= lastFleet; ++id) {
                handler.buy(id - 1, round * 6 + id);
            }
        }
    }
}

/// @dev Design §10.8 run from phase 0 with only the four founding fleets: the Safe steps the
/// phases while purchases, decks, reveals, new open fleets and attempts on every privileged
/// function run alongside, so items 3 and 4 also see the closed phases and the first creations.
/// The everyday run is short; `FOUNDRY_PROFILE=deep` runs it at the design's 256 runs × depth 100.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: deep.invariant.runs = 256
/// forge-config: deep.invariant.depth = 100
/// forge-config: deep.invariant.fail-on-revert = true
contract KeyfleetCollectionPhasesInvariantTest is KeyfleetCollectionInvariantBase {
    function setUp() public {
        _setUpFixture();
        vm.warp(1_000_000);
        for (uint256 id = 1; id <= keys.FOUNDING_FLEETS(); ++id) {
            _createFounding(keys.foundingPreset(id));
        }
        _startHandler();

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = CollectionHandler.buy.selector;
        selectors[1] = CollectionHandler.buy.selector;
        selectors[2] = CollectionHandler.advancePhase.selector;
        selectors[3] = CollectionHandler.createOpenFleet.selector;
        selectors[4] = CollectionHandler.transfer.selector;
        selectors[5] = CollectionHandler.recordDeck.selector;
        selectors[6] = CollectionHandler.requestReveal.selector;
        selectors[7] = CollectionHandler.fulfil.selector;
        selectors[8] = CollectionHandler.attack.selector;
        selectors[9] = CollectionHandler.sendProtocolShare.selector;
        selectors[10] = CollectionHandler.claim.selector;
        selectors[11] = CollectionHandler.wait.selector;
        selectors[12] = CollectionHandler.attack.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
}
