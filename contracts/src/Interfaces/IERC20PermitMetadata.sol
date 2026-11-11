// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IERC20PermitMetadata is IERC20Permit, IERC20Metadata {}
