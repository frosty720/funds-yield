// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BeaconProxy} from "@openzeppelin-4/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin-4/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Ownable} from "@openzeppelin-4/contracts/access/Ownable.sol";

// FrostyFi CLM strategy factory: Beefy's StrategyFactory (MIT; see NOTICE), forked 2026-10-11
// Minimal upgradeable beacon proxy pattern for creating new Beefy concentrated liquidity vaults
contract FrostyClmStrategyFactory is Ownable {

  /// @notice instance mapping to strategy name with version. 
  mapping (string => UpgradeableBeacon) public instances;

  /// @notice approved rebalancer mapping 
  mapping (address => bool) public rebalancers;

  /// @notice deployed strategy types
  string[] public strategyTypes;

  /// @notice The address of the keeper
  address public keeper;

  /// @notice FrostyFi 2026-10-11: FrostyFi's treasury, paid the performance fee on every reward claim.
  address public treasury;

  /// @notice FrostyFi 2026-10-11: the performance fee on claimed rewards, in basis points.
  uint256 public perfFeeBps;

  /// @notice FrostyFi 2026-10-11: FrostyFi's ValueInterpreter, which prices a harvest's reward sale.
  address public valueInterpreter;

  /// @notice FrostyFi 2026-10-11: bytecode bounds on the performance fee (hard rule 5; the FeeCompounder vaults' bounds).
  uint256 public constant MIN_PERF_FEE_BPS = 500;
  uint256 public constant MAX_PERF_FEE_BPS = 3000;

  /// @notice Global pause state for all strategies that use this
  bool public globalPause;

  /// @notice Emitted when a new Beefy Strategy is created
  event ProxyCreated(string strategyName, address proxy);

  /// @notice Emitted when a Beefy Strategy is upgraded
  event InstanceUpgraded(string strategyName, address newImplementation);

  /// @notice Emitted when a new Beefy Strategy is added
  event NewStrategyAdded(string strategyName, address implementation);

  /// @notice Emitted when the treasury is changed
  event SetTreasury(address treasury);

  /// @notice Emitted when the performance fee is changed
  event SetPerfFeeBps(uint256 perfFeeBps);

  /// @notice Emitted when the ValueInterpreter is changed
  event SetValueInterpreter(address valueInterpreter);

  /// @notice Emitted when the keeper address is changed
  event SetKeeper(address keeper);

  /// @notice Emitted when the global pause state is changed
  event GlobalPause(bool paused);

  /// @notice Emitted when a rebalancer is added or removed
  event RebalancerChanged(address rebalancer, bool isRebalancer);

  // Errors
  error NotManager();
  error StratVersionExists();
  error ZeroAddress();
  error PerfFeeOutOfBounds(uint256 bps);

  /// @notice Throws if called by any account other than the owner or the keeper
  modifier onlyManager() {
    if (msg.sender != owner() && msg.sender != address(keeper)) revert NotManager();
    _;
  }

  /// @notice Constructor initializes the keeper, the treasury, the ValueInterpreter and the performance fee
  constructor(
    address _keeper,
    address _treasury,
    address _valueInterpreter,
    uint256 _perfFeeBps
  ) Ownable(msg.sender) {
    keeper = _keeper;
    _setTreasury(_treasury);
    _setValueInterpreter(_valueInterpreter);
    _setPerfFeeBps(_perfFeeBps);
  }

  /** @notice Creates a new Beefy Strategy as a proxy of the template instance
    * @param _strategyName The name of the strategy
    * @return A reference to the new proxied Beefy Strategy
   */
  function createStrategy(string calldata _strategyName) external returns (address) {
    
    // Create a new Beefy Strategy as a proxy of the template instance
    UpgradeableBeacon instance = instances[_strategyName];
    BeaconProxy proxy = new BeaconProxy(address(instance), "");

    emit ProxyCreated(_strategyName, address(proxy));

    return address(proxy);
  }

  /**
   * @notice Upgrades the implementation of a strategy
   * @param _strategyName The name of the strategy
   * @param _newImplementation The new implementation address
   */
  function upgradeTo(string calldata _strategyName, address _newImplementation) external onlyOwner {
    UpgradeableBeacon instance = instances[_strategyName];
    instance.upgradeTo(_newImplementation);
    emit InstanceUpgraded(_strategyName, _newImplementation);
  }

  /**
   * @notice Adds a new strategy to the factory
   * @param _strategyName The name of the strategy
   * @param _implementation The implementation address
   */
  function addStrategy(string calldata _strategyName, address _implementation) external onlyManager {
    if (address(instances[_strategyName]) != address(0)) revert StratVersionExists();
    instances[_strategyName] = new UpgradeableBeacon(_implementation, address(this));

    // Store in our deployed strategy type array
    strategyTypes.push(_strategyName);
    emit NewStrategyAdded(_strategyName, _implementation);
  }

  /**
   * @notice Pauses all strategies
   */
  function pauseAllStrats() external onlyManager {
    globalPause = true;
    emit GlobalPause(true);
  }

  /**
   * @notice Unpauses all strategies
   */
  function unpauseAllStrats() external onlyOwner {
    globalPause = false;
    emit GlobalPause(false);
  }

  /**
   * @notice Adds a rebalancer callable by the owner
   * @param _rebalancer The rebalancer address
   */
  function addRebalancer(address _rebalancer) external onlyOwner {
    rebalancers[_rebalancer] = true;
    emit RebalancerChanged(_rebalancer, true);
  }

  /**
   * @notice Removes a rebalancer callable by a manager
   * @param _rebalancer The rebalancer address
   */
  function removeRebalancer(address _rebalancer) external onlyManager {
    rebalancers[_rebalancer] = false;
    emit RebalancerChanged(_rebalancer, false);
  }

  /**
   * @notice set the treasury address
   * @param _treasury The new treasury address
   */
  function setTreasury(address _treasury) external onlyOwner {
    _setTreasury(_treasury);
  }

  /**
   * @notice set the performance fee, within [MIN_PERF_FEE_BPS, MAX_PERF_FEE_BPS]
   * @param _perfFeeBps The new performance fee in basis points
   */
  function setPerfFeeBps(uint256 _perfFeeBps) external onlyOwner {
    _setPerfFeeBps(_perfFeeBps);
  }

  /**
   * @notice set the ValueInterpreter address
   * @param _valueInterpreter The new ValueInterpreter address
   */
  function setValueInterpreter(address _valueInterpreter) external onlyOwner {
    _setValueInterpreter(_valueInterpreter);
  }

  /// @dev FrostyFi 2026-10-11: a zero treasury would make every claim revert, which locks deposits and withdrawals.
  function _setTreasury(address _treasury) private {
    if (_treasury == address(0)) revert ZeroAddress();
    treasury = _treasury;
    emit SetTreasury(_treasury);
  }

  function _setPerfFeeBps(uint256 _perfFeeBps) private {
    if (_perfFeeBps < MIN_PERF_FEE_BPS || _perfFeeBps > MAX_PERF_FEE_BPS) revert PerfFeeOutOfBounds(_perfFeeBps);
    perfFeeBps = _perfFeeBps;
    emit SetPerfFeeBps(_perfFeeBps);
  }

  function _setValueInterpreter(address _valueInterpreter) private {
    if (_valueInterpreter == address(0)) revert ZeroAddress();
    valueInterpreter = _valueInterpreter;
    emit SetValueInterpreter(_valueInterpreter);
  }

  /**
   * @notice set the keeper address
   * @param _keeper The new keeper address
   */
  function setKeeper(address _keeper) external onlyOwner {
      keeper = _keeper;
      emit SetKeeper(_keeper);
  }

  /**
   * @notice Gets the implementation of a strategy
   * @param _strategyName The name of the strategy
   * @return The implementation address
   */
  function getImplementation(string calldata _strategyName) external view returns (address) {
    return instances[_strategyName].implementation();
  }

  /**
   * @notice Gets the array of deployed strategies
   * @return The array of deployed strategies
   */
  function getStrategyTypes() external view returns (string[] memory) {
    return strategyTypes;
  }
}