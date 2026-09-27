// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAutolaunchAuction} from "../../src/interfaces/IAutolaunchAuction.sol";
import {IAutolaunchEscrow} from "../../src/interfaces/IAutolaunchEscrow.sol";
import {IRegentLBPStrategy} from "../../src/interfaces/IRegentLBPStrategy.sol";
import {IRegentsAutolaunchFactoryV1} from "../../src/interfaces/IRegentsAutolaunchFactoryV1.sol";

/// @dev Anything the mock strategy can mint REGENT from.
interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @dev The SUBJECT a mock launch creates: a plain eighteen-decimal token anyone may mint.
contract MockLaunchToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for the launch's continuous clearing auction. It answers `lbpInitializationParams`
/// with the REGENT the auction raised, which is the figure the strategy sweeps at graduation.
contract MockAuction is IAutolaunchAuction {
    uint256 public currencyRaised;

    function setCurrencyRaised(uint256 amount) external {
        currencyRaised = amount;
    }

    function lbpInitializationParams() external view returns (LBPInitializationParams memory params) {
        params.currencyRaised = currencyRaised;
    }
}

/// @dev Stands in for `ConditionalVestingEscrowV1`. It holds the launch's pending SUBJECT and
/// releases it to the one fixed treasury, counting every unit in `totalReleased` exactly as the
/// real escrow does. Anyone may release, as on the real one.
contract MockEscrow is IAutolaunchEscrow {
    MockLaunchToken public immutable SUBJECT;
    address public immutable TREASURY;
    uint256 public totalReleased;

    constructor(MockLaunchToken subject, address treasury) {
        SUBJECT = subject;
        TREASURY = treasury;
    }

    function release(uint256 amount) external {
        totalReleased += amount;
        SUBJECT.transfer(TREASURY, amount);
    }
}

/// @dev Stands in for the shared `RegentLBPStrategy`. It holds the one bound it publishes and the
/// per-auction record the fleet reads, and lets a test put an auction into any lifecycle the real
/// strategy can reach. Graduation does what the real strategy does to the treasury in the same
/// transaction: the auction reports what it raised, the pool takes `lpRegentUsed` of it, and the
/// rest of the raised REGENT is sent to the treasury.
contract MockLBPStrategy is IRegentLBPStrategy {
    uint128 public constant MAX_REACHABLE_RAISE = 658_201_822_928_399_999_999_999_581_824_872_526;

    IMintable public immutable REGENT;

    mapping(address auction => Distribution) private _distributions;

    constructor(IMintable regent) {
        REGENT = regent;
    }

    function open(address auction, uint256 launchId, address subject, address escrow, address treasury, uint128 raise)
        external
    {
        Distribution storage d = _distributions[auction];
        d.lifecycle = Lifecycle.Active;
        d.startBlock = uint64(block.number) + 300;
        d.endBlock = d.startBlock + 86_401;
        d.requiredRegentRaised = raise;
        d.launchId = launchId;
        d.subject = subject;
        d.escrow = escrow;
        d.treasury = treasury;
    }

    function graduate(
        address auction,
        address splitter,
        address receiver,
        bytes32 poolId,
        uint256 lpTokenId,
        uint128 raised,
        uint128 lpRegentUsed
    ) external {
        Distribution storage d = _distributions[auction];
        d.lifecycle = Lifecycle.Graduated;
        d.splitter = splitter;
        d.receiver = receiver;
        d.poolId = poolId;
        d.lpTokenId = lpTokenId;
        d.lpRegentUsed = lpRegentUsed;
        MockAuction(auction).setCurrencyRaised(raised);
        REGENT.mint(d.treasury, raised - lpRegentUsed);
    }

    function fail(address auction) external {
        _distributions[auction].lifecycle = Lifecycle.Failed;
    }

    function distribution(address auction) external view returns (Distribution memory) {
        return _distributions[auction];
    }
}

