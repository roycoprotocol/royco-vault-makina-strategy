// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { StrategyType } from "../../src/RoycoVaultMakinaStrategy.sol";

/**
 * @title DeploymentConfig
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Configuration contract containing all deployment parameters for RoycoVaultMakinaStrategy
 * @dev Inherit this contract to access strategy deployment configurations. Add new configurations in _initializeStrategyConfigs().
 */
abstract contract DeploymentConfig {
    /// @notice Chain ID for Ethereum Mainnet
    uint256 internal constant MAINNET = 1;

    /// @notice Strategy name identifier for the Royco Dawn Senior Vault
    string internal constant ROYCO_DAWN_SENIOR_VAULT = "DSV";

    // TODO: Update with new Royco Dawn factory address
    /// @notice Royco Factory address - deployed using CREATE2, consistent across all chains
    address internal constant ROYCO_FACTORY_ADDRESS = 0xD567cCbb336Eb71eC2537057E2bCF6DB840bB71d;

    /// @notice Address of the Royco Dawn Senior Vault on Mainnet
    address internal constant DSV = 0xcD9f5907F92818bC06c9Ad70217f089E190d2a32;

    /// @notice Address of the DUSD Makina Machine on Mainnet
    address internal constant DUSD_MAKINA_MACHINE = 0x6b006870C83b1Cd49E766Ac9209f8d68763Df721;

    /**
     * @notice Configuration parameters for deploying a strategy
     * @param roycoFactory The address of the Royco factory (serves as AccessManager)
     * @param roycoVault The address of the Royco vault this strategy is for
     * @param makinaMachine The address of the Makina machine to allocate into
     * @param strategyType The operational type of the strategy (ATOMIC, ASYNC, or CROSSCHAIN)
     */
    struct StrategyDeploymentConfig {
        address roycoFactory;
        address roycoVault;
        address makinaMachine;
        StrategyType strategyType;
    }

    /// @notice Mapping of strategy names to their deployment configurations
    mapping(string strategyName => StrategyDeploymentConfig) internal _strategyConfigs;

    /**
     * @notice Initializes the deployment configurations
     * @dev Called in constructor to populate _strategyConfigs mapping
     */
    constructor() {
        _initializeStrategyConfigs();
    }

    /**
     * @notice Populates the strategy configurations mapping
     * @dev Add new strategy configurations here when deploying new strategies
     */
    function _initializeStrategyConfigs() internal {
        // TODO: Update with new Makina machine when deployed
        _strategyConfigs[ROYCO_DAWN_SENIOR_VAULT] = StrategyDeploymentConfig({
            roycoFactory: ROYCO_FACTORY_ADDRESS, roycoVault: DSV, makinaMachine: DUSD_MAKINA_MACHINE, strategyType: StrategyType.CROSSCHAIN
        });
    }
}
