// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {KeyfleetClubClaims} from "../../src/KeyfleetClubClaims.sol";
import {KeyfleetManager} from "../../src/KeyfleetManager.sol";
import {KeyfleetSafeSteps} from "../../script/KeyfleetSafeSteps.s.sol";
import {KeyfleetForkFixture} from "./KeyfleetBaseFork.t.sol";

/// @dev Every Regents Club gift the Safe steps build, from the Safe, on a fork of Base at the latest
/// block, against the real Pass and its real holders: key N goes to the holder of Pass N or is held
/// for claiming, and every receiving wallet gets one key per Pass it holds. Then 100 Passes leave the
/// contract that refuses NFTs for a wallet, which claims their 100 keys in one transaction that fits
/// Base's limit for one transaction. Runs only when
/// `BASE_RPC_URL` is set and skips itself otherwise:
///
///     forge test --match-contract ClubGiftsRehearsal -vv
contract ClubGiftsRehearsal is KeyfleetForkFixture {
    mapping(address => bool) private seen;
    address[] private holders;

    function setUp() public {
        _setUpFork(0);
    }

    function test_everyClubGiftOnBase() public {
        _found(5);
        _advancePhase();
        console2.log("fork block", block.number);

        KeyfleetSafeSteps.SafeCall[] memory calls = safeSteps.clubGiftCalls(_manifest(), factory, new uint256[](0));
        console2.log("safe transactions", calls.length);
        uint256 most;
        for (uint256 i = 0; i < calls.length; ++i) {
            uint256 before = gasleft();
            _asSafe(calls[i]);
            uint256 used = before - gasleft();
            if (used > most) most = used;
        }
        console2.log("most gas in one transaction", most);

        KeyfleetManager club = _fleet(5);
        IERC721 pass = factory.CLUB_PASS();
        address claims = address(factory.CLUB_CLAIMS());
        assertEq(club.totalMinted(), 1998, "every key given");

        uint256 held;
        uint256 direct;
        for (uint256 n = 1; n <= 1998; ++n) {
            address keyOwner = keys.ownerOf(_key(club, n));
            if (keyOwner == claims) {
                held++;
                continue;
            }
            assertEq(keyOwner, pass.ownerOf(n), "key N with the holder of Pass N");
            direct++;
            if (!seen[keyOwner]) {
                seen[keyOwner] = true;
                holders.push(keyOwner);
            }
        }

        uint256 multi;
        uint256 biggest;
        for (uint256 i = 0; i < holders.length; ++i) {
            uint256 count = pass.balanceOf(holders[i]);
            assertEq(keys.balanceOf(holders[i]), count, "one key per Pass held");
            if (count > 1) multi++;
            if (count > biggest) biggest = count;
        }
        console2.log("keys sent straight to holders", direct);
        console2.log("keys held for claiming", held);
        console2.log("wallets that received keys", holders.length);
        console2.log("of them holding more than one Pass", multi);
        console2.log("most Passes held by one receiving wallet", biggest);
        console2.log(
            "Passes inside refusing contract 0x71065b", pass.balanceOf(0x71065b775a590c43933F10c0055dc7d74AfAbb0e)
        );

        _claimHundred(KeyfleetClubClaims(payable(claims)), pass, held);
    }

    /// @dev 100 of the refusing contract's Passes move to a wallet, which `claimable` then names and
    /// one claim takes, under Base's 16,777,216 gas limit for one transaction.
    function _claimHundred(KeyfleetClubClaims claims, IERC721 pass, uint256 held) private {
        address vault = 0x71065b775a590c43933F10c0055dc7d74AfAbb0e;
        uint256[] memory every = new uint256[](1998);
        for (uint256 n = 1; n <= 1998; ++n) {
            every[n - 1] = n;
        }
        uint256 before = gasleft();
        uint256[] memory kept = claims.claimable(vault, every);
        console2.log("claimable over 1,998 Passes, gas", before - gasleft());
        assertEq(kept.length, pass.balanceOf(vault), "every Pass in the vault has its key kept");
        assertLe(kept.length, held);

        address claimer = makeAddr("claimer");
        uint256[] memory hundred = new uint256[](100);
        vm.startPrank(vault);
        for (uint256 i = 0; i < 100; ++i) {
            hundred[i] = kept[i];
            pass.transferFrom(vault, claimer, kept[i]);
        }
        vm.stopPrank();
        assertEq(claims.claimable(claimer, every).length, 100, "the wallet can claim all 100");

        vm.prank(claimer);
        before = gasleft();
        claims.claim(hundred);
        uint256 used = before - gasleft();
        console2.log("claim of 100 keys, gas", used);
        assertLt(used, 16_777_216, "fits one Base transaction");
        assertEq(keys.balanceOf(claimer), 100, "one key per Pass");
        assertEq(claims.claimable(claimer, every).length, 0);
    }
}
