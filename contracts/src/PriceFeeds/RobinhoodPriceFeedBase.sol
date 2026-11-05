// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "../Interfaces/IMainnetPriceFeed.sol";
import "../BorrowerOperations.sol";

// import "forge-std/console2.sol";

abstract contract RobinhoodPriceFeedBase is IMainnetPriceFeed {
    uint256 constant public SEQUENCER_GRACE_SECS = 24 hours;

    // Determines where the PriceFeed sources data from. Possible states:
    // - primary: Uses the primary price calculation, which depends on the specific feed
    // - lastGoodPrice: the last good price recorded by this PriceFeed.
    PriceSource public priceSource;

    // Last good price tracker for the derived USD price
    uint256 public lastGoodPrice;

    AggregatorV3Interface public sequencerUptimeFeed;

    struct Oracle {
        AggregatorV3Interface aggregator;
        uint8 decimals;
    }

    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
    }

    error InsufficientGasForExternalCall();

    event ShutDownFromOracleFailure(address _failedOracleAddr);

    Oracle public ethUsdOracle;

    IBorrowerOperations borrowerOperations;

    constructor(address _ethUsdOracleAddress, address _borrowOperationsAddress, address _sequencerUptimeFeed) {
        // Store ETH-USD oracle
        ethUsdOracle.aggregator = AggregatorV3Interface(_ethUsdOracleAddress);
        ethUsdOracle.decimals = ethUsdOracle.aggregator.decimals();

        borrowerOperations = IBorrowerOperations(_borrowOperationsAddress);
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);

        assert(ethUsdOracle.decimals == 8);
    }

    function _isSequencerOffline() internal view returns (bool) {
        (, int256 sequencerStatus, uint256 startedAt, , ) = sequencerUptimeFeed.latestRoundData();
        bool sequencerDown = sequencerStatus != 0;
        bool sequencerPastGracePeriod = block.timestamp - startedAt > SEQUENCER_GRACE_SECS;
        return (sequencerDown && sequencerPastGracePeriod);
    }

    function _getOracleAnswer(Oracle memory _oracle) internal view returns (uint256, bool) {
        ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse(_oracle.aggregator);

        uint256 scaledPrice;
        bool oracleIsDown;
        // Check if the sequencer is operating before consulting the oracle
        // Check oracle is serving an up-to-date and sensible price. If not, shut down this collateral branch.
        if (_isSequencerOffline() || !_isValidChainlinkPrice(chainlinkResponse)) {
            oracleIsDown = true;
        } else {
            scaledPrice = _scaleChainlinkPriceTo18decimals(chainlinkResponse.answer, _oracle.decimals);
        }

        return (scaledPrice, oracleIsDown);
    }

    function _shutDownAndSwitchToLastGoodPriceNoReturn(address _failedOracleAddr) internal returns (uint256) {
        // Shut down the branch
        borrowerOperations.shutdownFromOracleFailure();

        priceSource = PriceSource.lastGoodPrice;

        emit ShutDownFromOracleFailure(_failedOracleAddr);

        return lastGoodPrice;
    }

    function _getCurrentChainlinkResponse(AggregatorV3Interface _aggregator)
        internal
        view
        returns (ChainlinkResponse memory chainlinkResponse)
    {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = _aggregator.latestRoundData();
        chainlinkResponse.roundId = roundId;
        chainlinkResponse.answer = answer;
    }

    // False if:
    // - Call to Chainlink aggregator reverts
    // - Price answer is 0 or negative
    function _isValidChainlinkPrice(ChainlinkResponse memory chainlinkResponse)
        internal
        view
        returns (bool)
    {
        return chainlinkResponse.answer > 0;
    }

    // Trust assumption: Chainlink won't change the decimal precision on any feed used in v2 after deployment
    function _scaleChainlinkPriceTo18decimals(int256 _price, uint256 _decimals) internal pure returns (uint256) {
        // Scale an int price to a uint with 18 decimals
        return uint256(_price) * 10 ** (18 - _decimals);
    }
}
