// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import "./StockTokenInterface.sol";

interface ISPYToken is StockTokenInterface, IERC20 {}
