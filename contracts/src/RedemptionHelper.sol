// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {_100pct, DECIMAL_PRECISION} from "./Dependencies/Constants.sol";
import {IAddressesRegistry} from "./Interfaces/IAddressesRegistry.sol";
import {IBoldToken} from "./Interfaces/IBoldToken.sol";
import {ICollateralRegistry} from "./Interfaces/ICollateralRegistry.sol";
import {IRedemptionHelper} from "./Interfaces/IRedemptionHelper.sol";
import {ISortedTroves} from "./Interfaces/ISortedTroves.sol";
import {ITroveManager} from "./Interfaces/ITroveManager.sol";
import {LatestTroveData} from "./Types/LatestTroveData.sol";
import {Ownable} from "src/Dependencies/Ownable.sol";

contract RedemptionHelper is IRedemptionHelper, Ownable {
    using SafeERC20 for IERC20;

    event AddressesRegistryAdded(IAddressesRegistry addressesRegistry);

    struct RedemptionContext {
        IERC20 collToken;
        uint256 collBalanceBefore;
    }

    ICollateralRegistry public immutable collateralRegistry;
    IBoldToken public immutable boldToken;
    IAddressesRegistry[] public addresses; // only used off-chain, so we don't care about storage cost

    constructor(
        ICollateralRegistry _collateralRegistry,
        IAddressesRegistry[] memory _addresses,
        address _governance
    ) Ownable(_governance) {
        require(_addresses.length == _collateralRegistry.totalCollaterals(), "Wrong number of registries");
        collateralRegistry = _collateralRegistry;
        boldToken = _collateralRegistry.boldToken();

        for (uint256 i = 0; i < _addresses.length; ++i) {
            require(_collateralRegistry.getTroveManager(i) == _addresses[i].troveManager(), "TroveManager mismatch");
            addresses.push(_addresses[i]);
        }
    }

    function numBranches() public view returns (uint256) {
        return collateralRegistry.totalCollaterals();
    }

    function addAddressesRegistry(IAddressesRegistry _addressesRegistry) external onlyOwner {
        require(address(0) != address(_addressesRegistry), "Invalid AddressesRegistry");
        addresses.push(_addressesRegistry);
        emit AddressesRegistryAdded(_addressesRegistry);
    }

    // Meant to be called off-chain
    // Not a view because price fetching has side-effects
    function simulateRedemption(uint256 _bold, uint256 _maxIterationsPerCollateral)
        public
        returns (SimulationContext[] memory branch, uint256 totalProportions)
    {
        uint numBranches_ = numBranches();
        branch = new SimulationContext[](numBranches_);

        // First priority: proportional to unbacked debt
        for (uint256 i = 0; i < numBranches_; ++i) {
            branch[i].troveManager = address(addresses[i].troveManager());
            branch[i].sortedTroves = address(addresses[i].sortedTroves());
            (branch[i].proportion, branch[i].price, branch[i].redeemable) =
                ITroveManager(branch[i].troveManager).getUnbackedPortionPriceAndRedeemability();
            if (branch[i].redeemable) totalProportions += branch[i].proportion;
        }

        // CS-BOLD-013: truncate redemption if it would exceed total unbacked debt
        if (0 < totalProportions && totalProportions < _bold) _bold = totalProportions;

        // Fallback: proportional to total debt
        if (totalProportions == 0) {
            for (uint256 i = 0; i < numBranches_; ++i) {
                branch[i].proportion = ITroveManager(branch[i].troveManager).getEntireBranchDebt();
                if (branch[i].redeemable) totalProportions += branch[i].proportion;
            }
        }

        if (totalProportions == 0) return (branch, totalProportions);

        for (uint256 i = 0; i < numBranches_; ++i) {
            if (!branch[i].redeemable) continue;

            branch[i].attemptedBold = _bold * branch[i].proportion / totalProportions;
            if (branch[i].attemptedBold == 0) continue;

            uint256 lastZombieTroveId = ITroveManager(branch[i].troveManager).lastZombieTroveId();
            uint256 lastTroveId = ISortedTroves(branch[i].sortedTroves).getLast();

            (uint256 troveId, uint256 nextTroveId) = lastZombieTroveId != 0
                ? (lastZombieTroveId, lastTroveId)
                : (lastTroveId, ISortedTroves(branch[i].sortedTroves).getPrev(lastTroveId));

            for (
                branch[i].iterations = 0;
                branch[i].iterations < _maxIterationsPerCollateral || _maxIterationsPerCollateral == 0;
                ++branch[i].iterations
            ) {
                if (branch[i].redeemedBold == branch[i].attemptedBold || troveId == 0) break;

                LatestTroveData memory trove = ITroveManager(branch[i].troveManager).getLatestTroveData(troveId);
                if (trove.entireColl * branch[i].price / trove.entireDebt >= _100pct) {
                    branch[i].redeemedBold +=
                        Math.min(branch[i].attemptedBold - branch[i].redeemedBold, trove.entireDebt);
                }

                troveId = nextTroveId;
                nextTroveId = ISortedTroves(branch[i].sortedTroves).getPrev(nextTroveId);
            }
        }
    }

    // Meant to be called off-chain
    // Not a view because price fetching has side-effects
    function truncateRedemption(uint256 _bold, uint256 _maxIterationsPerCollateral)
        external
        returns (uint256 truncatedBold, uint256 feePct, Redeemed[] memory redeemed)
    {
        (SimulationContext[] memory branch, uint256 totalProportions) =
            simulateRedemption(_bold, _maxIterationsPerCollateral);

        if (totalProportions == 0) return (0, 0, redeemed);

        uint numBranches_ = numBranches();

        truncatedBold = _bold;
        for (uint256 i = 0; i < numBranches_; ++i) {
            if (branch[i].redeemable && branch[i].proportion > 0) {
                // Extrapolate how much the entire redeemed BOLD would
                // have been if this branch was redeemed proportionally.
                uint256 extrapolatedBold = branch[i].redeemedBold * totalProportions / branch[i].proportion;

                // Normally this is no different from `_bold`, but can be less if the redemption on this branch
                // terminated due to hitting the iteration limit. We're looking for the smallest extrapolated value,
                // since that is the maximum amount of BOLD that can be redeemed proportionally within the given
                // iteration limit. Any attempt to redeem more than this would result in a partial redemption, thus
                // paying a higher redemption fee than necessary — since the fee is based on the attempted amount.
                if (extrapolatedBold < truncatedBold) truncatedBold = extrapolatedBold;
            }
        }

        feePct = collateralRegistry.getRedemptionRateForRedeemedAmount(truncatedBold);
        redeemed = new Redeemed[](numBranches_);

        for (uint256 i = 0; i < numBranches_; ++i) {
            if (branch[i].redeemable && branch[i].proportion > 0) {
                (uint256 redemptionPrice,) = addresses[i].priceFeed().fetchRedemptionPriceNoPauseCheck();
                redeemed[i].bold = truncatedBold * branch[i].proportion / totalProportions;
                redeemed[i].coll = redeemed[i].bold * (DECIMAL_PRECISION - feePct) / redemptionPrice;
            }
        }
    }

    function redeemCollateral(
        uint256 _bold,
        uint256 _maxIterationsPerCollateral,
        uint256 _maxFeePct,
        uint256[] memory _minCollRedeemed
    ) external {
        require(_bold > 0, "Redeemed amount must be non-zero");

        uint numBranches_ = numBranches();
        require(_minCollRedeemed.length == numBranches_, "Wrong _minCollRedeemed length");

        RedemptionContext[] memory branch = new RedemptionContext[](numBranches_);

        for (uint256 i = 0; i < numBranches_; ++i) {
            branch[i].collToken = collateralRegistry.getToken(i);
            branch[i].collBalanceBefore = branch[i].collToken.balanceOf(address(this));
        }

        uint256 boldBalanceBefore = boldToken.balanceOf(address(this));

        boldToken.transferFrom(msg.sender, address(this), _bold);
        collateralRegistry.redeemCollateral(_bold, _maxIterationsPerCollateral, _maxFeePct);

        for (uint256 i = 0; i < numBranches_; ++i) {
            uint256 collRedeemed = branch[i].collToken.balanceOf(address(this)) - branch[i].collBalanceBefore;
            require(collRedeemed >= _minCollRedeemed[i], "Insufficient collateral redeemed");
            if (collRedeemed > 0) branch[i].collToken.safeTransfer(msg.sender, collRedeemed);
        }

        uint256 boldRemaining = boldToken.balanceOf(address(this)) - boldBalanceBefore;
        if (boldRemaining > 0) boldToken.transfer(msg.sender, boldRemaining);
    }
}
