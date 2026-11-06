// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {AggregatorV3Interface} from "../../../Dependencies/AggregatorV3Interface.sol";
import {IExchange} from "../../Interfaces/IExchange.sol";
import {IFlashLoanProvider} from "../../Interfaces/IFlashLoanProvider.sol";
import {IFlashLoanReceiver} from "../../Interfaces/IFlashLoanReceiver.sol";
import {ILeverageZapper} from "../../Interfaces/ILeverageZapper.sol";
import {IZapper} from "../../Interfaces/IZapper.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

contract MockSPYExchange is IExchange, IFlashLoanProvider, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable boldToken;
    IERC20 public immutable collToken;
    AggregatorV3Interface public immutable priceFeed;
    uint256 public immutable priceScale;
    uint256 public immutable oracleScale;

    IPoolManager public immutable poolManager;
    IFlashLoanReceiver public override receiver;
    bool private _awaitingUnlock;
    // Existing SPY reserves, adjusted for swaps during the loan, must not fund repayment.
    uint256 private _expectedReserve;

    constructor(
        IERC20Metadata _boldToken,
        IERC20Metadata _spyToken,
        AggregatorV3Interface _priceFeed,
        IPoolManager _poolManager
    ) {
        require(address(_poolManager).code.length != 0, "MockSPYExchange: invalid PoolManager");
        poolManager = _poolManager;
        require(address(_boldToken) != address(_spyToken), "MockSPYExchange: identical tokens");
        require(_boldToken.decimals() == 18, "MockSPYExchange: BOLD decimals");
        uint8 collDecimals = _spyToken.decimals();
        uint8 feedDecimals = _priceFeed.decimals();
        require(collDecimals <= 18 && feedDecimals <= 18, "MockSPYExchange: unsupported decimals");
        boldToken = IERC20(address(_boldToken));
        collToken = IERC20(address(_spyToken));
        priceFeed = _priceFeed;
        // Multiplying an oracle answer by this scale gives BOLD base units per SPY base unit.
        priceScale = 10 ** (18 - collDecimals);
        oracleScale = 10 ** feedDecimals;
    }

    function swapToBold(uint256 _collAmount, uint256 _minBoldAmount)
        external
        override
        nonReentrant
        returns (uint256 boldAmount)
    {
        boldAmount = Math.mulDiv(_collAmount, _price() * priceScale, oracleScale);
        require(boldAmount >= _minBoldAmount, "MockSPYExchange: insufficient output");
        if (address(receiver) != address(0)) _expectedReserve += _collAmount;
        collToken.safeTransferFrom(msg.sender, address(this), _collAmount);
        boldToken.safeTransfer(msg.sender, boldAmount);
    }

    function swapFromBold(uint256 _boldAmount, uint256 _minCollAmount) external override nonReentrant {
        uint256 collAmount = Math.mulDiv(_boldAmount, oracleScale, _price() * priceScale);
        require(collAmount >= _minCollAmount, "MockSPYExchange: insufficient output");
        if (address(receiver) != address(0)) _expectedReserve -= collAmount;
        boldToken.safeTransferFrom(msg.sender, address(this), _boldAmount);
        collToken.safeTransfer(msg.sender, collAmount);
    }

    /// @notice Borrow SPY via v4 flash accounting. The receiver pushes repayment back here.
    /// @dev No flash-loan fee is charged by PoolManager; swaps retain the mock's pricing.
    function makeFlashLoan(IERC20 _token, uint256 _amount, Operation _operation, bytes calldata _userData)
        external
        override
    {
        require(address(receiver) == address(0) && !_reentrancyGuardEntered(), "MockSPYExchange: loan active");
        require(address(_token) == address(collToken), "MockSPYExchange: unsupported loan token");
        require(_amount > 0 && _amount <= uint256(uint128(type(int128).max)), "MockSPYExchange: invalid amount");
        require(msg.sender.code.length != 0, "MockSPYExchange: invalid receiver");

        receiver = IFlashLoanReceiver(msg.sender);
        _expectedReserve = collToken.balanceOf(address(this));
        _awaitingUnlock = true;
        poolManager.unlock(abi.encode(_amount, _operation, _userData));
        require(!_awaitingUnlock, "MockSPYExchange: missing callback");
        delete receiver;
        delete _expectedReserve;
    }

    function unlockCallback(bytes calldata _data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager) && _awaitingUnlock, "MockSPYExchange: unauthorized callback");
        _awaitingUnlock = false;
        (uint256 amount, Operation operation, bytes memory userData) = abi.decode(_data, (uint256, Operation, bytes));
        IFlashLoanReceiver loanReceiver = receiver;
        Currency currency = Currency.wrap(address(collToken));

        // PoolManager records this contract's debt, but sends the SPY straight to the zapper.
        poolManager.take(currency, address(loanReceiver), amount);
        if (operation == Operation.OpenTrove) {
            loanReceiver.receiveFlashLoanOnOpenLeveragedTrove(
                abi.decode(userData, (ILeverageZapper.OpenLeveragedTroveParams)), amount
            );
        } else if (operation == Operation.CloseTrove) {
            loanReceiver.receiveFlashLoanOnCloseTroveFromCollateral(
                abi.decode(userData, (IZapper.CloseTroveParams)), amount
            );
        } else if (operation == Operation.LeverUpTrove) {
            loanReceiver.receiveFlashLoanOnLeverUpTrove(
                abi.decode(userData, (ILeverageZapper.LeverUpTroveParams)), amount
            );
        } else {
            loanReceiver.receiveFlashLoanOnLeverDownTrove(
                abi.decode(userData, (ILeverageZapper.LeverDownTroveParams)), amount
            );
        }

        // Swaps are allowed during the callback, but their reserve changes are not loan repayment.
        require(collToken.balanceOf(address(this)) >= _expectedReserve + amount, "MockSPYExchange: loan not repaid");
        poolManager.sync(currency);
        collToken.safeTransfer(address(poolManager), amount);
        require(poolManager.settle() == amount, "MockSPYExchange: incomplete settlement");
        return "";
    }

    function _price() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp, "MockSPYExchange: invalid price");
        return uint256(answer);
    }
}
