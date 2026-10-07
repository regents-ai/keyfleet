// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IRegentLBPStrategyV2} from "../../src/interfaces/IRegentLBPStrategyV2.sol";
import {IRegentsAutolaunchFactoryV2} from "../../src/interfaces/IRegentsAutolaunchFactoryV2.sol";

/// @dev A stand-in for a launched token: eighteen decimals, minted to whoever a test names.
contract MockLaunchToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stands in for a launch's auction: a fresh address of its own for each launch.
contract MockLaunchPart {}

/// @dev A stand-in for a launch's vesting escrow. It holds the tokens that vest to the launch's
/// treasury, and `release` sends them all there once the launch sold, as Autolaunch v2's
/// `ConditionalVestingEscrowV2.release()` sends what has vested so far.
contract MockLaunchEscrow {
    MockAutolaunchStrategy private immutable STRATEGY;
    address private immutable AUCTION;
    MockLaunchToken private immutable SUBJECT;
    address private immutable TREASURY;

    event SubjectReleased(address indexed treasury, uint256 amount);

    constructor(MockAutolaunchStrategy strategy, address auction, MockLaunchToken subject, address treasury) {
        (STRATEGY, AUCTION, SUBJECT, TREASURY) = (strategy, auction, subject, treasury);
    }

    function release() external {
        require(STRATEGY.distribution(AUCTION).lifecycle == IRegentLBPStrategyV2.Lifecycle.Graduated, "not graduated");
        uint256 held = SUBJECT.balanceOf(address(this));
        emit SubjectReleased(TREASURY, held);
        SUBJECT.transfer(TREASURY, held);
    }
}

/// @dev A stand-in for Autolaunch v2's liquidity locker: `collect` takes a registered position's
/// fees, as `RevstakeLPLocker.collect(tokenId)` does, and refuses any other position. The stand-in
/// has no fees to take.
contract MockLaunchLocker {
    address private immutable STRATEGY;
    mapping(uint256 tokenId => bool registered) public registered;

    event Collected(uint256 indexed tokenId);

    constructor() {
        STRATEGY = msg.sender;
    }

    function register(uint256 tokenId) external {
        require(msg.sender == STRATEGY, "strategy only");
        registered[tokenId] = true;
    }

    function collect(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        require(registered[tokenId], "unregistered position");
        emit Collected(tokenId);
        return (0, 0);
    }
}

/// @dev A stand-in for Autolaunch v2's strategy. A launch the factory opens is `Active` until
/// anyone settles it with `migrate` once its migration block is reached, which here always sells
/// it; or until a test settles it with the factory's `graduate` or `fail`. A launch that sold has
/// its position registered with the locker under its launch id.
contract MockAutolaunchStrategy {
    /// @dev How many blocks after a launch anyone may settle it.
    uint64 public constant MIGRATION_DELAY = 10;

    address private immutable FACTORY;
    MockLaunchLocker public immutable lpLocker;
    mapping(address auction => IRegentLBPStrategyV2.Distribution) private _distributions;

    constructor() {
        FACTORY = msg.sender;
        lpLocker = new MockLaunchLocker();
    }

    function open(address auction, uint256 launchId, address subject, address escrow, address treasury)
        external
        returns (uint64 startBlock, uint64 endBlock)
    {
        require(msg.sender == FACTORY, "factory only");
        IRegentLBPStrategyV2.Distribution storage d = _distributions[auction];
        (startBlock, endBlock) = (uint64(block.number), uint64(block.number) + MIGRATION_DELAY);
        d.lifecycle = IRegentLBPStrategyV2.Lifecycle.Active;
        (d.startBlock, d.endBlock, d.claimBlock, d.migrationBlock) = (startBlock, endBlock, endBlock, endBlock);
        (d.launchId, d.subject, d.escrow, d.treasury) = (launchId, subject, escrow, treasury);
    }

    function migrate(address auction) external {
        IRegentLBPStrategyV2.Distribution storage d = _distributions[auction];
        require(d.lifecycle == IRegentLBPStrategyV2.Lifecycle.Active, "launch not active");
        require(block.number >= d.migrationBlock, "migration not yet allowed");
        _settle(auction, IRegentLBPStrategyV2.Lifecycle.Graduated);
    }

    function settle(address auction, IRegentLBPStrategyV2.Lifecycle lifecycle) external {
        require(msg.sender == FACTORY, "factory only");
        _settle(auction, lifecycle);
    }

    function distribution(address auction) external view returns (IRegentLBPStrategyV2.Distribution memory) {
        return _distributions[auction];
    }

    function _settle(address auction, IRegentLBPStrategyV2.Lifecycle lifecycle) private {
        IRegentLBPStrategyV2.Distribution storage d = _distributions[auction];
        d.lifecycle = lifecycle;
        if (lifecycle == IRegentLBPStrategyV2.Lifecycle.Graduated) {
            d.lpTokenId = d.launchId;
            lpLocker.register(d.launchId);
        }
    }
}

/// @dev A stand-in for Autolaunch v2's factory. `launch` records the caller and the named treasury,
/// creates a fresh token with 700 of it vesting in the launch's escrow, emits `LaunchCreated` as
/// the real factory does, and leaves the launch active; it is settled by anyone with the strategy's
/// `migrate`, or by a test with `graduate` or `fail`.
contract MockAutolaunchFactory is IRegentsAutolaunchFactoryV2 {
    /// @dev What vests to a launch's treasury from its escrow.
    uint256 public constant VESTING = 700 ether;

    MockAutolaunchStrategy private immutable STRATEGY;
    uint256 public nextLaunchId = 1;
    mapping(uint256 launchId => Launch) private _launches;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed launcher,
        address indexed subject,
        address auction,
        address escrow,
        address treasury,
        uint64 startBlock,
        uint64 endBlock
    );

    constructor() {
        STRATEGY = new MockAutolaunchStrategy();
    }

    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow)
    {
        launchId = nextLaunchId++;
        MockLaunchToken token = new MockLaunchToken(params.name, params.symbol);
        subject = address(token);
        auction = address(new MockLaunchPart());
        escrow = address(new MockLaunchEscrow(STRATEGY, auction, token, params.treasury));
        token.mint(escrow, VESTING);
        _launches[launchId] = Launch({
            launcher: msg.sender, subject: subject, auction: auction, escrow: escrow, treasury: params.treasury
        });
        (uint64 startBlock, uint64 endBlock) = STRATEGY.open(auction, launchId, subject, escrow, params.treasury);
        emit LaunchCreated(launchId, msg.sender, subject, auction, escrow, params.treasury, startBlock, endBlock);
    }

    function graduate(uint256 launchId) external {
        STRATEGY.settle(_launches[launchId].auction, IRegentLBPStrategyV2.Lifecycle.Graduated);
    }

    function fail(uint256 launchId) external {
        STRATEGY.settle(_launches[launchId].auction, IRegentLBPStrategyV2.Lifecycle.Failed);
    }

    function launches(uint256 launchId) external view returns (Launch memory) {
        return _launches[launchId];
    }

    function strategy() external view returns (IRegentLBPStrategyV2) {
        return IRegentLBPStrategyV2(address(STRATEGY));
    }
}
