
# Changes for Florin

This is a record of the changes made to the Liquity Bold codebase for Florin, and an
explanation of the functional outcome in the codebase.

In our modifications, we've preserved some function names to keep things consistent
internally and to simplify any discovery for auditors/users with familiarity with the base
contract. We replace comments in some places to explain the meaning of some of the decisions.

Commits have been separated from the frontend, and are referred to here.

- Removed WSTETHPriceFeed and RETHPriceFeed oracle types.

- Removed branching for ETHUSDxCanonical.

- We use SPYPriceFeed as the price feed for the stock tokens, renamed from WETHPriceFeed.
The oracle checks if the stock token is trading by checking a schedule internally, and
also checking if the token is reported as paused. `fetchPriceNoPauseCheck` and
`fetchRedemptionPriceNoPauseCheck` functions are provided to not check the status of the
contract's paused status. We introduce a new internally used struct, and rename
`_shutDownAndSwitchToLastGoodPrice` to make it clear it can't be used for control flow
anymore. We also check if the sequencer is powered on, and we remove the staleness for the
oracle last update.

- We added _allowStockPaused in adjusting trove code in the BorrowerOperations.

- Renamed MainnetPriceFeedBase.sol to RobinhoodPriceFeedBase.sol and added a sequencer
uptime check during the checking of the oracle liveliness.

- Renamed "BOLD Stablecoin" to "Florin USD". - Added support for Uniswap V4 in the test
scaffolding.

- Removed WETHZapper and LeverageWETHZapper. DeployLiquity2 does not deploy any pools
except a Uniswap V4 hook that is shipped with the code.
