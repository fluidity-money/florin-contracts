// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./TestContracts/DevTestSetup.sol";
import "./TestContracts/ChainlinkOracleMock.sol";
import "src/PriceFeeds/SPYPriceFeed.sol";

contract OperationsStockPauseSignal {
    bool public paused;

    function setPaused(bool value) external {
        paused = value;
    }
}

contract OperationsFeedBridge {
    SPYPriceFeed public immutable feed;

    constructor(SPYPriceFeed value) {
        feed = value;
    }

    function fetchPrice() external returns (OracleAnswer memory) {
        return feed.fetchPrice();
    }

    function fetchRedemptionPrice() external returns (OracleAnswer memory) {
        return feed.fetchRedemptionPrice();
    }

    function fetchPriceNoPauseCheck() external returns (uint256, bool) {
        return feed.fetchPriceNoPauseCheck();
    }

    function fetchRedemptionPriceNoPauseCheck() external returns (uint256, bool) {
        return feed.fetchRedemptionPriceNoPauseCheck();
    }

    function isStockPaused() external view returns (bool) {
        return feed.isStockPaused();
    }

    function lastGoodPrice() external view returns (uint256) {
        return feed.lastGoodPrice();
    }
}

abstract contract StockPauseOperationsSetup is DevTestSetup {
    uint256 constant OPEN_TIME = 1793638800; // Monday 2026-11-02, noon New York
    uint256 constant MAX_FEE = type(uint256).max;
    SPYPriceFeed internal stockFeed;
    OperationsStockPauseSignal internal stock;
    ChainlinkOracleMock internal oracle;
    uint256 internal aId;
    uint256 internal bId;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(OPEN_TIME);
        oracle = new ChainlinkOracleMock();
        oracle.setDecimals(8);
        oracle.setPrice(2000e8);
        ChainlinkOracleMock sequencer = new ChainlinkOracleMock(); // status 0: up
        stock = new OperationsStockPauseSignal();
        uint256 hoursWord;
        for (uint256 day = 1; day <= 5; day++) {
            hoursWord |= uint256(19 | (13 << 6)) << (day * 12);
        }
        HolidayWord[] memory holidays = new HolidayWord[](1);
        holidays[0] = HolidayWord(0, 0); // nonempty constructor input, no holiday
        stockFeed = new SPYPriceFeed(
            address(oracle), address(borrowerOperations), address(stock), address(sequencer), hoursWord, holidays, address(0)
        );
        vm.etch(address(priceFeed), address(new OperationsFeedBridge(stockFeed)).code);
        assertFalse(stockFeed.isStockPaused());
        aId = openTroveNoHints100pct(A, 20e18, 10000e18, 5e16);
        bId = openTroveNoHints100pct(B, 100e18, 20000e18, 6e16);
        vm.prank(D);
        borrowerOperations.registerBatchManager(1e16, 1e17, 5e16, 1e15, 1 hours);
        vm.prank(E);
        borrowerOperations.registerBatchManager(1e16, 1e17, 6e16, 1e15, 1 hours);
    }

    // cause 0=calendar, 1=token, 2=both; all calls still have a healthy oracle.
    function _pause(uint8 cause) internal {
        cause = uint8(bound(cause, 0, 2));
        vm.warp(cause == 1 ? OPEN_TIME : OPEN_TIME + 8 hours);
        stock.setPaused(cause != 0);
        assertEq(stockFeed.isStockMarketNonMarketHours(block.timestamp), cause != 1);
        assertEq(stock.paused(), cause != 0);
        OracleAnswer memory answer = priceFeed.fetchPrice();
        assertTrue(answer.stockPaused);
        assertFalse(answer.oracleDown);
        assertEq(answer.lastGoodPrice, uint256(oraclePrice()));
        assertFalse(borrowerOperations.hasBeenShutDown());
    }

    function oraclePrice() internal view returns (int256) {
        (, int256 answer,,,) = oracle.latestRoundData();
        return answer * 1e10;
    }

    function _unpause() internal {
        // Move forward, never backwards: same market time the following Monday.
        vm.warp(OPEN_TIME + ((block.timestamp - OPEN_TIME) / 7 days + 1) * 7 days);
        stock.setPaused(false);
        assertFalse(stockFeed.isStockPaused());
    }

    function _open(bool batch) internal returns (uint256) {
        if (!batch) {
            return borrowerOperations.openTrove(
                C, 0, 20e18, 10000e18, 0, 0, 5e16, MAX_FEE, address(0), address(0), address(0)
            );
        }
        return borrowerOperations.openTroveAndJoinInterestBatchManager(
            IBorrowerOperations.OpenTroveAndJoinInterestBatchManagerParams(
                C, 0, 20e18, 10000e18, 0, 0, D, MAX_FEE, address(0), address(0), address(0)
            )
        );
    }
}

