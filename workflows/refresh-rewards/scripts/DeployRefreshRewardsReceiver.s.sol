// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3EthereumLido} from 'aave-address-book/AaveV3EthereumLido.sol';
import {AaveV3Avalanche} from 'aave-address-book/AaveV3Avalanche.sol';
import {AaveV3Optimism} from 'aave-address-book/AaveV3Optimism.sol';
import {AaveV3Arbitrum} from 'aave-address-book/AaveV3Arbitrum.sol';
import {AaveV3Base} from 'aave-address-book/AaveV3Base.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';
import {RefreshRewardsReceiver} from '../src/RefreshRewardsReceiver.sol';

// make deploy-refresh-rewards env=<Mainnet|Avalanche|Optimism|Arbitrum|Base> [dry=1]
contract DeployRefreshRewardsReceiver is Script {
  function run() external returns (address) {
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);
    address[] memory factories = getFactories(block.chainid);

    vm.startBroadcast();
    RefreshRewardsReceiver receiver = new RefreshRewardsReceiver(owner, guardian, factories);
    vm.stopBroadcast();
    return address(receiver);
  }

  /// @dev The chain's Aave v3 stataToken factories. Only chains whose stataTokens have had
  /// rewards configured are supported.
  function getFactories(uint256 chainId) public pure returns (address[] memory) {
    if (chainId == ChainIds.MAINNET)
      return _two(AaveV3Ethereum.STATA_FACTORY, AaveV3EthereumLido.STATA_FACTORY);
    if (chainId == ChainIds.AVALANCHE) return _one(AaveV3Avalanche.STATA_FACTORY);
    if (chainId == ChainIds.OPTIMISM) return _one(AaveV3Optimism.STATA_FACTORY);
    if (chainId == ChainIds.ARBITRUM) return _one(AaveV3Arbitrum.STATA_FACTORY);
    if (chainId == ChainIds.BASE) return _one(AaveV3Base.STATA_FACTORY);
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
