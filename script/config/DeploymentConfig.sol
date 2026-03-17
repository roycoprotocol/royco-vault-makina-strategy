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

    /// @notice Strategy name identifier for the Vaults
    string internal constant ROYCO_DAWN_SENIOR_VAULT = "DSV";
    string internal constant ROYCO_ETH = "ROYWSTETH";
    string internal constant ROYCO_STAKED_WSTETH = "SROYWSTETH";

    /// @notice Royco Factory address - deployed using CREATE2, consistent across all chains
    address internal constant ROYCO_FACTORY_ADDRESS = 0xD567cCbb336Eb71eC2537057E2bCF6DB840bB71d;

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
        _strategyConfigs[ROYCO_DAWN_SENIOR_VAULT] = StrategyDeploymentConfig({
            roycoFactory: ROYCO_FACTORY_ADDRESS,
            roycoVault: 0xcD9f5907F92818bC06c9Ad70217f089E190d2a32,
            makinaMachine: 0xFa097420f0e2C72456B361a1eD85172B9ccd8c38,
            strategyType: StrategyType.CROSSCHAIN
        });

        _strategyConfigs[ROYCO_ETH] = StrategyDeploymentConfig({
            roycoFactory: ROYCO_FACTORY_ADDRESS,
            roycoVault: 0x41Ce72E04D349Eb957bdc373baA9c69207032c56,
            makinaMachine: 0x0FDF9F1920e160ea8Ae267BdE13e725DeF81E5Ee,
            strategyType: StrategyType.CROSSCHAIN
        });

        _strategyConfigs[ROYCO_STAKED_WSTETH] = StrategyDeploymentConfig({
            roycoFactory: ROYCO_FACTORY_ADDRESS,
            roycoVault: 0xc678159179EEA877608df50c26C048551a3B6a90,
            makinaMachine: 0x6BE5ea969E18BF4c9DE0A00EC4F226055f46aA7D,
            strategyType: StrategyType.CROSSCHAIN
        });
    }
}
