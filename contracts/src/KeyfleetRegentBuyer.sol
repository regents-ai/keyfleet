// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IUniswapV3Pool, IUniswapV3SwapCallback} from "./interfaces/IUniswapV3Pool.sol";
import {IUniswapV4PoolManager, IUnlockCallback, V4PoolKey, V4SwapParams} from "./interfaces/IUniswapV4PoolManager.sol";

/// @notice Turns a fleet's USDC into REGENT for the fleet's treasury, at the market price, by one
/// fixed route: USDC to WETH on a Uniswap v3 pool, then WETH to REGENT on a Uniswap v4 pool.
/// @dev Shared by every fleet and stateless between calls: it holds no token, no approval and no
/// setting, and its route is fixed at deployment for ever. `buy` pulls exactly the USDC a caller
/// approved, through the v3 pool's callback straight into the pool, swaps the WETH that comes out
/// inside one PoolManager `unlock`, and has the PoolManager pay the REGENT straight to the
/// recipient. It returns the REGENT the recipient actually received, measured as the change in its
/// balance.
///
/// The swap takes the pool's price at that moment, with no minimum and no oracle: the founder chose
/// a plain swap. Each leg must spend exactly what it was given, or the whole call reverts, so a
/// partial fill can never leave USDC or WETH behind here.
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
    /// @notice A buy of nothing.
    error ZeroAmount();
    /// @notice A callback came from someone other than the fixed pool, or outside this contract's
    /// own swap.
    error UnexpectedCallback(address caller);
    /// @notice A leg did not spend exactly what it was given.
    error SwapIncomplete(uint256 expected, uint256 actual);
    /// @notice The REGENT leg paid nothing out.
    error NothingBought();

    /// @notice One buy finished.
    /// @param payer The account the USDC came from.
    /// @param recipient The account the REGENT went to.
    /// @param usdcIn The USDC spent.
    /// @param wethMid The WETH the first leg produced and the second leg spent.
    /// @param regentOut The REGENT the recipient received.
    event RegentBought(
        address indexed payer, address indexed recipient, uint256 usdcIn, uint256 wethMid, uint256 regentOut
    );

    /// @dev The lowest and highest prices a Uniswap pool accepts as a limit, plus and minus one, so a
    /// swap is limited only by its amount.
    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    /// @dev Transient: who pays the v3 leg, and the exact USDC it is owed. Both are zero except
    /// inside `buy`, which is what lets the v3 callback tell its own swap from any other call.
    bytes32 private constant PAYER_SLOT = keccak256("keyfleet.regent_buyer.payer");
    bytes32 private constant OWED_SLOT = keccak256("keyfleet.regent_buyer.usdc_owed");
    /// @dev Transient: whether this contract is inside its own `unlock`.
    bytes32 private constant UNLOCKED_SLOT = keccak256("keyfleet.regent_buyer.unlocked");

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

    /// @notice Fixes the route. The v3 pool must hold exactly USDC and WETH, and the v4 pool key
    /// exactly WETH and REGENT; every address must hold code.
    constructor(Route memory route) {
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

    /// @notice Spends `usdcIn` of the caller's USDC on REGENT for `recipient`, at the market price.
    /// @dev The caller must have approved this contract for exactly `usdcIn`. Locked, so a hook
    /// cannot start a second buy inside the first.
    /// @return regentOut The REGENT `recipient` received.
    function buy(uint256 usdcIn, address recipient) external nonReentrant returns (uint256 regentOut) {
        if (usdcIn == 0) revert ZeroAmount();
        PAYER_SLOT.asAddress().tstore(msg.sender);
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
        emit RegentBought(msg.sender, recipient, usdcIn, wethMid, regentOut);
    }

    /// @notice Pays the v3 pool the USDC its swap is owed, straight from the payer.
    /// @dev Only the fixed pool, only inside `buy`, and only for exactly the USDC `buy` asked to swap.
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

    function _abs(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }
}
