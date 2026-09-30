// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Optimism} from 'aave-address-book/GovernanceV3Optimism.sol';
import {GovernanceV3Arbitrum} from 'aave-address-book/GovernanceV3Arbitrum.sol';
import {GovernanceV3Base} from 'aave-address-book/GovernanceV3Base.sol';
import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3EthereumLido} from 'aave-address-book/AaveV3EthereumLido.sol';
import {AaveV3Avalanche} from 'aave-address-book/AaveV3Avalanche.sol';
import {AaveV3Optimism} from 'aave-address-book/AaveV3Optimism.sol';
import {AaveV3Arbitrum} from 'aave-address-book/AaveV3Arbitrum.sol';
import {AaveV3Base} from 'aave-address-book/AaveV3Base.sol';

import {RefreshRewardsReceiver} from '../src/RefreshRewardsReceiver.sol';

// make deploy-refresh-rewards env=<Mainnet|Avalanche|Optimism|Arbitrum|Base> [dry=1]
contract DeployRefreshRewardsReceiver is Script {
  struct DeployConfig {
    address owner;
    address guardian;
    address[] factories;
  }

  function run() external returns (address) {
    DeployConfig memory config = getDeployConfig(block.chainid);
    vm.startBroadcast();
    RefreshRewardsReceiver receiver = new RefreshRewardsReceiver(
      config.owner,
      config.guardian,
      config.factories
    );
    vm.stopBroadcast();
    console.log('RefreshRewardsReceiver deployed at:', address(receiver));
    console.log('Owner:', config.owner);
    console.log('Guardian:', config.guardian);
    for (uint256 i = 0; i < config.factories.length; i++) {
      console.log('Enabled factory:', config.factories[i]);
    }
    return address(receiver);
  }

  /// @dev Owner / guardian are the chain's governance executor and guardian; the
  /// factories are the chain's Aave v3 stataToken factories. Only chains whose
  /// stataTokens have had rewards configured are supported.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory) {
    if (chainId == ChainIds.MAINNET)
      return
        DeployConfig(
          GovernanceV3Ethereum.EXECUTOR_LVL_1,
          GovernanceV3Ethereum.GOVERNANCE_GUARDIAN,
          _two(AaveV3Ethereum.STATA_FACTORY, AaveV3EthereumLido.STATA_FACTORY)
        );
    if (chainId == ChainIds.AVALANCHE)
      return
        DeployConfig(
          GovernanceV3Avalanche.EXECUTOR_LVL_1,
          GovernanceV3Avalanche.GOVERNANCE_GUARDIAN,
          _one(AaveV3Avalanche.STATA_FACTORY)
        );
    if (chainId == ChainIds.OPTIMISM)
      return
        DeployConfig(
          GovernanceV3Optimism.EXECUTOR_LVL_1,
          GovernanceV3Optimism.GOVERNANCE_GUARDIAN,
          _one(AaveV3Optimism.STATA_FACTORY)
        );
    if (chainId == ChainIds.ARBITRUM)
      return
        DeployConfig(
          GovernanceV3Arbitrum.EXECUTOR_LVL_1,
          GovernanceV3Arbitrum.GOVERNANCE_GUARDIAN,
          _one(AaveV3Arbitrum.STATA_FACTORY)
        );
    if (chainId == ChainIds.BASE)
      return
        DeployConfig(
          GovernanceV3Base.EXECUTOR_LVL_1,
          GovernanceV3Base.GOVERNANCE_GUARDIAN,
          _one(AaveV3Base.STATA_FACTORY)
        );
    revert('unsupported chain');
  }

  function _one(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function _two(address a, address b) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
  }
}
