// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {ChainlinkEthereum} from 'aave-address-book/ChainlinkEthereum.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';
import {GovernanceChainRobotReceiver} from '../src/GovernanceChainRobotReceiver.sol';

// make deploy-governance-chain-robot env=Mainnet [dry=1]
contract DeployGovernanceChainRobotReceiver is Script {
  struct DeployConfig {
    address governance;
    address gasPriceOracle;
    uint256 maxGasPrice;
    address owner;
    address guardian;
  }

  /// @dev The max gas price set on BGD's keeper.
  uint256 public constant MAX_GAS_PRICE = 150 gwei;

  function run() external returns (address) {
    DeployConfig memory config = getDeployConfig(block.chainid);
    require(config.governance.code.length > 0, 'governance not deployed on this chain');
    require(config.gasPriceOracle.code.length > 0, 'gas price oracle not deployed on this chain');

    vm.startBroadcast();
    GovernanceChainRobotReceiver receiver = new GovernanceChainRobotReceiver(
      config.governance,
      config.gasPriceOracle,
      config.maxGasPrice,
      config.owner,
      config.guardian
    );
    vm.stopBroadcast();

    return address(receiver);
  }

  /// @dev Governance V3 only lives on Ethereum.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory config) {
    require(chainId == ChainIds.MAINNET, 'unsupported chain');

    config.governance = address(GovernanceV3Ethereum.GOVERNANCE);
    config.gasPriceOracle = ChainlinkEthereum.Fast_Gas__Gwei;
    config.maxGasPrice = MAX_GAS_PRICE;
    (config.owner, config.guardian) = GovernanceOwners.get(chainId);
  }
}
