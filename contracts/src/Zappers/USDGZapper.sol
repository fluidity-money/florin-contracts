// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./BaseZapper.sol";
import "../Dependencies/Constants.sol";

contract USDGZapper is BaseZapper {
    using SafeERC20 for IERC20PermitMetadata;
    using SafeERC20 for IERC20Metadata;

    IERC20PermitMetadata public immutable collToken;
    IERC20Metadata public immutable usdg;

    constructor(
        IAddressesRegistry _addressesRegistry,
        IFlashLoanProvider _flashLoanProvider,
        IERC20Metadata _usdg,
        IExchange _spyUsdgExchange
    )
        BaseZapper(_addressesRegistry, _flashLoanProvider, _spyUsdgExchange)
    {
        collToken = _addressesRegistry.collToken();

        usdg = _usdg;

        // Approve WETH to BorrowerOperations
        WETH.approve(address(borrowerOperations), type(uint256).max);
        // Approve coll to BorrowerOperations
        collToken.approve(address(borrowerOperations), type(uint256).max);
	// Approve FUSD to the exchange for swaps into USDG.
	boldToken.approve(address(_spyUsdgExchange), type(uint256).max);
    }

    struct OpenTroveSwapParams {
        address owner;
        uint256 ownerIndex;
        uint256 collAmount;
        uint256 boldAmount;
        uint256 usdgAmount;
        uint256 upperHint;
        uint256 lowerHint;
        uint256 annualInterestRate;
        address batchManager;
        uint256 maxUpfrontFee;
        address addManager;
        address removeManager;
        address receiver;
    }

    function openTroveWithRawETHPermitSwap(
        PermitParams calldata _permit,
        OpenTroveSwapParams calldata _params
    ) external payable returns (uint256) {
        collToken.safePermit(
            msg.sender, address(this), _permit.value, _permit.deadline,
            _permit.v, _permit.r, _permit.s
        );
        return openTroveWithRawETHSwap(_params);
    }

    function openTroveWithRawETHSwap(
        OpenTroveSwapParams calldata _params
    ) public payable returns (uint256) {
        require(msg.value == ETH_GAS_COMPENSATION, "GCZ: Wrong ETH");
        require(
            _params.batchManager == address(0) || _params.annualInterestRate == 0,
            "GCZ: Cannot choose interest if joining a batch"
        );

        // Convert ETH to WETH
        WETH.deposit{value: msg.value}();

        // Pull coll
        collToken.safeTransferFrom(msg.sender, address(this), _params.collAmount);

        uint256 troveId;
        // Include sender in index
        uint256 index = _getTroveIndex(_params.ownerIndex);
        if (_params.batchManager == address(0)) {
            troveId = borrowerOperations.openTrove(
                _params.owner,
                index,
                _params.collAmount,
                _params.boldAmount,
                _params.upperHint,
                _params.lowerHint,
                _params.annualInterestRate,
                _params.maxUpfrontFee,
                // Add this contract as add/receive manager to be able to fully adjust trove,
                // while keeping the same management functionality
                address(this), // add manager
                address(this), // remove manager
                address(this) // receiver for remove manager
            );
        } else {
            IBorrowerOperations.OpenTroveAndJoinInterestBatchManagerParams memory
                openTroveAndJoinInterestBatchManagerParams = IBorrowerOperations
                    .OpenTroveAndJoinInterestBatchManagerParams({
                    owner: _params.owner,
                    ownerIndex: index,
                    collAmount: _params.collAmount,
                    boldAmount: _params.boldAmount,
                    upperHint: _params.upperHint,
                    lowerHint: _params.lowerHint,
                    interestBatchManager: _params.batchManager,
                    maxUpfrontFee: _params.maxUpfrontFee,
                    // Add this contract as add/receive manager to be able to fully adjust trove,
                    // while keeping the same management functionality
                    addManager: address(this), // add manager
                    removeManager: address(this), // remove manager
                    receiver: address(this) // receiver for remove manager
                });
            troveId =
                borrowerOperations.openTroveAndJoinInterestBatchManager(openTroveAndJoinInterestBatchManagerParams);
        }

		// Forward only this swap's proceeds, leaving any pre-existing USDG untouched.
		uint256 usdgBalanceBefore = usdg.balanceOf(address(this));
		exchange.swapFromBold(_params.boldAmount, _params.usdgAmount);
		uint256 usdgReceived = usdg.balanceOf(address(this)) - usdgBalanceBefore;
		require(usdgReceived >= _params.usdgAmount, "USDGZapper: insufficient output");
		usdg.safeTransfer(msg.sender, usdgReceived);

        // Set add/remove managers
        _setAddManager(troveId, _params.addManager);
        _setRemoveManagerAndReceiver(troveId, _params.removeManager, _params.receiver);

        return troveId;
    }

    function openTroveWithRawETHPermitSwap(
        PermitParams calldata _permit,
        OpenTroveParams calldata _params
    ) external payable returns (uint256) {
        return 0;
    }

    function openTroveWithRawETH(
        OpenTroveParams calldata _params
    ) public payable returns (uint256) {
        return 0;
    }

    function addColl(uint256 _troveId, uint256 _amount) external {}

    function withdrawColl(uint256 _troveId, uint256 _amount) external {}

    function withdrawBold(uint256 _troveId, uint256 _boldAmount, uint256 _maxUpfrontFee) external {}

    function repayBold(uint256 _troveId, uint256 _boldAmount) external {}

    function adjustTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _boldChange,
        bool _isDebtIncrease,
        uint256 _maxUpfrontFee
    ) external {}

    function adjustZombieTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _boldChange,
        bool _isDebtIncrease,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external {}

    function _adjustTrovePre(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _boldChange,
        bool _isDebtIncrease,
        InitialBalances memory _initialBalances
    ) internal returns (address) {}

    function closeTroveToRawETH(uint256 _troveId) external {}

    function closeTroveFromCollateral(uint256 _troveId, uint256 _flashLoanAmount, uint256 _minExpectedCollateral)
        external
        override
    {}

    function receiveFlashLoanOnCloseTroveFromCollateral(
        CloseTroveParams calldata _params,
        uint256 _effectiveFlashLoanAmount
    ) external override {}

    receive() external payable {}

    // Unimplemented flash loan receive functions for leverage
    function receiveFlashLoanOnOpenLeveragedTrove(
        ILeverageZapper.OpenLeveragedTroveParams calldata _params,
        uint256 _effectiveFlashLoanAmount
    ) external override {}
    function receiveFlashLoanOnLeverUpTrove(
        ILeverageZapper.LeverUpTroveParams calldata _params,
        uint256 _effectiveFlashLoanAmount
    ) external override {}
	function receiveFlashLoanOnLeverDownTrove(
		ILeverageZapper.LeverDownTroveParams calldata _params,
		uint256 _effectiveFlashLoanAmount
	) external override {}
}
