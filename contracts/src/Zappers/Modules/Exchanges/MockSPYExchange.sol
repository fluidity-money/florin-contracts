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
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

contract MockSPYExchange is IExchange, IFlashLoanProvider, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable boldToken;
    IERC20 public immutable collToken;
    AggregatorV3Interface public immutable priceFeed;
    uint256 public immutable priceScale;
    uint256 public immutable oracleScale;

    IFlashLoanReceiver public override receiver;
    // Unlent SPY reserves, adjusted for swaps during the loan, must not fund repayment.
    uint256 private _expectedReserve;

    constructor(IERC20Metadata _boldToken, IERC20Metadata _spyToken, AggregatorV3Interface _priceFeed) {
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

    /// @notice Borrow prefunded SPY. The receiver pushes repayment back here.
    /// @dev No flash-loan fee is charged; swaps retain the mock's pricing.
    /// The mock needs enough reserves for both the loan and swaps during its callback.
    function makeFlashLoan(IERC20 _token, uint256 _amount, Operation _operation, bytes calldata _userData)
        external
        override
    {
        require(address(receiver) == address(0) && !_reentrancyGuardEntered(), "MockSPYExchange: loan active");
        require(address(_token) == address(collToken), "MockSPYExchange: unsupported loan token");
        require(_amount > 0, "MockSPYExchange: invalid amount");
        require(msg.sender.code.length != 0, "MockSPYExchange: invalid receiver");

        uint256 balance = collToken.balanceOf(address(this));
        require(balance >= _amount, "MockSPYExchange: insufficient loan liquidity");
        IFlashLoanReceiver loanReceiver = IFlashLoanReceiver(msg.sender);
        receiver = loanReceiver;
        _expectedReserve = balance - _amount;

        collToken.safeTransfer(address(loanReceiver), _amount);
        if (_operation == Operation.OpenTrove) {
            loanReceiver.receiveFlashLoanOnOpenLeveragedTrove(
                abi.decode(_userData, (ILeverageZapper.OpenLeveragedTroveParams)), _amount
            );
        } else if (_operation == Operation.CloseTrove) {
            loanReceiver.receiveFlashLoanOnCloseTroveFromCollateral(
                abi.decode(_userData, (IZapper.CloseTroveParams)), _amount
            );
        } else if (_operation == Operation.LeverUpTrove) {
            loanReceiver.receiveFlashLoanOnLeverUpTrove(
                abi.decode(_userData, (ILeverageZapper.LeverUpTroveParams)), _amount
            );
        } else {
            loanReceiver.receiveFlashLoanOnLeverDownTrove(
                abi.decode(_userData, (ILeverageZapper.LeverDownTroveParams)), _amount
            );
        }

        // Swaps are allowed during the callback, but their reserve changes are not loan repayment.
        require(collToken.balanceOf(address(this)) >= _expectedReserve + _amount, "MockSPYExchange: loan not repaid");
        delete receiver;
        delete _expectedReserve;
    }

    function _price() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp, "MockSPYExchange: invalid price");
        return uint256(answer);
    }
}
