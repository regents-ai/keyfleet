// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {IKeyfleetDeployer} from "./KeyfleetWiring.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";

/// @notice What one Trading Fleet's contracts are built with: the fleet, the address of each of its
/// three contracts, which the trading factory works out before deploying any, and the creator's
/// terms that are fixed at creation or start the sale.
/// @param fleetId The fleet's number in the collection.
/// @param manager Where the fleet's `KeyfleetTradingManager` is deployed.
/// @param treasury Where the fleet's `KeyfleetTradingTreasury` is deployed.
/// @param rewards Where the fleet's `KeyfleetRewards` ledger is deployed.
/// @param firstPrice The USDC price of Key 1, in atomic USDC; the creator may change the price later.
/// @param stepBps How much each sale raises the price, in hundredths of a percent; the creator may
/// change it later.
/// @param dailyPaybackBps The guaranteed daily payback, in hundredths of a percent of the treasury's
/// USDC. It never changes.
/// @param keyCap The most Keys the fleet sells, Key 1 included; zero for the collection's own limit.
/// It never changes.
struct TradingWiring {
    uint256 fleetId;
    address manager;
    address treasury;
    address rewards;
    uint256 firstPrice;
    uint256 stepBps;
    uint256 dailyPaybackBps;
    uint256 keyCap;
}

/// @notice What a Trading Fleet contract reads from the trading factory while the factory deploys it.
/// @dev `tradingWiring` is held in the factory's transient storage only while it deploys one fleet's
/// contracts, and is all zero at every other moment.
interface IKeyfleetTradingFactory {
    function tradingWiring() external view returns (TradingWiring memory);
    function KEYS() external view returns (KeyfleetKeys);
    function USDC() external view returns (IERC20);
    function REGENT_STAKING() external view returns (IRegentRevenueStaking);
}

/// @notice Reads the wiring of the Trading Fleet contract being constructed.
library KeyfleetTradingWiring {
    /// @notice The trading factory behind the deployer that is constructing the caller, and the
    /// wiring it holds now.
    /// @dev Called from a constructor, where `msg.sender` is the deployer.
    function read() internal view returns (IKeyfleetTradingFactory factory, TradingWiring memory wiring) {
        factory = IKeyfleetTradingFactory(address(IKeyfleetDeployer(msg.sender).FACTORY()));
        wiring = factory.tradingWiring();
    }
}
