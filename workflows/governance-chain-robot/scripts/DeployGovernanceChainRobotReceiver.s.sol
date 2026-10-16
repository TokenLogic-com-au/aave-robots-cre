// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {ChainlinkEthereum} from 'aave-address-book/ChainlinkEthereum.sol';

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

  /// @dev Max gas price set on BGD's `GasCappedGovernanceChainRobotKeeper` (0x1996…9C11).
  uint256 internal constant MAX_GAS_PRICE = 150 gwei;

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

    console.log('GovernanceChainRobotReceiver deployed at:', address(receiver));
    console.log('Governance:', config.governance);
    console.log('Gas price oracle:', config.gasPriceOracle);
    console.log('Max gas price:', config.maxGasPrice);
    console.log('Owner:', config.owner);
    console.log('Guardian:', config.guardian);
    return address(receiver);
  }

  /// @dev Governance V3 only lives on Ethereum.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory) {
    require(chainId == ChainIds.MAINNET, 'unsupported chain');
    return
      DeployConfig({
        governance: address(GovernanceV3Ethereum.GOVERNANCE),
        gasPriceOracle: ChainlinkEthereum.Fast_Gas__Gwei,
        maxGasPrice: MAX_GAS_PRICE,
        owner: GovernanceV3Ethereum.EXECUTOR_LVL_1,
        guardian: GovernanceV3Ethereum.GOVERNANCE_GUARDIAN
      });
  }
}
