// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockStakingV1} from "V2-gov/test/mocks/MockStakingV1.sol";
import {Ownable} from "src/Dependencies/Ownable.sol";
import "./Utils/E2EHelpers.sol";

contract E2ETest is E2EHelpers {
    using SideEffectFreeGetPrice for IPriceFeedV1;

    address[] ownables;

    function _mainnet_V1_openTroveAtTail(address owner, uint256 lusdAmount) internal returns (uint256 borrowingFee) {
        uint256 price = mainnet_V1_priceFeed.getPrice();
        address lastTrove = mainnet_V1_sortedTroves.getLast();
        assertGeDecimal(mainnet_V1_troveManager.getCurrentICR(lastTrove, price), 1.1 ether, 18, "last ICR < MCR");

        uint256 borrowingRate = mainnet_V1_troveManager.getBorrowingRateWithDecay();
        borrowingFee = lusdAmount * borrowingRate / 1 ether;
        uint256 debt = lusdAmount + borrowingFee + 200 ether;
        uint256 collAmount = Math.ceilDiv(debt * 1.1 ether, price);
        deal(owner, collAmount);

        vm.startPrank(owner);
        mainnet_V1_borrowerOperations.openTrove{value: collAmount}({
            _LUSDAmount: lusdAmount, _maxFeePercentage: borrowingRate, _upperHint: lastTrove, _lowerHint: address(0)
        });
        vm.stopPrank();

        assertEq(mainnet_V1_sortedTroves.getLast(), owner, "last Trove != new Trove");
    }

    function _mainnet_V1_redeemCollateralFromTroveAtTail(address redeemer, uint256 lusdAmount)
        internal
        returns (uint256 redemptionFee)
    {
        address lastTrove = mainnet_V1_sortedTroves.getLast();
        address prevTrove = mainnet_V1_sortedTroves.getPrev(lastTrove);
        (uint256 lastTroveDebt, uint256 lastTroveColl,,) = mainnet_V1_troveManager.getEntireDebtAndColl(lastTrove);
        assertLeDecimal(lusdAmount, lastTroveDebt - 2_000 ether, 18, "lusdAmount > redeemable from last Trove");

        uint256 price = mainnet_V1_priceFeed.getPrice();
        uint256 collAmount = lusdAmount * 1 ether / price;
        uint256 balanceBefore = redeemer.balance;

        vm.startPrank(redeemer);
        mainnet_V1_troveManager.redeemCollateral({
            _LUSDamount: lusdAmount,
            _maxFeePercentage: 1 ether,
            _maxIterations: 1,
            _firstRedemptionHint: lastTrove,
            _upperPartialRedemptionHint: prevTrove,
            _lowerPartialRedemptionHint: prevTrove,
            _partialRedemptionHintNICR: (lastTroveColl - collAmount) * 100 ether / (lastTroveDebt - lusdAmount)
        });
        vm.stopPrank();

        redemptionFee = collAmount * mainnet_V1_troveManager.getBorrowingRateWithDecay() / 1 ether;
        assertEqDecimal(redeemer.balance - balanceBefore, collAmount - redemptionFee, 18, "coll received != expected");
    }

    function _generateStakingRewards() internal returns (uint256 lusdAmount, uint256 ethAmount) {
        if (block.chainid == 1) {
            address stakingRewardGenerator = makeAddr("stakingRewardGenerator");
            lusdAmount = _mainnet_V1_openTroveAtTail(stakingRewardGenerator, 1e6 ether);
            ethAmount = _mainnet_V1_redeemCollateralFromTroveAtTail(stakingRewardGenerator, 1_000 ether);
        } else {
            // Testnet
            lusdAmount = 10_000 ether;
            ethAmount = 1 ether;

            MockStakingV1 stakingV1 = MockStakingV1(address(governance.stakingV1()));
            address owner = stakingV1.owner();

            deal(LUSD, owner, lusdAmount);
            deal(owner, ethAmount);

            vm.startPrank(owner);
            lusd.approve(address(stakingV1), lusdAmount);
            stakingV1.mock_addLUSDGain(lusdAmount);
            stakingV1.mock_addETHGain{value: ethAmount}();
            vm.stopPrank();
        }
    }

    function test_OwnershipRenounced() external {
        ownables.push(address(boldToken));

        for (uint256 i = 0; i < branches.length; ++i) {
            ownables.push(address(branches[i].addressesRegistry));
        }

        for (uint256 i = 0; i < ownables.length; ++i) {
            assertEq(
                Ownable(ownables[i]).owner(),
                address(0),
                string.concat("Ownership of ", vm.getLabel(ownables[i]), " should have been renounced")
            );
        }
    }

    function _epoch(uint256 n) internal view returns (uint256) {
        return EPOCH_START + (n - 1) * EPOCH_DURATION;
    }

    function test_Initially_NewInitiativeCannotBeRegistered() external {
        vm.skip(governance.epoch() > 2);

        address registrant = makeAddr("registrant");
        address newInitiative = makeAddr("newInitiative");

        _openTrove(0, registrant, 0, Math.max(REGISTRATION_FEE, MIN_DEBT));

        uint256 epoch2 = _epoch(2);
        if (block.timestamp < epoch2) vm.warp(epoch2);

        vm.startPrank(registrant);
        {
            boldToken.approve(address(governance), REGISTRATION_FEE);
            vm.expectRevert("Governance: registration-not-yet-enabled");
            governance.registerInitiative(newInitiative);
        }
        vm.stopPrank();
    }

    function test_AfterOneEpoch_NewInitiativeCanBeRegistered() external {
        vm.skip(governance.epoch() > 2);

        address registrant = makeAddr("registrant");
        address newInitiative = makeAddr("newInitiative");

        _openTrove(0, registrant, 0, Math.max(REGISTRATION_FEE, MIN_DEBT));

        uint256 epoch3 = _epoch(3);
        if (block.timestamp < epoch3) vm.warp(epoch3);

        vm.startPrank(registrant);
        {
            boldToken.approve(address(governance), REGISTRATION_FEE);
            governance.registerInitiative(newInitiative);
        }
        vm.stopPrank();
    }

    function test_E2E() external {
        // Test assumes that all Stability Pools are empty in the beginning
        for (uint256 i = 0; i < branches.length; ++i) {
            vm.skip(branches[i].stabilityPool.getTotalBoldDeposits() != 0);
        }

        uint256 borrowed = boldToken.totalSupply() - boldToken.balanceOf(address(governance));

        for (uint256 i = 0; i < branches.length; ++i) {
            borrowed -= boldToken.balanceOf(address(branches[i].stabilityPool));
        }

        if (block.chainid == 1) {
            assertEqDecimal(borrowed, 0, 18, "Mainnet deployment script should not have borrowed anything");
            assertNotEq(address(defiCollectiveInitiative), address(0), "Mainnet should have DeFi Collective initiative");
        }

        address borrower = providerOf[BOLD] = makeAddr("borrower");

        for (uint256 j = 0; j < 5; ++j) {
            for (uint256 i = 0; i < branches.length; ++i) {
                skip(5 minutes);
                borrowed += _openTrove(i, borrower, j, 20_000 ether);
            }
        }

        address stabilityDepositor = makeAddr("stabilityDepositor");

        for (uint256 i = 0; i < branches.length; ++i) {
            skip(5 minutes);
            _provideToSP(i, stabilityDepositor, boldToken.balanceOf(borrower) / (branches.length - i));
        }

        address staker = makeAddr("staker");
        {
            uint256 lqtyStake = 30_000 ether;
            _depositLQTY(staker, lqtyStake);

            skip(5 minutes);

            (uint256 lusdAmount, uint256 ethAmount) = _generateStakingRewards();
            uint256 totalLQTYStaked = governance.stakingV1().totalLQTYStaked();

            skip(5 minutes);

            vm.prank(staker);
            governance.claimFromStakingV1(staker);

            assertApproxEqAbsDecimal(
                lusd.balanceOf(staker), lusdAmount * lqtyStake / totalLQTYStaked, 1e5, 18, "LUSD reward"
            );
            assertApproxEqAbsDecimal(staker.balance, ethAmount * lqtyStake / totalLQTYStaked, 1e5, 18, "ETH reward");

            skip(5 minutes);

            if (initialInitiatives.length > 0) {
                // Voting on initial initiatives opens in epoch #2
                uint256 votingStart = _epoch(2);
                if (block.timestamp < votingStart) vm.warp(votingStart);

                _allocateLQTY_begin(staker);

                for (uint256 i = 0; i < initialInitiatives.length; ++i) {
                    _allocateLQTY_vote(initialInitiatives[i], int256(lqtyStake / initialInitiatives.length));
                }

                _allocateLQTY_end();
            }
        }

        skip(EPOCH_DURATION);

        for (uint256 i = 0; i < branches.length; ++i) {
            skip(5 minutes);
            _claimFromSP(i, stabilityDepositor);
        }

        uint256 interest = boldToken.totalSupply() - borrowed;
        uint256 spShareOfInterest = boldToken.balanceOf(stabilityDepositor);
        uint256 governanceShareOfInterest = boldToken.balanceOf(address(governance));

        assertApproxEqRelDecimal(
            interest,
            spShareOfInterest + governanceShareOfInterest,
            1e-16 ether,
            18,
            "Stability depositor and Governance should have received the interest"
        );

        if (initialInitiatives.length > 0) {
            uint256 initiativeShareOfInterest;

            for (uint256 i = 0; i < initialInitiatives.length; ++i) {
                governance.claimForInitiative(initialInitiatives[i]);
                initiativeShareOfInterest += boldToken.balanceOf(initialInitiatives[i]);
            }

            assertApproxEqRelDecimal(
                governanceShareOfInterest,
                initiativeShareOfInterest,
                1e-15 ether,
                18,
                "Initiatives should have received the interest from Governance"
            );
        }
    }

    // This can be used to check that everything's still working as expected in a live testnet deployment
    function test_Borrowing_InExistingDeployment() external {
        for (uint256 i = 0; i < branches.length; ++i) {
            vm.skip(branches[i].troveManager.getTroveIdsCount() == 0);
        }

        address borrower = makeAddr("borrower");

        for (uint256 i = 0; i < branches.length; ++i) {
            _openTrove(i, borrower, 0, 10_000 ether);
        }
    }
}
