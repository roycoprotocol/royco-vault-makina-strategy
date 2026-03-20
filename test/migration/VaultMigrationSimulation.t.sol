// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IAllocateModule } from "lib/concrete-earn-v2-bug-bounty/src/interface/IAllocateModule.sol";
import { IConcreteAsyncVaultImpl } from "lib/concrete-earn-v2-bug-bounty/src/interface/IConcreteAsyncVaultImpl.sol";
import { IConcreteStandardVaultImpl } from "lib/concrete-earn-v2-bug-bounty/src/interface/IConcreteStandardVaultImpl.sol";
import { ConcreteV2RolesLib as Roles } from "lib/concrete-earn-v2-bug-bounty/src/lib/Roles.sol";
import { Test } from "lib/forge-std/src/Test.sol";
import { console2 } from "lib/forge-std/src/console2.sol";
import { IMachine } from "lib/makina-core/src/interfaces/IMachine.sol";
import { IAccessControl } from "lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { IAccessControlEnumerable } from "lib/openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";
import { IAccessManager } from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import { IERC4626 } from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { RoycoVaultMakinaStrategy } from "src/RoycoVaultMakinaStrategy.sol";

interface IWhitelistHook {
    function whitelistUsers(address[] memory users) external;
    function isWhitelisted(address user) external view returns (bool);
    function setVaultDepositCap(address _vault, uint256 _depositCap) external;
}

