// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

struct Execution {
    address target;
    bytes cd;
}

/// @notice GovernanceUpgradeFlowThrough is a "flow through" contract that
/// executes calldata given to another location by its owner, until it's
/// later upgraded. The current address is a team multisig, hardcoded to
/// free up a storage slot.
contract GovernanceUpgradeFlowThrough {
    address immutable public ADDRESS;

    constructor(address _multisig) {
        ADDRESS = _multisig;
    }

    function execute(Execution[] calldata _execution) external {
        require(msg.sender == ADDRESS, "not multisig");
        for (uint256 i = 0; i < _execution.length; ++i) {
            address target = _execution[i].target;
            bytes memory cd = _execution[i].cd;
            require(target.code.length != 0, "target has no code");
            assembly ("memory-safe") {
                let rc := delegatecall(gas(), target, add(cd, 0x20), mload(cd), 0, 0)
                if iszero(rc) {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
            }
        }
    }
}
