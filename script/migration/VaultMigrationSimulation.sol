// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "lib/forge-std/src/Test.sol";
import { console2 } from "lib/forge-std/src/console2.sol";

import { IConcreteAsyncVaultImpl } from "lib/concrete-earn-v2-bug-bounty/src/interface/IConcreteAsyncVaultImpl.sol";
import { IConcreteStandardVaultImpl } from "lib/concrete-earn-v2-bug-bounty/src/interface/IConcreteStandardVaultImpl.sol";
import { ConcreteV2RolesLib as Roles } from "lib/concrete-earn-v2-bug-bounty/src/lib/Roles.sol";

import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { IAccessControlEnumerable } from "lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";
import { IAccessManager } from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC4626 } from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { RoycoVaultMakinaStrategy } from "src/RoycoVaultMakinaStrategy.sol";

/// @title VaultMigrationSimulation
/// @notice Simulates the full migration of 3 ConcreteAsyncVaults: role migration, strategy swap, and verification
/// @dev Run with: forge test --match-contract VaultMigrationSimulation --fork-url $MAINNET_RPC_URL -vvv
contract VaultMigrationSimulation is Test {
    // ═════════════════════════════════════════════════════════════════
    //                       CONFIGURATION
    // ═════════════════════════════════════════════════════════════════

    /// @dev The multisig safe that owns all 3 vaults and holds all *_ADMIN roles
    address constant FNDNv1 = 0x85De42e5697D16b853eA24259C42290DaCe35190;

    /// @dev New Multisigs
    address constant FNDNv2 = 0x7c405bbD131e42af506d14e752f2e59B19D49997;
    address constant WCE = 0x84d37A25e46029CE161111420E07cEb78880119e;
    address constant DIALECTIC = 0xe7E4FA51280eB212254458d62081587Acd2077eE;

    /// @dev The Royco Factory — serves as AccessManager for Makina Strategy `restricted` functions
    address constant ROYCO_FACTORY = 0x7cC6fB28eC7b5e7afC3cB3986141797ffc27253C;

    // ── Vault Addresses ──────────────────────────────────────────────

    address constant DSV_VAULT = 0xcD9f5907F92818bC06c9Ad70217f089E190d2a32;
    address constant ROYWSTETH_VAULT = 0x41Ce72E04D349Eb957bdc373baA9c69207032c56;
    address constant SROYWSTETH_VAULT = 0xc678159179EEA877608df50c26C048551a3B6a90;

    // ── Existing Multisig Strategy Addresses ─────────────────────────

    address constant DSV_MULTISIG_STRATEGY = 0xd3F8Edff57570c4F9B11CC95eA65117e2D7A6C2D;
    address constant ROYWSTETH_MULTISIG_STRATEGY = 0xeD45292EeAC48324daBf7c76C2bd71b194a3f97D;
    address constant SROYWSTETH_MULTISIG_STRATEGY = 0x11571c9976e3b784c91e851aD8dafbefa594055e;

    // ── New Makina Strategy Addresses (pre-deployed) ─────────────────

    address constant DSV_MAKINA_STRATEGY = 0x080184cD22fef5A205E4754B602ACbe6621A383D;
    address constant ROYWSTETH_MAKINA_STRATEGY = 0x88F20214075D5a4B53084af00AB3330019417a8b;
    address constant SROYWSTETH_MAKINA_STRATEGY = 0x804690836349e7ce5630C69c2C623916631f7307;

    // ── Whitelisting Hook Addresses ──────────────────────────────────

    address constant DSV_WHITELIST_HOOK = 0x5c4952751CF5C9D4eA3ad84F3407C56Ba2342F13;
    address constant ROYWSTETH_WHITELIST_HOOK = 0xcD6ddfC0520A17dF7bC675fC9B31cb4d7E9e050C;
    address constant SROYWSTETH_WHITELIST_HOOK = 0xe8663631042B015b1Ae03B995c75E79cE9B21d5e;

    // ── New Vault Role Holders (same across all 3 vaults) ────────────

    address constant NEW_VAULT_MANAGER = FNDNv2;
    address constant NEW_HOOK_MANAGER = FNDNv2;
    address constant NEW_STRATEGY_MANAGER = FNDNv2;
    address constant NEW_ALLOCATOR = DIALECTIC;
    address constant NEW_WITHDRAWAL_MANAGER = DIALECTIC;
    address constant NEW_VAULT_MANAGER_ADMIN = FNDNv2;
    address constant NEW_HOOK_MANAGER_ADMIN = FNDNv2;
    address constant NEW_STRATEGY_MANAGER_ADMIN = FNDNv2;
    address constant NEW_ALLOCATOR_ADMIN = FNDNv2;
    address constant NEW_WITHDRAWAL_MANAGER_ADMIN = FNDNv2;

    /// @dev DSV-specific: this address retains ALLOCATOR and WITHDRAWAL_MANAGER roles alongside the new holders
    address constant DSV_ADDITIONAL_ROLE_HOLDER = 0x170ff06326eBb64BF609a848Fc143143994AF6c8;

    // ── AccessManager Config for Makina Strategy `restricted` fns ────

    /// @dev The role ID to assign on the factory for strategy restricted functions
    uint64 constant STRATEGY_RESTRICTED_ROLE_ID = uint64(uint256(keccak256("STRATEGY_RESTRICTED_ROLE")));

    /// @dev The address authorized to call pause/unpause/rescueToken on the Makina strategies
    address constant STRATEGY_RESTRICTED_CALLER = FNDNv2;

    // ── Hook Ownership Config ────────────────────────────────────────
    // The Whitelisting Hook contracts are Ownable. Transfer ownership to the new owner.
    address constant NEW_HOOK_OWNER = FNDNv2;

    // ═════════════════════════════════════════════════════════════════
    //                          TYPES
    // ═════════════════════════════════════════════════════════════════

    struct VaultConfig {
        address vault;
        address multisigStrategy;
        address makinaStrategy;
        address whitelistHook;
    }

    struct VaultSnapshot {
        // Core accounting
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 cachedTotalAssets;
        uint256 sharePrice; // previewRedeem(1e18)
        // Strategy state
        address[] strategies;
        address[] deallocationOrder;
        uint120 multisigAllocated;
        uint256 totalAllocated;
        // Fee config
        uint16 managementFee;
        address managementFeeRecipient;
        uint32 lastManagementFeeAccrual;
        uint16 performanceFee;
        address performanceFeeRecipient;
        // Limits
        uint256 maxDepositAmount;
        uint256 minDepositAmount;
        uint256 maxWithdrawAmount;
        uint256 minWithdrawAmount;
        // Async queue
        bool isQueueActive;
        uint256 latestEpochID;
        // Role holders (first member of each role)
        address[5] functionalRoleHolders; // VM, HM, SM, ALLOC, WM
        address[5] adminRoleHolders; // VM_ADMIN, HM_ADMIN, SM_ADMIN, ALLOC_ADMIN, WM_ADMIN
    }

    // ═════════════════════════════════════════════════════════════════
    //                         CONSTANTS
    // ═════════════════════════════════════════════════════════════════

    struct RolePair {
        bytes32 functional;
        bytes32 admin;
    }

    /// @dev All 5 vault role pairs: functional role + its admin role
    function _rolePairs() internal pure returns (RolePair[5] memory) {
        return [
            RolePair(Roles.VAULT_MANAGER, Roles.VAULT_MANAGER_ADMIN),
            RolePair(Roles.HOOK_MANAGER, Roles.HOOK_MANAGER_ADMIN),
            RolePair(Roles.STRATEGY_MANAGER, Roles.STRATEGY_MANAGER_ADMIN),
            RolePair(Roles.ALLOCATOR, Roles.ALLOCATOR_ADMIN),
            RolePair(Roles.WITHDRAWAL_MANAGER, Roles.WITHDRAWAL_MANAGER_ADMIN)
        ];
    }

    /// @dev The selectors of `restricted` functions on the Makina Strategy
    bytes4[3] internal STRATEGY_RESTRICTED_SELECTORS =
        [RoycoVaultMakinaStrategy.rescueToken.selector, RoycoVaultMakinaStrategy.pause.selector, RoycoVaultMakinaStrategy.unpause.selector];

    // ═════════════════════════════════════════════════════════════════
    //                         SETUP
    // ═════════════════════════════════════════════════════════════════

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 24_680_567);
    }

    // ═════════════════════════════════════════════════════════════════
    //                      MAIN ENTRY POINT
    // ═════════════════════════════════════════════════════════════════

    function run() public {
        VaultConfig[3] memory configs = [
            VaultConfig({ vault: DSV_VAULT, multisigStrategy: DSV_MULTISIG_STRATEGY, makinaStrategy: DSV_MAKINA_STRATEGY, whitelistHook: DSV_WHITELIST_HOOK }),
            VaultConfig({
                vault: ROYWSTETH_VAULT,
                multisigStrategy: ROYWSTETH_MULTISIG_STRATEGY,
                makinaStrategy: ROYWSTETH_MAKINA_STRATEGY,
                whitelistHook: ROYWSTETH_WHITELIST_HOOK
            }),
            VaultConfig({
                vault: SROYWSTETH_VAULT,
                multisigStrategy: SROYWSTETH_MULTISIG_STRATEGY,
                makinaStrategy: SROYWSTETH_MAKINA_STRATEGY,
                whitelistHook: SROYWSTETH_WHITELIST_HOOK
            })
        ];

        for (uint256 i = 0; i < 3; i++) {
            VaultConfig memory cfg = configs[i];
            string memory label = i == 0 ? "DSV" : (i == 1 ? "roywstETH" : "sroywstETH");
            console2.log("========================================");
            console2.log("Migrating vault:", label);
            console2.log("========================================");

            // Step 0: Configure Makina Strategy on Royco Factory
            _configureStrategyOnFactory(cfg.makinaStrategy);

            // Step 1: Snapshot
            VaultSnapshot memory snap = _snapshot(cfg);
            console2.log("  Snapshot captured. totalAssets:", snap.totalAssets);

            if (i == 0) {
                // Step 2: Strategy migration
                _migrateDSV(cfg);

                // Step 3: Vault role migration
                _migrateVaultRoles(cfg.vault, true);
            } else {
                // Step 2: Strategy migration
                _migrateAndReplaceStrategy(cfg);

                // Step 3: Vault role migration
                _migrateVaultRoles(cfg.vault, false);
            }

            // Step 4: Hook ownership transfer
            _migrateHookRoles(cfg.whitelistHook);

            // Step 5: Verification
            _verifyAll(cfg, snap, i == 0);

            console2.log("  Migration complete and verified.");
        }
    }

    // ═════════════════════════════════════════════════════════════════
    //              STEP 0: CONFIGURE FACTORY ACCESS MANAGER
    // ═════════════════════════════════════════════════════════════════

    /// @notice Configures the Royco Factory (AccessManager) to authorize the intended caller
    ///         for the Makina Strategy's `restricted` functions (pause, unpause, rescueToken)
    function _configureStrategyOnFactory(address makinaStrategy) internal {
        IAccessManager factory = IAccessManager(ROYCO_FACTORY);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = STRATEGY_RESTRICTED_SELECTORS[0];
        selectors[1] = STRATEGY_RESTRICTED_SELECTORS[1];
        selectors[2] = STRATEGY_RESTRICTED_SELECTORS[2];

        vm.startPrank(FNDNv2);
        factory.setTargetFunctionRole(makinaStrategy, selectors, STRATEGY_RESTRICTED_ROLE_ID);
        factory.grantRole(STRATEGY_RESTRICTED_ROLE_ID, STRATEGY_RESTRICTED_CALLER, 0);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════
    //                    STEP 1: SNAPSHOT
    // ═════════════════════════════════════════════════════════════════

    function _snapshot(VaultConfig memory cfg) internal view returns (VaultSnapshot memory snap) {
        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(cfg.vault);
        IERC4626 erc4626 = IERC4626(cfg.vault);
        IConcreteAsyncVaultImpl asyncVault = IConcreteAsyncVaultImpl(cfg.vault);
        IAccessControlEnumerable acl = IAccessControlEnumerable(cfg.vault);

        // Core accounting
        snap.totalAssets = erc4626.totalAssets();
        snap.totalSupply = erc4626.totalSupply();
        snap.cachedTotalAssets = vault.cachedTotalAssets();
        snap.sharePrice = snap.totalSupply > 0 ? erc4626.previewRedeem(1e18) : 0;

        // Strategy state
        snap.strategies = vault.getStrategies();
        snap.deallocationOrder = vault.getDeallocationOrder();
        snap.multisigAllocated = vault.getStrategyData(cfg.multisigStrategy).allocated;
        snap.totalAllocated = vault.getTotalAllocated();

        // Fee config
        (snap.managementFee, snap.managementFeeRecipient, snap.lastManagementFeeAccrual, snap.performanceFee, snap.performanceFeeRecipient) =
            vault.getFeeConfig();

        // Limits
        (snap.minDepositAmount, snap.maxDepositAmount) = vault.getDepositLimits();
        (snap.minWithdrawAmount, snap.maxWithdrawAmount) = vault.getWithdrawLimits();

        // Async queue
        snap.isQueueActive = asyncVault.isQueueActive();
        snap.latestEpochID = asyncVault.latestEpochID();

        // Role holders
        RolePair[5] memory roles = _rolePairs();
        for (uint256 i = 0; i < 5; i++) {
            uint256 fCount = acl.getRoleMemberCount(roles[i].functional);
            if (fCount > 0) snap.functionalRoleHolders[i] = acl.getRoleMember(roles[i].functional, 0);

            uint256 aCount = acl.getRoleMemberCount(roles[i].admin);
            if (aCount > 0) snap.adminRoleHolders[i] = acl.getRoleMember(roles[i].admin, 0);
        }
    }

    // ═════════════════════════════════════════════════════════════════
    //                 STEP 2A: DSV STRATEGY MIGRATION
    // ═════════════════════════════════════════════════════════════════

    /// @notice DSV: Keep existing MultisigStrategy, add Makina Strategy alongside it
    function _migrateDSV(VaultConfig memory cfg) internal {
        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(cfg.vault);

        vm.startPrank(FNDNv1);

        // Add Makina Strategy
        vault.addStrategy(cfg.makinaStrategy);

        // Append Makina to existing deallocation order
        address[] memory currentOrder = vault.getDeallocationOrder();
        address[] memory newOrder = new address[](currentOrder.length + 1);
        for (uint256 i = 0; i < currentOrder.length; i++) {
            newOrder[i] = currentOrder[i];
        }
        newOrder[currentOrder.length] = cfg.makinaStrategy;
        vault.setDeallocationOrder(newOrder);

        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════
    //           STEP 2B: REPLACE STRATEGY (roywstETH, sroywstETH)
    // ═════════════════════════════════════════════════════════════════

    /// @notice Replace MultisigStrategy with Makina Strategy (no funds in multisig)
    function _migrateAndReplaceStrategy(VaultConfig memory cfg) internal {
        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(cfg.vault);

        // FNDNv1 has ALLOCATOR_ADMIN but not ALLOCATOR on non-DSV vaults — self-grant first
        vm.startPrank(FNDNv1);
        vault.grantRole(Roles.ALLOCATOR, FNDNv1);

        // Add Makina Strategy
        vault.addStrategy(cfg.makinaStrategy);

        // Set deallocation order to only include Makina
        address[] memory newOrder = new address[](1);
        newOrder[0] = cfg.makinaStrategy;
        vault.setDeallocationOrder(newOrder);

        // Remove MultisigStrategy (precondition: allocated == 0, not in deallocation order)
        vault.removeStrategy(cfg.multisigStrategy);

        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════
    //                 STEP 4: VAULT ROLE MIGRATION
    // ═════════════════════════════════════════════════════════════════

    function _migrateVaultRoles(address vault, bool isDSV) internal {
        IAccessControlEnumerable acl = IAccessControlEnumerable(vault);
        RolePair[5] memory roles = _rolePairs();

        address[5] memory newFunctional = [NEW_VAULT_MANAGER, NEW_HOOK_MANAGER, NEW_STRATEGY_MANAGER, NEW_ALLOCATOR, NEW_WITHDRAWAL_MANAGER];
        address[5] memory newAdmin =
            [NEW_VAULT_MANAGER_ADMIN, NEW_HOOK_MANAGER_ADMIN, NEW_STRATEGY_MANAGER_ADMIN, NEW_ALLOCATOR_ADMIN, NEW_WITHDRAWAL_MANAGER_ADMIN];

        vm.startPrank(FNDNv1);

        // ── Phase A: Grant all new holders first ──
        for (uint256 i = 0; i < 5; i++) {
            if (!acl.hasRole(roles[i].admin, newAdmin[i])) {
                IConcreteStandardVaultImpl(vault).grantRole(roles[i].admin, newAdmin[i]);
            }
            if (!acl.hasRole(roles[i].functional, newFunctional[i])) {
                IConcreteStandardVaultImpl(vault).grantRole(roles[i].functional, newFunctional[i]);
            }
        }

        // ── Phase B: Revoke all old functional holders ──
        for (uint256 i = 0; i < 5; i++) {
            uint256 count = acl.getRoleMemberCount(roles[i].functional);
            for (uint256 j = count; j > 0; j--) {
                address member = acl.getRoleMember(roles[i].functional, j - 1);
                if (member == newFunctional[i]) continue;
                // DSV: preserve the additional holder for ALLOCATOR and WITHDRAWAL_MANAGER
                if (isDSV && member == DSV_ADDITIONAL_ROLE_HOLDER) {
                    if (roles[i].functional == Roles.ALLOCATOR || roles[i].functional == Roles.WITHDRAWAL_MANAGER) {
                        continue;
                    }
                }
                IConcreteStandardVaultImpl(vault).revokeRole(roles[i].functional, member);
            }
        }

        // ── Phase C: Revoke all old admin holders (point of no return) ──
        for (uint256 i = 0; i < 5; i++) {
            uint256 count = acl.getRoleMemberCount(roles[i].admin);
            for (uint256 j = count; j > 0; j--) {
                address member = acl.getRoleMember(roles[i].admin, j - 1);
                if (member != newAdmin[i]) {
                    IConcreteStandardVaultImpl(vault).revokeRole(roles[i].admin, member);
                }
            }
        }

        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════
    //                 STEP 5: HOOK ROLE MIGRATION
    // ═════════════════════════════════════════════════════════════════

    function _migrateHookRoles(address hook) internal {
        if (hook == address(0)) return;
        if (Ownable(hook).owner() == NEW_HOOK_OWNER) return;

        vm.prank(FNDNv1);
        Ownable(hook).transferOwnership(NEW_HOOK_OWNER);
    }

    // ═════════════════════════════════════════════════════════════════
    //                 STEP 6: VERIFICATION
    // ═════════════════════════════════════════════════════════════════

    function _verifyAll(VaultConfig memory cfg, VaultSnapshot memory snap, bool isDSV) internal {
        _verifyStateInvariants(cfg, snap);
        _verifyRoles(cfg.vault, isDSV);
        _verifyHookOwnership(cfg.whitelistHook);
        _verifyStrategyState(cfg, snap, isDSV);
        _verifyMakinaStrategySanity(cfg);
        _verifyAccessManagerConfig(cfg.makinaStrategy);
    }

    // ── 6.1: State Invariants ────────────────────────────────────────

    function _verifyStateInvariants(VaultConfig memory cfg, VaultSnapshot memory snap) internal view {
        IERC4626 erc4626 = IERC4626(cfg.vault);
        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(cfg.vault);
        IConcreteAsyncVaultImpl asyncVault = IConcreteAsyncVaultImpl(cfg.vault);

        assertEq(erc4626.totalAssets(), snap.totalAssets, "totalAssets changed");
        assertEq(erc4626.totalSupply(), snap.totalSupply, "totalSupply changed");
        assertEq(vault.cachedTotalAssets(), snap.cachedTotalAssets, "cachedTotalAssets changed");

        if (snap.totalSupply > 0) {
            assertEq(erc4626.previewRedeem(1e18), snap.sharePrice, "share price changed");
        }

        // Fee config unchanged
        (uint16 mFee, address mRecipient, uint32 mAccrual, uint16 pFee, address pRecipient) = vault.getFeeConfig();
        assertEq(mFee, snap.managementFee, "managementFee changed");
        assertEq(mRecipient, snap.managementFeeRecipient, "managementFeeRecipient changed");
        assertEq(mAccrual, snap.lastManagementFeeAccrual, "lastManagementFeeAccrual changed");
        assertEq(pFee, snap.performanceFee, "performanceFee changed");
        assertEq(pRecipient, snap.performanceFeeRecipient, "performanceFeeRecipient changed");

        // Limits unchanged
        (uint256 minDep, uint256 maxDep) = vault.getDepositLimits();
        (uint256 minWd, uint256 maxWd) = vault.getWithdrawLimits();
        assertEq(minDep, snap.minDepositAmount, "minDepositAmount changed");
        assertEq(maxDep, snap.maxDepositAmount, "maxDepositAmount changed");
        assertEq(minWd, snap.minWithdrawAmount, "minWithdrawAmount changed");
        assertEq(maxWd, snap.maxWithdrawAmount, "maxWithdrawAmount changed");

        // Async queue state unchanged
        assertEq(asyncVault.isQueueActive(), snap.isQueueActive, "isQueueActive changed");
        assertEq(asyncVault.latestEpochID(), snap.latestEpochID, "latestEpochID changed");

        console2.log("    [OK] State invariants verified");
    }

    // ── 6.2: Role Verification ───────────────────────────────────────

    function _verifyRoles(address vault, bool isDSV) internal view {
        IAccessControlEnumerable acl = IAccessControlEnumerable(vault);
        RolePair[5] memory roles = _rolePairs();

        address[5] memory expectedFunctional = [NEW_VAULT_MANAGER, NEW_HOOK_MANAGER, NEW_STRATEGY_MANAGER, NEW_ALLOCATOR, NEW_WITHDRAWAL_MANAGER];
        address[5] memory expectedAdmin =
            [NEW_VAULT_MANAGER_ADMIN, NEW_HOOK_MANAGER_ADMIN, NEW_STRATEGY_MANAGER_ADMIN, NEW_ALLOCATOR_ADMIN, NEW_WITHDRAWAL_MANAGER_ADMIN];

        for (uint256 i = 0; i < 5; i++) {
            // New functional holder has the role
            assertTrue(acl.hasRole(roles[i].functional, expectedFunctional[i]), string.concat("New functional holder missing role at index ", vm.toString(i)));

            // New admin holder has the role, exactly 1
            assertTrue(acl.hasRole(roles[i].admin, expectedAdmin[i]), string.concat("New admin holder missing role at index ", vm.toString(i)));
            assertEq(acl.getRoleMemberCount(roles[i].admin), 1, string.concat("Admin role member count != 1 at index ", vm.toString(i)));

            // Check functional role member count
            bool isAllocatorOrWM = (roles[i].functional == Roles.ALLOCATOR || roles[i].functional == Roles.WITHDRAWAL_MANAGER);
            if (isDSV && isAllocatorOrWM) {
                // DSV: ALLOCATOR and WITHDRAWAL_MANAGER have 2 holders (new + additional)
                assertEq(acl.getRoleMemberCount(roles[i].functional), 2, string.concat("DSV functional role member count != 2 at index ", vm.toString(i)));
                assertTrue(
                    acl.hasRole(roles[i].functional, DSV_ADDITIONAL_ROLE_HOLDER), string.concat("DSV additional holder missing role at index ", vm.toString(i))
                );
            } else {
                assertEq(acl.getRoleMemberCount(roles[i].functional), 1, string.concat("Functional role member count != 1 at index ", vm.toString(i)));
            }

            // FNDNv1 no longer has either role
            if (FNDNv1 != expectedFunctional[i]) {
                assertFalse(acl.hasRole(roles[i].functional, FNDNv1), "FNDNv1 still has functional role");
            }
            if (FNDNv1 != expectedAdmin[i]) {
                assertFalse(acl.hasRole(roles[i].admin, FNDNv1), "FNDNv1 still has admin role");
            }
        }

        console2.log("    [OK] Vault roles verified");
    }

    // ── 6.3: Hook Ownership ─────────────────────────────────────────

    function _verifyHookOwnership(address hook) internal view {
        if (hook == address(0)) {
            console2.log("    [SKIP] No whitelist hook configured for ownership check");
            return;
        }

        assertEq(Ownable(hook).owner(), NEW_HOOK_OWNER, "Hook ownership not transferred");
        assertTrue(Ownable(hook).owner() != FNDNv1, "Hook still owned by old safe");

        console2.log("    [OK] Hook ownership verified");
    }

    // ── 6.4: Strategy State ──────────────────────────────────────────

    function _verifyStrategyState(VaultConfig memory cfg, VaultSnapshot memory snap, bool isDSV) internal view {
        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(cfg.vault);

        if (isDSV) {
            // DSV: Both strategies should be active
            address[] memory strategies = vault.getStrategies();
            assertTrue(strategies.length >= 2, "DSV should have at least 2 strategies");
            assertTrue(_contains(strategies, cfg.multisigStrategy), "DSV missing multisig strategy");
            assertTrue(_contains(strategies, cfg.makinaStrategy), "DSV missing makina strategy");

            IConcreteStandardVaultImpl.StrategyData memory msData = vault.getStrategyData(cfg.multisigStrategy);
            assertEq(uint8(msData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Active), "DSV multisig strategy not Active");
            assertEq(msData.allocated, snap.multisigAllocated, "DSV multisig allocated changed");

            IConcreteStandardVaultImpl.StrategyData memory mkData = vault.getStrategyData(cfg.makinaStrategy);
            assertEq(uint8(mkData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Active), "DSV makina strategy not Active");
            assertEq(mkData.allocated, 0, "DSV makina strategy should have 0 allocated");

            // Deallocation order should contain both
            address[] memory order = vault.getDeallocationOrder();
            assertTrue(_contains(order, cfg.multisigStrategy), "DSV dealloc order missing multisig");
            assertTrue(_contains(order, cfg.makinaStrategy), "DSV dealloc order missing makina");
        } else {
            // roywstETH / sroywstETH: Only Makina strategy
            address[] memory strategies = vault.getStrategies();
            assertEq(strategies.length, 1, "Non-DSV should have exactly 1 strategy");
            assertEq(strategies[0], cfg.makinaStrategy, "Non-DSV strategy should be makina");

            IConcreteStandardVaultImpl.StrategyData memory mkData = vault.getStrategyData(cfg.makinaStrategy);
            assertEq(uint8(mkData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Active), "Makina strategy not Active");
            assertEq(mkData.allocated, 0, "Makina strategy should have 0 allocated");

            // Multisig should be gone
            IConcreteStandardVaultImpl.StrategyData memory msData = vault.getStrategyData(cfg.multisigStrategy);
            assertEq(uint8(msData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Inactive), "Multisig strategy should be Inactive (removed)");

            address[] memory order = vault.getDeallocationOrder();
            assertEq(order.length, 1, "Non-DSV dealloc order should have 1 entry");
            assertEq(order[0], cfg.makinaStrategy, "Non-DSV dealloc order should be makina");
        }

        console2.log("    [OK] Strategy state verified");
    }

    // ── 6.4: Makina Strategy Sanity ──────────────────────────────────

    function _verifyMakinaStrategySanity(VaultConfig memory cfg) internal view {
        RoycoVaultMakinaStrategy strategy = RoycoVaultMakinaStrategy(cfg.makinaStrategy);

        assertEq(strategy.asset(), IERC4626(cfg.vault).asset(), "Strategy asset mismatch");
        assertEq(strategy.getVault(), cfg.vault, "Strategy vault mismatch");
        assertEq(strategy.totalAllocatedValue(), 0, "Strategy should have 0 allocated value");

        console2.log("    [OK] Makina strategy sanity verified");
    }

    // ── 6.5: AccessManager Config ────────────────────────────────────

    function _verifyAccessManagerConfig(address makinaStrategy) internal {
        IAccessManager factory = IAccessManager(ROYCO_FACTORY);

        // Authorized caller can call restricted functions
        for (uint256 i = 0; i < 3; i++) {
            (bool allowed,) = factory.canCall(STRATEGY_RESTRICTED_CALLER, makinaStrategy, STRATEGY_RESTRICTED_SELECTORS[i]);
            assertTrue(allowed, string.concat("Restricted caller not authorized for selector index ", vm.toString(i)));
        }

        // Random address cannot call restricted functions
        address rando = makeAddr("unauthorized");
        for (uint256 i = 0; i < 3; i++) {
            (bool allowed,) = factory.canCall(rando, makinaStrategy, STRATEGY_RESTRICTED_SELECTORS[i]);
            assertFalse(allowed, string.concat("Random address authorized for selector index ", vm.toString(i)));
        }

        console2.log("    [OK] AccessManager config verified");
    }

    // ═════════════════════════════════════════════════════════════════
    //                        UTILITIES
    // ═════════════════════════════════════════════════════════════════

    function _contains(address[] memory arr, address target) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == target) return true;
        }
        return false;
    }
}
