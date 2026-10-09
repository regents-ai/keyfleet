// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev A stand-in for USDC: six decimals, minted to whoever a test names, and able to freeze an
/// account the way USDC's issuer can.
contract MockToken is ERC20 {
    mapping(address => bool) public frozen;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function freeze(address account) external {
        frozen[account] = true;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        require(!frozen[from] && !frozen[to], "frozen");
        super._update(from, to, value);
    }
}
