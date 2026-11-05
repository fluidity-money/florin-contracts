// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {UniswapV4Exchange} from "../src/Zappers/Modules/Exchanges/UniswapV4.sol";

contract V4ExchangeTestToken is ERC20 {
    constructor() ERC20("Test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Inherit the complete suite twice so every direction/failure is checked with
/// BOLD as currency0 AND currency1. No fork, mocked manager, or mocked swap deltas.
abstract contract UniswapV4ExchangeIntegrationBase is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal referenceRouter;
    V4ExchangeTestToken internal bold;
    V4ExchangeTestToken internal coll;
    UniswapV4Exchange internal exchange;
    PoolKey internal key;
    address internal trader = address(0xBEEF);
    uint256 internal constant INITIAL_BALANCE = 1e30;

    function boldIsCurrency0() internal pure virtual returns (bool);

    function setUp() public {
        // v4.0.0 PoolManager pins solc 0.8.26; the adapter/tests pin 0.8.24.
        // Utils/V4PoolManagerArtifact.sol compiles it as a separate graph.
        // Deploy real creation bytecode (constructor/immutables), not a mock.
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        referenceRouter = new PoolSwapTest(manager);
        V4ExchangeTestToken a = new V4ExchangeTestToken();
        V4ExchangeTestToken b = new V4ExchangeTestToken();
        (V4ExchangeTestToken low, V4ExchangeTestToken high) = address(a) < address(b) ? (a, b) : (b, a);
        (bold, coll) = boldIsCurrency0() ? (low, high) : (high, low);
        key = PoolKey(Currency.wrap(address(low)), Currency.wrap(address(high)), 3000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        exchange = new UniswapV4Exchange(manager, IERC20(address(bold)), IERC20(address(coll)), key);
        a.mint(address(this), INITIAL_BALANCE);
        b.mint(address(this), INITIAL_BALANCE);
        a.approve(address(liquidityRouter), type(uint256).max);
        b.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 1e24, bytes32(0)), "");
        a.mint(trader, INITIAL_BALANCE);
        b.mint(trader, INITIAL_BALANCE);
        vm.startPrank(trader);
        a.approve(address(exchange), type(uint256).max);
        b.approve(address(exchange), type(uint256).max);
        a.approve(address(referenceRouter), type(uint256).max);
        b.approve(address(referenceRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _params(bool fromBold, uint256 amount) internal view returns (IPoolManager.SwapParams memory) {
        bool zeroForOne = fromBold == boldIsCurrency0();
        return IPoolManager.SwapParams(
            zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    // Execute a real reference swap, then restore ALL state. This checks exact
    // integer rounding, fees, and output independently of the adapter's return value.
    function _reference(bool fromBold, uint256 amount) internal returns (uint256 spent, uint256 received) {
        uint256 snapshot = vm.snapshotState();
        IPoolManager.SwapParams memory params = _params(fromBold, amount);
        vm.prank(trader);
        BalanceDelta delta = referenceRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        spent = uint256(-int256(params.zeroForOne ? delta.amount0() : delta.amount1()));
        received = uint256(int256(params.zeroForOne ? delta.amount1() : delta.amount0()));
        assertTrue(vm.revertToState(snapshot));
    }

    function _swap(bool fromBold, uint256 amount, uint256 minimum) internal returns (uint256 result) {
        vm.prank(trader);
        if (fromBold) exchange.swapFromBold(amount, minimum);
        else result = exchange.swapToBold(amount, minimum);
    }

    function _assertSettled() internal view {
        assertEq(bold.balanceOf(address(exchange)), 0, "adapter retains BOLD");
        assertEq(coll.balanceOf(address(exchange)), 0, "adapter retains collateral");
        assertEq(bold.allowance(address(exchange), address(manager)), 0);
        assertEq(coll.allowance(address(exchange), address(manager)), 0);
        assertEq(manager.currencyDelta(address(exchange), key.currency0), 0);
        assertEq(manager.currencyDelta(address(exchange), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }

    function _checkSwap(bool fromBold, uint256 amount) internal {
        (uint256 spent, uint256 expected) = _reference(fromBold, amount);
        assertEq(spent, amount, "reference must fully fill");
        assertGt(expected, 0);
        V4ExchangeTestToken input = fromBold ? bold : coll;
        V4ExchangeTestToken output = fromBold ? coll : bold;
        uint256 inputBefore = input.balanceOf(trader);
        uint256 outputBefore = output.balanceOf(trader);
        uint256 managerInput = input.balanceOf(address(manager));
        uint256 managerOutput = output.balanceOf(address(manager));
        uint256 result = _swap(fromBold, amount, expected); // minimum equality succeeds
        if (!fromBold) assertEq(result, expected, "swapToBold return value");
        assertEq(input.balanceOf(trader), inputBefore - amount, "exact input debit");
        assertEq(output.balanceOf(trader), outputBefore + expected, "exact output credit");
        assertEq(input.balanceOf(address(manager)), managerInput + amount);
        assertEq(output.balanceOf(address(manager)), managerOutput - expected);
        _assertSettled();
    }

    function _stateHash() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                fee0,
                fee1,
                manager.getLiquidity(key.toId()),
                bold.balanceOf(trader),
                coll.balanceOf(trader),
                bold.balanceOf(address(manager)),
                coll.balanceOf(address(manager)),
                bold.allowance(trader, address(exchange)),
                coll.allowance(trader, address(exchange))
            )
        );
    }

    function _expectRollback(bool fromBold, uint256 amount, uint256 minimum, bytes memory reason) internal {
        bytes32 beforeState = _stateHash();
        vm.expectRevert(reason);
        _swap(fromBold, amount, minimum);
        assertEq(_stateHash(), beforeState, "revert must restore pool, balances and allowances");
        _assertSettled();
    }

    function test_swapFromBold_exactBalances() public {
        _checkSwap(true, 1e18);
    }

    function test_swapToBold_exactBalancesAndReturn() public {
        _checkSwap(false, 1e18);
    }

    function test_roundTrip() public {
        _checkSwap(true, 1e20);
        _checkSwap(false, 5e19);
    }

    function test_slippageRollback_bothDirections() public {
        for (uint256 i; i < 2; ++i) {
            bool fromBold = i == 0;
            (, uint256 expected) = _reference(fromBold, 1e18);
            _expectRollback(
                fromBold, 1e18, expected + 1, abi.encodeWithSelector(UniswapV4Exchange.InsufficientOutput.selector)
            );
            _checkSwap(fromBold, 1e18); // guard and manager remain usable after revert
        }
    }

    function test_noAllowance_bothDirections() public {
        vm.startPrank(trader);
        bold.approve(address(exchange), 0);
        coll.approve(address(exchange), 0);
        vm.stopPrank();
        bytes memory reason = abi.encodeWithSignature("Error(string)", "ERC20: insufficient allowance");
        _expectRollback(true, 1e18, 0, reason);
        _expectRollback(false, 1e18, 0, reason);
    }

    function test_finiteAllowance_consumedExactly() public {
        vm.startPrank(trader);
        bold.approve(address(exchange), 1e18);
        coll.approve(address(exchange), 2e18);
        vm.stopPrank();
        _checkSwap(true, 1e18);
        _checkSwap(false, 2e18);
        assertEq(bold.allowance(trader, address(exchange)), 0);
        assertEq(coll.allowance(trader, address(exchange)), 0);
    }

    function test_zeroAndOversizedAmounts_bothDirections() public {
        uint256[3] memory amounts = [uint256(0), uint256(uint128(type(int128).max)) + 1, type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            _expectRollback(true, amounts[i], 0, abi.encodeWithSelector(UniswapV4Exchange.InvalidAmount.selector));
            _expectRollback(false, amounts[i], 0, abi.encodeWithSelector(UniswapV4Exchange.InvalidAmount.selector));
        }
    }

    function test_callbackRejectsExternalCaller() public {
        vm.expectRevert(UniswapV4Exchange.UnauthorizedCallback.selector);
        exchange.unlockCallback(abi.encode(trader, true, 1e18, 0));
    }

    function test_callbackRejectsManagerOutsideActiveSwap() public {
        vm.prank(address(manager));
        vm.expectRevert(UniswapV4Exchange.UnauthorizedCallback.selector);
        exchange.unlockCallback(abi.encode(trader, true, 1e18, 0));
    }

    function test_partialFillRejected_bothDirections() public {
        for (uint256 i; i < 2; ++i) {
            bool fromBold = i == 0;
            (uint256 spent, uint256 received) = _reference(fromBold, 1e27);
            assertGt(spent, 0, "prove partial rather than empty fill");
            assertLt(spent, 1e27);
            assertGt(received, 0);
            _expectRollback(fromBold, 1e27, 0, abi.encodeWithSelector(UniswapV4Exchange.IncompleteSwap.selector));
        }
    }

    function test_emptyLiquidityRejected_bothDirections() public {
        liquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, -1e24, bytes32(0)), "");
        assertEq(manager.getLiquidity(key.toId()), 0);
        _expectRollback(true, 1e18, 0, abi.encodeWithSelector(UniswapV4Exchange.IncompleteSwap.selector));
        _expectRollback(false, 1e18, 0, abi.encodeWithSelector(UniswapV4Exchange.IncompleteSwap.selector));
    }

    function testFuzz_swapFromBold(uint256 amount) public {
        _checkSwap(true, bound(amount, 1e6, 1e21));
    }

    function testFuzz_swapToBold(uint256 amount) public {
        _checkSwap(false, bound(amount, 1e6, 1e21));
    }
}

contract UniswapV4ExchangeBoldCurrency0Test is UniswapV4ExchangeIntegrationBase {
    function boldIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract UniswapV4ExchangeBoldCurrency1Test is UniswapV4ExchangeIntegrationBase {
    function boldIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
