// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {KeyfleetTradingManager} from "../src/KeyfleetTradingManager.sol";
import {KeyfleetTradingFixture} from "./helpers/KeyfleetTradingFixture.sol";
import {MockToken} from "./mocks/MockToken.sol";

/// @dev Buys many Keys of a Trading Fleet in one transaction, each to a wallet of its own, so a
/// fleet of 10,000 Keys is set up in a few transactions.
contract BulkBuyer {
    function buy(KeyfleetTradingManager fleet, uint256 firstWallet, uint256 count) external {
        MockToken usdc = MockToken(address(fleet.USDC()));
        bytes32[] memory none;
        for (uint256 i = 0; i < count; ++i) {
            uint256 price = fleet.price();
            usdc.mint(address(this), price);
            usdc.approve(address(fleet), price);
            fleet.purchase(address(uint160(firstWallet + i)), price, block.timestamp, none);
        }
    }
}

/// @dev The gas of a Trading Fleet's purchase, creator's payback and daily payback with 1, 100 and
/// 10,000 Keys, on the stand-in system. Each figure is the whole transaction's gas, the 21,000 base
/// and the calldata included, so it runs only when Forge runs each call as a transaction of its own
/// (`--isolate`), and skips itself otherwise:
///
///     forge test --match-contract KeyfleetTradingGasTest --isolate -vv
///
/// The stand-in USDC and staking cost less than the real ones on Base, so the Base fork test's
/// figures are the ones to quote for real costs; these show how cost grows with the number of
/// Keys, which is the binary search over Key mint times in `matureKeys`, read twice a payback.
contract KeyfleetTradingGasTest is KeyfleetTradingFixture {
    uint256 private constant BATCH = 1_000;

    function setUp() public {
        _setUpTrading();
    }

    function test_gasAtOneHundredAndTenThousandKeys() public {
        usdc.approve(address(this), 0);
        if (vm.lastCallGas().gasTotalUsed < 21_000) {
            vm.skip(true);
            return;
        }
        BulkBuyer bulk = new BulkBuyer();
        uint256[3] memory sizes = [uint256(1), 100, 10_000];
        uint256[3] memory paybackGas;
        uint256[3] memory dailyGas;
        for (uint256 s = 0; s < sizes.length; ++s) {
            uint256 size = sizes[s];
            usdc.mint(creator, MIN_PRICE);
            vm.prank(creator);
            usdc.approve(address(trading), MIN_PRICE);
            vm.prank(creator);
            (uint256 fleetId,) = trading.create(_tradingTerms(MIN_PRICE, 0, DAILY_BPS, 0));
            _log("create, with Key 1", size, vm.lastCallGas().gasTotalUsed);
            fleet = KeyfleetTradingManager(keys.managerOf(fleetId));
            treasury = fleet.TREASURY();

            vm.pauseGasMetering();
            for (uint256 bought = 1; bought < size; bought += BATCH) {
                uint256 count = size - bought < BATCH ? size - bought : BATCH;
                bulk.buy(fleet, 0x200000 + s * 0x100000 + bought, count);
            }
            vm.resumeGasMetering();
            assertEq(fleet.totalMinted(), size);
            _tcount();
            _return(1_000_000e6);

            usdc.mint(buyer, MIN_PRICE);
            vm.prank(buyer);
            usdc.approve(address(fleet), MIN_PRICE);
            vm.prank(buyer);
            fleet.purchase(address(0xFEED), MIN_PRICE, block.timestamp, new bytes32[](0));
            _log("purchase", size, vm.lastCallGas().gasTotalUsed);

            vm.prank(creator);
            treasury.payback(100_000e6);
            paybackGas[s] = vm.lastCallGas().gasTotalUsed;
            _log("payback by the creator, the fleet's first", size, paybackGas[s]);

            treasury.runDailyPayback();
            dailyGas[s] = vm.lastCallGas().gasTotalUsed;
            _log("runDailyPayback, a later payback", size, dailyGas[s]);
            assertEq(fleet.matureKeys(), size);
        }
        // Cost grows only with the binary search over mint times, read twice a payback.
        assertLt(paybackGas[2], paybackGas[0] + 100_000);
        assertLt(dailyGas[2], dailyGas[0] + 100_000);
    }

    function _log(string memory call, uint256 size, uint256 gas) private pure {
        console2.log(string.concat(call, ", Keys counted or sold:"), size, gas);
    }
}
