// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { StrategyTest } from "./base/StrategyTest.t.sol";
import { StrategyType } from "lib/concrete-earn-v2-bug-bounty/src/interface/IStrategyTemplate.sol";

/// @title sroywstETH_Test
/// @notice Concrete test suite for Staked Royco wstETH strategy
contract sroywstETH_Test is StrategyTest {
    function setUp() public {
        _setupStrategyBase();
        _setupInvariantHandler();
    }

    function _strategyName() internal pure override returns (string memory) {
        return "SROYWSTETH";
    }

    function _strategyType() internal pure override returns (StrategyType) {
        return StrategyType.CROSSCHAIN;
    }

    function _forkConfiguration() internal view override returns (uint256 forkBlock, string memory forkRpcUrl) {
        return (24_686_182, vm.envString("MAINNET_RPC_URL"));
    }
}
