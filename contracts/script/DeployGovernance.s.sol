// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

import {Script} from "forge-std/Script.sol";

import {IGovernance} from "V2-gov/src/interfaces/IGovernance.sol";

import {Governance} from "V2-gov/src/Governance.sol";

library AddressArray {
    using Strings for *;
    using AddressArray for *;

    function toJSON(address addr) internal pure returns (string memory) {
        return string.concat('"', addr.toHexString(), '"');
    }

    function toJSON(address[] memory addresses) internal pure returns (string memory) {
        if (addresses.length == 0) return "[]";

        string memory commaSeparatedStrings = addresses[0].toJSON();
        for (uint256 i = 1; i < addresses.length; ++i) {
            commaSeparatedStrings = string.concat(commaSeparatedStrings, ",", addresses[i].toJSON());
        }

        return string.concat("[", commaSeparatedStrings, "]");
    }
}

contract DeployGovernance is Script {
    using Strings for *;
    using AddressArray for *;

    struct DeployGovernanceParams {
        uint256 epochStart;
        address deployer;
        bytes32 salt;
        address stakingV1;
        address lqty;
        address lusd;
        address bold;
    }

    address constant DEFI_COLLECTIVE_GRANTS_ADDRESS = 0xDc6f869d2D34E4aee3E89A51f2Af6D54F0F7f690;

    // Governance Constants
    uint128 private constant REGISTRATION_FEE = 100e18;
    uint128 private constant REGISTRATION_THRESHOLD_FACTOR = 0.0001e18; // 0.01%
    uint128 private constant UNREGISTRATION_THRESHOLD_FACTOR = 1e18 + 1;
    uint16 private constant UNREGISTRATION_AFTER_EPOCHS = 4;
    uint128 private constant VOTING_THRESHOLD_FACTOR = 0.02e18;
    uint88 private constant MIN_CLAIM = 0;
    uint88 private constant MIN_ACCRUAL = 0;
    uint32 internal constant EPOCH_DURATION = 7 days;
    uint32 private constant EPOCH_VOTING_CUTOFF = 6 days;

    // Contracts
    Governance private governance;
    address[] private initialInitiatives;
    address private defiCollectiveInitiative;

    function deployGovernance(DeployGovernanceParams memory p) internal returns (address, string memory) {
        (address governanceAddress, IGovernance.Configuration memory governanceConfiguration) =
            computeGovernanceAddressAndConfig(p);

        governance = new Governance{salt: p.salt}(
            p.lqty, p.lusd, p.stakingV1, p.bold, governanceConfiguration, p.deployer, initialInitiatives
        );

        assert(governanceAddress == address(governance));

        if (block.chainid == 1) {
            initialInitiatives.push(defiCollectiveInitiative = DEFI_COLLECTIVE_GRANTS_ADDRESS);
        } else {
            initialInitiatives.push(makeAddr("initiative1"));
            initialInitiatives.push(makeAddr("initiative2"));
            initialInitiatives.push(makeAddr("initiative3"));
        }

        governance.registerInitialInitiatives{gas: 600000}(initialInitiatives);

        return (governanceAddress, _getGovernanceManifestJson(p));
    }

    function computeGovernanceAddress(DeployGovernanceParams memory p) internal pure returns (address) {
        (address governanceAddress,) = computeGovernanceAddressAndConfig(p);
        return governanceAddress;
    }

    function computeGovernanceAddressAndConfig(DeployGovernanceParams memory p)
        internal
        pure
        returns (address, IGovernance.Configuration memory)
    {
        IGovernance.Configuration memory governanceConfiguration = IGovernance.Configuration({
            registrationFee: REGISTRATION_FEE,
            registrationThresholdFactor: REGISTRATION_THRESHOLD_FACTOR,
            unregistrationThresholdFactor: UNREGISTRATION_THRESHOLD_FACTOR,
            unregistrationAfterEpochs: UNREGISTRATION_AFTER_EPOCHS,
            votingThresholdFactor: VOTING_THRESHOLD_FACTOR,
            minClaim: MIN_CLAIM,
            minAccrual: MIN_ACCRUAL,
            epochStart: p.epochStart,
            epochDuration: EPOCH_DURATION,
            epochVotingCutoff: EPOCH_VOTING_CUTOFF
        });

        bytes memory bytecode = abi.encodePacked(
            type(Governance).creationCode,
            abi.encode(p.lqty, p.lusd, p.stakingV1, p.bold, governanceConfiguration, p.deployer, new address[](0))
        );

        address governanceAddress = vm.computeCreate2Address(p.salt, keccak256(bytecode));
        return (governanceAddress, governanceConfiguration);
    }

    function _getGovernanceDeploymentConstants(DeployGovernanceParams memory p) internal pure returns (string memory) {
        return string.concat(
            "{",
            string.concat(
                string.concat('"REGISTRATION_FEE":"', REGISTRATION_FEE.toString(), '",'),
                string.concat('"REGISTRATION_THRESHOLD_FACTOR":"', REGISTRATION_THRESHOLD_FACTOR.toString(), '",'),
                string.concat('"UNREGISTRATION_THRESHOLD_FACTOR":"', UNREGISTRATION_THRESHOLD_FACTOR.toString(), '",'),
                string.concat('"UNREGISTRATION_AFTER_EPOCHS":"', UNREGISTRATION_AFTER_EPOCHS.toString(), '",'),
                string.concat('"VOTING_THRESHOLD_FACTOR":"', VOTING_THRESHOLD_FACTOR.toString(), '",'),
                string.concat('"MIN_CLAIM":"', MIN_CLAIM.toString(), '",'),
                string.concat('"MIN_ACCRUAL":"', MIN_ACCRUAL.toString(), '",'),
                string.concat('"EPOCH_START":"', p.epochStart.toString(), '",')
            ),
            string.concat(
                string.concat('"EPOCH_DURATION":"', EPOCH_DURATION.toString(), '",'),
                string.concat('"EPOCH_VOTING_CUTOFF":"', EPOCH_VOTING_CUTOFF.toString(), '"') // no comma
            ),
            "}"
        );
    }

    function _getGovernanceManifestJson(DeployGovernanceParams memory p) internal view returns (string memory) {
        return string.concat(
            "{",
            string.concat(
                string.concat('"constants":', _getGovernanceDeploymentConstants(p), ","),
                string.concat('"governance":"', address(governance).toHexString(), '",')
            ),
            string.concat(
                string.concat('"defiCollectiveInitiative":"', defiCollectiveInitiative.toHexString(), '",'),
                string.concat('"stakingV1":"', p.stakingV1.toHexString(), '",'),
                string.concat('"LQTYToken":"', p.lqty.toHexString(), '",'),
                string.concat('"LUSDToken":"', p.lusd.toHexString(), '",'),
                string.concat('"initialInitiatives":', initialInitiatives.toJSON()) // no comma
            ),
            "}"
        );
    }
}
