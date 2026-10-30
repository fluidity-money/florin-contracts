// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

struct OracleAnswer {
    uint256 lastGoodPrice;
    bool oracleDown;
    bool stockPaused;
}

interface IPriceFeed {
    function isStockPaused() external view returns (bool);
    function fetchPriceNoPauseCheck() external returns (uint256, bool);
    function fetchPrice() external returns (OracleAnswer memory);
    function fetchRedemptionPriceNoPauseCheck() external returns (uint256, bool);
    function fetchRedemptionPrice() external returns (OracleAnswer memory);
    function lastGoodPrice() external view returns (uint256);
}
