// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStrategyFactory {
    function globalPause() external view returns (bool);
    function keeper() external view returns (address);
    function treasury() external view returns (address);
    function perfFeeBps() external view returns (uint256);
    function valueInterpreter() external view returns (address);
    function rebalancers(address) external view returns (bool);
}
