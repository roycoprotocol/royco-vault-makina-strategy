// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAllocateModule } from "lib/concrete-earn-v2-bug-bounty/src/interface/IAllocateModule.sol";
import { IConcreteStandardVaultImpl } from "lib/concrete-earn-v2-bug-bounty/src/interface/IConcreteStandardVaultImpl.sol";
import { ConcreteV2RolesLib } from "lib/concrete-earn-v2-bug-bounty/src/lib/Roles.sol";
import { Test } from "lib/forge-std/src/Test.sol";
import { IMachine } from "lib/makina-core/src/interfaces/IMachine.sol";
import { IAccessControlEnumerable } from "lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RoycoVaultMakinaStrategy } from "src/RoycoVaultMakinaStrategy.sol";

/// @title StrategyInvariantHandler
/// @notice Handler contract for invariant testing of RoycoVaultMakinaStrategy
/// @dev Exposes bounded actions that fuzz testing will call randomly
contract StrategyInvariantHandler is Test {
    // -----------------------------------------
    // State
    // -----------------------------------------
    RoycoVaultMakinaStrategy public strategy;
    IConcreteStandardVaultImpl public vault;
    IMachine public machine;
    IERC20 public asset;
    IERC20 public machineShareToken;

    // Ghost variables for tracking
    uint256 public ghost_allocateCallCount;
    uint256 public ghost_deallocateCallCount;
    uint256 public ghost_withdrawCallCount;

    // Invariant tracking: onWithdraw bounds
    uint256 public ghost_withdrawBoundsViolations;
    uint256 public ghost_lastWithdrawRequested;
    uint256 public ghost_lastWithdrawActual;

    // Actors
    address public allocator;
    address public admin;

    // Bounds
    uint256 public constant MIN_AMOUNT = 1e18;
    uint256 public constant MAX_AMOUNT = 1_000_000e18;

    // -----------------------------------------
    // Constructor
    // -----------------------------------------
    constructor(
        RoycoVaultMakinaStrategy _strategy,
        IConcreteStandardVaultImpl _vault,
        IMachine _machine,
        IERC20 _asset,
        IERC20 _machineShareToken,
        address _allocator,
        address _admin
    ) {
        strategy = _strategy;
        vault = _vault;
        machine = _machine;
        asset = _asset;
        machineShareToken = _machineShareToken;
        allocator = _allocator;
        admin = _admin;
    }

    // -----------------------------------------
    // Handler Actions
    // -----------------------------------------

    /// @notice Allocate assets from vault to strategy
    function allocate(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        // Skip if strategy is paused
        if (strategy.paused()) return;

        // Setup: deal assets to vault and approve strategy
        deal(address(asset), address(vault), asset.balanceOf(address(vault)) + amount);
        vm.prank(address(vault));
        asset.approve(address(strategy), type(uint256).max);

        // Perform allocation through vault
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({ isDeposit: true, strategy: address(strategy), extraData: abi.encode(amount, uint256(0)) });

        vm.prank(allocator);
        try vault.allocate(abi.encode(params)) {
            ghost_allocateCallCount++;
        } catch {
            // Allocation may fail due to machine constraints
        }
    }

    /// @notice Deallocate assets from strategy back to vault
    function deallocate(uint256 sharesFraction) external {
        sharesFraction = bound(sharesFraction, 1, 100); // 1-100% of shares

        // Skip if strategy is paused
        if (strategy.paused()) return;

        uint256 strategyShares = machineShareToken.balanceOf(address(strategy));
        if (strategyShares == 0) return;

        uint256 sharesToRedeem = (strategyShares * sharesFraction) / 100;
        if (sharesToRedeem == 0) return;

        // Ensure machine has liquidity
        uint256 expectedAssets = machine.convertToAssets(sharesToRedeem);
        deal(address(asset), address(machine), asset.balanceOf(address(machine)) + expectedAssets);

        // Perform deallocation through vault
        IAllocateModule.AllocateParams[] memory params = new IAllocateModule.AllocateParams[](1);
        params[0] = IAllocateModule.AllocateParams({ isDeposit: false, strategy: address(strategy), extraData: abi.encode(sharesToRedeem, uint256(0)) });

        vm.prank(allocator);
        try vault.allocate(abi.encode(params)) {
            ghost_deallocateCallCount++;
        } catch {
            // Deallocation may fail
        }
    }

    /// @notice Withdraw assets via onWithdraw
    function withdraw(uint256 amount) external {
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);

        // Skip if strategy is paused
        if (strategy.paused()) return;

        uint256 strategyValue = strategy.totalAllocatedValue();
        if (strategyValue == 0) return;

        // Bound to available value
        amount = bound(amount, MIN_AMOUNT, strategyValue);

        // Ensure machine has liquidity
        deal(address(asset), address(machine), asset.balanceOf(address(machine)) + amount);

        // Calculate max allowed overage (1 share worth)
        uint256 maxOverage = machine.convertToAssets(1);

        vm.prank(address(vault));
        try strategy.onWithdraw(amount) returns (uint256 withdrawn) {
            ghost_lastWithdrawRequested = amount;
            ghost_lastWithdrawActual = withdrawn;
            ghost_withdrawCallCount++;

            // Check bounds: requested <= withdrawn <= requested + 1 share worth
            if (withdrawn < amount || withdrawn > amount + maxOverage) {
                ghost_withdrawBoundsViolations++;
            }
        } catch {
            // Withdraw may fail
        }
    }

    // -----------------------------------------
    // Invariant Checks
    // -----------------------------------------

    /// @notice Returns true if no idle assets in strategy
    function checkNoIdleAssets() external view returns (bool) {
        return asset.balanceOf(address(strategy)) == 0;
    }

    /// @notice Returns true if no withdraw bounds violations occurred
    function checkWithdrawBounds() external view returns (bool) {
        return ghost_withdrawBoundsViolations == 0;
    }
}
