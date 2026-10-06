// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A stand-in for REGENT: eighteen decimals, minted to whoever a test names.
contract MockRegent is ERC20 {
    constructor() ERC20("Regent", "REGENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
