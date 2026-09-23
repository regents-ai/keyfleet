// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @dev The draw rule in the README, written out once in Solidity so its `abi.encode` and
/// `keccak256` are the chain's own. The weights come from the site's own fixture table, the
/// file its tests draw from, and the site pins these same results in
/// platform/test/keyfleet/traits_test.exs. If either side changes the rule or the table, its
/// own copy of these results fails until both agree again.
contract KeyfleetTraitDrawTest is Test {
    bytes32 private constant TABLE_HASH = 0x1249d615f793a311bcb27def92766224fb544df85aa74359a785a6349df18610;
    string private constant TABLE =
        "../platform/test/support/fixtures/trait_tables/0x1249d615f793a311bcb27def92766224fb544df85aa74359a785a6349df18610.json";

    function test_goldenDraws() public view {
        string memory table = vm.readFile(TABLE);
        assertEq(keccak256(bytes(table)), TABLE_HASH);

        _assertDraws(table, keccak256("golden-1"), [uint256(1), 1, 1]);
        _assertDraws(table, keccak256("golden-4"), [uint256(0), 0, 1]);
        _assertDraws(table, keccak256("golden-5"), [uint256(2), 2, 1]);
        _assertDraws(table, keccak256("golden-85"), [uint256(3), 2, 1]);
        _assertDraws(table, keccak256("golden-105"), [uint256(1), 2, 2]);
    }

    /// @dev One value of a trait as the table writes it; the JSON cheatcodes fill fields in
    /// alphabetical order of their keys.
    struct Value {
        string name;
        uint256 weight;
    }

    /// @dev `picks[i]` is the value drawn for the table's trait `i`, by its place in the table.
    function _assertDraws(string memory table, bytes32 seed, uint256[3] memory picks) private pure {
        for (uint256 i = 0; i < picks.length; ++i) {
            Value[] memory values =
                abi.decode(vm.parseJson(table, string.concat(".traits[", vm.toString(i), "].values")), (Value[]));
            uint256[] memory weights = new uint256[](values.length);
            for (uint256 j = 0; j < values.length; ++j) {
                weights[j] = values[j].weight;
            }
            assertEq(_draw(seed, i, weights), picks[i]);
        }
    }

    /// @dev Word `i` is `keccak256(abi.encode(seed, i))`; `u` its top 32 bits; the pick is the first
    /// value whose running weight exceeds `floor(u * total / 2^32)`.
    function _draw(bytes32 seed, uint256 i, uint256[] memory weights) private pure returns (uint256) {
        uint256 u = uint256(keccak256(abi.encode(seed, i))) >> 224;
        uint256 total;
        for (uint256 j = 0; j < weights.length; ++j) {
            total += weights[j];
        }
        uint256 r = u * total / 2 ** 32;
        uint256 running;
        for (uint256 j = 0; j < weights.length; ++j) {
            running += weights[j];
            if (running > r) return j;
        }
        revert("no value drawn");
    }
}
