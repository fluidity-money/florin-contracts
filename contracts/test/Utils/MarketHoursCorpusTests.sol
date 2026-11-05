// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../StockPauseOperations.t.sol";
import {packUSMarketHours2027} from "script/EncodeMarketHours.s.sol";

// Exposes production DST logic: market closures on transition Sundays would
// otherwise mask an incorrect transition hour.
contract CalendarFeedHarness is SPYPriceFeed {
    constructor(address oracle, address stock, address sequencer, uint256 word, HolidayWord[] memory holidays)
        SPYPriceFeed(oracle, address(0), stock, sequencer, word, holidays, address(0))
    {}

    function isDST(uint256 ts) external view returns (bool) {
        return _isUsEasternDST(ts, stockMarketHoursWord);
    }
}

abstract contract CalendarCorpus {
    // Generated records are big-endian (uint64 start, uint64 end, uint8 expected),
    // with [start,end) bounds. Expected means OPEN for market data, DST for DST data.
    function marketCorpus() internal pure virtual returns (bytes memory);
    function fixedCorpus() internal pure virtual returns (bytes memory);
    function dstCorpus() internal pure virtual returns (bytes memory);

    function rangeAt(bytes memory data, uint256 index)
        internal
        pure
        returns (uint256 start, uint256 end, bool expected)
    {
        require(data.length % 17 == 0 && index < data.length / 17, "invalid corpus record");
        uint256 packed;
        assembly { packed := mload(add(add(data, 32), mul(index, 17))) }
        start = packed >> 192;
        end = (packed >> 128) & type(uint64).max;
        expected = ((packed >> 120) & 255) == 1;
        require(end > start, "empty range");
    }
}

abstract contract MarketHoursCorpusTests is Test, CalendarCorpus {
    CalendarFeedHarness internal feed;
    CalendarFeedHarness internal fixedFeed;
    OperationsStockPauseSignal internal stock;

    function setUp() public {
        vm.warp(1793638800);
        ChainlinkOracleMock oracle = new ChainlinkOracleMock();
        oracle.setDecimals(8);
        oracle.setPrice(2000e8);
        ChainlinkOracleMock sequencer = new ChainlinkOracleMock();
        stock = new OperationsStockPauseSignal();
        (uint256 word, HolidayWord[] memory holidays) = packUSMarketHours2027();
        feed = new CalendarFeedHarness(address(oracle), address(stock), address(sequencer), word, holidays);
        fixedFeed = new CalendarFeedHarness(
            address(oracle), address(stock), address(sequencer), word | (uint256(1) << 84), holidays
        );
    }

    function _sample(bytes memory data, uint256 rangeSeed, uint256 secondSeed)
        internal
        pure
        returns (uint256 ts, bool expected)
    {
        (uint256 start, uint256 end, bool value) = rangeAt(data, rangeSeed % (data.length / 17));
        return (start + secondSeed % (end - start), value);
    }

    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_marketRanges(uint256 rangeSeed, uint256 secondSeed, bool tokenPaused) public {
        (uint256 ts, bool open) = _sample(marketCorpus(), rangeSeed, secondSeed);
        vm.warp(ts);
        stock.setPaused(tokenPaused);
        assertEq(feed.isStockMarketNonMarketHours(ts), !open, "calendar");
        assertEq(feed.isStockPaused(), !open || tokenPaused, "combined pause");
        OracleAnswer memory answer = feed.fetchPrice();
        assertEq(answer.stockPaused, !open || tokenPaused, "fetchPrice pause");
        assertFalse(answer.oracleDown);
        assertEq(answer.lastGoodPrice, 2000e18);
        assertEq(feed.fetchRedemptionPrice().stockPaused, !open || tokenPaused, "redemption pause");
    }

    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_fixedOffsetRanges(uint256 rangeSeed, uint256 secondSeed) public view {
        (uint256 ts, bool open) = _sample(fixedCorpus(), rangeSeed, secondSeed);
        assertEq(fixedFeed.isStockMarketNonMarketHours(ts), !open);
        assertFalse(fixedFeed.isDST(ts));
    }

    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_dstRanges(uint256 rangeSeed, uint256 secondSeed) public view {
        (uint256 ts, bool dst) = _sample(dstCorpus(), rangeSeed, secondSeed);
        assertEq(feed.isDST(ts), dst);
        assertFalse(fixedFeed.isDST(ts));
    }

    // Every record is visited regardless of the fuzzer's seed. Test both sides
    // of each shared boundary, plus each interval's midpoint.
    function _checkAll(bytes memory data, uint256 mode) internal view {
        uint256 previousEnd;
        bool previousValue;
        for (uint256 i; i < data.length / 17; ++i) {
            (uint256 start, uint256 end, bool value) = rangeAt(data, i);
            if (i > 0) {
                assertEq(start, previousEnd, "corpus gap/overlap");
                _check(start - 1, previousValue, mode);
            }
            _check(start, value, mode);
            _check(start + 1, value, mode);
            _check(start + (end - start) / 2, value, mode);
            _check(end - 1, value, mode);
            previousEnd = end;
            previousValue = value;
        }
    }

    function _check(uint256 ts, bool value, uint256 mode) internal view {
        if (mode == 2) {
            assertEq(feed.isDST(ts), value, "DST boundary");
            assertFalse(fixedFeed.isDST(ts));
        } else {
            CalendarFeedHarness target = mode == 0 ? feed : fixedFeed;
            assertEq(target.isStockMarketNonMarketHours(ts), !value, "market boundary");
        }
    }

    function test_allMarketRangeBoundaries() public view {
        _checkAll(marketCorpus(), 0);
    }

    function test_allFixedRangeBoundaries() public view {
        _checkAll(fixedCorpus(), 1);
    }

    function test_allDSTRangeBoundaries() public view {
        _checkAll(dstCorpus(), 2);
    }

    function test_entireYearHalfHourly() public view {
        bytes memory data = marketCorpus();
        for (uint256 i; i < data.length / 17; ++i) {
            (uint256 start, uint256 end, bool open) = rangeAt(data, i);
            for (uint256 ts = start; ts < end; ts += 30 minutes) {
                assertEq(feed.isStockMarketNonMarketHours(ts), !open);
            }
        }
    }
}

