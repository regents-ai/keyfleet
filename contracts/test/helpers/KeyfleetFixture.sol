// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Keyfleet} from "../../src/Keyfleet.sol";
import {KeyfleetPresets} from "../../src/KeyfleetPresets.sol";
import {KeyfleetTreasury} from "../../src/KeyfleetTreasury.sol";
import {KeyfleetVotes} from "../../src/KeyfleetVotes.sol";
import {KeyfleetStack} from "../../script/KeyfleetStack.sol";
import {IVRFCoordinatorV2Plus} from "../../src/vendor/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {MockToken} from "../KeyfleetIncome.t.sol";
import {MockRegentRevenueStaking} from "../mocks/MockRegentRevenueStaking.sol";
import {MockVRFCoordinatorV2Plus} from "../mocks/MockVRFCoordinatorV2Plus.sol";

/// @dev A whole fleet on stand-in USDC, VRF and staking, with the steps the money tests repeat:
/// buying keys, and passing and carrying out a proposal's calls.
abstract contract KeyfleetFixture is Test {
    MockToken internal usdc;
    MockVRFCoordinatorV2Plus internal vrf;
    uint256 internal vrfSubscription;
    MockRegentRevenueStaking internal staking;
    address internal buyer = address(0xB0B0B0);

    function _setUpFixture() internal {
        usdc = new MockToken("USD Coin", "USDC");
        vrf = new MockVRFCoordinatorV2Plus();
        vrfSubscription = vrf.createSubscription();
        staking = new MockRegentRevenueStaking(usdc);
    }

    function _deploy(KeyfleetPresets.Preset preset) internal returns (Keyfleet fleet) {
        fleet = KeyfleetStack.deploy(
            preset,
            usdc,
            staking,
            Keyfleet.Metadata("Keyfleet Alpha", "KFA", "https://keys.regents.sh/alpha/"),
            Keyfleet.Randomness({
                coordinator: IVRFCoordinatorV2Plus(address(vrf)),
                subscriptionId: vrfSubscription,
                keyHash: keccak256("key hash")
            }),
            keccak256("trait table")
        );
        vrf.addConsumer(vrfSubscription, address(fleet));
    }

    function _buy(Keyfleet fleet, address receiver) internal returns (uint256 tokenId) {
        uint256 price = fleet.nextPrice();
        usdc.mint(buyer, price);
        vm.startPrank(buyer);
        usdc.approve(address(fleet), price);
        tokenId = fleet.purchase(receiver, price, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Key `i` goes to `_wallet(i)`, one key per wallet.
    function _buyMany(Keyfleet fleet, uint256 count) internal {
        for (uint256 i = 0; i < count; ++i) {
            _buy(fleet, _wallet(fleet.totalMinted() + 1));
        }
    }

    function _wallet(uint256 index) internal pure returns (address) {
        return address(uint160(0x100000 + index));
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _range(uint256 first, uint256 count) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            ids[i] = first + i;
        }
    }

    function _one(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (KeyfleetTreasury.Call[] memory calls)
    {
        calls = new KeyfleetTreasury.Call[](1);
        calls[0] = KeyfleetTreasury.Call(target, value, data);
    }

    /// @dev Proposes `calls` with key 1, as its owner, and votes it Yes; nobody else is present, so
    /// it is approved once it closes a second later.
    function _approve(Keyfleet fleet, KeyfleetTreasury.Call[] memory calls) internal returns (uint256 proposalId) {
        KeyfleetVotes votes = fleet.VOTES();
        address author = fleet.ownerOf(1);
        vm.startPrank(author);
        proposalId = votes.propose(1, keccak256("narrative"), uint64(block.timestamp + 1), calls);
        votes.castBallot(proposalId, _ids(1), KeyfleetVotes.Choice.Yes);
        vm.stopPrank();
    }

    /// @dev Passes `calls` and carries them out.
    function _execute(Keyfleet fleet, KeyfleetTreasury.Call[] memory calls) internal {
        uint256 proposalId = _approve(fleet, calls);
        vm.warp(fleet.VOTES().proposal(proposalId).closesAt);
        fleet.VOTES().execute(proposalId, calls);
    }
}
