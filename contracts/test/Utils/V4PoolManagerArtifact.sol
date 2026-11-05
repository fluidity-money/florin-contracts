// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Separate compiler graph: the v4.0.0 manager pins 0.8.26, while Florin uses
// 0.8.24. The integration suite deploys this imported artifact using deployCode.
import {PoolManager} from "v4-core/src/PoolManager.sol";