contract StockPauseOperationsTest is StockPauseOperationsSetup {
    function test_openTroveRevertsWhenStockTokenPaused() public {
        stock.setPaused(true);
        vm.prank(C);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        _open(false);
        assertEq(troveManager.getTroveIdsCount(), 2);
    }

    function test_withdrawCollRevertsWhenStockTokenPaused() public {
        stock.setPaused(true);
        uint256 collateral = troveManager.getTroveColl(aId);
        vm.prank(A);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.withdrawColl(aId, 1e18);
        assertEq(troveManager.getTroveColl(aId), collateral);
    }

    function test_redemptionRevertsWhenStockTokenPaused() public {
        stock.setPaused(true);
        uint256 wallet = boldToken.balanceOf(B);
        vm.prank(B);
        vm.expectRevert(TroveManager.StockMarketPaused.selector);
        collateralRegistry.redeemCollateral(100e18, 10, 1e18);
        assertEq(boldToken.balanceOf(B), wallet);
    }

    function testFuzz_openDisabledWithPositiveControl(uint8 cause, bool batch) public {
        _pause(cause);
        vm.startPrank(C);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        _open(batch);
        vm.stopPrank();
        assertEq(troveManager.getTroveIdsCount(), 2);
        _unpause();
        vm.prank(C);
        uint256 id = _open(batch);
        assertEq(troveManager.getTroveColl(id), 20e18);
        assertEq(boldToken.balanceOf(C), 10000e18);
    }

    function testFuzz_withdrawalsDisabledWithPositiveControls(uint8 cause, uint256 amount) public {
        amount = bound(amount, 1e12, 1e18);
        _pause(cause);
        vm.startPrank(A);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.withdrawColl(aId, amount);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.withdrawBold(aId, amount, MAX_FEE);
        vm.stopPrank();
        assertEq(troveManager.getTroveColl(aId), 20e18);
        _unpause();
        uint256 wallet = boldToken.balanceOf(A);
        vm.startPrank(A);
        borrowerOperations.withdrawColl(aId, amount);
        borrowerOperations.withdrawBold(aId, amount, MAX_FEE);
        vm.stopPrank();
        assertEq(troveManager.getTroveColl(aId), 20e18 - amount);
        assertEq(boldToken.balanceOf(A), wallet + amount);
    }

    function testFuzz_addAndRepayEnabled(uint8 cause, uint256 coll, uint256 debt) public {
        coll = bound(coll, 1e12, 5e18);
        debt = bound(debt, 1e12, 1000e18);
        _pause(cause);
        uint256 beforeDebt = troveManager.getLatestTroveData(aId).entireDebt;
        uint256 wallet = boldToken.balanceOf(A);
        vm.startPrank(A);
        borrowerOperations.addColl(aId, coll);
        borrowerOperations.repayBold(aId, debt);
        vm.stopPrank();
        assertEq(troveManager.getTroveColl(aId), 20e18 + coll);
        assertEq(troveManager.getLatestTroveData(aId).entireDebt, beforeDebt - debt);
        assertEq(boldToken.balanceOf(A), wallet - debt);
    }

    function testFuzz_adjustFlags(uint8 cause, bool collIncrease, bool debtIncrease, uint256 coll, uint256 debt)
        public
    {
        coll = bound(coll, 0, 1e18);
        debt = bound(debt, 0, 100e18);
        if (coll == 0 && debt == 0) debt = 1; // valid, non-no-op adjustment
        _pause(cause);
        bool allowed = collIncrease && !debtIncrease;
        vm.startPrank(A);
        if (!allowed) vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.adjustTrove(aId, coll, collIncrease, debt, debtIncrease, MAX_FEE);
        vm.stopPrank();
        if (!allowed) {
            assertEq(troveManager.getTroveColl(aId), 20e18);
            _unpause();
            vm.prank(A);
            borrowerOperations.adjustTrove(aId, coll, collIncrease, debt, debtIncrease, MAX_FEE);
        }
        assertEq(troveManager.getTroveColl(aId), collIncrease ? 20e18 + coll : 20e18 - coll);
        assertEq(boldToken.balanceOf(A), debtIncrease ? 10000e18 + debt : 10000e18 - debt);
    }

    function testFuzz_interestPendingDebtAndCloseEnabled(uint8 cause) public {
        _pause(cause);
        vm.prank(A);
        borrowerOperations.adjustTroveInterestRate(aId, 7e16, 0, 0, MAX_FEE);
        assertEq(troveManager.getTroveAnnualInterestRate(aId), 7e16);
        uint256 recordedDebt = troveManager.getTroveDebt(aId);
        vm.warp(block.timestamp + 7 days);
        assertTrue(stockFeed.isStockPaused());
        borrowerOperations.applyPendingDebt(aId, 0, 0);
        assertGt(troveManager.getTroveDebt(aId), recordedDebt);
        vm.prank(B);
        boldToken.transfer(A, 1000e18);
        uint256 collBefore = collToken.balanceOf(A);
        uint256 debt = troveManager.getLatestTroveData(aId).entireDebt;
        uint256 wallet = boldToken.balanceOf(A);
        vm.prank(A);
        borrowerOperations.closeTrove(aId);
        assertEq(uint256(troveManager.getTroveStatus(aId)), uint256(ITroveManager.Status.closedByOwner));
        assertEq(collToken.balanceOf(A), collBefore + 20e18 + ETH_GAS_COMPENSATION);
        assertEq(boldToken.balanceOf(A), wallet - debt);
    }

    function testFuzz_batchManagementEnabled(uint8 cause) public {
        _pause(cause);
        vm.warp(block.timestamp + 1 hours);
        assertTrue(stockFeed.isStockPaused());
        vm.prank(A);
        borrowerOperations.setInterestBatchManager(aId, D, 0, 0, MAX_FEE);
        assertEq(borrowerOperations.interestBatchManagerOf(aId), D);
        vm.prank(D);
        borrowerOperations.setBatchManagerAnnualInterestRate(7e16, 0, 0, MAX_FEE);
        assertEq(troveManager.getLatestBatchData(D).annualInterestRate, 7e16);
        vm.prank(A);
        borrowerOperations.switchBatchManager(aId, 0, 0, E, 0, 0, MAX_FEE);
        assertEq(borrowerOperations.interestBatchManagerOf(aId), E);
        vm.prank(A);
        borrowerOperations.removeFromBatch(aId, 8e16, 0, 0, MAX_FEE);
        assertEq(borrowerOperations.interestBatchManagerOf(aId), address(0));
        assertEq(troveManager.getTroveAnnualInterestRate(aId), 8e16);
    }

    function testFuzz_interestAfterCooldownEnabled(uint8 cause) public {
        _pause(cause);
        vm.warp(block.timestamp + 7 days);
        assertTrue(stockFeed.isStockPaused());
        vm.prank(A);
        borrowerOperations.adjustTroveInterestRate(aId, 7e16, 0, 0, MAX_FEE);
        assertEq(troveManager.getTroveAnnualInterestRate(aId), 7e16);
        vm.prank(A);
        borrowerOperations.setInterestBatchManager(aId, D, 0, 0, MAX_FEE);
        vm.warp(block.timestamp + 7 days);
        assertTrue(stockFeed.isStockPaused());
        vm.prank(D);
        borrowerOperations.setBatchManagerAnnualInterestRate(8e16, 0, 0, MAX_FEE);
        assertEq(troveManager.getLatestBatchData(D).annualInterestRate, 8e16);
    }

    function testFuzz_batchedTroveOperations(uint8 cause, uint256 amount) public {
        amount = bound(amount, 1e12, 1e18);
        vm.prank(A);
        borrowerOperations.setInterestBatchManager(aId, D, 0, 0, MAX_FEE);
        _pause(cause);
        uint256 wallet = boldToken.balanceOf(A);
        vm.startPrank(A);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.withdrawColl(aId, amount);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.withdrawBold(aId, amount, MAX_FEE);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.adjustTrove(aId, amount, false, amount, true, MAX_FEE);
        borrowerOperations.addColl(aId, amount);
        borrowerOperations.repayBold(aId, amount);
        borrowerOperations.adjustTrove(aId, amount, true, amount, false, MAX_FEE);
        vm.stopPrank();
        assertEq(troveManager.getTroveColl(aId), 20e18 + 2 * amount);
        assertEq(boldToken.balanceOf(A), wallet - 2 * amount);
        uint256 recorded = troveManager.getTroveDebt(aId);
        vm.warp(block.timestamp + 7 days);
        assertTrue(stockFeed.isStockPaused());
        borrowerOperations.applyPendingDebt(aId, 0, 0);
        assertGt(troveManager.getTroveDebt(aId), recorded);
        vm.prank(B);
        boldToken.transfer(A, 1000e18);
        vm.prank(A);
        borrowerOperations.closeTrove(aId);
        assertEq(uint256(troveManager.getTroveStatus(aId)), uint256(ITroveManager.Status.closedByOwner));
    }

    function testFuzz_redemptionDisabledWithPositiveControl(uint8 cause) public {
        _pause(cause);
        vm.prank(B);
        vm.expectRevert(TroveManager.StockMarketPaused.selector);
        collateralRegistry.redeemCollateral(100e18, 10, 1e18);
        _unpause();
        uint256 wallet = boldToken.balanceOf(B);
        uint256 collateral = collToken.balanceOf(B);
        vm.prank(B);
        collateralRegistry.redeemCollateral(100e18, 10, 1e18);
        assertEq(boldToken.balanceOf(B), wallet - 100e18);
        assertGt(collToken.balanceOf(B), collateral);
    }

    function testFuzz_zombieAlwaysDisabled(uint8 cause, bool collIncrease, bool debtIncrease, uint256 amount) public {
        // Create a genuine zombie through redemption, just below MIN_DEBT.
        // Accrued interest subsequently makes every flag combination valid,
        // including collateral-in/debt-out (the former pause-policy loophole).
        uint256 redemption = troveManager.getLatestTroveData(aId).entireDebt - (MIN_DEBT - 1);
        vm.prank(B);
        collateralRegistry.redeemCollateral(redemption, 10, 1e18);
        assertEq(uint256(troveManager.getTroveStatus(aId)), uint256(ITroveManager.Status.zombie));
        _pause(cause);
        vm.warp(block.timestamp + 7 days);
        assertTrue(stockFeed.isStockPaused());
        amount = bound(amount, 1e12, 1e16);
        assertGt(troveManager.getLatestTroveData(aId).entireDebt, MIN_DEBT + amount);
        uint256 collateral = troveManager.getTroveColl(aId);
        vm.prank(A);
        vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.adjustZombieTrove(aId, amount, collIncrease, amount, debtIncrease, 0, 0, MAX_FEE);
        assertEq(troveManager.getTroveColl(aId), collateral);
        assertEq(uint256(troveManager.getTroveStatus(aId)), uint256(ITroveManager.Status.zombie));
        _unpause();
        vm.prank(A);
        borrowerOperations.adjustZombieTrove(aId, amount, collIncrease, amount, debtIncrease, 0, 0, MAX_FEE);
        assertEq(uint256(troveManager.getTroveStatus(aId)), uint256(ITroveManager.Status.active));
        assertEq(troveManager.getTroveColl(aId), collIncrease ? collateral + amount : collateral - amount);
        assertTrue(sortedTroves.contains(aId));
    }

    function testFuzz_urgentRedemptionEnabledAfterShutdown(uint8 cause) public {
        _pause(cause);
        uint256[] memory ids = new uint256[](1);
        ids[0] = bId;
        vm.prank(A);
        vm.expectRevert(TroveManager.NotShutDown.selector);
        troveManager.urgentRedemption(100e18, ids, 0);
        oracle.setPrice(100e8);
        borrowerOperations.shutdown();
        assertTrue(borrowerOperations.hasBeenShutDown());
        assertTrue(stockFeed.isStockPaused());
        uint256 wallet = boldToken.balanceOf(A);
        uint256 collateral = collToken.balanceOf(A);
        vm.prank(A);
        troveManager.urgentRedemption(100e18, ids, 0);
        assertEq(boldToken.balanceOf(A), wallet - 100e18);
        assertGt(collToken.balanceOf(A), collateral);
    }

    function testFuzz_spYieldRewardsEnabled(uint8 cause) public {
        _pause(cause);
        vm.prank(A);
        stabilityPool.provideToSP(5000e18, true);
        vm.warp(block.timestamp + 7 days);
        assertTrue(stockFeed.isStockPaused());
        borrowerOperations.applyPendingDebt(bId, 0, 0);
        uint256 gain = stabilityPool.getDepositorYieldGain(A);
        assertGt(gain, 0);
        uint256 wallet = boldToken.balanceOf(A);
        vm.prank(A);
        stabilityPool.withdrawFromSP(0, true);
        assertGe(boldToken.balanceOf(A), wallet + gain);
        assertEq(stabilityPool.getDepositorYieldGain(A), 0);
        assertEq(stabilityPool.getCompoundedBoldDeposit(A), 5000e18);
    }

    // Deterministic coverage complements fuzzing: no reliance on the seed to
    // select every cause, opening mode, or adjustment flag combination.
    function test_allPauseCausesAndFlags() public {
        uint256 snap = vm.snapshotState();
        for (uint8 cause; cause < 3; cause++) {
            testFuzz_addAndRepayEnabled(cause, 1e18, 100e18);
            assertTrue(vm.revertToState(snap));
            testFuzz_withdrawalsDisabledWithPositiveControls(cause, 1e18);
            assertTrue(vm.revertToState(snap));
            testFuzz_interestPendingDebtAndCloseEnabled(cause);
            assertTrue(vm.revertToState(snap));
            testFuzz_batchedTroveOperations(cause, 1e18);
            assertTrue(vm.revertToState(snap));
            testFuzz_interestAfterCooldownEnabled(cause);
            assertTrue(vm.revertToState(snap));
            testFuzz_batchManagementEnabled(cause);
            assertTrue(vm.revertToState(snap));
            testFuzz_redemptionDisabledWithPositiveControl(cause);
            assertTrue(vm.revertToState(snap));
            testFuzz_urgentRedemptionEnabledAfterShutdown(cause);
            assertTrue(vm.revertToState(snap));
            testFuzz_liquidationAndSPEnabled(cause, 5000e18);
            assertTrue(vm.revertToState(snap));
            testFuzz_spYieldRewardsEnabled(cause);
            assertTrue(vm.revertToState(snap));
            for (uint256 flags; flags < 4; flags++) {
                bool collIncrease = flags & 1 != 0;
                bool debtIncrease = flags & 2 != 0;
                testFuzz_adjustFlags(cause, collIncrease, debtIncrease, 1e18, 100e18);
                assertTrue(vm.revertToState(snap));
                testFuzz_adjustFlags(cause, collIncrease, debtIncrease, 0, 100e18);
                assertTrue(vm.revertToState(snap));
                testFuzz_adjustFlags(cause, collIncrease, debtIncrease, 1e18, 0);
                assertTrue(vm.revertToState(snap));
                testFuzz_zombieAlwaysDisabled(cause, collIncrease, debtIncrease, 1e16);
                assertTrue(vm.revertToState(snap));
            }
            testFuzz_openDisabledWithPositiveControl(cause, false);
            assertTrue(vm.revertToState(snap));
            testFuzz_openDisabledWithPositiveControl(cause, true);
            assertTrue(vm.revertToState(snap));
        }
    }

    function testFuzz_liquidationAndSPEnabled(uint8 cause, uint256 deposit) public {
        deposit = bound(deposit, 5000e18, 9000e18);
        uint256 cId = openTroveNoHints100pct(C, 2e18, 2000e18, 5e16);
        _pause(cause);
        vm.prank(A);
        stabilityPool.provideToSP(deposit, true);
        assertEq(stabilityPool.getCompoundedBoldDeposit(A), deposit);
        oracle.setPrice(1000e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = cId;
        troveManager.batchLiquidateTroves(ids);
        assertEq(uint256(troveManager.getTroveStatus(cId)), uint256(ITroveManager.Status.closedByLiquidation));
        assertGt(stabilityPool.getDepositorCollGain(A), 0);
        uint256 coll = collToken.balanceOf(A);
        vm.prank(A);
        stabilityPool.withdrawFromSP(0, true);
        assertGt(collToken.balanceOf(A), coll);
        assertEq(stabilityPool.getDepositorCollGain(A), 0);
        uint256 wallet = boldToken.balanceOf(A);
        uint256 compounded = stabilityPool.getCompoundedBoldDeposit(A);
        vm.prank(A);
        stabilityPool.withdrawFromSP(compounded - 1e18, true);
        assertEq(stabilityPool.getCompoundedBoldDeposit(A), 1e18);
        assertGe(boldToken.balanceOf(A), wallet + compounded - 1e18);
    }
}
