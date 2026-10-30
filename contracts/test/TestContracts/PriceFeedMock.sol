// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "./Interfaces/IPriceFeedMock.sol";

contract PriceFeedMock is IPriceFeedMock {
    uint256 private PRICE;

    bool public isStockPaused;

    function setPrice(uint256 _price) external {
        PRICE = _price;
    }

    function getPrice() external view returns (uint256 _price) {
        return PRICE;
    }

    function fetchPriceNoPauseCheck() public view returns (uint256, bool) {
        return (PRICE, false);
    }

    function fetchPrice() public view returns (OracleAnswer memory o) {
        (o.lastGoodPrice, o.oracleDown) = fetchPriceNoPauseCheck();
        return o;
    }

    function fetchRedemptionPriceNoPauseCheck() public view returns (uint256, bool) {
        return fetchPriceNoPauseCheck();
    }

    function fetchRedemptionPrice() external view returns (OracleAnswer memory o) {
        return fetchPrice();
    }

    function lastGoodPrice() external view returns (uint256) {
        return PRICE;
    }
}
