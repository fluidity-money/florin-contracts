// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

struct Execution {
    address target;
    bytes cd;
    /// @dev This contract is ready for its upgrade! We'll change the address.
    address newImpl;
    /// @dev Wipe out the storage from the contract when we do an upgrade,
    /// also only running a single operation.
    bool shouldWipe;
}

struct QueuedOperation {
    bytes32 digest;
    /// @dev When this operation was scheduled at first.
    uint256 scheduledTs;
}

bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

library StorageSlot {
    struct AddressSlot {
        address value;
    }

    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly {
            r.slot := slot
        }
    }
}

/// @notice GovernanceUpgradeFlowThrough is a "flow through" contract that
/// executes calldata given to another location by its owner, until it's
/// later upgraded. The current address is the team multisig. There is a one week delay
/// to every operation that the governance takes. Note that prior to setting up
/// with a new contract, it might be smart to run shouldWipe, which will erase the current
/// slots involved with the governance operations, and end the current operation.
contract GovernanceUpgradeFlowThrough {
    uint256 public constant CURRENT_WAITTIME = 7 days;

    address immutable public ADDRESS;

    /// @notice The current offset of the operation ringbuffer that we use.
    uint256 public operationOffset;

    /// @notice Queue of upcoming operations this governor will run.
    QueuedOperation[] public operationQueue;

    error ExecutionFailed(bytes error);

    event OperationQueued(bytes32 digest);

    event OperationExecuted(bytes32 digest);

    event OperationCancelled(bytes32 digest);

    event StorageWiped();

    constructor(address _multisig) {
        ADDRESS = _multisig;
    }

    function queue(bytes32 _hash) external {
        require(msg.sender == ADDRESS, "not multisig");
        operationQueue.push(QueuedOperation({
            digest: _hash,
            scheduledTs: block.timestamp
        }));
        emit OperationQueued(_hash);
    }

    function provideHash(Execution[] calldata _execution) public pure returns (bytes32) {
        return keccak256(abi.encode(_execution));
    }

    function _setNewImpl(address _impl) internal {
        require(_impl.code.length > 0);
        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = _impl;
        emit IERC1967.Upgraded(_impl);
    }

    function cancel() external {
        require(msg.sender == ADDRESS, "Not multisig");
        require(operationOffset < operationQueue.length, "No operations to cancel");
        bytes32 expHash = operationQueue[operationOffset].digest;
        operationOffset += 1;
        emit OperationCancelled(expHash);
    }

    function _wipeStorage() internal {
        for (uint i = 0; i < operationQueue.length; ++i) {
            operationQueue[i].digest = bytes32(0);
            operationQueue[i].scheduledTs = 0;
        }
        operationOffset = 0;
    }

    function execute(Execution[] calldata _execution) external {
        require(msg.sender == ADDRESS, "Not multisig");
        require(operationQueue.length > operationOffset, "No operations to execute");
        bytes32 expHash = operationQueue[operationOffset].digest;
        bytes32 curHash = provideHash(_execution);
        // Only the current operation can be run in a queue:
        require(expHash == curHash, "Bad current operation hash");
        // Though it's not strictly necessary, we have a protection here so the
        // team can control the timing of an operation:
        uint256 scheduledTs = operationQueue[operationOffset].scheduledTs;
        require(
            scheduledTs + CURRENT_WAITTIME > block.timestamp,
            "Not time to run the scheduled operation"
        );
        operationOffset += 1;
        for (uint256 i = 0; i < _execution.length; ++i) {
            address newImpl = _execution[i].newImpl;
            if (address(0) != newImpl) {
                _setNewImpl(newImpl);
            } else {
                address target = _execution[i].target;
                require(target.code.length != 0, "target has no code");
                if (_execution[i].shouldWipe) {
                    require(i == 0 && _execution.length == 1, "Only a single operation can wipe");
                    _wipeStorage();
                    emit StorageWiped();
                }
                (bool rc, bytes memory rd) = target.call(_execution[i].cd);
                if (!rc) {
                    revert ExecutionFailed(rd);
                }
            }
        }
        emit OperationExecuted(curHash);
    }
}
