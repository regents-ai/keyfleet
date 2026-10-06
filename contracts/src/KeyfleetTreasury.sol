// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Keyfleet} from "./Keyfleet.sol";
import {KeyfleetVotes} from "./KeyfleetVotes.sol";
import {IRegentRevenueStaking} from "./interfaces/IRegentRevenueStaking.sol";

/// @notice The treasury of one fleet: the fleet's one payment address, the only place its free
/// capital is held, and the only account of the fleet that approves a token.
/// @dev One instance is permanently bound to one fleet. It is deployed straight after the fleet,
/// at the address the fleet was given for it, and refuses to deploy for a fleet that names another
/// treasury. Anyone paying the fleet pays this address, in USDC or any other token. The capital
/// part of every purchase, a completed Cascade level's released surplus and anything sent to the
/// fleet contract itself outside a purchase are sent here too.
///
/// The treasury holds native ETH as well as tokens. It spends only by making the exact calls of a
/// proposal the keys approved, which the fleet's `KeyfleetVotes` hands it when the proposal is
/// carried out. Some of its own functions can only be reached that way, because they accept only
/// the treasury itself as caller: `pay` sends a payment, and `advance` sends one and records it as
/// an advance to an operator, which anyone may return with `returnAdvance` up to what is still
/// outstanding. The fleet's owed protocol share passes through here inside one call and never
/// stays: the fleet sends it and immediately asks for it to be deposited into REGENT revenue
/// staking. Carrying out calls, the deposit and returning an advance run under one reentrancy
/// lock. There is no administrator, no upgrade path and no pause.
contract KeyfleetTreasury is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @notice One call an approved proposal makes from the treasury.
    /// @param target The account called.
    /// @param value Wei sent with the call, from the treasury's balance.
    /// @param data The exact calldata.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice One advance to an operator, recorded when an approved proposal makes it.
    /// @param operator Who received it.
    /// @param asset What was sent: a token, or `NATIVE` for ETH.
    /// @param outstanding How much of it has not been returned yet.
    /// @param purposeHash The hash of what it is for, kept off chain.
    struct Advance {
        address operator;
        address asset;
        uint256 outstanding;
        bytes32 purposeHash;
    }

    /// @notice How the treasury names native ETH wherever it names an asset.
    address public constant NATIVE = address(0);

    /// @notice The source tag every protocol share deposit carries:
    /// `keccak256("keyfleet.protocol_share")`. The source reference is the fleet's address.
    bytes32 public constant PROTOCOL_SHARE_TAG = keccak256("keyfleet.protocol_share");

    /// @dev The transient slot of the split-in-progress flag:
    /// `keccak256(abi.encode(uint256(keccak256("keyfleet.treasury.split_in_progress")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant SPLIT_IN_PROGRESS = 0xd9aca5cd3a42e97768814a58347bfab1c7bcba20bf1fb9c47c8b9d767310a900;

    /// @notice The fleet this treasury holds the capital of.
    Keyfleet public immutable FLEET;
    /// @notice The fleet's voting controller, the only account that hands the treasury calls to make.
    KeyfleetVotes public immutable VOTES;
    /// @notice The fleet's USDC.
    IERC20 public immutable USDC;
    /// @notice Where the protocol share is deposited. On Base the deployment scripts require REGENT
    /// revenue staking, `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5`.
    IRegentRevenueStaking public immutable REGENT_STAKING;

    /// @notice Every advance an approved proposal has made, by the id the proposal gave it.
    mapping(uint256 advanceId => Advance advance) public advances;

    /// @notice The fleet does not name this contract as its treasury.
    error WrongFleet(address fleet);
    /// @notice The staking address is zero.
    error ZeroAddress();
    /// @notice Only the fleet may ask for the protocol share to be deposited.
    error OnlyFleet();
    /// @notice Only the fleet's voting controller hands the treasury calls to make.
    error OnlyVotes();
    /// @notice Staking did not take exactly the amount approved for it.
    error StakingDepositFailed(uint256 amount, uint256 received);
    /// @notice Only the treasury itself may call this, so only an approved proposal's call reaches it.
    error OnlySelf();
    /// @notice An advance already has this id.
    error AdvanceIdTaken(uint256 advanceId);
    /// @notice More was returned than the advance has outstanding.
    error ReturnAboveOutstanding(uint256 advanceId, uint256 amount, uint256 outstanding);
    /// @notice The ETH sent with a return does not match the amount: all of it for an ETH advance,
    /// none for a token advance.
    error WrongValue(uint256 value);

    /// @notice An approved proposal paid an asset out of the treasury.
    event Paid(address indexed asset, address indexed to, uint256 amount);
    /// @notice An approved proposal advanced an asset to an operator.
    event Advanced(
        uint256 indexed advanceId, address indexed operator, address indexed asset, uint256 amount, bytes32 purposeHash
    );
    /// @notice Part or all of an advance came back.
    /// @param from Whoever returned it; anyone may.
    /// @param outstanding What is still outstanding afterwards.
    event AdvanceReturned(uint256 indexed advanceId, address indexed from, uint256 amount, uint256 outstanding);

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    /// @notice Binds this treasury to its fleet and to the staking contract the protocol share goes to.
    /// @param fleet The fleet, which must name this contract's address as its treasury.
    /// @param staking REGENT revenue staking. Not zero.
    constructor(Keyfleet fleet, IRegentRevenueStaking staking) {
        if (address(fleet.TREASURY()) != address(this)) revert WrongFleet(address(fleet));
        if (address(staking) == address(0)) revert ZeroAddress();
        FLEET = fleet;
        VOTES = fleet.VOTES();
        USDC = fleet.USDC();
        REGENT_STAKING = staking;
    }

    /// @notice Whether the treasury is inside its split routine right now. The fleet's ledger
    /// accepts split funding only while this is true, so no approved proposal's call can fund it.
    function splitInProgress() external view returns (bool) {
        return SPLIT_IN_PROGRESS.asBoolean().tload();
    }

    /// @notice Takes native ETH from anyone. It is free capital like any token the treasury holds.
    receive() external payable {}

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

    /// @notice Makes an approved proposal's calls, in order.
    /// @dev Only the voting controller calls this, when a proposal is carried out, after checking
    /// the calls against the proposal. Each is a plain call with its value; the first that reverts
    /// reverts the whole batch with its reason, so a batch never half succeeds.
    /// @param calls The proposal's exact calls.
    function executeBatch(Call[] calldata calls) external nonReentrant {
        if (msg.sender != address(VOTES)) revert OnlyVotes();
        for (uint256 i = 0; i < calls.length; ++i) {
            Call calldata call = calls[i];
            (bool success, bytes memory returndata) = call.target.call{value: call.value}(call.data);
            Address.verifyCallResult(success, returndata);
        }
    }

    /// @notice Pays `amount` of an asset to `to`. Only an approved proposal's call reaches it.
    /// @dev A token is sent with `SafeERC20`, so a token that returns false instead of reverting
    /// still fails the batch; ETH (`NATIVE`) is sent with `Address.sendValue`. Proposals pay tokens
    /// through here rather than through a raw `transfer` call for that reason.
    function pay(address asset, address to, uint256 amount) external onlySelf {
        emit Paid(asset, to, amount);
        _send(asset, to, amount);
    }

    /// @notice Advances `amount` of an asset to an operator and records it under `advanceId` as
    /// outstanding. Only an approved proposal's call reaches it.
    /// @param advanceId A new id, chosen in the proposal.
    /// @param operator Who receives it.
    /// @param asset A token, or `NATIVE` for ETH.
    /// @param amount How much.
    /// @param purposeHash The hash of what it is for, kept off chain.
    function advance(uint256 advanceId, address operator, address asset, uint256 amount, bytes32 purposeHash)
        external
        onlySelf
    {
        if (advances[advanceId].operator != address(0)) revert AdvanceIdTaken(advanceId);
        advances[advanceId] = Advance({operator: operator, asset: asset, outstanding: amount, purposeHash: purposeHash});
        emit Advanced(advanceId, operator, asset, amount, purposeHash);
        _send(asset, operator, amount);
    }

    /// @notice Returns part or all of an advance to the treasury. Anyone may return it.
    /// @dev Capped at what is still outstanding, so a return can never be labelled against more
    /// than was advanced. An ETH advance is returned by sending exactly `amount` with the call; a
    /// token advance is pulled from the caller, who approves the treasury first, and takes no ETH.
    function returnAdvance(uint256 advanceId, uint256 amount) external payable nonReentrant {
        Advance storage stored = advances[advanceId];
        uint256 outstanding = stored.outstanding;
        if (amount > outstanding) revert ReturnAboveOutstanding(advanceId, amount, outstanding);
        address asset = stored.asset;
        if (msg.value != (asset == NATIVE ? amount : 0)) revert WrongValue(msg.value);
        stored.outstanding = outstanding - amount;
        emit AdvanceReturned(advanceId, msg.sender, amount, outstanding - amount);
        if (asset != NATIVE) IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _send(address asset, address to, uint256 amount) private {
        if (asset == NATIVE) Address.sendValue(payable(to), amount);
        else IERC20(asset).safeTransfer(to, amount);
    }
}
