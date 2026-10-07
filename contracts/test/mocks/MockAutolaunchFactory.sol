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

/// @dev Stands in for a launch's auction or escrow: a fresh address of its own for each launch.
contract MockLaunchPart {}

/// @dev A stand-in for Autolaunch v2's strategy: each auction's outcome is whatever the factory
/// sets it to.
contract MockAutolaunchStrategy {
    address private immutable FACTORY;
    mapping(address auction => IRegentLBPStrategyV2.Lifecycle lifecycle) private _lifecycle;

    constructor() {
        FACTORY = msg.sender;
    }

    function setLifecycle(address auction, IRegentLBPStrategyV2.Lifecycle lifecycle) external {
        require(msg.sender == FACTORY, "factory only");
        _lifecycle[auction] = lifecycle;
    }

    function distribution(address auction) external view returns (IRegentLBPStrategyV2.Distribution memory d) {
        d.lifecycle = _lifecycle[auction];
    }
}

/// @dev A stand-in for Autolaunch v2's factory. `launch` records the caller and the named treasury
/// and creates a fresh token, as the real factory does, and leaves the launch active; a test then
/// settles it with `graduate` or `fail`, which the real strategy does when the auction ends.
contract MockAutolaunchFactory is IRegentsAutolaunchFactoryV2 {
    MockAutolaunchStrategy private immutable STRATEGY;
    uint256 public nextLaunchId = 1;
    mapping(uint256 launchId => Launch) private _launches;

    constructor() {
        STRATEGY = new MockAutolaunchStrategy();
    }

    function launch(LaunchParams calldata params)
        external
        returns (uint256 launchId, address subject, address auction, address escrow)
    {
        launchId = nextLaunchId++;
        subject = address(new MockLaunchToken(params.name, params.symbol));
        auction = address(new MockLaunchPart());
        escrow = address(new MockLaunchPart());
        _launches[launchId] = Launch({
            launcher: msg.sender, subject: subject, auction: auction, escrow: escrow, treasury: params.treasury
        });
        STRATEGY.setLifecycle(auction, IRegentLBPStrategyV2.Lifecycle.Active);
    }

    function graduate(uint256 launchId) external {
        STRATEGY.setLifecycle(_launches[launchId].auction, IRegentLBPStrategyV2.Lifecycle.Graduated);
    }

    function fail(uint256 launchId) external {
        STRATEGY.setLifecycle(_launches[launchId].auction, IRegentLBPStrategyV2.Lifecycle.Failed);
    }

    function launches(uint256 launchId) external view returns (Launch memory) {
        return _launches[launchId];
    }

    function strategy() external view returns (IRegentLBPStrategyV2) {
        return IRegentLBPStrategyV2(address(STRATEGY));
    }
}
