pragma solidity ^0.8.28;

import {
    BaseStrategy,
    BaseStrategyStorage,
    IERC4626,
    IStrategyTemplate,
    StrategyType
} from "../lib/concrete-earn-v2-bug-bounty/src/periphery/strategies/BaseStrategy.sol";
import {IMachine} from "../lib/makina-core/src/interfaces/IMachine.sol";
import {IERC20, SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract RoycoVaultMakinaStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /// @dev Storage slot for RoycoVaultMakinaStrategyState using the ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoVaultMakinaStrategy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_VAULT_MAKINA_STRATEGY_STORAGE_SLOT =
        0x74bb1dae121a4ee47ec7be9d92ef020f47df18a11f3c24f1f86e4109db715c00;

    /**
     * @notice Storage state for the Royco Vault's Makina Machine Strategy
     * @custom:storage-location erc7201:Royco.storage.RoycoVaultMakinaStrategy
     * @custom:field strategyType - The operational type of this strategy (ATOMIC, ASYNC, or CROSSCHAIN)
     * @custom:field makinaMachine - The Makina machine that this strategy allocates to and deallocates from
     * @custom:field machineShareToken - The share token of the Makina machine
     */
    struct RoycoVaultMakinaStrategyState {
        StrategyType strategyType;
        address makinaMachine;
        address machineShareToken;
    }

    /// @dev Thrown when an address that is expected to be non-null is set to the null address
    error VAULT_AND_MACHINE_ASSET_MISMATCH();

    /// @dev Thrown when the allocation params are not exactly 64 bytes (amount to allocate and minimum shares out)
    error INVALID_ALLOCATION_PARAMS();

    /// @dev Thrown when the deallocation params are not exactly 32 bytes (amount to deallocate)
    error INVALID_DEALLOCATION_PARAMS();

    /**
     * @notice Initializes the Royco Vault's Makina Machine Strategy
     * @param _admin The designated admin for this strategy
     * @param _roycoVault The Royco vault that utilizes this strategy
     * @param _makinaMachine The Makina machine that this strategy allocates to and deallocates from
     * @param _strategyType The operational type of this strategy (ATOMIC, ASYNC, or CROSSCHAIN)
     */
    function initialize(address _admin, address _roycoVault, address _makinaMachine, StrategyType _strategyType)
        external
        initializer
    {
        // Initialize the base strategy state
        _initializeBaseStrategy(_admin, _roycoVault);

        // Ensure that the vault and machine's base assets are identical
        address roycoVaultAsset = BaseStrategyStorage.fetch().asset;
        require(roycoVaultAsset == IMachine(_makinaMachine).accountingToken(), VAULT_AND_MACHINE_ASSET_MISMATCH());

        // Initialize the strategy specfic state
        RoycoVaultMakinaStrategyState storage $ = _getRoycoVaultMakinaStrategyStorage();
        $.strategyType = _strategyType;
        $.makinaMachine = _makinaMachine;
        $.machineShareToken = IMachine(_makinaMachine).shareToken();

        // Extend a one-time maximum approval to the machine for pulling assets on deposit
        IERC20(roycoVaultAsset).forceApprove(_makinaMachine, type(uint256).max);
    }

    /// @inheritdoc IStrategyTemplate
    function strategyType() external view override(IStrategyTemplate) returns (StrategyType) {
        return _getRoycoVaultMakinaStrategyStorage().strategyType;
    }

    /// @inheritdoc BaseStrategy
    /// @dev The current value of the strategy's position is the asset value of the Makina machine shares owned by the strategy
    function _previewPosition() internal view override(BaseStrategy) returns (uint256) {
        RoycoVaultMakinaStrategyState storage $ = _getRoycoVaultMakinaStrategyStorage();
        // Get the machine shares owned by this strategy
        uint256 strategySharesBalance = IERC20($.machineShareToken).balanceOf(address(this));
        // Return the value of the shares owned by this strategy in the machine's accounting asset
        // NOTE: The accounting asset is guaranteed to be identical to the Royco vault's base asset
        return IMachine($.makinaMachine).convertToAssets(strategySharesBalance);
    }

    /// @inheritdoc BaseStrategy
    /// @dev Deposits the specified assets into the Makina machine and is minted shares in return
    /// @dev This strategy contract must be configured as the depositor for the machine
    function _allocateToPosition(bytes calldata _allocationParams)
        internal
        override(BaseStrategy)
        returns (uint256 assetsToAllocate)
    {
        // Validate and parse the allocation params to get the amount of assets to allocate and minimum shares to be minted in return
        require(_allocationParams.length == 64, INVALID_ALLOCATION_PARAMS());
        uint256 minSharesOut;
        assembly {
            assetsToAllocate := calldataload(_allocationParams.offset)
            minSharesOut := calldataload(add(_allocationParams.offset, 0x20))
        }

        // Deposit the specified assets into the Makina machine
        // NOTE: Approval for the machine to pull assets was given on initialization
        IMachine(_getRoycoVaultMakinaStrategyStorage().makinaMachine)
            .deposit(assetsToAllocate, address(this), minSharesOut, bytes32(0));
    }

    /// @inheritdoc BaseStrategy
    /// @dev This strategy contract must be configured as the redeemer for the machine
    function _deallocateFromPosition(bytes calldata _deallocationParams)
        internal
        override(BaseStrategy)
        returns (uint256)
    {
        // Validate and parse the deallocation params to get the amount of assets to deallocate
        require(_deallocationParams.length == 32, INVALID_DEALLOCATION_PARAMS());
        uint256 assetsToDeallocate;
        assembly {
            assetsToDeallocate := calldataload(_deallocationParams.offset)
        }

        // Withdraw the specified assets from the machine
        return _withdrawAssetsFromMachine(assetsToDeallocate);
    }

    /// @inheritdoc BaseStrategy
    /// @dev This strategy contract must be configured as the redeemer for the machine
    function _withdrawFromPosition(uint256 _assets) internal override(BaseStrategy) returns (uint256) {
        // Withdraw the specified assets from the machine
        return _withdrawAssetsFromMachine(_assets);
    }

    /**
     * @dev Internal helper which withdraws strategy owned assets from the Makina machine
     * @param _assetsToWithdraw The amount of assets to withdraw from the Makina machine
     * @return assetsWithdrawn The amount of assets withdrawn from the Makina machine
     */
    function _withdrawAssetsFromMachine(uint256 _assetsToWithdraw) internal returns (uint256 assetsWithdrawn) {
        IMachine makinaMachine = IMachine(_getRoycoVaultMakinaStrategyStorage().makinaMachine);
        // Compute the shares equivalent to the value of the assets to withdraw
        uint256 sharesToRedeem = makinaMachine.convertToShares(_assetsToWithdraw);
        // Redeem the shares from the Makina machine, withdrawing the assets to this strategy contract
        // NOTE: We set min amount out to 0 in order to preclude any rounding related reversions
        return makinaMachine.redeem(sharesToRedeem, address(this), 0);
    }

    /**
     * @notice Returns a storage pointer to the state of the Royco Vault's Makina Machine Strategy
     * @dev Uses ERC-7201 storage slot pattern for collision-resistant storage
     * @return $ Storage pointer to the strategy's state
     */
    function _getRoycoVaultMakinaStrategyStorage() internal pure returns (RoycoVaultMakinaStrategyState storage $) {
        assembly ("memory-safe") {
            $.slot := ROYCO_VAULT_MAKINA_STRATEGY_STORAGE_SLOT
        }
    }
}
