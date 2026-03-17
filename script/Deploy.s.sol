// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { RoycoVaultMakinaStrategy } from "../src/RoycoVaultMakinaStrategy.sol";
import { DeploymentConfig } from "./config/DeploymentConfig.sol";
import { Create2DeployUtils } from "./utils/Create2DeployUtils.sol";
import { Script } from "lib/forge-std/src/Script.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

/**
 * @title DeployScript
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice Deployment script for RoycoVaultMakinaStrategy contracts
 * @dev Uses CREATE2 for deterministic deployments across chains
 */
contract DeployScript is Script, Create2DeployUtils, DeploymentConfig {
    /// @notice Salt used for deterministic CREATE2 deployment of strategies
    bytes32 internal constant STRATEGY_DEPLOYMENT_SALT = keccak256(abi.encode("ROYCO_VAULT_MAKINA_STRATEGY"));

    /**
     * @notice Main entry point for deployment via forge script
     * @dev Reads DEPLOYER_PRIVATE_KEY and STRATEGY_NAME from environment variables
     */
    function run() external virtual {
        // Read deployer private key
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Read market name from config
        string memory strategyName = vm.envString("STRATEGY_NAME");

        console2.log("Deploying Makina strategy from config:", strategyName);
        deployFromConfig(strategyName, deployerPrivateKey);
    }

    /**
     * @notice Deploy a strategy using Solidity configuration
     * @dev Uses CREATE2 for deterministic addressing. Will not redeploy if already deployed.
     * @param _strategyName The name of the strategy to deploy (must match a config in DeploymentConfig)
     * @param _deployerPrivateKey The private key of the deployer
     * @return strategy The address of the deployed (or existing) strategy
     */
    function deployFromConfig(string memory _strategyName, uint256 _deployerPrivateKey) public returns (address strategy) {
        // Assemble the init code for the strategy using its configuration
        StrategyDeploymentConfig memory config = _strategyConfigs[_strategyName];
        require(config.roycoFactory != address(0), string.concat("Strategy config not found for: ", _strategyName));
        bytes memory strategyCreationCode = abi.encodePacked(
            type(RoycoVaultMakinaStrategy).creationCode, abi.encode(config.roycoFactory, config.roycoVault, config.makinaMachine, config.strategyType)
        );

        // Deploy the strategy with sanity checks
        vm.startBroadcast(_deployerPrivateKey);
        bool alreadyDeployed;
        (strategy, alreadyDeployed) = _deployWithSanityChecks(STRATEGY_DEPLOYMENT_SALT, strategyCreationCode, false);
        vm.stopBroadcast();

        if (alreadyDeployed) {
            console2.log(_strategyName, " Makina Strategy already deployed at:", strategy);
        } else {
            console2.log(_strategyName, " Makina Strategy deployed at:", strategy);
        }
    }
}
