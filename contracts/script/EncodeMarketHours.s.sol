// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

struct MarketHoliday {
    uint8 month;
    uint8 date;
    uint8 hour;
    uint8 length;
}

struct MarketHours {
    uint8 mondayTradingHour;
    uint8 mondayTradingLength;
    uint8 tuesdayTradingHour;
    uint8 tuesdayTradingLength;
    uint8 wednesdayTradingHour;
    uint8 wednesdayTradingLength;
    uint8 thursdayTradingHour;
    uint8 thursdayTradingLength;
    uint8 fridayTradingHour;
    uint8 fridayTradingLength;
    uint8 saturdayTradingHour;
    uint8 saturdayTradingLength;
    uint8 sundayTradingHour;
    uint8 sundayTradingLength;
    bool disableDST;
    MarketHoliday[] marketHolidays;
}

struct HolidayWord {
    uint256 key;
    uint256 value;
}

function packMarketHours(MarketHours memory hours_) pure returns (uint256 weeklyWord, HolidayWord[] memory holidays) {
    uint8[7] memory starts = [
        hours_.sundayTradingHour,
        hours_.mondayTradingHour,
        hours_.tuesdayTradingHour,
        hours_.wednesdayTradingHour,
        hours_.thursdayTradingHour,
        hours_.fridayTradingHour,
        hours_.saturdayTradingHour
    ];

    uint8[7] memory lengths = [
        hours_.sundayTradingLength,
        hours_.mondayTradingLength,
        hours_.tuesdayTradingLength,
        hours_.wednesdayTradingLength,
        hours_.thursdayTradingLength,
        hours_.fridayTradingLength,
        hours_.saturdayTradingLength
    ];

    for (uint256 i; i < 7; ++i) {
        require(starts[i] < 48);
        require(uint256(starts[i]) + lengths[i] <= 48);

        weeklyWord |= (uint256(starts[i]) | (uint256(lengths[i]) << 6)) << (i * 12);
    }

    if (hours_.disableDST) {
        weeklyWord |= uint256(1) << 84;
    }

    uint256 count = hours_.marketHolidays.length;
    holidays = new HolidayWord[](count);

    for (uint256 i; i < count; ++i) {
        MarketHoliday memory h = hours_.marketHolidays[i];

        require(h.month >= 1 && h.month <= 12);
        require(h.date >= 1 && h.date <= 31);
        require(h.hour < 24);
        require(h.length > 0);
        require(uint256(h.hour) + h.length <= 24);

        uint256 start = uint256(h.hour) * 2;
        uint256 duration = uint256(h.length) * 2;

        holidays[i] = HolidayWord({
            key: (uint256(h.month) << 5) | h.date,
            value: start | (duration << 6)
        });
    }
}

function packUSMarketHours2027() pure returns (uint256 weeklyWord, HolidayWord[] memory holidays) {
    MarketHours memory hours_;

    hours_.disableDST = false;

    hours_.mondayTradingLength = 48;
    hours_.tuesdayTradingLength = 48;
    hours_.wednesdayTradingLength = 48;
    hours_.thursdayTradingLength = 48;
    hours_.fridayTradingLength = 40; // Midnight to 20:00 ET
    hours_.sundayTradingHour = 40;  // Opens at 20:00 ET
    hours_.sundayTradingLength = 8; // Through midnight

    hours_.marketHolidays = new MarketHoliday[](11);

    hours_.marketHolidays[0] = MarketHoliday(1, 1, 0, 24);
    hours_.marketHolidays[1] = MarketHoliday(1, 18, 0, 24);
    hours_.marketHolidays[2] = MarketHoliday(2, 15, 0, 24);
    hours_.marketHolidays[3] = MarketHoliday(3, 26, 0, 24);
    hours_.marketHolidays[4] = MarketHoliday(5, 31, 0, 24);
    hours_.marketHolidays[5] = MarketHoliday(6, 18, 0, 24);
    hours_.marketHolidays[6] = MarketHoliday(7, 5, 0, 24);
    hours_.marketHolidays[7] = MarketHoliday(9, 6, 0, 24);
    hours_.marketHolidays[8] = MarketHoliday(11, 25, 0, 24);
    hours_.marketHolidays[9] = MarketHoliday(12, 24, 0, 24);

    // November 26: closed from 13:00 New York time until midnight.
    hours_.marketHolidays[10] = MarketHoliday(11, 26, 13, 11);

    return packMarketHours(hours_);
}
