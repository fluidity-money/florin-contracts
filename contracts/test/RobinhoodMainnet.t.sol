// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "src/PriceFeeds/RobinhoodPriceFeedBase.sol";
import "src/PriceFeeds/SPYPriceFeed.sol";

import "./TestContracts/Accounts.sol";
import "./TestContracts/ChainlinkOracleMock.sol";
import "./TestContracts/GasGuzzlerOracle.sol";

import {TestDeployer, CollateralRegistryTester} from "./TestContracts/Deployment.t.sol";

import "src/Dependencies/AggregatorV3Interface.sol";

import "forge-std/Test.sol";
import "lib/forge-std/src/console2.sol";

contract OraclesMainnet is TestAccounts {
    AggregatorV3Interface ethOracle;

    ChainlinkOracleMock mockOracle;
    GasGuzzlerOracle gasGuzzlerOracle;

    IMainnetPriceFeed wethPriceFeed;

    TestDeployer.LiquityContracts[] contractsArray;
    CollateralRegistryTester collateralRegistry;
    IBoldToken boldToken;

    struct StoredOracle {
        AggregatorV3Interface aggregator;
        uint256 stalenessThreshold;
        uint256 decimals;
    }

    struct Vars {
        uint256 numCollaterals;
        uint256 initialColl;
        uint256 price;
        uint256 coll;
        uint256 debtRequest;
    }

    function setUp() public {
        try vm.envString("MAINNET_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
        } catch {
            vm.skip(true);
        }

        Vars memory vars;

        accounts = new Accounts();
        createAccounts();

        (A, B, C, D, E, F) =
            (accountsList[0], accountsList[1], accountsList[2], accountsList[3], accountsList[4], accountsList[5]);

        vars.numCollaterals = 1;
        TestDeployer.TroveManagerParams memory tmParams =
            TestDeployer.TroveManagerParams(150e16, 110e16, 10e16, 110e16, 5e16, 10e16);
        TestDeployer.TroveManagerParams[] memory troveManagerParamsArray =
            new TestDeployer.TroveManagerParams[](vars.numCollaterals);
        for (uint256 i = 0; i < troveManagerParamsArray.length; i++) {
            troveManagerParamsArray[i] = tmParams;
        }

        TestDeployer deployer = new TestDeployer();
        TestDeployer.DeploymentResultMainnet memory result =
            deployer.deployAndConnectContractsMainnet(troveManagerParamsArray);
        collateralRegistry = result.collateralRegistry;
        boldToken = result.boldToken;

        ethOracle = AggregatorV3Interface(result.externalAddresses.ETHOracle);

        mockOracle = new ChainlinkOracleMock();
        gasGuzzlerOracle = new GasGuzzlerOracle();

        // Record contracts
        for (uint256 c = 0; c < vars.numCollaterals; c++) {
            contractsArray.push(result.contractsArray[c]);
        }

        // Give all users all collaterals
        vars.initialColl = 1000_000e18;
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = 0; j < vars.numCollaterals; j++) {
                deal(address(contractsArray[j].collToken), accountsList[i], vars.initialColl);
                vm.startPrank(accountsList[i]);
                // Approve Borrower Ops to use the user's collateral funds
                contractsArray[j].collToken.approve(address(contractsArray[j].borrowerOperations), type(uint256).max);
                vm.stopPrank();
            }

            vm.startPrank(accountsList[i]);
        }

        wethPriceFeed = IMainnetPriceFeed(address(contractsArray[0].priceFeed));

        // log some current blockchain state
        // console2.log(block.timestamp, "block.timestamp");
        // console2.log(block.number, "block.number");
        // console2.log(ethOracle.decimals(), "ETHUSD decimals");

        // Artificially decay the base rate so we start with a low redemption rate.
        // Normally, we would just wait for it to decay "naturally" (with `vm.warp`), but we can't do that here,
        // as it would result in all the oracles going stale.
        collateralRegistry.setBaseRate(0);
    }

    function _getLatestAnswerFromOracle(AggregatorV3Interface _oracle) internal view returns (uint256) {
        (, int256 answer,,,) = _oracle.latestRoundData();

        uint256 decimals = _oracle.decimals();
        assertLe(decimals, 18);
        // Convert to uint and scale up to 18 decimals
        return uint256(answer) * 10 ** (18 - decimals);
    }

    function redeem(address _from, uint256 _boldAmount) public {
        vm.startPrank(_from);
        collateralRegistry.redeemCollateral(_boldAmount, MAX_UINT256, 1e18);
        vm.stopPrank();
    }

    function etchStaleMockToEthOracle(bytes memory _mockOracleCode) internal {
        // Etch the mock code to the ETH-USD oracle address
        vm.etch(address(ethOracle), _mockOracleCode);
        ChainlinkOracleMock mock = ChainlinkOracleMock(address(ethOracle));
        mock.setDecimals(8);
        // Fake ETH-USD price of 2000 USD
        mock.setPrice(2000e8);
        // Make it stale
        mock.setUpdatedAt(block.timestamp - 7 days);
    }

    function etchGasGuzzlerToEthOracle(bytes memory _mockOracleCode) internal {
        // Etch the mock code to the ETH-USD oracle address
        vm.etch(address(ethOracle), _mockOracleCode);
        GasGuzzlerOracle mock = GasGuzzlerOracle(address(ethOracle));
        mock.setDecimals(8);
        // Fake ETH-USD price of 2000 USD
        mock.setPrice(2000e8);
        mock.setUpdatedAt(block.timestamp);
    }

    // --- lastGoodPrice set on deployment ---

    function testSetLastGoodPriceOnDeploymentWETH() public view {
        uint256 lastGoodPriceWeth = wethPriceFeed.lastGoodPrice();
        assertGt(lastGoodPriceWeth, 0);

        uint256 latestAnswerEthUsd = _getLatestAnswerFromOracle(ethOracle);

        assertEq(lastGoodPriceWeth, latestAnswerEthUsd);
    }

    // --- fetchPrice ---

    function testFetchPriceReturnsCorrectPriceWETH() public {
        (uint256 fetchedEthUsdPrice,) = wethPriceFeed.fetchPriceNoPauseCheck();
        assertGt(fetchedEthUsdPrice, 0);

        uint256 latestAnswerEthUsd = _getLatestAnswerFromOracle(ethOracle);

        assertEq(fetchedEthUsdPrice, latestAnswerEthUsd);
    }

    // // --- Basic actions ---

    function testOpenTroveWETH() public {
        uint256 price = _getLatestAnswerFromOracle(ethOracle);

        uint256 coll = 5 ether;
        uint256 debtRequest = coll * price / 2 / 1e18;

        uint256 trovesCount = contractsArray[0].troveManager.getTroveIdsCount();
        assertEq(trovesCount, 0);

        vm.startPrank(A);
        contractsArray[0].borrowerOperations.openTrove(
            A, 0, coll, debtRequest, 0, 0, 5e16, debtRequest, address(0), address(0), address(0)
        );

        trovesCount = contractsArray[0].troveManager.getTroveIdsCount();
        assertEq(trovesCount, 1);
    }

    // --- Oracle manipulation tests ---

    function testManipulatedChainlinkReturnsStalePrice() public {
        // Replace the ETH Oracle's code with the mock oracle's code that returns a stale price
        etchStaleMockToEthOracle(address(mockOracle).code);

        (,,, uint256 updatedAt,) = ethOracle.latestRoundData();

        // Confirm it's stale
        assertEq(updatedAt, block.timestamp - 7 days);
    }

    function testManipulatedChainlinkReturns2kUsdPrice() public {
        // Replace the ETH Oracle's code with the mock oracle's code that returns a stale price
        etchStaleMockToEthOracle(address(mockOracle).code);

        uint256 price = _getLatestAnswerFromOracle(ethOracle);
        assertEq(price, 2000e18);
    }

    function testOpenTroveWETHWithStalePriceReverts() public {
        Vars memory vars;
        etchStaleMockToEthOracle(address(mockOracle).code);
        (,,, uint256 updatedAt,) = ethOracle.latestRoundData();
        assertEq(updatedAt, block.timestamp - 7 days);

        assertFalse(contractsArray[0].borrowerOperations.hasBeenShutDown());

        vars.price = _getLatestAnswerFromOracle(ethOracle);
        vars.coll = 5 ether;
        vars.debtRequest = vars.coll * vars.price / 2 / 1e18;

        vm.startPrank(A);
        vm.expectRevert(BorrowerOperations.NewOracleFailureDetected.selector);
        contractsArray[0].borrowerOperations.openTrove(
            A, 0, vars.coll, vars.debtRequest, 0, 0, 5e16, vars.debtRequest, address(0), address(0), address(0)
        );
    }

    function testAdjustTroveWETHWithStalePriceReverts() public {
        uint256 price = _getLatestAnswerFromOracle(ethOracle);

        uint256 coll = 5 ether;
        uint256 debtRequest = coll * price / 2 / 1e18;

        vm.startPrank(A);
        uint256 troveId = contractsArray[0].borrowerOperations.openTrove(
            A, 0, coll, debtRequest, 0, 0, 5e16, debtRequest, address(0), address(0), address(0)
        );

        // confirm Trove was opened
        uint256 trovesCount = contractsArray[0].troveManager.getTroveIdsCount();
        assertEq(trovesCount, 1);

        // Replace oracle with a stale oracle
        etchStaleMockToEthOracle(address(mockOracle).code);
        (,,, uint256 updatedAt,) = ethOracle.latestRoundData();
        assertEq(updatedAt, block.timestamp - 7 days);

        // Try to adjust Trove
        vm.expectRevert(BorrowerOperations.NewOracleFailureDetected.selector);
        contractsArray[0].borrowerOperations.adjustTrove(troveId, 0, false, 1 wei, true, 1e18);
    }

    // --- SPY shutdown ---

    function testSPYPriceFeedShutsDownWhenSPYUSDOracleFails() public {
        // Fetch price
        (uint256 price, bool ethUsdFailed) = wethPriceFeed.fetchPriceNoPauseCheck();
        assertGt(price, 0);

        // Check oracle call didn't fail
        assertFalse(ethUsdFailed);

        // Check branch is live, not shut down
        assertEq(contractsArray[0].troveManager.shutdownTime(), 0);

        // Make the ETH-USD oracle stale
        etchStaleMockToEthOracle(address(mockOracle).code);
        (,,, uint256 updatedAt,) = ethOracle.latestRoundData();
        assertEq(updatedAt, block.timestamp - 7 days);

        // Fetch price again
        (, ethUsdFailed) = wethPriceFeed.fetchPriceNoPauseCheck();

        // Check oracle call failed this time
        assertTrue(ethUsdFailed);

        // Confirm the branch is now shutdown
        assertEq(contractsArray[0].troveManager.shutdownTime(), block.timestamp);
    }

    function testSPYPriceFeedReturnsLastGoodPriceWhenSPYUSDOracleFails() public {
        // Fetch price
        wethPriceFeed.fetchPriceNoPauseCheck();
        uint256 lastGoodPrice1 = wethPriceFeed.lastGoodPrice();
        assertGt(lastGoodPrice1, 0, "lastGoodPrice 0");

        // Make the ETH-USD oracle stale
        etchStaleMockToEthOracle(address(mockOracle).code);
        (, int256 mockPrice,, uint256 updatedAt,) = ethOracle.latestRoundData();
        assertEq(updatedAt, block.timestamp - 7 days);
        assertGt(mockPrice, 0, "mockPrice 0");
        // Confirm the lastGoodPrice is not coincidentally equal to the mock oracle's price
        assertNotEq(lastGoodPrice1, uint256(mockPrice));

        // Fetch price again
        (uint256 price, bool ethUsdFailed) = wethPriceFeed.fetchPriceNoPauseCheck();

        // Check oracle call failed this time
        assertTrue(ethUsdFailed);

        // Confirm the PriceFeed's returned price equals the lastGoodPrice
        assertEq(price, lastGoodPrice1, "current price != lastGoodPrice");

        // Confirm the stored lastGoodPrice has not changed
        assertEq(wethPriceFeed.lastGoodPrice(), lastGoodPrice1, "lastGoodPrice not same");
    }

    // --- redemptions ---

    function testNormalWETHRedemptionDoesNotHitShutdownBranch() public {
        // Fetch price
        wethPriceFeed.fetchPriceNoPauseCheck();
        uint256 lastGoodPrice1 = wethPriceFeed.lastGoodPrice();
        assertGt(lastGoodPrice1, 0, "lastGoodPrice 0");

        // Check using primary
        assertEq(uint8(wethPriceFeed.priceSource()), uint8(IMainnetPriceFeed.PriceSource.primary));

        uint256 coll = 100 ether;
        uint256 debtRequest = 3000e18;

        vm.startPrank(A);
        contractsArray[0].borrowerOperations.openTrove(
            A, 0, coll, debtRequest, 0, 0, 5e16, debtRequest, address(0), address(0), address(0)
        );

        // Make the ETH-USD oracle stale
        etchStaleMockToEthOracle(address(mockOracle).code);
        (,,, uint256 updatedAt,) = ethOracle.latestRoundData();
        assertEq(updatedAt, block.timestamp - 7 days);

        // Fetch price again
        (, bool oracleFailedWhileBranchLive) = wethPriceFeed.fetchPriceNoPauseCheck();
        assertTrue(oracleFailedWhileBranchLive);
        // Confirm branch shutdown
        assertEq(contractsArray[0].troveManager.shutdownTime(), block.timestamp);

        uint256 totalBoldRedeemAmount = 100e18;
        uint256 branch0DebtBefore = contractsArray[0].activePool.getBoldDebt();
        assertGt(branch0DebtBefore, 0);

        uint256 boldBalBefore_A = boldToken.balanceOf(A);

        // Redeem
        redeem(A, totalBoldRedeemAmount);

        // Confirm A lost no BOLD
        assertEq(boldToken.balanceOf(A), boldBalBefore_A);

        // Confirm WETH branch did not get redeemed from
        assertEq(contractsArray[0].activePool.getBoldDebt(), branch0DebtBefore);
    }

    function testRedemptionOfWETHUsesETHUSDMarketforPrimaryPrice() public {
        // Fetch price
        wethPriceFeed.fetchPriceNoPauseCheck();
        uint256 lastGoodPrice1 = wethPriceFeed.lastGoodPrice();
        assertGt(lastGoodPrice1, 0, "lastGoodPrice 0");

        // Check using primary
        assertEq(uint8(wethPriceFeed.priceSource()), uint8(IMainnetPriceFeed.PriceSource.primary));

        uint256 coll = 100 ether;
        uint256 debtRequest = 3000e18;

        vm.startPrank(A);
        contractsArray[0].borrowerOperations.openTrove(
            A, 0, coll, debtRequest, 0, 0, 5e16, debtRequest, address(0), address(0), address(0)
        );

        // Expected price used for primary calc: ETH-USD market price
        uint256 expectedPrice = _getLatestAnswerFromOracle(ethOracle);
        assertGt(expectedPrice, 0);

        // Calc expected fee based on price
        uint256 totalBoldRedeemAmount = 100e18;
        uint256 totalCorrespondingColl = totalBoldRedeemAmount * DECIMAL_PRECISION / expectedPrice;
        assertGt(totalCorrespondingColl, 0);

        uint256 redemptionFeePct = collateralRegistry.getEffectiveRedemptionFeeInBold(totalBoldRedeemAmount)
            * DECIMAL_PRECISION / totalBoldRedeemAmount;
        assertGt(redemptionFeePct, 0);

        uint256 totalCollFee = totalCorrespondingColl * redemptionFeePct / DECIMAL_PRECISION;

        uint256 expectedCollDelta = totalCorrespondingColl - totalCollFee;
        assertGt(expectedCollDelta, 0);

        uint256 branch0DebtBefore = contractsArray[0].activePool.getBoldDebt();
        assertGt(branch0DebtBefore, 0);
        uint256 A_collBefore = contractsArray[0].collToken.balanceOf(A);
        assertGt(A_collBefore, 0);
        // Redeem
        redeem(A, totalBoldRedeemAmount);

        // Confirm WETH branch got redeemed from
        assertEq(contractsArray[0].activePool.getBoldDebt(), branch0DebtBefore - totalBoldRedeemAmount);

        // Confirm the received amount coll is the expected amount (i.e. used the expected price)
        assertEq(contractsArray[0].collToken.balanceOf(A), A_collBefore + expectedCollDelta);
    }

    // --- Low gas market oracle reverts ---

    function testRevertLowGasETHOracle() public {
        // Confirm call to the real external contracts succeeds with sufficient gas i.e. 500k
        (bool success,) = address(wethPriceFeed).call{gas: 500000}(abi.encodeWithSignature("fetchPriceNoPauseCheck()"));
        assertTrue(success);

        // Etch gas guzzler to the oracle
        etchGasGuzzlerToEthOracle(address(gasGuzzlerOracle).code);

        // After etching the gas guzzler to the oracle, confirm the same call with 500k gas now reverts due to OOG
        vm.expectRevert(RobinhoodPriceFeedBase.InsufficientGasForExternalCall.selector);
        (bool revertAsExpected,) = address(wethPriceFeed).call{gas: 500000}(abi.encodeWithSignature("fetchPriceNoPauseCheck()"));
        assertTrue(revertAsExpected);
    }

    /*
    function testTMCodeSize() public {
        uint256 codeSize = address(contractsArray[0].troveManager).code.length;
        uint256 left = 24576 - codeSize;
        console.log(codeSize, "TM contract size");
        console.log(left, "space left in TM");
    }
    */

    // - More basic actions tests (adjust, close, etc)
    // - liq tests (manipulate aggregator stored price)
}
