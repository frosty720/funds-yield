// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FrostyClmVault} from "./FrostyClmVault.sol";
import {ClonesUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/ClonesUpgradeable.sol";

// FrostyFi CLM vault factory: Beefy's BeefyVaultConcLiqFactory (MIT; see NOTICE), forked 2026-10-11
// Minimal proxy pattern for creating new Beefy concentrated liquidity vaults
contract FrostyClmVaultFactory {
  using ClonesUpgradeable for address;

  /// @notice Contract template for deploying proxied Beefy vaults
  FrostyClmVault public instance;

  /// @notice Emitted when a new Beefy Vault is created
  event ProxyCreated(address proxy);

  /** 
   * @notice Constructor initializes the Beefy Vault template instance
   * @param _instance The address of the Beefy Vault template instance
   */
  constructor(address _instance) {
    if (_instance == address(0)) {
      instance = new FrostyClmVault();
    } else {
      instance = FrostyClmVault(_instance);
    }
  }

  /**
   * @notice Create a new Beefy Conc Liq Vault as a proxy of the template instance
   * @return A reference to the new proxied Beefy Vault
   */
  function cloneVault(
  ) external returns (FrostyClmVault) {
    FrostyClmVault vault = FrostyClmVault(_cloneContract(address(instance)));
    return vault;
  }

  /**
   * Deploys and returns the address of a clone that mimics the behaviour of `implementation`
   * @param implementation The address of the contract to clone
   * @return The address of the newly created clone
  */
  function _cloneContract(address implementation) private returns (address) {
    address proxy = implementation.clone();
    emit ProxyCreated(proxy);
    return proxy;
  }
}