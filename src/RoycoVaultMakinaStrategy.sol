// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IStrategyTemplate, StrategyType} from "../lib/concrete-earn-v2-bug-bounty/src/interface/IStrategyTemplate.sol";
import {IMachine} from "../lib/makina-core/src/interfaces/IMachine.sol";
import {IERC20, SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {AccessManaged} from "../lib/openzeppelin-contracts/contracts/access/manager/AccessManaged.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Pausable} from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title RoycoVaultMakinaStrategy
 * @author Shivaansh Kapoor, Ankur Dubey
 * @notice A strategy contract for Royco vaults, enabling them to allocate assets into Makina machines
 * @dev This strategy must be configured as the designated depositor and redeemer of the underlying Makina machine
 */
contract RoycoVaultMakinaStrategy is AccessManaged, Pausable, IStrategyTemplate {
    using SafeERC20 for IERC20;

    /// @notice The Royco vault that this strategy is configured for
    address internal immutable ROYCO_VAULT;

    /// @notice The Makina machine that this strategy allocates into and deallocates from
    address internal immutable MAKINA_MACHINE;

    /// @notice The base asset used by the Royco vault and the Makina machine
    address internal immutable ASSET;

    /// @notice The share token of the Makina machine
    address internal immutable MACHINE_SHARE_TOKEN;

    /// @notice The operational type of this strategy (ATOMIC, ASYNC, or CROSSCHAIN)
    StrategyType internal immutable STRATEGY_TYPE;

    /// @notice Emitted when assets are allocated from the vault to the strategy
    /// @param amount The amount of assets allocated
    event AllocateFunds(uint256 amount);

    /// @notice Emitted when assets are deallocated from the strategy back to the vault
    /// @param amount The amount of assets deallocated
    event DeallocateFunds(uint256 amount);

    /// @notice Emitted when assets are withdrawn from the strategy
    /// @param amount The amount of assets withdrawn
    event StrategyWithdraw(uint256 amount);

    /// @dev Thrown when a function permissioned to only be called by the Royco vault is called by another account
    error ONLY_ROYCO_VAULT();

    /// @dev Thrown when an address that is expected to be non-null is set to the null address
    error VAULT_AND_MACHINE_ASSET_MISMATCH();

    /// @dev Thrown when the allocation params are not exactly 64 bytes (amount to allocate and minimum shares out)
    error INVALID_ALLOCATION_PARAMS();

    /// @dev Thrown when the deallocation params are not exactly 64 bytes (shares to redeem and minimum assets out)
    error INVALID_DEALLOCATION_PARAMS();

    /// @dev Thrown when the token being rescued is the base asset or the machine share token
    error INVALID_TOKEN_TO_RESCUE();

    /// @dev Modifier to permission a function to only be callable by the Royco vault
    modifier onlyRoycoVault() {
        require(msg.sender == ROYCO_VAULT, ONLY_ROYCO_VAULT());
        _;
    }

    /**
     * @notice Constructs the Royco Vault's Makina Machine Strategy
     * @param _roycoFactory The Royco factory serves as the access manager for this strategy
     * @param _roycoVault The Royco vault that utilizes this strategy
     * @param _makinaMachine The Makina machine that this strategy allocates into and deallocates from
     * @param _strategyType The operational type of this strategy (ATOMIC, ASYNC, or CROSSCHAIN)
     */
    constructor(address _roycoFactory, address _roycoVault, address _makinaMachine, StrategyType _strategyType)
        AccessManaged(_roycoFactory)
    {
        // Ensure that the Royco vault and machine's base assets are identical
        ASSET = IERC4626(_roycoVault).asset();
        require(ASSET == IMachine(_makinaMachine).accountingToken(), VAULT_AND_MACHINE_ASSET_MISMATCH());

        ROYCO_VAULT = _roycoVault;
        MAKINA_MACHINE = _makinaMachine;
        MACHINE_SHARE_TOKEN = IMachine(_makinaMachine).shareToken();
        STRATEGY_TYPE = _strategyType;
    }

    /**
     * @inheritdoc IStrategyTemplate
     * @dev This strategy must be configured as the depositor for the machine
     * @dev Cannot be called when this strategy is paused
     */
    function allocateFunds(bytes calldata _allocationParams)
        external
        override(IStrategyTemplate)
        whenNotPaused
        onlyRoycoVault
        returns (uint256 amountAllocated)
    {
        // Validate and parse the allocation params to get the amount of assets to allocate and minimum shares to be minted in return
        require(_allocationParams.length == 64, INVALID_ALLOCATION_PARAMS());
        uint256 minSharesOut;
        assembly ("memory-safe") {
            amountAllocated := calldataload(_allocationParams.offset)
            minSharesOut := calldataload(add(_allocationParams.offset, 0x20))
        }

        // Pull the assets to allocate from the vault to the strategy
        IERC20(ASSET).safeTransferFrom(ROYCO_VAULT, address(this), amountAllocated);

        // Deposit the specified assets into the Makina machine, minting the shares to this strategy
        IERC20(ASSET).forceApprove(MAKINA_MACHINE, amountAllocated);
        IMachine(MAKINA_MACHINE).deposit(amountAllocated, address(this), minSharesOut, bytes32(0));

        emit AllocateFunds(amountAllocated);
    }

    /**
     * @inheritdoc IStrategyTemplate
     * @dev This strategy must be configured as the redeemer for the machine
     * @dev Cannot be called when this strategy is paused
     */
    function deallocateFunds(bytes calldata _deallocationParams)
        external
        override(IStrategyTemplate)
        whenNotPaused
        onlyRoycoVault
        returns (uint256 amountDeallocated)
    {
        // Validate and parse the deallocation params to get the shares to redeem and the minimum assets to be deallocated in return
        require(_deallocationParams.length == 64, INVALID_DEALLOCATION_PARAMS());
        uint256 sharesToRedeem;
        uint256 minAssetsOut;
        assembly ("memory-safe") {
            sharesToRedeem := calldataload(_deallocationParams.offset)
            minAssetsOut := calldataload(add(_deallocationParams.offset, 0x20))
        }

        // Redeem the shares from the Makina machine, withdrawing the assets directly to the Royco vault
        amountDeallocated = IMachine(MAKINA_MACHINE).redeem(sharesToRedeem, ROYCO_VAULT, minAssetsOut);

        emit DeallocateFunds(amountDeallocated);
    }

    /**
     * @inheritdoc IStrategyTemplate
     * @dev This strategy must be configured as the redeemer for the machine
     * @dev Cannot be called when this strategy is paused
     */
    function onWithdraw(uint256 _amountToWithdraw)
        external
        override(IStrategyTemplate)
        whenNotPaused
        onlyRoycoVault
        returns (uint256 amountWithdrawn)
    {
        // Compute the shares equivalent to the value of the amount of assets to withdraw
        // NOTE: The conversion rounds down, so we pad it by 1 share to ensure that the requested amount to withdraw is always fulfilled
        uint256 sharesToRedeem = IMachine(MAKINA_MACHINE).convertToShares(_amountToWithdraw) + 1;
        sharesToRedeem = Math.min(sharesToRedeem, _getStrategyOwnedShares());
        // Redeem the shares from the Makina machine, withdrawing the assets directly to the Royco vault
        amountWithdrawn = IMachine(MAKINA_MACHINE).redeem(sharesToRedeem, ROYCO_VAULT, 0);
        emit StrategyWithdraw(amountWithdrawn);
    }

    /**
     * @inheritdoc IStrategyTemplate
     * @dev Only callable by a designated admin assigned by the Royco access manager
     * @dev Can be called when this strategy is paused
     */
    function rescueToken(address _token, uint256 _amount) external override(IStrategyTemplate) restricted {
        // Ensure that the token to rescue is not the base asset or the machine share token
        require(_token != ASSET && _token != MACHINE_SHARE_TOKEN, INVALID_TOKEN_TO_RESCUE());

        // Rescue the specified amount of tokens, remitting them back to the caller
        // An amount of 0 is interpreted as the entire token balance of this strategy
        _amount = _amount == 0 ? IERC20(_token).balanceOf(address(this)) : _amount;
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /// @inheritdoc IStrategyTemplate
    function totalAllocatedValue() external view override(IStrategyTemplate) returns (uint256) {
        return _getStrategyOwnedAssets();
    }

    /// @inheritdoc IStrategyTemplate
    /// @dev Returns the max assets depositable into this strategy
    function maxAllocation() external view override(IStrategyTemplate) returns (uint256) {
        // Return the asset value of the maximum mintable shares
        uint256 maxMintableShares = IMachine(MAKINA_MACHINE).maxMint();
        if (maxMintableShares == type(uint256).max) return type(uint256).max;
        else return IMachine(MAKINA_MACHINE).convertToAssets(maxMintableShares);
    }

    /// @inheritdoc IStrategyTemplate
    /// @dev Returns the max withdrawable assets from this strategy: accounts for vault and machine level liquidity constraints
    function maxWithdraw() external view override(IStrategyTemplate) returns (uint256) {
        // Retrieve the maximum withdrawable liquid assets from the machine
        uint256 maxWithdrawableAssets = IMachine(MAKINA_MACHINE).maxWithdraw();
        // Return the minimum of the maximum withdrawable assets and the strategy's position in the machine
        return Math.min(maxWithdrawableAssets, _getStrategyOwnedAssets());
    }

    /// @inheritdoc IStrategyTemplate
    function asset() external view override(IStrategyTemplate) returns (address) {
        return ASSET;
    }

    /// @inheritdoc IStrategyTemplate
    function getVault() external view override(IStrategyTemplate) returns (address) {
        return ROYCO_VAULT;
    }

    /// @notice Returns the Makina machine that this strategy is configured to allocate assets into
    function getMakinaMachine() external view returns (address) {
        return MAKINA_MACHINE;
    }

    /// @inheritdoc IStrategyTemplate
    function strategyType() external view override(IStrategyTemplate) returns (StrategyType) {
        return STRATEGY_TYPE;
    }

    /// @dev Internal helper which retrieves the current value of the strategy's position in base assets
    function _getStrategyOwnedAssets() internal view returns (uint256) {
        // Return the value of the shares owned by this strategy in the machine's accounting asset
        // NOTE: The accounting asset is guaranteed to be identical to the Royco vault's base asset
        return IMachine(MAKINA_MACHINE).convertToAssets(_getStrategyOwnedShares());
    }

    /// @dev Internal helper which retrieves the Makina machine shares owned by this strategy
    function _getStrategyOwnedShares() internal view returns (uint256) {
        return IERC20(MACHINE_SHARE_TOKEN).balanceOf(address(this));
    }

    /// @notice Pauses the strategy, disabling allocations and deallocations
    /// @dev Only callable by a designated admin assigned by the Royco access manager
    function pause() external restricted {
        _pause();
    }

    /// @notice Unpauses the strategy, enabling allocations and deallocations
    /// @dev Only callable by a designated admin assigned by the Royco access manager
    function unpause() external restricted {
        _unpause();
    }
}
