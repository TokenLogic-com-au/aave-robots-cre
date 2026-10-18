// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

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

import {ExecutionChainRobotReceiver} from '../src/ExecutionChainRobotReceiver.sol';

// make deploy-execution-chain-robot env=<Mainnet|Avalanche|Polygon|Optimism|Arbitrum|Base|BNB|Plasma> [dry=1]
contract DeployExecutionChainRobotReceiver is Script {
  struct DeployConfig {
    address payloadsController;
    address gasPriceOracle;
    uint256 maxGasPrice;
    address owner;
    address guardian;
  }

  /// @dev The cap set on BGD's live `GasCappedExecutionChainRobotKeeper`.
  uint256 public constant ETHEREUM_MAX_GAS_PRICE = 150 gwei;

  function run() external returns (address) {
    DeployConfig memory config = getDeployConfig(block.chainid);

    vm.startBroadcast();
    ExecutionChainRobotReceiver receiver = new ExecutionChainRobotReceiver(
      config.payloadsController,
      config.gasPriceOracle,
      config.maxGasPrice,
      config.owner,
      config.guardian
    );
    vm.stopBroadcast();

    console.log('ExecutionChainRobotReceiver deployed at:', address(receiver));
    console.log('PayloadsController:', config.payloadsController);
    console.log('Gas price oracle:', config.gasPriceOracle);
    console.log('Max gas price:', config.maxGasPrice);
    console.log('Owner:', config.owner);
    console.log('Guardian:', config.guardian);
    return address(receiver);
  }

  /// @dev Owner / guardian are the chain's governance executor and guardian. Only Ethereum
  /// is gas capped, on Chainlink's Fast Gas feed, like BGD's keepers.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory) {
    if (chainId == ChainIds.MAINNET)
      return
        DeployConfig(
          address(GovernanceV3Ethereum.PAYLOADS_CONTROLLER),
          ChainlinkEthereum.Fast_Gas__Gwei,
          ETHEREUM_MAX_GAS_PRICE,
          GovernanceV3Ethereum.EXECUTOR_LVL_1,
          GovernanceV3Ethereum.GOVERNANCE_GUARDIAN
        );

    if (chainId == ChainIds.AVALANCHE)
      return
        _uncapped(
          address(GovernanceV3Avalanche.PAYLOADS_CONTROLLER),
          GovernanceV3Avalanche.EXECUTOR_LVL_1,
          GovernanceV3Avalanche.GOVERNANCE_GUARDIAN
        );

    if (chainId == ChainIds.POLYGON)
      return
        _uncapped(
          address(GovernanceV3Polygon.PAYLOADS_CONTROLLER),
          GovernanceV3Polygon.EXECUTOR_LVL_1,
          GovernanceV3Polygon.GOVERNANCE_GUARDIAN
        );

    if (chainId == ChainIds.OPTIMISM)
      return
        _uncapped(
          address(GovernanceV3Optimism.PAYLOADS_CONTROLLER),
          GovernanceV3Optimism.EXECUTOR_LVL_1,
          GovernanceV3Optimism.GOVERNANCE_GUARDIAN
        );

    if (chainId == ChainIds.ARBITRUM)
      return
        _uncapped(
          address(GovernanceV3Arbitrum.PAYLOADS_CONTROLLER),
          GovernanceV3Arbitrum.EXECUTOR_LVL_1,
          GovernanceV3Arbitrum.GOVERNANCE_GUARDIAN
        );

    if (chainId == ChainIds.BASE)
      return
        _uncapped(
          address(GovernanceV3Base.PAYLOADS_CONTROLLER),
          GovernanceV3Base.EXECUTOR_LVL_1,
          GovernanceV3Base.GOVERNANCE_GUARDIAN
        );

    if (chainId == ChainIds.BNB)
      return
        _uncapped(
          address(GovernanceV3BNB.PAYLOADS_CONTROLLER),
          GovernanceV3BNB.EXECUTOR_LVL_1,
          GovernanceV3BNB.GOVERNANCE_GUARDIAN
        );

    if (chainId == ChainIds.PLASMA)
      return
        _uncapped(
          address(GovernanceV3Plasma.PAYLOADS_CONTROLLER),
          GovernanceV3Plasma.EXECUTOR_LVL_1,
          GovernanceV3Plasma.GOVERNANCE_GUARDIAN
        );

    revert('unsupported chain');
  }

  function _uncapped(
    address payloadsController,
    address owner,
    address guardian
  ) internal pure returns (DeployConfig memory) {
    return DeployConfig(payloadsController, address(0), 0, owner, guardian);
  }
}
