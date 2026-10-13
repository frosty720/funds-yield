// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IStrategyFactory} from "../interfaces/clm/IStrategyFactory.sol";

/// @dev Beefy's StratFeeManagerInitializable (MIT; see NOTICE). FrostyFi 2026-10-11: Beefy's fee config and the
///      chain's native token are replaced by the factory's treasury and performance fee.
contract StratFeeManagerInitializable is OwnableUpgradeable, PausableUpgradeable {
    struct CommonAddresses {
        address vault;
        address unirouter;
        address strategist;
        address factory;
    }

    /// @notice The address of the vault
    address public vault;

    /// @notice The address of the unirouter
    address public unirouter;

    /// @notice The address of the strategist
    address public strategist;

    /// @notice The address of the strategy factory
    IStrategyFactory public factory;

    /// @notice The total amount of token0 locked in the vault
    uint256 public totalLocked0;

    /// @notice The total amount of token1 locked in the vault
    uint256 public totalLocked1;

    /// @notice The last time the strat harvested
    uint256 public lastHarvest;

    /// @notice The last time we adjusted the position
    uint256 public lastPositionAdjustment;

    /// @notice The duration of the locked rewards
    /// @dev FrostyFi 2026-10-13 (final review I1): 1 day, the keeper's harvest interval (Beefy: 1 hour).
    uint256 constant DURATION = 1 days;

    // Events
    event SetUnirouter(address unirouter);
    event SetStrategist(address strategist);

    // Errors
    error NotManager();
    error NotStrategist();
    error OverLimit();
    error StrategyPaused();

    /**
     * @notice Initialize the Strategy Fee Manager inherited contract with the common addresses
     * @param _commonAddresses The common addresses of the vault, unirouter, strategist and factory
     */
    function __StratFeeManager_init(CommonAddresses calldata _commonAddresses) internal onlyInitializing {
        __Ownable_init();
        __Pausable_init();
        vault = _commonAddresses.vault;
        unirouter = _commonAddresses.unirouter;
        strategist = _commonAddresses.strategist;
        factory = IStrategyFactory(_commonAddresses.factory);
    }

    /**
     * @notice function that throws if the strategy is paused
     */
    function _whenStrategyNotPaused() internal view {
        if (paused() || factory.globalPause()) revert StrategyPaused();
    }

    /**
     * @notice function that returns true if the strategy is paused
     */
    function _isPaused() internal view returns (bool) {
        return paused() || factory.globalPause();
    }

    /** 
     * @notice Modifier that throws if called by any account other than the manager or the owner
    */
    modifier onlyManager() {
        if (msg.sender != owner() && msg.sender != keeper()) revert NotManager();
        _;
    }

    /// @notice The address of the keeper, set on the factory. 
    function keeper() public view returns (address) {
        return factory.keeper();
    }

    /// @notice FrostyFi 2026-10-11: FrostyFi's treasury, set on the factory; paid the performance fee.
    function treasury() public view returns (address) {
        return factory.treasury();
    }

    /// @notice FrostyFi 2026-10-11: the performance fee on claimed rewards, in basis points, set on the factory.
    function perfFeeBps() public view returns (uint256) {
        return factory.perfFeeBps();
    }

    /**
     * @notice set the unirouter address
     * @param _unirouter The new unirouter address
     */
    function setUnirouter(address _unirouter) external virtual onlyOwner {
        unirouter = _unirouter;
        emit SetUnirouter(_unirouter);
    }

    /**
     * @notice set the strategist address
     * @param _strategist The new strategist address
     */
    function setStrategist(address _strategist) external {
        if (msg.sender != strategist) revert NotStrategist();
        strategist = _strategist;
        emit SetStrategist(_strategist);
    }

    /**
     * @notice The deposit fee variable will alwasy be 0. This is used by the UI. 
     * @return uint256 The deposit fee
     */
    function depositFee() public virtual view returns (uint256) {
        return 0;
    }

    /**
     * @notice The withdraw fee variable will alwasy be 0. This is used by the UI. 
     * @return uint256 The withdraw fee
     */
    function withdrawFee() public virtual view returns (uint256) {
        return 0;
    }

    /**
     * @notice The locked profit is the amount of token0 and token1 that is locked in the vault, this can be overriden by the strategy contract.
     * @return locked0 The amount of token0 locked
     * @return locked1 The amount of token1 locked
     */
    function lockedProfit() public virtual view returns (uint256 locked0, uint256 locked1) {
        uint256 elapsed = block.timestamp - lastHarvest;
        uint256 remaining = elapsed < DURATION ? DURATION - elapsed : 0;
        return (totalLocked0 * remaining / DURATION, totalLocked1 * remaining / DURATION);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}