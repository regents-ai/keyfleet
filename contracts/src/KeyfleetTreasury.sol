// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";

/// @notice The treasury of one fleet: the fleet's one payment address, the only place its free
/// capital is held, and the only account of the fleet that approves a token.
/// @dev One instance is permanently bound to one fleet. It is deployed straight after the fleet,
/// at the address the fleet was given for it, and refuses to deploy for a fleet that names another
/// treasury. Anyone paying the fleet pays this address, in USDC or any other token. The capital
/// part of every purchase, a completed Cascade level's released surplus and anything sent to the
/// fleet contract itself outside a purchase are sent here too.
///
/// The fleet's owed protocol share passes through here inside one call and never stays: the fleet
/// sends it and immediately asks for it to be deposited into REGENT revenue staking. There is no
/// administrator, no upgrade path and no pause.
contract KeyfleetTreasury is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The source tag every protocol share deposit carries:
    /// `keccak256("keyfleet.protocol_share")`. The source reference is the fleet's address.
    bytes32 public constant PROTOCOL_SHARE_TAG = keccak256("keyfleet.protocol_share");

    /// @notice The fleet this treasury holds the capital of.
    Keyfleet public immutable FLEET;
    /// @notice The fleet's USDC.
    IERC20 public immutable USDC;
    /// @notice Where the protocol share is deposited. On Base the deployment scripts require REGENT
    /// revenue staking, `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`.
    IRegentRevenueStaking public immutable REGENT_STAKING;

    /// @notice The fleet does not name this contract as its treasury.
    error WrongFleet(address fleet);
    /// @notice The staking address is zero.
    error ZeroAddress();
    /// @notice Only the fleet may ask for the protocol share to be deposited.
    error OnlyFleet();
    /// @notice Staking did not take exactly the amount approved for it.
    error StakingDepositFailed(uint256 amount, uint256 received);

    /// @notice Binds this treasury to its fleet and to the staking contract the protocol share goes to.
    /// @param fleet The fleet, which must name this contract's address as its treasury.
    /// @param staking REGENT revenue staking. Not zero.
    constructor(Keyfleet fleet, IRegentRevenueStaking staking) {
        if (address(fleet.TREASURY()) != address(this)) revert WrongFleet(address(fleet));
        if (address(staking) == address(0)) revert ZeroAddress();
        FLEET = fleet;
        USDC = fleet.USDC();
        REGENT_STAKING = staking;
    }

    /// @notice Deposits `amount` USDC, which the fleet has just sent here, into REGENT revenue
    /// staking as the fleet's protocol share.
    /// @dev Only the fleet calls this, in the same call that sends the amount. The approval is
    /// exact and is used up in the deposit; staking must report receiving exactly `amount` and
    /// leave no allowance, or the whole call reverts and the share stays owed in the fleet. A
    /// paused staking contract reverts the same way.
    function depositProtocolShare(uint256 amount) external nonReentrant {
        if (msg.sender != address(FLEET)) revert OnlyFleet();
        USDC.forceApprove(address(REGENT_STAKING), amount);
        uint256 received =
            REGENT_STAKING.depositUSDC(amount, PROTOCOL_SHARE_TAG, bytes32(uint256(uint160(address(FLEET)))));
        if (received != amount || USDC.allowance(address(this), address(REGENT_STAKING)) != 0) {
            revert StakingDepositFailed(amount, received);
        }
    }
}
