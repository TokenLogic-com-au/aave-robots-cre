// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {ChainlinkEthereum} from 'aave-address-book/ChainlinkEthereum.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';
import {GovernanceV3Optimism} from 'aave-address-book/GovernanceV3Optimism.sol';
import {GovernanceV3Arbitrum} from 'aave-address-book/GovernanceV3Arbitrum.sol';
import {GovernanceV3Base} from 'aave-address-book/GovernanceV3Base.sol';
import {GovernanceV3BNB} from 'aave-address-book/GovernanceV3BNB.sol';
import {GovernanceV3Plasma} from 'aave-address-book/GovernanceV3Plasma.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';

import {ExecutionChainRobotReceiver} from '../src/ExecutionChainRobotReceiver.sol';

// make deploy-execution-chain-robot env=<Mainnet|Avalanche|Polygon|Optimism|Arbitrum|Base|BNB|Plasma> [dry=1]
contract DeployExecutionChainRobotReceiver is Script {
  struct DeployConfig {
    address payloadsController;
    address gasPriceOracle;
    uint256 maxGasPrice;
  }

  /// @dev The cap set on BGD's live `GasCappedExecutionChainRobotKeeper`.
  uint256 public constant ETHEREUM_MAX_GAS_PRICE = 150 gwei;

  function run() external returns (address) {
    DeployConfig memory config = getDeployConfig(block.chainid);
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);

    vm.startBroadcast();
    ExecutionChainRobotReceiver receiver = new ExecutionChainRobotReceiver(
      config.payloadsController,
      config.gasPriceOracle,
      config.maxGasPrice,
      owner,
      guardian
    );
    vm.stopBroadcast();

    return address(receiver);
  }

  /// @dev Only Ethereum is gas capped, on Chainlink's Fast Gas feed.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory) {
    if (chainId == ChainIds.MAINNET) {
      return
        DeployConfig({
          payloadsController: address(GovernanceV3Ethereum.PAYLOADS_CONTROLLER),
          gasPriceOracle: ChainlinkEthereum.Fast_Gas__Gwei,
          maxGasPrice: ETHEREUM_MAX_GAS_PRICE
        });
    }
    if (chainId == ChainIds.AVALANCHE) {
      return _uncapped(address(GovernanceV3Avalanche.PAYLOADS_CONTROLLER));
    }
    if (chainId == ChainIds.POLYGON) {
      return _uncapped(address(GovernanceV3Polygon.PAYLOADS_CONTROLLER));
    }
    if (chainId == ChainIds.OPTIMISM) {
      return _uncapped(address(GovernanceV3Optimism.PAYLOADS_CONTROLLER));
    }
    if (chainId == ChainIds.ARBITRUM) {
      return _uncapped(address(GovernanceV3Arbitrum.PAYLOADS_CONTROLLER));
    }
    if (chainId == ChainIds.BASE) {
      return _uncapped(address(GovernanceV3Base.PAYLOADS_CONTROLLER));
    }
    if (chainId == ChainIds.BNB) {
      return _uncapped(address(GovernanceV3BNB.PAYLOADS_CONTROLLER));
    }
    if (chainId == ChainIds.PLASMA) {
      return _uncapped(address(GovernanceV3Plasma.PAYLOADS_CONTROLLER));
    }
    revert('unsupported chain');
  }

  function _uncapped(address payloadsController) internal pure returns (DeployConfig memory) {
    return
      DeployConfig({
        payloadsController: payloadsController,
        // No gas price oracle, so `checkUpkeep` ignores the gas price.
        gasPriceOracle: address(0),
        // No cap: the constructor requires 0 without an oracle.
        maxGasPrice: 0
      });
  }
}
