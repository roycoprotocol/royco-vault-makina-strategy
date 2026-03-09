// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBase } from "../../base/TestBase.sol";
import { StrategyInvariantHandler } from "./StrategyInvariantHandler.sol";
import { StrategyType } from "lib/concrete-earn-v2-bug-bounty/src/interface/IStrategyTemplate.sol";
import { ConcreteV2RolesLib } from "lib/concrete-earn-v2-bug-bounty/src/lib/Roles.sol";
import { IMachine } from "lib/makina-core/src/interfaces/IMachine.sol";
import { IAccessManaged } from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManaged.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Pausable } from "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import { RoycoVaultMakinaStrategy } from "src/RoycoVaultMakinaStrategy.sol";

/// @title StrategyTest
/// @notice Comprehensive test suite for RoycoVaultMakinaStrategy
/// @dev Inherit this contract and implement _forkConfiguration() and setUp() for concrete tests
abstract contract StrategyTest is TestBase {
    // -----------------------------------------
    // Test Constants
    // -----------------------------------------
    uint256 internal ALLOCATION_AMOUNT; // For unit tests - 1000 tokens
    uint256 internal MIN_FUZZ_AMOUNT; // For fuzz tests - 1 token
    uint256 internal MAX_FUZZ_AMOUNT; // For fuzz tests - 1M tokens
    uint256 internal constant MIN_SHARES_OUT = 0;
    uint256 internal constant MIN_ASSETS_OUT = 0;

    // -----------------------------------------
    // Setup Hook (override in child)
    // -----------------------------------------
    function _strategyName() internal virtual returns (string memory);

    function _strategyType() internal view virtual returns (StrategyType) {
        return StrategyType.ATOMIC;
    }

    function _setupStrategyBase() internal {
        _setUpTestBase(_strategyName());
        _deployStrategy(_strategyName());

        // Set test amounts based on asset decimals
        uint8 decimals = IERC20Metadata(address(ASSET)).decimals();
        ALLOCATION_AMOUNT = 1_000_000 * (10 ** decimals); // 1M tokens for unit tests
        MIN_FUZZ_AMOUNT = 10 ** decimals; // 1 token minimum for fuzz tests
        MAX_FUZZ_AMOUNT = 100_000_000 * (10 ** decimals); // 100M tokens maximum for fuzz tests
    }

    // =========================================
    // UNIT TESTS: Constructor
    // =========================================

    function test_constructor_setsImmutablesCorrectly() public view {
        assertEq(STRATEGY.asset(), address(ASSET), "Asset mismatch");
        assertEq(STRATEGY.getVault(), address(ROYCO_VAULT), "Vault mismatch");
        assertEq(STRATEGY.getMakinaMachine(), address(MAKINA_MACHINE), "Machine mismatch");
        assertEq(uint8(STRATEGY.strategyType()), uint8(_strategyType()), "Strategy type mismatch");
    }

    function test_constructor_grantsMaxApprovalToMachine() public view {
        uint256 allowance = ASSET.allowance(address(STRATEGY), address(MAKINA_MACHINE));
        assertEq(allowance, type(uint256).max, "Approval not granted");
    }

    function test_constructor_reverts_onDisparateAssets() public {
        // Deploy a mock machine with different asset
        address mockMachine = makeAddr("MOCK_MACHINE");
        address differentAsset = makeAddr("DIFFERENT_ASSET");
        vm.mockCall(mockMachine, abi.encodeWithSelector(IMachine.accountingToken.selector), abi.encode(differentAsset));
        vm.mockCall(mockMachine, abi.encodeWithSelector(IMachine.shareToken.selector), abi.encode(makeAddr("SHARE")));

        vm.expectRevert(RoycoVaultMakinaStrategy.DISPARATE_VAULT_AND_MACHINE_ASSETS.selector);
        new RoycoVaultMakinaStrategy(ROYCO_FACTORY_ADDRESS, address(ROYCO_VAULT), mockMachine, StrategyType.ATOMIC);
    }

    // =========================================
    // UNIT TESTS: allocateFunds
    // =========================================

    function test_allocateFunds_success() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);

        uint256 vaultBalBefore = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 strategySharesBefore = _getStrategyShares();
        uint256 strategyAssetBalBefore = ASSET.balanceOf(address(STRATEGY));
        uint256 machineAssetBalBefore = ASSET.balanceOf(address(MAKINA_MACHINE));

        // Calculate expected shares before allocation
        uint256 expectedShares = MAKINA_MACHINE.convertToShares(amount);

        _allocateToStrategy(amount, MIN_SHARES_OUT);

        uint256 vaultBalAfter = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 strategySharesAfter = _getStrategyShares();
        uint256 strategyAssetBalAfter = ASSET.balanceOf(address(STRATEGY));
        uint256 machineAssetBalAfter = ASSET.balanceOf(address(MAKINA_MACHINE));

        // Exact vault balance decrease
        assertEq(vaultBalBefore - vaultBalAfter, amount, "Vault balance should decrease by exact amount");
        // Exact shares minted to strategy
        assertEq(strategySharesAfter - strategySharesBefore, expectedShares, "Strategy should receive exact expected shares");
        // Strategy should hold no idle assets (all transferred to machine)
        assertEq(strategyAssetBalAfter, strategyAssetBalBefore, "Strategy should hold no idle assets");
        // Machine should receive the exact amount
        assertEq(machineAssetBalAfter - machineAssetBalBefore, amount, "Machine should receive exact amount");
    }

    function test_allocateFunds_returnsExactAmount() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);

        bytes memory params = _encodeAllocationParams(amount, MIN_SHARES_OUT);
        vm.prank(address(ROYCO_VAULT));
        uint256 returnedAmount = STRATEGY.allocateFunds(params);

        // Return value must exactly match the allocated amount
        assertEq(returnedAmount, amount, "Return value should exactly match allocated amount");
    }

    function test_allocateFunds_emitsEvent() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);

        vm.expectEmit(true, true, true, true, address(STRATEGY));
        emit RoycoVaultMakinaStrategy.AllocateFunds(amount);

        _allocateToStrategy(amount, MIN_SHARES_OUT);
    }

    function test_allocateFunds_reverts_whenPaused() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);

        _pauseStrategy();

        // Call strategy directly (not through vault) to test pause revert
        bytes memory params = _encodeAllocationParams(amount, MIN_SHARES_OUT);
        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        STRATEGY.allocateFunds(params);
    }

    function test_allocateFunds_reverts_onInvalidParams() public {
        bytes memory invalidParams = abi.encode(uint256(100)); // Only 32 bytes, need 64

        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_ALLOCATION_PARAMS.selector);
        STRATEGY.allocateFunds(invalidParams);
    }

    function test_allocateFunds_reverts_onEmptyParams() public {
        bytes memory emptyParams = "";

        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_ALLOCATION_PARAMS.selector);
        STRATEGY.allocateFunds(emptyParams);
    }

    function test_allocateFunds_reverts_onExcessiveParams() public {
        bytes memory excessiveParams = abi.encode(uint256(100), uint256(0), uint256(999)); // 96 bytes

        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_ALLOCATION_PARAMS.selector);
        STRATEGY.allocateFunds(excessiveParams);
    }

    function test_allocateFunds_reverts_onNonVaultCaller() public {
        bytes memory params = _encodeAllocationParams(ALLOCATION_AMOUNT, MIN_SHARES_OUT);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(RoycoVaultMakinaStrategy.ONLY_ROYCO_VAULT.selector);
        STRATEGY.allocateFunds(params);
    }

    // =========================================
    // UNIT TESTS: deallocateFunds
    // =========================================

    function test_deallocateFunds_success() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);

        uint256 sharesToRedeem = _getStrategyShares();
        _dealAssetToMachine(amount); // Ensure machine has liquidity

        uint256 vaultBalBefore = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineAssetBalBefore = ASSET.balanceOf(address(MAKINA_MACHINE));
        uint256 strategyAssetBalBefore = ASSET.balanceOf(address(STRATEGY));

        // Calculate expected assets before deallocation
        uint256 expectedAssets = MAKINA_MACHINE.convertToAssets(sharesToRedeem);

        _deallocateFromStrategy(sharesToRedeem, MIN_ASSETS_OUT);

        uint256 vaultBalAfter = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineAssetBalAfter = ASSET.balanceOf(address(MAKINA_MACHINE));
        uint256 strategyAssetBalAfter = ASSET.balanceOf(address(STRATEGY));

        // Exact vault balance increase
        assertEq(vaultBalAfter - vaultBalBefore, expectedAssets, "Vault should receive exact expected assets");
        // Strategy shares should be exactly zero
        assertEq(_getStrategyShares(), 0, "Strategy shares should be exactly zero");
        // Machine balance should decrease by exact amount
        assertEq(machineAssetBalBefore - machineAssetBalAfter, expectedAssets, "Machine balance should decrease by exact amount");
        // Strategy should hold no idle assets
        assertEq(strategyAssetBalAfter, strategyAssetBalBefore, "Strategy should hold no idle assets");
    }

    function test_deallocateFunds_returnsExactAmount() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);

        uint256 sharesToRedeem = _getStrategyShares();
        _dealAssetToMachine(amount);

        // Calculate expected assets
        uint256 expectedAssets = MAKINA_MACHINE.convertToAssets(sharesToRedeem);

        bytes memory params = _encodeDeallocationParams(sharesToRedeem, MIN_ASSETS_OUT);
        vm.prank(address(ROYCO_VAULT));
        uint256 returnedAmount = STRATEGY.deallocateFunds(params);

        // Return value must exactly match the deallocated amount
        assertEq(returnedAmount, expectedAssets, "Return value should exactly match deallocated amount");
    }

    function test_deallocateFunds_emitsEvent() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);

        uint256 sharesToRedeem = _getStrategyShares();
        _dealAssetToMachine(amount);

        // Calculate exact expected assets
        uint256 expectedAssets = MAKINA_MACHINE.convertToAssets(sharesToRedeem);

        // Expect exact event with exact amount
        vm.expectEmit(true, true, true, true, address(STRATEGY));
        emit RoycoVaultMakinaStrategy.DeallocateFunds(expectedAssets);

        bytes memory params = _encodeDeallocationParams(sharesToRedeem, MIN_ASSETS_OUT);
        vm.prank(address(ROYCO_VAULT));
        STRATEGY.deallocateFunds(params);
    }

    function test_deallocateFunds_reverts_whenPaused() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);

        uint256 sharesToRedeem = _getStrategyShares();
        _pauseStrategy();

        // Call strategy directly (not through vault) to test pause revert
        bytes memory params = _encodeDeallocationParams(sharesToRedeem, MIN_ASSETS_OUT);
        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        STRATEGY.deallocateFunds(params);
    }

    function test_deallocateFunds_reverts_onInvalidParams() public {
        bytes memory invalidParams = abi.encode(uint256(100)); // Only 32 bytes

        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_DEALLOCATION_PARAMS.selector);
        STRATEGY.deallocateFunds(invalidParams);
    }

    function test_deallocateFunds_reverts_onEmptyParams() public {
        bytes memory emptyParams = "";

        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_DEALLOCATION_PARAMS.selector);
        STRATEGY.deallocateFunds(emptyParams);
    }

    function test_deallocateFunds_reverts_onExcessiveParams() public {
        bytes memory excessiveParams = abi.encode(uint256(100), uint256(0), uint256(999)); // 96 bytes

        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_DEALLOCATION_PARAMS.selector);
        STRATEGY.deallocateFunds(excessiveParams);
    }

    function test_deallocateFunds_reverts_onNonVaultCaller() public {
        bytes memory params = _encodeDeallocationParams(100, MIN_ASSETS_OUT);

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(RoycoVaultMakinaStrategy.ONLY_ROYCO_VAULT.selector);
        STRATEGY.deallocateFunds(params);
    }

    // =========================================
    // UNIT TESTS: onWithdraw
    // =========================================

    function test_onWithdraw_success() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);

        uint256 withdrawAmount = amount / 2;
        _dealAssetToMachine(amount);

        uint256 vaultBalBefore = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineBalBefore = ASSET.balanceOf(address(MAKINA_MACHINE));
        uint256 strategySharesBefore = _getStrategyShares();
        uint256 strategyAssetBalBefore = ASSET.balanceOf(address(STRATEGY));

        // Calculate exact expected shares to redeem (mirrors contract logic)
        uint256 expectedSharesToRedeem = MAKINA_MACHINE.convertToShares(withdrawAmount) + 1;
        expectedSharesToRedeem = expectedSharesToRedeem > strategySharesBefore ? strategySharesBefore : expectedSharesToRedeem;
        uint256 expectedWithdrawn = MAKINA_MACHINE.convertToAssets(expectedSharesToRedeem);

        vm.prank(address(ROYCO_VAULT));
        uint256 withdrawn = STRATEGY.onWithdraw(withdrawAmount);

        uint256 vaultBalAfter = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineBalAfter = ASSET.balanceOf(address(MAKINA_MACHINE));
        uint256 strategySharesAfter = _getStrategyShares();
        uint256 strategyAssetBalAfter = ASSET.balanceOf(address(STRATEGY));

        // Exact return value verification
        assertEq(withdrawn, expectedWithdrawn, "Return value should match expected withdrawn amount");
        // Exact vault balance increase
        assertEq(vaultBalAfter - vaultBalBefore, expectedWithdrawn, "Vault balance should increase by exact withdrawn amount");
        // Exact machine balance decrease
        assertEq(machineBalBefore - machineBalAfter, expectedWithdrawn, "Machine balance should decrease by exact withdrawn amount");
        // Exact shares consumed
        assertEq(strategySharesBefore - strategySharesAfter, expectedSharesToRedeem, "Exact shares should be consumed");
        // Strategy should hold no idle assets
        assertEq(strategyAssetBalAfter, strategyAssetBalBefore, "Strategy should hold no idle assets");
        // Withdrawn should be >= requested (due to +1 padding)
        assertGe(withdrawn, withdrawAmount, "Withdrawn should be at least requested amount");
        // Overage should be bounded by 1 share worth (the +1 padding)
        assertLe(withdrawn - withdrawAmount, MAKINA_MACHINE.convertToAssets(1), "Overage should be at most 1 share worth");
    }

    function test_onWithdraw_emitsEvent() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);
        _dealAssetToMachine(amount);

        uint256 withdrawAmount = amount / 2;
        uint256 strategyShares = _getStrategyShares();

        // Calculate exact expected withdrawn amount (mirrors contract logic)
        uint256 expectedSharesToRedeem = MAKINA_MACHINE.convertToShares(withdrawAmount) + 1;
        expectedSharesToRedeem = expectedSharesToRedeem > strategyShares ? strategyShares : expectedSharesToRedeem;
        uint256 expectedWithdrawn = MAKINA_MACHINE.convertToAssets(expectedSharesToRedeem);

        // Expect exact event with exact amount
        vm.expectEmit(true, true, true, true, address(STRATEGY));
        emit RoycoVaultMakinaStrategy.StrategyWithdraw(expectedWithdrawn);

        vm.prank(address(ROYCO_VAULT));
        STRATEGY.onWithdraw(withdrawAmount);
    }

    function test_onWithdraw_reverts_whenPaused() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);

        _pauseStrategy();

        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        STRATEGY.onWithdraw(amount / 2);
    }

    function test_onWithdraw_reverts_onNonVaultCaller() public {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(RoycoVaultMakinaStrategy.ONLY_ROYCO_VAULT.selector);
        STRATEGY.onWithdraw(100);
    }

    // =========================================
    // UNIT TESTS: rescueToken
    // =========================================

    function test_rescueToken_success() public {
        // Use the base asset for rescue test (it's a real ERC20)
        uint256 rescueAmount = ALLOCATION_AMOUNT;
        deal(address(ASSET), address(STRATEGY), rescueAmount);

        address admin = _getAuthorizedAdmin();
        uint256 adminBalBefore = ASSET.balanceOf(admin);

        vm.prank(admin);
        STRATEGY.rescueToken(address(ASSET), rescueAmount);

        assertEq(ASSET.balanceOf(admin) - adminBalBefore, rescueAmount, "Token not rescued");
        assertEq(ASSET.balanceOf(address(STRATEGY)), 0, "Strategy balance not zeroed");
    }

    function test_rescueToken_rescuesEntireBalance_whenAmountIsZero() public {
        uint256 tokenBalance = ALLOCATION_AMOUNT * 5;
        deal(address(ASSET), address(STRATEGY), tokenBalance);

        address admin = _getAuthorizedAdmin();
        uint256 adminBalBefore = ASSET.balanceOf(admin);

        vm.prank(admin);
        STRATEGY.rescueToken(address(ASSET), 0);

        assertEq(ASSET.balanceOf(admin) - adminBalBefore, tokenBalance, "Full balance not rescued");
    }

    function test_rescueToken_reverts_onMachineShareToken() public {
        address admin = _getAuthorizedAdmin();

        vm.prank(admin);
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_TOKEN_TO_RESCUE.selector);
        STRATEGY.rescueToken(address(MACHINE_SHARE_TOKEN), 100);
    }

    function test_rescueToken_reverts_onUnauthorizedCaller() public {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        STRATEGY.rescueToken(address(ASSET), 100);
    }

    function test_rescueToken_worksWhenPaused() public {
        uint256 rescueAmount = ALLOCATION_AMOUNT;
        deal(address(ASSET), address(STRATEGY), rescueAmount);

        _pauseStrategy();

        address admin = _getAuthorizedAdmin();
        uint256 adminBalBefore = ASSET.balanceOf(admin);

        vm.prank(admin);
        STRATEGY.rescueToken(address(ASSET), rescueAmount);

        assertEq(ASSET.balanceOf(admin) - adminBalBefore, rescueAmount, "Token not rescued while paused");
    }

    function test_rescueToken_canRescueBaseAsset() public {
        // Base asset should be rescuable since it's only transiently held
        uint256 rescueAmount = ALLOCATION_AMOUNT / 2;
        deal(address(ASSET), address(STRATEGY), rescueAmount);

        address admin = _getAuthorizedAdmin();
        uint256 adminBalBefore = ASSET.balanceOf(admin);

        vm.prank(admin);
        STRATEGY.rescueToken(address(ASSET), rescueAmount);

        assertEq(ASSET.balanceOf(admin) - adminBalBefore, rescueAmount, "Base asset not rescued");
    }

    // =========================================
    // UNIT TESTS: pause/unpause
    // =========================================

    function test_pause_success() public {
        assertFalse(STRATEGY.paused(), "Should not start paused");

        address admin = _getAuthorizedAdmin();
        vm.prank(admin);
        STRATEGY.pause();

        assertTrue(STRATEGY.paused(), "Should be paused");
    }

    function test_unpause_success() public {
        _pauseStrategy();
        assertTrue(STRATEGY.paused(), "Should be paused");

        address admin = _getAuthorizedAdmin();
        vm.prank(admin);
        STRATEGY.unpause();

        assertFalse(STRATEGY.paused(), "Should be unpaused");
    }

    function test_pause_reverts_onUnauthorizedCaller() public {
        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        STRATEGY.pause();
    }

    function test_unpause_reverts_onUnauthorizedCaller() public {
        _pauseStrategy();

        vm.prank(ALICE_ADDRESS);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ALICE_ADDRESS));
        STRATEGY.unpause();
    }

    function test_pause_reverts_whenAlreadyPaused() public {
        _pauseStrategy();

        address admin = _getAuthorizedAdmin();
        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        STRATEGY.pause();
    }

    function test_unpause_reverts_whenNotPaused() public {
        address admin = _getAuthorizedAdmin();
        vm.prank(admin);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        STRATEGY.unpause();
    }

    // =========================================
    // UNIT TESTS: View Functions
    // =========================================

    function test_totalAllocatedValue_returnsZero_whenNoAllocation() public view {
        assertEq(STRATEGY.totalAllocatedValue(), 0, "Should be zero initially");
    }

    function test_totalAllocatedValue_returnsCorrectValue_afterAllocation() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);

        // Calculate expected shares before allocation
        uint256 expectedShares = MAKINA_MACHINE.convertToShares(amount);

        _allocateToStrategy(amount, MIN_SHARES_OUT);

        // Calculate exact expected value from shares
        uint256 expectedValue = MAKINA_MACHINE.convertToAssets(expectedShares);

        uint256 allocatedValue = STRATEGY.totalAllocatedValue();
        // Must match exactly - no tolerance
        assertEq(allocatedValue, expectedValue, "Allocated value should match exactly");
    }

    function test_maxAllocation_returnsMaxUint256_whenMachineReturnsMaxUint256() public {
        // Mock maxMint to return type(uint256).max
        vm.mockCall(address(MAKINA_MACHINE), abi.encodeWithSelector(IMachine.maxMint.selector), abi.encode(type(uint256).max));

        uint256 maxAlloc = STRATEGY.maxAllocation();
        assertEq(maxAlloc, type(uint256).max, "Should return max uint256");
    }

    function test_maxAllocation_returnsConvertedValue_whenMachineReturnsFiniteValue() public {
        uint256 finiteMaxMint = 1000e18;
        uint256 expectedAssets = MAKINA_MACHINE.convertToAssets(finiteMaxMint);

        // Mock maxMint to return a finite value
        vm.mockCall(address(MAKINA_MACHINE), abi.encodeWithSelector(IMachine.maxMint.selector), abi.encode(finiteMaxMint));

        uint256 maxAlloc = STRATEGY.maxAllocation();
        assertEq(maxAlloc, expectedAssets, "Should return converted asset value");
    }

    function test_maxWithdraw_returnsZero_whenNoAllocation() public view {
        assertEq(STRATEGY.maxWithdraw(), 0, "Should be zero initially");
    }

    function test_maxWithdraw_returnsCorrectValue_afterAllocation() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);

        // Calculate expected shares before allocation
        uint256 expectedShares = MAKINA_MACHINE.convertToShares(amount);

        _allocateToStrategy(amount, MIN_SHARES_OUT);
        _dealAssetToMachine(amount);

        // Calculate exact expected max withdraw
        // maxWithdraw = min(machine.maxWithdraw(), strategy.totalAllocatedValue())
        uint256 machineMaxWithdraw = MAKINA_MACHINE.maxWithdraw();
        uint256 strategyValue = MAKINA_MACHINE.convertToAssets(expectedShares);
        uint256 expectedMaxWithdraw = machineMaxWithdraw < strategyValue ? machineMaxWithdraw : strategyValue;

        uint256 maxWithdrawable = STRATEGY.maxWithdraw();
        assertEq(maxWithdrawable, expectedMaxWithdraw, "Max withdraw should match exactly");
    }

    function test_asset_returnsCorrectAddress() public view {
        assertEq(STRATEGY.asset(), address(ASSET), "Asset mismatch");
    }

    function test_getVault_returnsCorrectAddress() public view {
        assertEq(STRATEGY.getVault(), address(ROYCO_VAULT), "Vault mismatch");
    }

    function test_getMakinaMachine_returnsCorrectAddress() public view {
        assertEq(STRATEGY.getMakinaMachine(), address(MAKINA_MACHINE), "Machine mismatch");
    }

    function test_strategyType_returnsCorrectType() public view {
        assertEq(uint8(STRATEGY.strategyType()), uint8(_strategyType()), "Strategy type mismatch");
    }

    // =========================================
    // FUZZ TESTS
    // =========================================

    function testFuzz_allocateFunds_variousAmounts(uint256 amount) public {
        // Bound by Machine's max allocation to avoid ExceededMaxMint errors
        uint256 maxAlloc = STRATEGY.maxAllocation();
        if (maxAlloc < MIN_FUZZ_AMOUNT) return; // Skip if machine can't accept minimum
        amount = bound(amount, MIN_FUZZ_AMOUNT, maxAlloc > MAX_FUZZ_AMOUNT ? MAX_FUZZ_AMOUNT : maxAlloc);
        _setupAllocationScenario(amount);

        uint256 sharesBefore = _getStrategyShares();
        uint256 vaultBalBefore = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineBalBefore = ASSET.balanceOf(address(MAKINA_MACHINE));

        // Calculate exact expected shares
        uint256 expectedShares = MAKINA_MACHINE.convertToShares(amount);

        _allocateToStrategy(amount, MIN_SHARES_OUT);

        uint256 sharesAfter = _getStrategyShares();
        uint256 vaultBalAfter = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineBalAfter = ASSET.balanceOf(address(MAKINA_MACHINE));

        // Exact checks
        assertEq(sharesAfter - sharesBefore, expectedShares, "Shares minted should match expected");
        assertEq(vaultBalBefore - vaultBalAfter, amount, "Vault balance should decrease by exact amount");
        assertEq(machineBalAfter - machineBalBefore, amount, "Machine balance should increase by exact amount");
        assertEq(ASSET.balanceOf(address(STRATEGY)), 0, "Strategy should hold no idle assets");
    }

    function testFuzz_deallocateFunds_variousAmounts(uint256 amount) public {
        // Bound by Machine's max allocation to avoid ExceededMaxMint errors
        uint256 maxAlloc = STRATEGY.maxAllocation();
        if (maxAlloc < MIN_FUZZ_AMOUNT) return; // Skip if machine can't accept minimum
        amount = bound(amount, MIN_FUZZ_AMOUNT, maxAlloc > MAX_FUZZ_AMOUNT ? MAX_FUZZ_AMOUNT : maxAlloc);
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);

        uint256 shares = _getStrategyShares();
        _dealAssetToMachine(amount);

        // Calculate exact expected assets
        uint256 expectedAssets = MAKINA_MACHINE.convertToAssets(shares);

        uint256 vaultBalBefore = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineBalBefore = ASSET.balanceOf(address(MAKINA_MACHINE));

        _deallocateFromStrategy(shares, MIN_ASSETS_OUT);

        uint256 vaultBalAfter = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineBalAfter = ASSET.balanceOf(address(MAKINA_MACHINE));

        // Exact checks
        assertEq(vaultBalAfter - vaultBalBefore, expectedAssets, "Vault should receive exact expected assets");
        assertEq(machineBalBefore - machineBalAfter, expectedAssets, "Machine balance should decrease by exact amount");
        assertEq(_getStrategyShares(), 0, "Strategy shares should be exactly zero");
        assertEq(ASSET.balanceOf(address(STRATEGY)), 0, "Strategy should hold no idle assets");
    }

    function testFuzz_onWithdraw_variousAmounts(uint256 allocAmount, uint256 withdrawAmount) public {
        // Bound by Machine's max allocation to avoid ExceededMaxMint errors
        uint256 maxAlloc = STRATEGY.maxAllocation();
        if (maxAlloc < MIN_FUZZ_AMOUNT) return; // Skip if machine can't accept minimum
        allocAmount = bound(allocAmount, MIN_FUZZ_AMOUNT, maxAlloc > MAX_FUZZ_AMOUNT ? MAX_FUZZ_AMOUNT : maxAlloc);

        _setupAllocationScenario(allocAmount);
        _allocateToStrategy(allocAmount, MIN_SHARES_OUT);
        _dealAssetToMachine(allocAmount * 2); // Extra liquidity for rounding

        // Bound to maxWithdraw - this is how the vault uses onWithdraw (it checks maxWithdraw first)
        uint256 maxWithdrawable = STRATEGY.maxWithdraw();
        if (maxWithdrawable < MIN_FUZZ_AMOUNT) return; // Skip if not enough to withdraw
        withdrawAmount = bound(withdrawAmount, MIN_FUZZ_AMOUNT, maxWithdrawable);

        uint256 strategySharesBefore = _getStrategyShares();
        uint256 vaultBalBefore = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineBalBefore = ASSET.balanceOf(address(MAKINA_MACHINE));

        // Calculate exact expected values (mirrors contract logic)
        uint256 expectedSharesToRedeem = MAKINA_MACHINE.convertToShares(withdrawAmount) + 1;
        expectedSharesToRedeem = expectedSharesToRedeem > strategySharesBefore ? strategySharesBefore : expectedSharesToRedeem;
        uint256 expectedWithdrawn = MAKINA_MACHINE.convertToAssets(expectedSharesToRedeem);

        vm.prank(address(ROYCO_VAULT));
        uint256 withdrawn = STRATEGY.onWithdraw(withdrawAmount);

        uint256 strategySharesAfter = _getStrategyShares();
        uint256 vaultBalAfter = ASSET.balanceOf(address(ROYCO_VAULT));
        uint256 machineBalAfter = ASSET.balanceOf(address(MAKINA_MACHINE));

        // Exact checks
        assertEq(withdrawn, expectedWithdrawn, "Withdrawn should match expected");
        assertEq(vaultBalAfter - vaultBalBefore, expectedWithdrawn, "Vault balance should increase by exact withdrawn");
        assertEq(machineBalBefore - machineBalAfter, expectedWithdrawn, "Machine balance should decrease by exact withdrawn");
        assertEq(strategySharesBefore - strategySharesAfter, expectedSharesToRedeem, "Exact shares should be consumed");
        assertGe(withdrawn, withdrawAmount, "Should withdraw at least requested amount");
        assertLe(withdrawn - withdrawAmount, MAKINA_MACHINE.convertToAssets(1), "Overage should be at most 1 share worth");
        assertEq(ASSET.balanceOf(address(STRATEGY)), 0, "Strategy should hold no idle assets");
    }

    function testFuzz_rescueToken_variousAmounts(uint256 amount) public {
        amount = bound(amount, MIN_FUZZ_AMOUNT, MAX_FUZZ_AMOUNT);

        address admin = _getAuthorizedAdmin();

        // Deal base asset instead of random token (which has no ERC20 implementation)
        deal(address(ASSET), address(STRATEGY), amount);

        uint256 adminBalBefore = ASSET.balanceOf(admin);
        vm.prank(admin);
        STRATEGY.rescueToken(address(ASSET), amount);

        assertEq(ASSET.balanceOf(admin) - adminBalBefore, amount, "Amount not rescued");
    }

    function testFuzz_allocateFunds_reverts_onInvalidParamsLength(uint8 length) public {
        vm.assume(length != 64);

        bytes memory params = new bytes(length);
        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_ALLOCATION_PARAMS.selector);
        STRATEGY.allocateFunds(params);
    }

    function testFuzz_deallocateFunds_reverts_onInvalidParamsLength(uint8 length) public {
        vm.assume(length != 64);

        bytes memory params = new bytes(length);
        vm.prank(address(ROYCO_VAULT));
        vm.expectRevert(RoycoVaultMakinaStrategy.INVALID_DEALLOCATION_PARAMS.selector);
        STRATEGY.deallocateFunds(params);
    }

    // =========================================
    // EDGE CASE TESTS
    // =========================================

    function test_allocateFunds_withZeroMinShares() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);

        // Should work with 0 minSharesOut
        _allocateToStrategy(amount, 0);
        assertGt(_getStrategyShares(), 0, "Should have shares");
    }

    function test_deallocateFunds_withZeroMinAssets() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);
        _dealAssetToMachine(amount);

        // Should work with 0 minAssetsOut
        _deallocateFromStrategy(_getStrategyShares(), 0);
        assertEq(_getStrategyShares(), 0, "Shares should be zero");
    }

    function test_onWithdraw_withZeroAmount() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);
        _dealAssetToMachine(amount);

        uint256 sharesBefore = _getStrategyShares();

        vm.prank(address(ROYCO_VAULT));
        STRATEGY.onWithdraw(0);

        // With 0 amount, convertToShares(0) + 1 = 1 share redeemed
        assertLe(_getStrategyShares(), sharesBefore, "Some shares may be redeemed");
    }

    function test_multipleAllocationsAndDeallocations() public {
        uint256 amount = ALLOCATION_AMOUNT;

        // Allocate 3 times
        for (uint256 i = 0; i < 3; i++) {
            _setupAllocationScenario(amount);
            _allocateToStrategy(amount, MIN_SHARES_OUT);
        }

        uint256 totalShares = _getStrategyShares();
        assertGt(totalShares, 0, "Should have accumulated shares");

        // Deallocate in parts
        _dealAssetToMachine(amount * 5);

        uint256 sharesToRedeem = totalShares / 3;
        for (uint256 i = 0; i < 3; i++) {
            if (_getStrategyShares() > 0) {
                uint256 redeemAmount = i == 2 ? _getStrategyShares() : sharesToRedeem;
                _deallocateFromStrategy(redeemAmount, MIN_ASSETS_OUT);
            }
        }

        assertEq(_getStrategyShares(), 0, "All shares should be redeemed");
    }

    function test_pauseUnpauseCycle() public {
        address admin = _getAuthorizedAdmin();

        // Multiple pause/unpause cycles
        for (uint256 i = 0; i < 3; i++) {
            assertFalse(STRATEGY.paused(), "Should not be paused");

            vm.prank(admin);
            STRATEGY.pause();
            assertTrue(STRATEGY.paused(), "Should be paused");

            vm.prank(admin);
            STRATEGY.unpause();
            assertFalse(STRATEGY.paused(), "Should be unpaused");
        }
    }

    // =========================================
    // ADVERSARIAL TESTS
    // =========================================

    function test_adversarial_directMachineInteraction() public {
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);
        _allocateToStrategy(amount, MIN_SHARES_OUT);

        // Attacker tries to redeem strategy's shares directly from machine
        uint256 strategyShares = _getStrategyShares();
        assertGt(strategyShares, 0, "Strategy should have shares");

        // Machine should reject redemption from non-redeemer
        vm.prank(ALICE_ADDRESS);
        // This should revert because ALICE is not the redeemer
        vm.expectRevert();
        IMachine(address(MAKINA_MACHINE)).redeem(strategyShares, ALICE_ADDRESS, 0);
    }

    function test_adversarial_stateConsistencyAfterAllocation() public {
        // Verify state consistency after allocation operations
        uint256 amount = ALLOCATION_AMOUNT;
        _setupAllocationScenario(amount);

        uint256 vaultBalBefore = ASSET.balanceOf(address(ROYCO_VAULT));
        _allocateToStrategy(amount, MIN_SHARES_OUT);
        uint256 vaultBalAfter = ASSET.balanceOf(address(ROYCO_VAULT));

        // Verify exact amount was transferred (no funds lost or double-counted)
        assertEq(vaultBalBefore - vaultBalAfter, amount, "Exact amount should be transferred");
    }

    function test_adversarial_pauseDoesNotAffectRescue() public {
        uint256 rescueAmount = ALLOCATION_AMOUNT;
        deal(address(ASSET), address(STRATEGY), rescueAmount);

        _pauseStrategy();

        // Rescue should still work when paused
        address admin = _getAuthorizedAdmin();
        uint256 adminBalBefore = ASSET.balanceOf(admin);

        vm.prank(admin);
        STRATEGY.rescueToken(address(ASSET), rescueAmount);

        assertEq(ASSET.balanceOf(address(STRATEGY)), 0, "Token should be rescued");
        assertEq(ASSET.balanceOf(admin) - adminBalBefore, rescueAmount, "Admin should receive token");
    }

    function test_adversarial_cannotBypassVaultRestriction() public {
        bytes memory params = _encodeAllocationParams(ALLOCATION_AMOUNT, MIN_SHARES_OUT);

        // Try from various addresses
        address[] memory attackers = new address[](4);
        attackers[0] = ALICE_ADDRESS;
        attackers[1] = address(MAKINA_MACHINE);
        attackers[2] = address(STRATEGY);
        attackers[3] = address(this);

        for (uint256 i = 0; i < attackers.length; i++) {
            vm.prank(attackers[i]);
            vm.expectRevert(RoycoVaultMakinaStrategy.ONLY_ROYCO_VAULT.selector);
            STRATEGY.allocateFunds(params);
        }
    }

    // =========================================
    // STATEFUL INVARIANT TESTS
    // =========================================

    StrategyInvariantHandler internal handler;

    function _setupInvariantHandler() internal {
        address allocator = _getRoleHolder(address(ROYCO_VAULT), ConcreteV2RolesLib.ALLOCATOR);

        handler = new StrategyInvariantHandler(STRATEGY, ROYCO_VAULT, MAKINA_MACHINE, ASSET, MACHINE_SHARE_TOKEN, allocator, DEPLOYER_ADDRESS);

        // Target only the handler for invariant testing
        targetContract(address(handler));
    }

    /// @notice Invariant: Strategy never holds idle assets after any sequence of operations
    function invariant_noIdleAssets() public view {
        assertTrue(handler.checkNoIdleAssets(), "Strategy must never hold idle assets");
    }

    /// @notice Invariant: onWithdraw always returns within bounds [requested, requested + 1 share worth]
    function invariant_withdrawBounds() public view {
        assertTrue(handler.checkWithdrawBounds(), "onWithdraw must return within bounds");
    }

    /// @notice Invariant: Ensure sufficient test coverage - not all operations should fail
    function invariant_sufficientCoverage() public view {
        uint256 successOps = handler.totalSuccessfulOps();
        uint256 failedOps = handler.totalFailedOps();
        uint256 totalOps = successOps + failedOps;

        // Only check coverage after enough operations have been attempted
        if (totalOps >= 10) {
            // At least 10% of operations should succeed for meaningful coverage
            // If all operations fail, the other invariants pass vacuously
            assertTrue(successOps * 10 >= totalOps, "Too many failed operations - invariants may pass vacuously");
        }
    }

    // =========================================
    // INTERNAL HELPERS
    // =========================================

    /// @notice Sets up an allocation scenario by depositing assets to vault
    function _setupAllocationScenario(uint256 _amount) internal {
        // Deal assets to the vault for allocation
        deal(address(ASSET), address(ROYCO_VAULT), ASSET.balanceOf(address(ROYCO_VAULT)) + _amount);
        // Approve strategy to pull from vault
        vm.prank(address(ROYCO_VAULT));
        ASSET.approve(address(STRATEGY), type(uint256).max);
    }

    /// @notice Pauses the strategy using authorized admin
    function _pauseStrategy() internal {
        address admin = _getAuthorizedAdmin();
        vm.prank(admin);
        STRATEGY.pause();
    }
}