/// @title VaultMigrationSimulation
/// @notice Simulates the full migration of 3 ConcreteAsyncVaults: role migration, strategy swap, and verification.
///         Records all transactions per-safe into queues and writes them to JSON files.
/// @dev Run with: forge test --match-test test_migration -vvv
contract VaultMigrationSimulation is Test {
    // ═════════════════════════════════════════════════════════════════
    //                       CONFIGURATION
    // ═════════════════════════════════════════════════════════════════

    address constant FNDNv1 = 0x85De42e5697D16b853eA24259C42290DaCe35190;
    address constant FNDNv2 = 0x7c405bbD131e42af506d14e752f2e59B19D49997;
    address constant WCE = 0x84d37A25e46029CE161111420E07cEb78880119e;
    address constant DIALECTIC = 0xe7E4FA51280eB212254458d62081587Acd2077eE;

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

    address constant DSV_MAKINA_STRATEGY = 0xc5FeF644d59415cec65049e0653CA10eD9Cba778;
    address constant ROYWSTETH_MAKINA_STRATEGY = 0x185313DBb1f3AA2b3fCc603f0EE4cbA753Ef1DD7;
    address constant SROYWSTETH_MAKINA_STRATEGY = 0x43c30666baB795Bf567A142e9dD67c59083B86D2;

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

    address constant DSV_ADDITIONAL_ROLE_HOLDER = 0x170ff06326eBb64BF609a848Fc143143994AF6c8;

    // ── AccessManager Config ─────────────────────────────────────────

    uint64 constant STRATEGY_RESTRICTED_ROLE_ID = uint64(uint256(keccak256("STRATEGY_RESTRICTED_ROLE")));
    address constant STRATEGY_RESTRICTED_CALLER = FNDNv2;

    // ── Hook Ownership Config ────────────────────────────────────────

    address constant NEW_HOOK_OWNER = FNDNv2;

    // ── Test Depositor ───────────────────────────────────────────────

    /// @dev Address to whitelist on roywstETH/sroywstETH hooks and use for deposit tests
    address constant TEST_DEPOSITOR = 0x77777Cc68b333a2256B436D675E8D257699Aa667;

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
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 cachedTotalAssets;
        uint256 sharePrice;
        address[] strategies;
        address[] deallocationOrder;
        uint120 multisigAllocated;
        uint256 totalAllocated;
        uint16 managementFee;
        address managementFeeRecipient;
        uint32 lastManagementFeeAccrual;
        uint16 performanceFee;
        address performanceFeeRecipient;
        uint256 maxDepositAmount;
        uint256 minDepositAmount;
        uint256 maxWithdrawAmount;
        uint256 minWithdrawAmount;
        bool isQueueActive;
        uint256 latestEpochID;
        address[5] functionalRoleHolders;
        address[5] adminRoleHolders;
    }

    struct RolePair {
        bytes32 functional;
        bytes32 admin;
    }

    struct Transaction {
        address to;
        uint256 value;
        bytes data;
    }

    // ═════════════════════════════════════════════════════════════════
    //                     TRANSACTION QUEUES
    // ═════════════════════════════════════════════════════════════════

    Transaction[] internal fndnV1Queue;
    Transaction[] internal fndnV2Queue;

    // ═════════════════════════════════════════════════════════════════
    //                         CONSTANTS
    // ═════════════════════════════════════════════════════════════════

    function _rolePairs() internal pure returns (RolePair[5] memory) {
        return [
            RolePair(Roles.VAULT_MANAGER, Roles.VAULT_MANAGER_ADMIN),
            RolePair(Roles.HOOK_MANAGER, Roles.HOOK_MANAGER_ADMIN),
            RolePair(Roles.STRATEGY_MANAGER, Roles.STRATEGY_MANAGER_ADMIN),
            RolePair(Roles.ALLOCATOR, Roles.ALLOCATOR_ADMIN),
            RolePair(Roles.WITHDRAWAL_MANAGER, Roles.WITHDRAWAL_MANAGER_ADMIN)
        ];
    }

    string[5] internal ROLE_NAMES = ["VAULT_MANAGER", "HOOK_MANAGER", "STRATEGY_MANAGER", "ALLOCATOR", "WITHDRAWAL_MANAGER"];
    string[5] internal ADMIN_ROLE_NAMES =
        ["VAULT_MANAGER_ADMIN", "HOOK_MANAGER_ADMIN", "STRATEGY_MANAGER_ADMIN", "ALLOCATOR_ADMIN", "WITHDRAWAL_MANAGER_ADMIN"];

    bytes4[3] internal STRATEGY_RESTRICTED_SELECTORS =
        [RoycoVaultMakinaStrategy.rescueToken.selector, RoycoVaultMakinaStrategy.pause.selector, RoycoVaultMakinaStrategy.unpause.selector];

    /// @dev EIP-7201 storage slot for Makina Machine storage
    bytes32 private constant MACHINE_STORAGE_LOCATION = 0x55fe2a17e400bcd0e2125123a7fc955478e727b29a4c522f4f2bd95d961bd900;
    uint256 private constant DEPOSITOR_SLOT_OFFSET = 2;
    uint256 private constant REDEEMER_SLOT_OFFSET = 3;

    // ═════════════════════════════════════════════════════════════════
    //                   TX QUEUE HELPERS
    // ═════════════════════════════════════════════════════════════════

    function _callFromFNDNv1(address to, uint256 value, bytes memory data) internal {
        fndnV1Queue.push(Transaction({ to: to, value: value, data: data }));
        vm.prank(FNDNv1);
        (bool success, bytes memory ret) = to.call{ value: value }(data);
        require(success, string.concat("FNDNv1 tx failed: ", string(ret)));
    }

    function _callFromFNDNv2(address to, uint256 value, bytes memory data) internal {
        fndnV2Queue.push(Transaction({ to: to, value: value, data: data }));
        vm.prank(FNDNv2);
        (bool success, bytes memory ret) = to.call{ value: value }(data);
        require(success, string.concat("FNDNv2 tx failed: ", string(ret)));
    }

    // ═════════════════════════════════════════════════════════════════
    //                      MAIN ENTRY POINT
    // ═════════════════════════════════════════════════════════════════

    function test_migration() public {
        vm.skip(true);
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 24_685_811);
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

        string[3] memory labels = ["DSV", "roywstETH", "sroywstETH"];

        for (uint256 i = 0; i < 3; i++) {
            VaultConfig memory cfg = configs[i];
            console2.log("========================================");
            console2.log("Migrating vault:", labels[i]);
            console2.log("========================================");

            // Step 0: Configure Makina Strategy on Royco Factory
            _configureStrategyOnFactory(cfg.makinaStrategy);

            // Step 1: Snapshot
            VaultSnapshot memory snap = _snapshot(cfg);
            console2.log("  Snapshot captured. totalAssets:", snap.totalAssets);

            if (i == 0) {
                // DSV

                // Add the Makina strategy to the vault but don't remove the Multisig strategy
                _migrateDSV(cfg);

                // Migrate the vault roles
                _migrateVaultRoles(cfg.vault, true);
            } else {
                // roywstETH/sroywstETH

                // Add the Makina strategy to the vault and remove the Multisig strategy
                _migrateAndReplaceStrategy(cfg);

                // Set deposit limits to infinity before role migration (requires VAULT_MANAGER, held by FNDNv1)
                _callFromFNDNv1(cfg.vault, 0, abi.encodeCall(IConcreteStandardVaultImpl.setDepositLimits, (0, type(uint256).max)));

                // Migrate the vault roles
                _migrateVaultRoles(cfg.vault, false);

                // Whitelist the test depositor
                _whitelistTestDepositor(cfg.whitelistHook, cfg.vault);
            }

            // Hook ownership transfer
            _migrateHookOwnership(cfg.whitelistHook);

            // Verification
            _verifyAll(cfg, snap, i == 0);

            console2.log("  Migration complete and verified.");
        }

        // Print final state for all vaults
        console2.log("");
        console2.log("========================================");
        console2.log("         FINAL VAULT STATES");
        console2.log("========================================");
        for (uint256 i = 0; i < 3; i++) {
            _printVaultState(configs[i], labels[i]);
        }

        // Write transaction queues to files
        _writeTransactionQueues();
    }

    // ═════════════════════════════════════════════════════════════════
    //              STEP 0: CONFIGURE FACTORY ACCESS MANAGER
    // ═════════════════════════════════════════════════════════════════

    function _configureStrategyOnFactory(address makinaStrategy) internal {
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = STRATEGY_RESTRICTED_SELECTORS[0];
        selectors[1] = STRATEGY_RESTRICTED_SELECTORS[1];
        selectors[2] = STRATEGY_RESTRICTED_SELECTORS[2];

        _callFromFNDNv2(ROYCO_FACTORY, 0, abi.encodeCall(IAccessManager.setTargetFunctionRole, (makinaStrategy, selectors, STRATEGY_RESTRICTED_ROLE_ID)));
        _callFromFNDNv2(ROYCO_FACTORY, 0, abi.encodeCall(IAccessManager.grantRole, (STRATEGY_RESTRICTED_ROLE_ID, STRATEGY_RESTRICTED_CALLER, 0)));
    }

    // ═════════════════════════════════════════════════════════════════
    //                    STEP 1: SNAPSHOT
    // ═════════════════════════════════════════════════════════════════

    function _snapshot(VaultConfig memory cfg) internal view returns (VaultSnapshot memory snap) {
        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(cfg.vault);
        IERC4626 erc4626 = IERC4626(cfg.vault);
        IConcreteAsyncVaultImpl asyncVault = IConcreteAsyncVaultImpl(cfg.vault);
        IAccessControlEnumerable acl = IAccessControlEnumerable(cfg.vault);

        snap.totalAssets = erc4626.totalAssets();
        snap.totalSupply = erc4626.totalSupply();
        snap.cachedTotalAssets = vault.cachedTotalAssets();
        snap.sharePrice = snap.totalSupply > 0 ? erc4626.previewRedeem(1e18) : 0;

        snap.strategies = vault.getStrategies();
        snap.deallocationOrder = vault.getDeallocationOrder();
        snap.multisigAllocated = vault.getStrategyData(cfg.multisigStrategy).allocated;
        snap.totalAllocated = vault.getTotalAllocated();

        (snap.managementFee, snap.managementFeeRecipient, snap.lastManagementFeeAccrual, snap.performanceFee, snap.performanceFeeRecipient) =
            vault.getFeeConfig();

        (snap.maxDepositAmount, snap.minDepositAmount) = vault.getDepositLimits();
        (snap.maxWithdrawAmount, snap.minWithdrawAmount) = vault.getWithdrawLimits();

        snap.isQueueActive = asyncVault.isQueueActive();
        snap.latestEpochID = asyncVault.latestEpochID();

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

    function _migrateDSV(VaultConfig memory cfg) internal {
        // Add Makina Strategy
        _callFromFNDNv1(cfg.vault, 0, abi.encodeCall(IConcreteStandardVaultImpl.addStrategy, (cfg.makinaStrategy)));

        // Append Makina to existing deallocation order
        address[] memory currentOrder = IConcreteStandardVaultImpl(cfg.vault).getDeallocationOrder();
        address[] memory newOrder = new address[](currentOrder.length + 1);
        for (uint256 i = 0; i < currentOrder.length; i++) {
            newOrder[i] = currentOrder[i];
        }
        newOrder[currentOrder.length] = cfg.makinaStrategy;
        _callFromFNDNv1(cfg.vault, 0, abi.encodeCall(IConcreteStandardVaultImpl.setDeallocationOrder, (newOrder)));
    }

    // ═════════════════════════════════════════════════════════════════
    //           STEP 2B: REPLACE STRATEGY (roywstETH, sroywstETH)
    // ═════════════════════════════════════════════════════════════════

    function _migrateAndReplaceStrategy(VaultConfig memory cfg) internal {
        // FNDNv1 has ALLOCATOR_ADMIN but not ALLOCATOR on non-DSV vaults — self-grant first
        _callFromFNDNv1(cfg.vault, 0, abi.encodeCall(IAccessControl.grantRole, (Roles.ALLOCATOR, FNDNv1)));

        // Add Makina Strategy
        _callFromFNDNv1(cfg.vault, 0, abi.encodeCall(IConcreteStandardVaultImpl.addStrategy, (cfg.makinaStrategy)));

        // Set deallocation order to only include Makina
        address[] memory newOrder = new address[](1);
        newOrder[0] = cfg.makinaStrategy;
        _callFromFNDNv1(cfg.vault, 0, abi.encodeCall(IConcreteStandardVaultImpl.setDeallocationOrder, (newOrder)));

        // Remove MultisigStrategy
        _callFromFNDNv1(cfg.vault, 0, abi.encodeCall(IConcreteStandardVaultImpl.removeStrategy, (cfg.multisigStrategy)));
    }

    // ═════════════════════════════════════════════════════════════════
    //                 STEP 3: VAULT ROLE MIGRATION
    // ═════════════════════════════════════════════════════════════════

    function _migrateVaultRoles(address vault, bool isDSV) internal {
        IAccessControlEnumerable acl = IAccessControlEnumerable(vault);
        RolePair[5] memory roles = _rolePairs();

        address[5] memory newFunctional = [NEW_VAULT_MANAGER, NEW_HOOK_MANAGER, NEW_STRATEGY_MANAGER, NEW_ALLOCATOR, NEW_WITHDRAWAL_MANAGER];
        address[5] memory newAdmin =
            [NEW_VAULT_MANAGER_ADMIN, NEW_HOOK_MANAGER_ADMIN, NEW_STRATEGY_MANAGER_ADMIN, NEW_ALLOCATOR_ADMIN, NEW_WITHDRAWAL_MANAGER_ADMIN];

        // ── Phase A: Grant all new holders first ──
        for (uint256 i = 0; i < 5; i++) {
            if (!acl.hasRole(roles[i].admin, newAdmin[i])) {
                _callFromFNDNv1(vault, 0, abi.encodeCall(IAccessControl.grantRole, (roles[i].admin, newAdmin[i])));
            }
            if (!acl.hasRole(roles[i].functional, newFunctional[i])) {
                _callFromFNDNv1(vault, 0, abi.encodeCall(IAccessControl.grantRole, (roles[i].functional, newFunctional[i])));
            }
        }

        // ── Phase B: Revoke all old functional holders ──
        for (uint256 i = 0; i < 5; i++) {
            uint256 count = acl.getRoleMemberCount(roles[i].functional);
            for (uint256 j = count; j > 0; j--) {
                address member = acl.getRoleMember(roles[i].functional, j - 1);
                if (member == newFunctional[i]) continue;
                if (isDSV && member == DSV_ADDITIONAL_ROLE_HOLDER) {
                    if (roles[i].functional == Roles.ALLOCATOR || roles[i].functional == Roles.WITHDRAWAL_MANAGER) {
                        continue;
                    }
                }
                _callFromFNDNv1(vault, 0, abi.encodeCall(IAccessControl.revokeRole, (roles[i].functional, member)));
            }
        }

        // ── Phase C: Revoke all old admin holders (point of no return) ──
        for (uint256 i = 0; i < 5; i++) {
            uint256 count = acl.getRoleMemberCount(roles[i].admin);
            for (uint256 j = count; j > 0; j--) {
                address member = acl.getRoleMember(roles[i].admin, j - 1);
                if (member != newAdmin[i]) {
                    _callFromFNDNv1(vault, 0, abi.encodeCall(IAccessControl.revokeRole, (roles[i].admin, member)));
                }
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════
    //         STEP 4: WHITELIST TEST DEPOSITOR (roywstETH/sroywstETH)
    // ═════════════════════════════════════════════════════════════════

    function _whitelistTestDepositor(address hook, address vault) internal {
        if (hook == address(0)) return;

        if (!IWhitelistHook(hook).isWhitelisted(TEST_DEPOSITOR)) {
            address[] memory users = new address[](1);
            users[0] = TEST_DEPOSITOR;
            _callFromFNDNv1(hook, 0, abi.encodeCall(IWhitelistHook.whitelistUsers, (users)));
        }

        // Set vault deposit cap to unlimited
        _callFromFNDNv1(hook, 0, abi.encodeCall(IWhitelistHook.setVaultDepositCap, (vault, type(uint256).max)));
    }

    // ═════════════════════════════════════════════════════════════════
    //                 STEP 5: HOOK OWNERSHIP TRANSFER
    // ═════════════════════════════════════════════════════════════════

    function _migrateHookOwnership(address hook) internal {
        if (hook == address(0)) return;
        if (Ownable(hook).owner() == NEW_HOOK_OWNER) return;

        _callFromFNDNv1(hook, 0, abi.encodeCall(Ownable.transferOwnership, (NEW_HOOK_OWNER)));
    }

    // ═════════════════════════════════════════════════════════════════
    //                      VERIFICATION
    // ═════════════════════════════════════════════════════════════════

    function _verifyAll(VaultConfig memory cfg, VaultSnapshot memory snap, bool isDSV) internal {
        _verifyStateInvariants(cfg, snap);
        _verifyRoles(cfg.vault, isDSV);
        _verifyHookOwnership(cfg.whitelistHook);
        _verifyStrategyState(cfg, snap, isDSV);
        _verifyMakinaStrategySanity(cfg);
        _verifyAccessManagerConfig(cfg.makinaStrategy);
        _verifyDepositAndAllocate(cfg);
    }

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

        (uint16 mFee, address mRecipient, uint32 mAccrual, uint16 pFee, address pRecipient) = vault.getFeeConfig();
        assertEq(mFee, snap.managementFee, "managementFee changed");
        assertEq(mRecipient, snap.managementFeeRecipient, "managementFeeRecipient changed");
        assertEq(mAccrual, snap.lastManagementFeeAccrual, "lastManagementFeeAccrual changed");
        assertEq(pFee, snap.performanceFee, "performanceFee changed");
        assertEq(pRecipient, snap.performanceFeeRecipient, "performanceFeeRecipient changed");

        (uint256 maxDep, uint256 minDep) = vault.getDepositLimits();
        (uint256 maxWd, uint256 minWd) = vault.getWithdrawLimits();
        assertEq(minDep, snap.minDepositAmount, "minDepositAmount changed");
        assertEq(maxDep, type(uint256).max, "maxDepositAmount should be unlimited");
        assertEq(minWd, snap.minWithdrawAmount, "minWithdrawAmount changed");
        assertEq(maxWd, snap.maxWithdrawAmount, "maxWithdrawAmount changed");

        assertEq(asyncVault.isQueueActive(), snap.isQueueActive, "isQueueActive changed");
        assertEq(asyncVault.latestEpochID(), snap.latestEpochID, "latestEpochID changed");

        console2.log("    [OK] State invariants verified");
    }

    function _verifyRoles(address vault, bool isDSV) internal view {
        IAccessControlEnumerable acl = IAccessControlEnumerable(vault);
        RolePair[5] memory roles = _rolePairs();

        address[5] memory expectedFunctional = [NEW_VAULT_MANAGER, NEW_HOOK_MANAGER, NEW_STRATEGY_MANAGER, NEW_ALLOCATOR, NEW_WITHDRAWAL_MANAGER];
        address[5] memory expectedAdmin =
            [NEW_VAULT_MANAGER_ADMIN, NEW_HOOK_MANAGER_ADMIN, NEW_STRATEGY_MANAGER_ADMIN, NEW_ALLOCATOR_ADMIN, NEW_WITHDRAWAL_MANAGER_ADMIN];

        for (uint256 i = 0; i < 5; i++) {
            assertTrue(acl.hasRole(roles[i].functional, expectedFunctional[i]), string.concat("New functional holder missing role at index ", vm.toString(i)));
            assertTrue(acl.hasRole(roles[i].admin, expectedAdmin[i]), string.concat("New admin holder missing role at index ", vm.toString(i)));
            assertEq(acl.getRoleMemberCount(roles[i].admin), 1, string.concat("Admin role member count != 1 at index ", vm.toString(i)));

            bool isAllocatorOrWM = (roles[i].functional == Roles.ALLOCATOR || roles[i].functional == Roles.WITHDRAWAL_MANAGER);
            if (isDSV && isAllocatorOrWM) {
                assertEq(acl.getRoleMemberCount(roles[i].functional), 2, string.concat("DSV functional role member count != 2 at index ", vm.toString(i)));
                assertTrue(
                    acl.hasRole(roles[i].functional, DSV_ADDITIONAL_ROLE_HOLDER), string.concat("DSV additional holder missing role at index ", vm.toString(i))
                );
            } else {
                assertEq(acl.getRoleMemberCount(roles[i].functional), 1, string.concat("Functional role member count != 1 at index ", vm.toString(i)));
            }

            if (FNDNv1 != expectedFunctional[i]) {
                assertFalse(acl.hasRole(roles[i].functional, FNDNv1), "FNDNv1 still has functional role");
            }
            if (FNDNv1 != expectedAdmin[i]) {
                assertFalse(acl.hasRole(roles[i].admin, FNDNv1), "FNDNv1 still has admin role");
            }
        }
        console2.log("    [OK] Vault roles verified");
    }

    function _verifyHookOwnership(address hook) internal view {
        if (hook == address(0)) {
            console2.log("    [SKIP] No whitelist hook configured");
            return;
        }
        assertEq(Ownable(hook).owner(), NEW_HOOK_OWNER, "Hook ownership not transferred");
        assertTrue(Ownable(hook).owner() != FNDNv1, "Hook still owned by old safe");
        console2.log("    [OK] Hook ownership verified");
    }

    function _verifyStrategyState(VaultConfig memory cfg, VaultSnapshot memory snap, bool isDSV) internal view {
        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(cfg.vault);

        if (isDSV) {
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

            address[] memory order = vault.getDeallocationOrder();
            assertTrue(_contains(order, cfg.multisigStrategy), "DSV dealloc order missing multisig");
            assertTrue(_contains(order, cfg.makinaStrategy), "DSV dealloc order missing makina");
        } else {
            address[] memory strategies = vault.getStrategies();
            assertEq(strategies.length, 1, "Non-DSV should have exactly 1 strategy");
            assertEq(strategies[0], cfg.makinaStrategy, "Non-DSV strategy should be makina");

            IConcreteStandardVaultImpl.StrategyData memory mkData = vault.getStrategyData(cfg.makinaStrategy);
            assertEq(uint8(mkData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Active), "Makina strategy not Active");
            assertEq(mkData.allocated, 0, "Makina strategy should have 0 allocated");

            IConcreteStandardVaultImpl.StrategyData memory msData = vault.getStrategyData(cfg.multisigStrategy);
            assertEq(uint8(msData.status), uint8(IConcreteStandardVaultImpl.StrategyStatus.Inactive), "Multisig strategy should be Inactive (removed)");

            address[] memory order = vault.getDeallocationOrder();
            assertEq(order.length, 1, "Non-DSV dealloc order should have 1 entry");
            assertEq(order[0], cfg.makinaStrategy, "Non-DSV dealloc order should be makina");
        }
        console2.log("    [OK] Strategy state verified");
    }

    function _verifyMakinaStrategySanity(VaultConfig memory cfg) internal view {
        RoycoVaultMakinaStrategy strategy = RoycoVaultMakinaStrategy(cfg.makinaStrategy);
        assertEq(strategy.asset(), IERC4626(cfg.vault).asset(), "Strategy asset mismatch");
        assertEq(strategy.getVault(), cfg.vault, "Strategy vault mismatch");
        assertEq(strategy.totalAllocatedValue(), 0, "Strategy should have 0 allocated value");
        console2.log("    [OK] Makina strategy sanity verified");
    }

    function _verifyAccessManagerConfig(address makinaStrategy) internal {
        IAccessManager factory = IAccessManager(ROYCO_FACTORY);
        for (uint256 i = 0; i < 3; i++) {
            (bool allowed,) = factory.canCall(STRATEGY_RESTRICTED_CALLER, makinaStrategy, STRATEGY_RESTRICTED_SELECTORS[i]);
            assertTrue(allowed, string.concat("Restricted caller not authorized for selector index ", vm.toString(i)));
        }
        address rando = makeAddr("unauthorized");
        for (uint256 i = 0; i < 3; i++) {
            (bool allowed,) = factory.canCall(rando, makinaStrategy, STRATEGY_RESTRICTED_SELECTORS[i]);
            assertFalse(allowed, string.concat("Random address authorized for selector index ", vm.toString(i)));
        }
        console2.log("    [OK] AccessManager config verified");
    }

    function _verifyDepositAndAllocate(VaultConfig memory cfg) internal {
        IERC4626 erc4626 = IERC4626(cfg.vault);
        address asset = erc4626.asset();
        uint8 decimals = IERC20Metadata(asset).decimals();
        uint256 depositAmount = 10 ** decimals; // 1 token

        // ── 1. Deposit into vault ──
        deal(asset, TEST_DEPOSITOR, depositAmount);
        vm.startPrank(TEST_DEPOSITOR);
        IERC20(asset).approve(cfg.vault, depositAmount);
        uint256 shares = erc4626.deposit(depositAmount, TEST_DEPOSITOR);
        vm.stopPrank();

        assertTrue(shares > 0, "Deposit returned 0 shares");
        console2.log("    [OK] Deposit verified - shares received:", shares);

        // ── 2. Configure strategy as depositor/redeemer on the Makina Machine (vm.store override) ──
        RoycoVaultMakinaStrategy strategy = RoycoVaultMakinaStrategy(cfg.makinaStrategy);
        address machine = strategy.getMakinaMachine();

        // Save original depositor/redeemer to restore after
        address originalDepositor = IMachine(machine).depositor();
        address originalRedeemer = IMachine(machine).redeemer();

        bytes32 depositorSlot = bytes32(uint256(MACHINE_STORAGE_LOCATION) + DEPOSITOR_SLOT_OFFSET);
        bytes32 redeemerSlot = bytes32(uint256(MACHINE_STORAGE_LOCATION) + REDEEMER_SLOT_OFFSET);

        vm.store(machine, depositorSlot, bytes32(uint256(uint160(cfg.makinaStrategy))));
        vm.store(machine, redeemerSlot, bytes32(uint256(uint160(cfg.makinaStrategy))));

        // ── 3. Allocate to the Makina strategy through the vault ──
        address allocator = IAccessControlEnumerable(cfg.vault).getRoleMember(Roles.ALLOCATOR, 0);

        uint256 machineBalBefore = IERC20(asset).balanceOf(machine);

        IAllocateModule.AllocateParams[] memory allocParams = new IAllocateModule.AllocateParams[](1);
        allocParams[0] = IAllocateModule.AllocateParams({
            isDeposit: true,
            strategy: cfg.makinaStrategy,
            extraData: abi.encode(depositAmount, uint256(0)) // amount, minSharesOut
        });

        vm.prank(allocator);
        IConcreteStandardVaultImpl(cfg.vault).allocate(abi.encode(allocParams));

        uint256 machineBalAfter = IERC20(asset).balanceOf(machine);
        assertEq(machineBalAfter - machineBalBefore, depositAmount, "Machine did not receive exact deposit amount");

        uint256 allocatedValue = strategy.totalAllocatedValue();
        assertTrue(allocatedValue > 0, "Strategy should have allocated value after allocation");
        console2.log("    [OK] Allocation verified - machine received:", depositAmount, "totalAllocatedValue:", allocatedValue);

        // ── 4. Deallocate back from the Makina strategy ──
        IERC20 machineShareToken = IERC20(IMachine(machine).shareToken());
        uint256 strategyShares = machineShareToken.balanceOf(cfg.makinaStrategy);

        IAllocateModule.AllocateParams[] memory deallocParams = new IAllocateModule.AllocateParams[](1);
        deallocParams[0] = IAllocateModule.AllocateParams({
            isDeposit: false,
            strategy: cfg.makinaStrategy,
            extraData: abi.encode(strategyShares, uint256(0)) // sharesToRedeem, minAssetsOut
        });

        vm.prank(allocator);
        IConcreteStandardVaultImpl(cfg.vault).allocate(abi.encode(deallocParams));

        assertEq(strategy.totalAllocatedValue(), 0, "Strategy should have 0 allocated value after deallocation");
        console2.log("    [OK] Deallocation verified - round-trip complete");

        // ── 5. Restore original depositor/redeemer ──
        vm.store(machine, depositorSlot, bytes32(uint256(uint160(originalDepositor))));
        vm.store(machine, redeemerSlot, bytes32(uint256(uint160(originalRedeemer))));
    }

    // ═════════════════════════════════════════════════════════════════
    //                   FINAL STATE PRINTER
    // ═════════════════════════════════════════════════════════════════

    function _printVaultState(VaultConfig memory cfg, string memory label) internal view {
        IConcreteStandardVaultImpl vault = IConcreteStandardVaultImpl(cfg.vault);
        IConcreteAsyncVaultImpl asyncVault = IConcreteAsyncVaultImpl(cfg.vault);
        IAccessControlEnumerable acl = IAccessControlEnumerable(cfg.vault);
        IERC4626 erc4626 = IERC4626(cfg.vault);
        RolePair[5] memory roles = _rolePairs();

        console2.log("");
        console2.log("----------------------------------------");
        console2.log("  Vault:", label);
        console2.log("  Address:", cfg.vault);
        console2.log("  Asset:", erc4626.asset());
        console2.log("----------------------------------------");

        // Accounting
        console2.log("  totalAssets:", erc4626.totalAssets());
        console2.log("  totalSupply:", erc4626.totalSupply());
        console2.log("  cachedTotalAssets:", vault.cachedTotalAssets());
        console2.log("  totalAllocated:", vault.getTotalAllocated());
        console2.log("  isQueueActive:", asyncVault.isQueueActive());
        console2.log("  latestEpochID:", asyncVault.latestEpochID());

        // Strategies
        address[] memory strategies = vault.getStrategies();
        console2.log("  Strategies (count):", strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            IConcreteStandardVaultImpl.StrategyData memory sd = vault.getStrategyData(strategies[i]);
            console2.log("    -", strategies[i]);
            console2.log("      status:", uint8(sd.status));
            console2.log("      allocated:", sd.allocated);
        }

        address[] memory order = vault.getDeallocationOrder();
        console2.log("  Deallocation order (count):", order.length);
        for (uint256 i = 0; i < order.length; i++) {
            console2.log("    -", order[i]);
        }

        // Roles
        console2.log("  Roles:");
        for (uint256 i = 0; i < 5; i++) {
            uint256 fCount = acl.getRoleMemberCount(roles[i].functional);
            console2.log(string.concat("    ", ROLE_NAMES[i], " (", vm.toString(fCount), " members):"));
            for (uint256 j = 0; j < fCount; j++) {
                console2.log("      -", acl.getRoleMember(roles[i].functional, j));
            }
            uint256 aCount = acl.getRoleMemberCount(roles[i].admin);
            console2.log(string.concat("    ", ADMIN_ROLE_NAMES[i], " (", vm.toString(aCount), " members):"));
            for (uint256 j = 0; j < aCount; j++) {
                console2.log("      -", acl.getRoleMember(roles[i].admin, j));
            }
        }

        // Hook
        if (cfg.whitelistHook != address(0)) {
            console2.log("  Whitelist Hook:", cfg.whitelistHook);
            console2.log("    owner:", Ownable(cfg.whitelistHook).owner());
        }

        // Makina Strategy
        console2.log("  Makina Strategy:", cfg.makinaStrategy);
        console2.log("    asset:", RoycoVaultMakinaStrategy(cfg.makinaStrategy).asset());
        console2.log("    vault:", RoycoVaultMakinaStrategy(cfg.makinaStrategy).getVault());
        console2.log("    machine:", RoycoVaultMakinaStrategy(cfg.makinaStrategy).getMakinaMachine());
        console2.log("    totalAllocatedValue:", RoycoVaultMakinaStrategy(cfg.makinaStrategy).totalAllocatedValue());
    }

    // ═════════════════════════════════════════════════════════════════
    //                 TRANSACTION QUEUE WRITER
    // ═════════════════════════════════════════════════════════════════

    function _writeTransactionQueues() internal {
        string memory v1Path = "output/fndnv1_transactions.json";
        string memory v2Path = "output/fndnv2_transactions.json";

        _writeBatchJson(fndnV1Queue, v1Path, "Vault Migration - FNDNv1");
        _writeBatchJson(fndnV2Queue, v2Path, "Vault Migration - FNDNv2");

        console2.log("");
        console2.log("========================================");
        console2.log("  Transaction queues written:");
        console2.log("    FNDNv1:", fndnV1Queue.length, "transactions ->", v1Path);
        console2.log("    FNDNv2:", fndnV2Queue.length, "transactions ->", v2Path);
        console2.log("========================================");
    }

    /// @dev Writes a Safe Transaction Builder compatible JSON batch file
    function _writeBatchJson(Transaction[] storage queue, string memory path, string memory name) internal {
        // Build each transaction object and collect into an array
        string[] memory txJsons = new string[](queue.length);
        for (uint256 i = 0; i < queue.length; i++) {
            string memory key = string.concat("tx", vm.toString(i));
            vm.serializeAddress(key, "to", queue[i].to);
            vm.serializeString(key, "value", vm.toString(queue[i].value));
            txJsons[i] = vm.serializeBytes(key, "data", queue[i].data);
        }

        // Build the root object
        string memory root = "root";
        vm.serializeString(root, "version", "1.0");
        vm.serializeString(root, "chainId", "1");
        vm.serializeUint(root, "createdAt", block.timestamp);

        // Meta object
        string memory meta = vm.serializeString("meta", "name", name);
        meta = vm.serializeString("meta", "description", "Vault migration batch");
        vm.serializeString(root, "meta", meta);

        // Serialize transactions array
        string memory finalJson = vm.serializeString(root, "transactions", txJsons);

        vm.writeJson(finalJson, path);
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
