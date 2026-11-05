// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice GovernanceUpgradeFlowThrough is a "flow through" contract that
/// executes calldata given to another location by its owner, until it's
/// later upgraded. The current address is a team multisig, hardcoded to
/// free up a storage slot.
contract GovernanceUpgradeFlowThrough {
    address immutable public ADDRESS;

    constructor(address _multisig) {
        ADDRESS = _multisig;
    }

    function execute(address _target, bytes memory _args) external {
        require(msg.sender == ADDRESS, "not multisig");
        assembly {
            let result := delegatecall(gas(), _target, add(_args, 0x20), mload(_args), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
