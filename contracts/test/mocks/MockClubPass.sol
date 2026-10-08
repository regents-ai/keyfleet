// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev A stand-in for the Regents Club Pass: Pass N minted to whoever a test names, or burned.
contract MockClubPass is ERC721 {
    constructor() ERC721("Regents Club Pass", "PASS") {}

    function mint(address to, uint256 passId) external {
        _mint(to, passId);
    }

    function burn(uint256 passId) external {
        _burn(passId);
    }
}