abstract contract MarketHoursOperationsCorpusTests is StockPauseOperationsSetup, CalendarCorpus {
    function setUp() public override {
        super.setUp();
        // Replace the matrix fixture's deliberately short working day with the
        // real deployment schedule. All protocol contracts still use the bridge.
        (uint256 word, HolidayWord[] memory holidays) = packUSMarketHours2027();
        ChainlinkOracleMock sequencer = new ChainlinkOracleMock();
        stockFeed = new SPYPriceFeed(
            address(oracle), address(borrowerOperations), address(stock), address(sequencer), word, holidays, address(0)
        );
        vm.etch(address(priceFeed), address(new OperationsFeedBridge(stockFeed)).code);
    }

    function testFuzz_operationsFromCalendarRanges(uint256 rangeSeed, uint256 secondSeed, bool tokenPaused) public {
        bytes memory data = marketCorpus();
        (uint256 start, uint256 end, bool open) = rangeAt(data, rangeSeed % (data.length / 17));
        vm.warp(start + secondSeed % (end - start));
        stock.setPaused(tokenPaused);
        bool paused = !open || tokenPaused;
        assertEq(stockFeed.isStockPaused(), paused);
        vm.startPrank(C);
        if (paused) vm.expectRevert(BorrowerOperations.StockPaused.selector);
        uint256 id = _open(false);
        vm.stopPrank();
        if (!paused) assertEq(troveManager.getTroveColl(id), 20e18);
        assertEq(troveManager.getTroveIdsCount(), paused ? 2 : 3);
        uint256 wallet = boldToken.balanceOf(A);
        vm.startPrank(A);
        if (paused) vm.expectRevert(BorrowerOperations.StockPaused.selector);
        borrowerOperations.withdrawColl(aId, 1e18);
        borrowerOperations.addColl(aId, 2e18);
        borrowerOperations.repayBold(aId, 1e18);
        vm.stopPrank();
        assertEq(troveManager.getTroveColl(aId), paused ? 22e18 : 21e18);
        assertEq(boldToken.balanceOf(A), wallet - 1e18);
    }
}
