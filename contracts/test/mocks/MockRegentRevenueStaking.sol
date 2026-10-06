// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRegentRevenueStaking} from "../../src/interfaces/IRegentRevenueStaking.sol";

/// @dev A stand-in for REGENT revenue staking: `depositUSDC` pulls with `transferFrom`, refuses a
/// zero amount and refuses while paused, as the deployed contract does. Two settings make it
/// misbehave for the tests: `pullShort` takes that much less than asked, and `reportShort` reports
/// that much less than asked.
contract MockRegentRevenueStaking is IRegentRevenueStaking {
    IERC20 public immutable usdc;
    bool public paused;
    uint256 public pullShort;
    uint256 public reportShort;
    uint256 public totalUsdcReceived;
    bytes32 public lastSourceTag;
    bytes32 public lastSourceRef;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setShort(uint256 pullShort_, uint256 reportShort_) external {
        pullShort = pullShort_;
        reportShort = reportShort_;
    }

    function depositUSDC(uint256 amount, bytes32 sourceTag, bytes32 sourceRef) external returns (uint256 received) {
        require(!paused, "PAUSED");
        require(amount != 0, "AMOUNT_ZERO");
        uint256 pulled = amount - pullShort;
        require(usdc.transferFrom(msg.sender, address(this), pulled), "TRANSFER_FROM_FAILED");
        totalUsdcReceived += pulled;
        lastSourceTag = sourceTag;
        lastSourceRef = sourceRef;
        return amount - reportShort;
    }
}
