pragma solidity ^0.8.28;

import {
    BaseStrategy,
    BaseStrategyStorage,
    IERC4626,
    IStrategyTemplate,
    StrategyType
} from "../lib/concrete-earn-v2-bug-bounty/src/periphery/strategies/BaseStrategy.sol";
import {IMachine} from "../lib/makina-core/src/interfaces/IMachine.sol";

contract RoycoVaultMakinaStrategy is BaseStrategy {
    /// @dev Storage slot for RoycoVaultMakinaStrategyState using the ERC-7201 pattern
    // keccak256(abi.encode(uint256(keccak256("Royco.storage.RoycoVaultMakinaStrategy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ROYCO_VAULT_MAKINA_STRATEGY_STORAGE_SLOT =
        0x74bb1dae121a4ee47ec7be9d92ef020f47df18a11f3c24f1f86e4109db715c00;

    /**
     * @notice Storage state for the Royco Vault's Makina Machine Strategy
     * @custom:storage-location erc7201:Royco.storage.RoycoVaultMakinaStrategy
     * @custom:field strategyType - The operational type of this strategy (ATOMIC, ASYNC, or CROSSCHAIN)
     * @custom:field makinaMachine - The Makina machine that this strategy allocates to and deallocates from
     */
    struct RoycoVaultMakinaStrategyState {
        StrategyType strategyType;
        address makinaMachine;
    }

    /// @dev Thrown when an address that is expected to be non-null is set to the null address
    error VAULT_AND_MACHINE_ASSET_MISMATCH();

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
        // Ensure that the vault and machine's base assets are identical
        require(
            IERC4626(_roycoVault).asset() == IMachine(_makinaMachine).accountingToken(),
            VAULT_AND_MACHINE_ASSET_MISMATCH()
        );

        // Initialize the base strategy state
        _initializeBaseStrategy(_admin, _roycoVault);

        // Initialize the strategy specfic state
        RoycoVaultMakinaStrategyState storage $ = _getRoycoVaultMakinaStrategyStorage();
        $.strategyType = _strategyType;
        $.makinaMachine = _makinaMachine;
    }

    /// @inheritdoc IStrategyTemplate
    function strategyType() external view override(IStrategyTemplate) returns (StrategyType) {
        return _getRoycoVaultMakinaStrategyStorage().strategyType;
    }

    /// @inheritdoc BaseStrategy
    function _previewPosition() internal view override(BaseStrategy) returns (uint256) {}

    /// @inheritdoc BaseStrategy
    function _allocateToPosition(bytes calldata data) internal override(BaseStrategy) returns (uint256) {}

    /// @inheritdoc BaseStrategy
    function _deallocateFromPosition(bytes calldata data) internal override(BaseStrategy) returns (uint256) {}

    /// @inheritdoc BaseStrategy
    function _withdrawFromPosition(uint256 assets) internal override(BaseStrategy) returns (uint256) {}

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
