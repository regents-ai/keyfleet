// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KeyfleetKeys} from "./KeyfleetKeys.sol";
import {KeyfleetManager} from "./KeyfleetManager.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV4PoolManager, IUnlockCallback, V4PoolKey, V4SwapParams} from "./interfaces/IUniswapV4PoolManager.sol";

/// @notice Turns every fleet's booked USDC into REGENT for the fleet's treasury, in small pieces,
/// at the market price, by one fixed route: USDC to WETH on a Uniswap v3 pool, then WETH to REGENT
/// on a Uniswap v4 pool.
/// @dev Shared by every fleet. A purchase never swaps: each fleet's manager books the treasury's
/// part as `pendingConversion` and joins this contract's queue of fleets waiting for REGENT. Anyone
/// may call `convert(maxUsdc)`, which turns one piece of the first queued fleet's booked USDC into
/// REGENT: at most `PIECE_USDC` (250 USDC), and less when the caller names less. A piece holds the
/// next one back for its share of `PIECE_INTERVAL`, 15 minutes for a full piece and in proportion
/// for a smaller one, rounded up to the second, so across every fleet at most 250 USDC turns into
/// REGENT every 15 minutes and never two pieces in one block. A fleet with USDC still booked goes to
/// the back of the queue, so fleets take turns, one piece each. The queue holds
/// each fleet at most once and only fleets the collection registered, and `convert` touches only
/// its first entry, so every call costs the same whatever the queue's length.
///
/// A piece that moves the route's price by more than `MAX_PRICE_MOVE_BPS` (1%) reverts, and the
/// fleet keeps its place at the front until someone converts a smaller piece. The price is each
/// pool's own, read before and after the swap, so the rule bounds only the piece's own move, never
/// a move made before it in the same block; what makes pushing the price first and unwinding after
/// unprofitable is the REGENT pool hook's fee on both trades. The route's price moves by the two
/// pools' moves multiplied together.
///
/// A piece pulls exactly the USDC the fleet's manager approved, through the v3 pool's callback
/// straight into the pool, swaps the WETH that comes out inside one PoolManager `unlock`, and has
/// the PoolManager pay the REGENT straight to the fleet's treasury. Each leg must spend exactly what
/// it was given, or the whole call reverts, so a partial fill can never leave USDC or WETH behind
/// here; between calls this contract holds no token and no approval, and its route is fixed at
/// deployment for ever.
///
/// The two callbacks answer only the fixed v3 pool and the fixed PoolManager, and only while this
/// contract's own swap is under way, with the exact amount that swap is owed. The REGENT pool's
/// hook is third-party code that runs inside the v4 swap; anything it does is limited to its own
/// money and whatever this contract's checks allow.
contract KeyfleetRegentBuyer is IUniswapV3SwapCallback, IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @notice The fixed route, given at deployment.
    /// @param usdc The token paid in.
    /// @param weth The token between the two legs.
    /// @param regent The token paid out.
    /// @param v3Pool The Uniswap v3 USDC/WETH pool of the first leg.
    /// @param poolManager The Uniswap v4 PoolManager of the second leg.
    /// @param v4Pool The key of the v4 WETH/REGENT pool.
    struct Route {
        address usdc;
        address weth;
        address regent;
        address v3Pool;
        address poolManager;
        V4PoolKey v4Pool;
    }

    /// @notice A route address was zero or held no code.
    error RouteInvalid();
    /// @notice Only a fleet manager the collection registered may join the queue.
    error NotManager(address caller);
    /// @notice No fleet has USDC waiting to be turned into REGENT.
    error NothingQueued();
    /// @notice The last piece's share of `PIECE_INTERVAL` has not passed yet.
    /// @param nextPieceAt The first second the next piece may run.
    error PieceTooSoon(uint256 nextPieceAt);
    /// @notice The caller named a piece of no USDC.
    error PieceEmpty();
    /// @notice The piece moved the route's price by more than `MAX_PRICE_MOVE_BPS`.
    /// @param move The move, scaled by 1e18: 1e16 is 1%.
    error PriceMoved(uint256 move);
    /// @notice A callback came from someone other than the fixed pool, or outside this contract's
    /// own swap.
    error UnexpectedCallback(address caller);
    /// @notice A leg did not spend exactly what it was given.
    error SwapIncomplete(uint256 expected, uint256 actual);
    /// @notice The REGENT leg paid nothing out.
    error NothingBought();

    /// @notice A fleet joined the back of the queue.
    event Queued(address indexed manager);
    /// @notice One piece was turned into REGENT.
    /// @param payer The fleet's manager, which the USDC came from.
    /// @param recipient The fleet's treasury, which the REGENT went to.
    /// @param usdcIn The USDC spent.
    /// @param wethMid The WETH the first leg produced and the second leg spent.
    /// @param regentOut The REGENT the recipient received.
    event RegentBought(
        address indexed payer, address indexed recipient, uint256 usdcIn, uint256 wethMid, uint256 regentOut
    );

    /// @notice The most USDC one piece turns into REGENT: 250 USDC.
    uint256 public constant PIECE_USDC = 250e6;
    /// @notice How long a full piece holds the next one back, across every fleet: 15 minutes. A
    /// smaller piece holds it back in proportion.
    uint256 public constant PIECE_INTERVAL = 15 minutes;
    /// @notice The most one piece may move the route's price, in basis points: 1%.
    uint256 public constant MAX_PRICE_MOVE_BPS = 100;

    /// @dev The lowest and highest prices a Uniswap pool accepts as a limit, plus and minus one, so a
    /// swap is limited only by its amount.
    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    /// @dev Transient: who pays the v3 leg, and the exact USDC it is owed. Both are zero except
    /// inside a piece's swap, which is what lets the v3 callback tell its own swap from any other call.
    bytes32 private constant PAYER_SLOT = keccak256("keyfleet.regent_buyer.payer");
    bytes32 private constant OWED_SLOT = keccak256("keyfleet.regent_buyer.usdc_owed");
    /// @dev Transient: whether this contract is inside its own `unlock`.
    bytes32 private constant UNLOCKED_SLOT = keccak256("keyfleet.regent_buyer.unlocked");
    /// @dev v4-core's `PoolManager` keeps `mapping(PoolId => Pool.State) _pools` at this slot; a
    /// pool's price is the low 160 bits of its state's first word, as `StateLibrary.getSlot0` reads it.
    bytes32 private constant V4_POOLS_SLOT = bytes32(uint256(6));
    /// @dev A price move is counted in this fixed point: 1e18 is no move.
    uint256 private constant WAD = 1e18;

    /// @notice The collection, which says which accounts are fleet managers.
    KeyfleetKeys public immutable KEYS;

    IERC20 public immutable USDC;
    IERC20 public immutable WETH;
    IERC20 public immutable REGENT;
    IUniswapV3Pool public immutable V3_POOL;
    IUniswapV4PoolManager public immutable POOL_MANAGER;
    /// @notice The v4 pool's id, `keccak256(abi.encode(key))`.
    bytes32 public immutable V4_POOL_ID;
    /// @notice Whether USDC is the v3 pool's token0.
    bool public immutable USDC_IS_V3_TOKEN0;
    /// @notice Whether WETH is the v4 pool's currency0.
    bool public immutable WETH_IS_V4_CURRENCY0;

    address private immutable _currency0;
    address private immutable _currency1;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;
    address private immutable _hooks;

    /// @notice The first second the next piece may run; zero before the first piece.
    uint64 public nextPieceAt;
    /// @notice The queue's first position; positions `queueHead` up to `queueTail` are filled.
    uint64 public queueHead;
    /// @notice The position the next fleet to join takes.
    uint64 public queueTail;
    /// @notice Whether a fleet's manager is in the queue now.
    mapping(address manager => bool queued) public isQueued;

    mapping(uint256 position => address manager) private _queue;

    /// @notice Fixes the route and the collection. The v3 pool must hold exactly USDC and WETH, and
    /// the v4 pool key exactly WETH and REGENT; every address must hold code.
    constructor(Route memory route, KeyfleetKeys keys) {
        if (
            route.usdc.code.length == 0 || route.weth.code.length == 0 || route.regent.code.length == 0
                || route.v3Pool.code.length == 0 || route.poolManager.code.length == 0
        ) revert RouteInvalid();
        address token0 = IUniswapV3Pool(route.v3Pool).token0();
        address token1 = IUniswapV3Pool(route.v3Pool).token1();
        bool usdcIsToken0 = token0 == route.usdc && token1 == route.weth;
        if (!usdcIsToken0 && !(token0 == route.weth && token1 == route.usdc)) revert RouteInvalid();
        V4PoolKey memory key = route.v4Pool;
        bool wethIsCurrency0 = key.currency0 == route.weth && key.currency1 == route.regent;
        if (!wethIsCurrency0 && !(key.currency0 == route.regent && key.currency1 == route.weth)) {
            revert RouteInvalid();
        }

        KEYS = keys;
        USDC = IERC20(route.usdc);
        WETH = IERC20(route.weth);
        REGENT = IERC20(route.regent);
        V3_POOL = IUniswapV3Pool(route.v3Pool);
        POOL_MANAGER = IUniswapV4PoolManager(route.poolManager);
        V4_POOL_ID = keccak256(abi.encode(key));
        USDC_IS_V3_TOKEN0 = usdcIsToken0;
        WETH_IS_V4_CURRENCY0 = wethIsCurrency0;
        _currency0 = key.currency0;
        _currency1 = key.currency1;
        _fee = key.fee;
        _tickSpacing = key.tickSpacing;
        _hooks = key.hooks;
    }

    /// @notice The fixed v4 pool key.
    function v4PoolKey() public view returns (V4PoolKey memory) {
        return
            V4PoolKey({
                currency0: _currency0, currency1: _currency1, fee: _fee, tickSpacing: _tickSpacing, hooks: _hooks
            });
    }

    /// @notice The fleet whose piece is next, or zero when none is waiting.
    function nextInQueue() external view returns (address) {
        return _queue[queueHead];
    }

    /// @notice How many fleets are waiting.
    function queueLength() external view returns (uint256) {
        return queueTail - queueHead;
    }

    /// @notice Puts the calling fleet's manager at the back of the queue, unless it is already in it.
    /// A manager calls this whenever it books USDC for its treasury.
    function enqueue() external {
        if (KEYS.fleetOfManager(msg.sender) == 0) revert NotManager(msg.sender);
        if (!isQueued[msg.sender]) _push(msg.sender);
    }

    /// @notice Turns one piece of the first queued fleet's booked USDC into REGENT for its treasury,
    /// at the market price. Anyone may call it, and may name a smaller piece, for instance when a
    /// full one would move the price more than 1%.
    /// @dev Only from `nextPieceAt`. The fleet's manager hands over the least of its booking,
    /// `PIECE_USDC` and `maxUsdc`, and approves exactly that; the piece then holds the next one back
    /// for `PIECE_INTERVAL` times its share of `PIECE_USDC`, rounded up to the second, which also
    /// keeps two pieces out of one block. The fleet goes to the back of the queue if it still has
    /// USDC booked. Locked, so the REGENT pool's hook cannot start a second piece inside the first.
    /// @param maxUsdc The most USDC the caller wants this piece to be; above `PIECE_USDC` counts as
    /// `PIECE_USDC`.
    /// @return regentOut The REGENT the fleet's treasury received.
    function convert(uint256 maxUsdc) external nonReentrant returns (uint256 regentOut) {
        if (maxUsdc == 0) revert PieceEmpty();
        uint256 opensAt = nextPieceAt;
        if (block.timestamp < opensAt) revert PieceTooSoon(opensAt);
        uint64 head = queueHead;
        if (head == queueTail) revert NothingQueued();
        KeyfleetManager manager = KeyfleetManager(_queue[head]);
        delete _queue[head];
        queueHead = head + 1;
        isQueued[address(manager)] = false;

        (uint256 usdcIn, address recipient) = manager.takePiece(Math.min(maxUsdc, PIECE_USDC));
        nextPieceAt = uint64(block.timestamp + Math.ceilDiv(PIECE_INTERVAL * usdcIn, PIECE_USDC));
        regentOut = _swap(address(manager), usdcIn, recipient);
        if (manager.pendingConversion() != 0 && !isQueued[address(manager)]) _push(address(manager));
    }

    /// @notice Pays the v3 pool the USDC its swap is owed, straight from the payer.
    /// @dev Only the fixed pool, only inside a piece's swap, and only for exactly the USDC it asked to swap.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address payer = PAYER_SLOT.asAddress().tload();
        if (msg.sender != address(V3_POOL) || payer == address(0)) revert UnexpectedCallback(msg.sender);
        uint256 owed = OWED_SLOT.asUint256().tload();
        int256 usdcDelta = USDC_IS_V3_TOKEN0 ? amount0Delta : amount1Delta;
        if (usdcDelta != int256(owed)) revert SwapIncomplete(owed, _abs(usdcDelta));
        OWED_SLOT.asUint256().tstore(0);
        USDC.safeTransferFrom(payer, address(V3_POOL), owed);
    }

    /// @notice Swaps the WETH for REGENT inside the PoolManager, pays the WETH and has the REGENT sent
    /// to the recipient.
    /// @dev Only the fixed PoolManager, only inside this contract's own `unlock`. The WETH leg must
    /// spend exactly the WETH the first leg produced.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !UNLOCKED_SLOT.asBoolean().tload()) {
            revert UnexpectedCallback(msg.sender);
        }
        UNLOCKED_SLOT.asBoolean().tstore(false);
        (uint256 wethIn, address recipient) = abi.decode(data, (uint256, address));

        bool zeroForOne = WETH_IS_V4_CURRENCY0;
        int256 delta = POOL_MANAGER.swap(
            v4PoolKey(),
            V4SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(wethIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        (int128 wethDelta, int128 regentDelta) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        if (int256(wethDelta) != -int256(wethIn)) revert SwapIncomplete(wethIn, _abs(wethDelta));
        if (regentDelta <= 0) revert NothingBought();

        POOL_MANAGER.sync(address(WETH));
        WETH.safeTransfer(address(POOL_MANAGER), wethIn);
        POOL_MANAGER.settle();
        POOL_MANAGER.take(address(REGENT), recipient, uint256(uint128(regentDelta)));
        return "";
    }

    /// @dev Spends `usdcIn` of `payer`'s approved USDC on REGENT for `recipient`, refusing a swap
    /// that moves the route's price by more than `MAX_PRICE_MOVE_BPS`.
    function _swap(address payer, uint256 usdcIn, address recipient) private returns (uint256 regentOut) {
        uint256 v3Before = _v3Price();
        uint256 v4Before = _v4Price();
        PAYER_SLOT.asAddress().tstore(payer);
        OWED_SLOT.asUint256().tstore(usdcIn);

        bool zeroForOne = USDC_IS_V3_TOKEN0;
        (int256 amount0, int256 amount1) = V3_POOL.swap(
            address(this), zeroForOne, int256(usdcIn), zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT, ""
        );
        (int256 usdcDelta, int256 wethDelta) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        if (usdcDelta != int256(usdcIn)) revert SwapIncomplete(usdcIn, _abs(usdcDelta));
        // Cleared before the second leg, so the v3 callback refuses anything from here on.
        PAYER_SLOT.asAddress().tstore(address(0));
        OWED_SLOT.asUint256().tstore(0);
        if (wethDelta >= 0) revert NothingBought();
        uint256 wethMid = uint256(-wethDelta);

        uint256 before = REGENT.balanceOf(recipient);
        UNLOCKED_SLOT.asBoolean().tstore(true);
        POOL_MANAGER.unlock(abi.encode(wethMid, recipient));
        UNLOCKED_SLOT.asBoolean().tstore(false);
        regentOut = REGENT.balanceOf(recipient) - before;
        if (regentOut == 0) revert NothingBought();

        uint256 move = Math.mulDiv(_ratio(v3Before, _v3Price()), _ratio(v4Before, _v4Price()), WAD);
        move = Math.mulDiv(move, move, WAD) - WAD;
        if (move > (WAD * MAX_PRICE_MOVE_BPS) / 10_000) revert PriceMoved(move);
        emit RegentBought(payer, recipient, usdcIn, wethMid, regentOut);
    }

    function _push(address manager) private {
        uint64 tail = queueTail;
        _queue[tail] = manager;
        queueTail = tail + 1;
        isQueued[manager] = true;
        emit Queued(manager);
    }

    /// @dev The v3 pool's square-root price now.
    function _v3Price() private view returns (uint256 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = V3_POOL.slot0();
    }

    /// @dev The v4 pool's square-root price now, read from the PoolManager's storage.
    function _v4Price() private view returns (uint256) {
        bytes32 slot = keccak256(abi.encodePacked(V4_POOL_ID, V4_POOLS_SLOT));
        return uint160(uint256(POOL_MANAGER.extsload(slot)));
    }

    /// @dev How far apart two square-root prices are, the larger over the smaller, scaled by 1e18.
    function _ratio(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? Math.mulDiv(a, WAD, b) : Math.mulDiv(b, WAD, a);
    }

    function _abs(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }
}
