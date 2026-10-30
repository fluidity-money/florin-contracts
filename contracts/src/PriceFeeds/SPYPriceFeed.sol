// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "./RobinhoodPriceFeedBase.sol";

import "../Dependencies/StockTokenInterface.sol";

// import "forge-std/console2.sol";

struct HolidayWord {
    uint256 key;
    uint256 value;
}

contract SPYPriceFeed is RobinhoodPriceFeedBase {
    uint256 public stockMarketHoursWord;
    mapping(uint => uint256) public holidayWords;

    StockTokenInterface public stockToken;

    constructor(address _ethUsdOracleAddress, address _borrowerOperationsAddress, address _stockToken, address _sequencerUptimeFeed, uint256 _stockMarketHoursWord, HolidayWord[] memory _holidayWords)
        RobinhoodPriceFeedBase(_ethUsdOracleAddress, _borrowerOperationsAddress, _sequencerUptimeFeed)
    {
        require(_holidayWords.length > 0);

        stockToken = StockTokenInterface(_stockToken);

        _fetchPricePrimary();

        stockMarketHoursWord = _stockMarketHoursWord;
        for (uint i = 0; i < _holidayWords.length; ++i) {
            holidayWords[_holidayWords[i].key] = _holidayWords[i].value;
        }

        // Check the oracle didn't already fail
        assert(priceSource == PriceSource.primary);
    }

    function fetchPriceNoPauseCheck() public returns (uint256, bool) {
        // If branch is live and the primary oracle setup has been working, try to use it
        if (priceSource == PriceSource.primary) return _fetchPricePrimary();

        // Otherwise if branch is shut down and already using the lastGoodPrice, continue with it
        assert(priceSource == PriceSource.lastGoodPrice);
        return (lastGoodPrice, false);
    }

    function _isUsEasternDST(uint256 _ts, uint256 _word) internal pure returns (bool) {
        // First, we check to see if the word has daylight savings disabled
        // (there was some discussion at the time about this being the case):
        if ((_word & (uint256(1) << 84)) != 0) return false;

        (uint256 month, uint256 date) = _monthDayUTC(_ts);

        if (month < 3 || month > 11) return false;
        if (month > 3 && month < 11) return true;

        uint256 weekday = ((_ts / 1 days) + 4) % 7;
        uint256 firstWeekday = (weekday + 7 - ((date - 1) % 7)) % 7;
        uint256 firstSunday = 1 + (7 - firstWeekday) % 7;
        uint256 secs = _ts % 1 days;

        if (month == 3) {
            uint256 secondSunday = firstSunday + 7;
            return date > secondSunday ||
                (date == secondSunday && secs >= 7 hours);
        }

        return date < firstSunday ||
            (date == firstSunday && secs < 6 hours);
    }

    function isStockMarketNonMarketHours(uint256 _ts) public view returns (bool) {
        // This code calculates the stock market's non market hours by taking the
        // current timestamp, normalising it to the date, and the hour. We check
        // a word to see if we're within the weekly trading hours, then we check
        // the mapping to see if the current day is a holiday by consulting its
        // word in a similar way of checking the hours that can be traded. We
        // normalise the timestamp to the local time of the NSYE. We also
        // check if daylight savings time is even still happening.

        uint256 word = stockMarketHoursWord;

        uint256 offset = _isUsEasternDST(_ts, word) ? 4 hours : 5 hours;

        // Convert the timestamp to NYSE time:
        uint256 localTs = _ts - offset;
        uint256 day = ((localTs / 1 days) + 4) % 7;
        uint256 halfHour = (localTs % 1 days) / 30 minutes;

        uint256 schedule = (word >> (day * 12)) & 0xFFF;
        uint256 start = schedule & 63;
        uint256 duration = (schedule >> 6) & 63;

        if (duration == 0 || halfHour < start || halfHour >= start + duration) {
            return true;
        }

        (uint256 month, uint256 date) = _monthDayUTC(localTs);

        uint256 holiday = holidayWords[(month << 5) | date];
        uint256 closedStart = holiday & 63;
        uint256 closedDuration = (holiday >> 6) & 63;

        return closedDuration != 0
            && halfHour >= closedStart
            && halfHour < closedStart + closedDuration;
    }

    function _monthDayUTC(uint256 _ts) internal pure returns (uint256 month, uint256 date) {
        uint256 z = _ts / 1 days + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;

        month = mp < 10 ? mp + 3 : mp - 9;
        date = doy - (153 * mp + 2) / 5 + 1;
    }

    // Is the stock market paused? Returns whether it's either trading
    // outside market hours, or if the token reports its paused.
    function isStockPaused() public view returns (bool) {
        return isStockMarketNonMarketHours(block.timestamp)
            || stockToken.paused();
    }

    function fetchPrice() public returns (OracleAnswer memory oracleAnswer) {
        // When we fetch the price, we allow the oracle to update the last price
        // that was seen to keep it fully current. This might take place during a
        // paused window (somehow?), but we could attribute this to a governance
        // failure and assume the price is still current and good for us.

         (oracleAnswer.lastGoodPrice, oracleAnswer.oracleDown) = fetchPriceNoPauseCheck();
         if (isStockPaused()) {
             oracleAnswer.stockPaused = true;
             oracleAnswer.lastGoodPrice = lastGoodPrice;
             return oracleAnswer;
         }
    }

    function fetchRedemptionPriceNoPauseCheck() public returns (uint256, bool) {
        // Use same price for redemption as all other ops in WETH branch
        return fetchPriceNoPauseCheck();
    }

    function fetchRedemptionPrice() public returns (OracleAnswer memory) {
        return fetchPrice();
    }

    //  _fetchPricePrimary returns:
    // - The price
    // - A bool indicating whether a new oracle failure was detected in the call
    function _fetchPricePrimary() internal returns (uint256, bool) {
        assert(priceSource == PriceSource.primary);

        (uint256 ethUsdPrice, bool ethUsdOracleDown) = _getOracleAnswer(ethUsdOracle);

        // If the ETH-USD Chainlink response was invalid in this transaction,
        // return the last good ETH-USD price calculated This can only happen if
        // the sequencer is reported as having an outage. We don't do staleness
        // checking in this oracle.
        if (ethUsdOracleDown) return (super._shutDownAndSwitchToLastGoodPriceNoReturn(address(ethUsdOracle.aggregator)), true);

        lastGoodPrice = ethUsdPrice;
        return (ethUsdPrice, false);
    }
}
