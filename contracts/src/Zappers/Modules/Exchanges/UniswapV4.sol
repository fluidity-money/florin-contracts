// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IExchange} from "../../Interfaces/IExchange.sol";

contract UniswapV4Exchange is IExchange, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IERC20 public immutable boldToken;
    IERC20 public immutable collToken;
    PoolKey public poolKey;

    error InvalidAmount();
    error UnauthorizedCallback();
    error IncompleteSwap();
    error InsufficientOutput();

    constructor(IPoolManager _poolManager, IERC20 _boldToken, IERC20 _collToken, PoolKey memory _poolKey) {
        address bold = address(_boldToken);
        address coll = address(_collToken);
        address token0 = bold < coll ? bold : coll;
        address token1 = bold < coll ? coll : bold;
        poolManager = _poolManager;
        boldToken = _boldToken;
        collToken = _collToken;
        poolKey = _poolKey;
    }

    function swapFromBold(uint256 _boldAmount, uint256 _minCollAmount) external override nonReentrant {
        _swap(true, _boldAmount, _minCollAmount);
    }

    function swapToBold(uint256 _collAmount, uint256 _minBoldAmount) external override nonReentrant returns (uint256) {
        return _swap(false, _collAmount, _minBoldAmount);
    }

    function _swap(bool fromBold, uint256 amount, uint256 minimum) internal returns (uint256) {
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) {
            revert InvalidAmount();
        }
        return abi.decode(poolManager.unlock(abi.encode(msg.sender, fromBold, amount, minimum)), (uint256));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_reentrancyGuardEntered()) revert UnauthorizedCallback();
        (address payer, bool fromBold, uint256 amount, uint256 minimum) =
            abi.decode(data, (address, bool, uint256, uint256));
        PoolKey memory key = poolKey;
        IERC20 input = fromBold ? boldToken : collToken;
        bool zeroForOne = address(input) == Currency.unwrap(key.currency0);
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(inputDelta) != -int256(amount)) revert IncompleteSwap();
        if (outputDelta < 0 || uint256(uint128(outputDelta)) < minimum) revert InsufficientOutput();
        uint256 output = uint256(uint128(outputDelta));
        poolManager.sync(zeroForOne ? key.currency0 : key.currency1);
        input.safeTransferFrom(payer, address(poolManager), amount);
        poolManager.settle();
        poolManager.take(zeroForOne ? key.currency1 : key.currency0, payer, output);
        return abi.encode(output);
    }
}