/// @dev Stands in for `RegentsAutolaunchFactoryV1`. It applies the checks the real factory applies,
/// in the same order and with the same error shapes: launches are refused while paused, the five
/// metadata strings must be nonempty and within their byte caps, the treasury must be nonzero and
/// outside the system set, and the required raise must be positive and within the strategy's
/// ceiling. It records `msg.sender` as launcher, keeps the same `launches` and `launchIdOfSubject`
/// provenance, deploys a real SUBJECT, auction and escrow, puts the pending SUBJECT in the escrow,
/// and opens the strategy's record for the new auction.
///
/// It also has two hostilities the real factory does not: it can record any of the five provenance
/// fields differently from the ones it returned, and can break the subject index, so every
/// condition of the fleet's provenance check can be exercised on its own against a factory that
/// lies; and it can call anywhere from inside `launch`, which is where a real launch artifact would
/// get its chance to re-enter.
contract MockAutolaunchFactory is IRegentsAutolaunchFactoryV1 {
    error LaunchesArePaused();
    error EmptyMetadataField(uint256 field);
    error MetadataFieldTooLong(uint256 field, uint256 maximum, uint256 found);
    error RefusedTreasury(address treasury);
    error UnreachableRequiredRaise(uint128 requiredRegentRaised);

    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_DESCRIPTION_BYTES = 512;
    uint256 public constant MAX_WEBSITE_BYTES = 256;
    uint256 public constant MAX_IMAGE_BYTES = 256;
    /// @dev The escrow's pending allocation, 85% of the real launch's supply.
    uint256 public constant PENDING_ALLOCATION = 85_000_000_000e18;

    /// @notice Every factory is born paused, exactly as the real one is.
    bool public launchesPaused = true;
    IRegentLBPStrategy public strategy;
    uint256 public nextLaunchId = 1;

    /// @notice The exact parameters the last caller supplied, for the suite to read back.
    LaunchParams public lastParams;
    /// @notice Fields written into the recorded launch instead of the honest ones, where nonzero.
    /// @dev Each field lies on its own, so one condition of the fleet's provenance check can be
    /// broken at a time. The subject index still answers for the SUBJECT that was returned, so a
    /// forced record subject breaks only the recorded-subject condition.
    Launch public forcedRecord;
    /// @notice Whether `launchIdOfSubject` answers with a different launch.
    bool public breakSubjectIndex;

    address private _reentryTarget;
    bytes private _reentryPayload;
    /// @notice Whether the call from inside `launch` ran, and how it came back.
    bool public reentryFired;
    bool public reentryOk;
    bytes public reentryReturn;

    mapping(address treasury => bool refused) public refusedTreasury;
    mapping(address subject => uint256 launchId) private _launchIdOfSubject;
    mapping(uint256 launchId => Launch) private _launches;

    constructor(MockLBPStrategy strategy_) {
        strategy = strategy_;
    }

    function openLaunches() external {
        launchesPaused = false;
    }

    function closeLaunches() external {
        launchesPaused = true;
    }

    function setRefusedTreasury(address treasury, bool refused) external {
        refusedTreasury[treasury] = refused;
    }

    function setForcedRecord(Launch calldata record) external {
        forcedRecord = record;
    }

    function setBreakSubjectIndex(bool broken) external {
        breakSubjectIndex = broken;
    }

    /// @dev Arming again clears what the last call back left behind, so a suite that arms twice is
    /// never reading the first call's answer for the second.
    function armReentry(address target, bytes calldata payload) external {
        _reentryTarget = target;
        _reentryPayload = payload;
        reentryFired = false;
        reentryOk = false;
        reentryReturn = "";
    }

    function launchIdOfSubject(address subject) external view returns (uint256) {
        uint256 launchId = _launchIdOfSubject[subject];
        return breakSubjectIndex ? launchId + 1 : launchId;
    }

    function launches(uint256 launchId) external view returns (Launch memory) {
        return _launches[launchId];
    }

    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow)
    {
        if (launchesPaused) revert LaunchesArePaused();
        _requireBytes(0, bytes(params.name).length, MAX_NAME_BYTES);
        _requireBytes(1, bytes(params.symbol).length, MAX_SYMBOL_BYTES);
        _requireBytes(2, bytes(params.description).length, MAX_DESCRIPTION_BYTES);
        _requireBytes(3, bytes(params.website).length, MAX_WEBSITE_BYTES);
        _requireBytes(4, bytes(params.image).length, MAX_IMAGE_BYTES);
        if (params.treasury == address(0) || refusedTreasury[params.treasury]) revert RefusedTreasury(params.treasury);
        if (params.requiredRegentRaised == 0 || params.requiredRegentRaised > strategy.MAX_REACHABLE_RAISE()) {
            revert UnreachableRequiredRaise(params.requiredRegentRaised);
        }

        lastParams = params;
        launchId = nextLaunchId;
        nextLaunchId = launchId + 1;
        MockLaunchToken token = new MockLaunchToken(params.name, params.symbol);
        MockEscrow vesting = new MockEscrow(token, params.treasury);
        token.mint(address(vesting), PENDING_ALLOCATION);
        subject = address(token);
        auction = address(new MockAuction());
        escrow = address(vesting);

        _launches[launchId] = Launch(
            forcedRecord.launcher == address(0) ? msg.sender : forcedRecord.launcher,
            forcedRecord.subject == address(0) ? subject : forcedRecord.subject,
            forcedRecord.auction == address(0) ? auction : forcedRecord.auction,
            forcedRecord.escrow == address(0) ? escrow : forcedRecord.escrow,
            forcedRecord.treasury == address(0) ? params.treasury : forcedRecord.treasury
        );
        _launchIdOfSubject[subject] = launchId;
        MockLBPStrategy(address(strategy))
            .open(auction, launchId, subject, escrow, params.treasury, params.requiredRegentRaised);

        if (_reentryTarget != address(0) && !reentryFired) {
            reentryFired = true;
            (reentryOk, reentryReturn) = _reentryTarget.call(_reentryPayload);
        }
    }

    function _requireBytes(uint256 field, uint256 length, uint256 maximum) private pure {
        if (length == 0) revert EmptyMetadataField(field);
        if (length > maximum) revert MetadataFieldTooLong(field, maximum, length);
    }
}
