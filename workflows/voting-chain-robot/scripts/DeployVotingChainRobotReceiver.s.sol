// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';
import {VotingChainRobotReceiver} from '../src/VotingChainRobotReceiver.sol';

// make deploy-voting-chain-robot env=<Mainnet|Avalanche|Polygon> [dry=1]
contract DeployVotingChainRobotReceiver is Script {
  struct DeployConfig {
    address votingMachine;
    address gasPriceOracle;
    uint256 maxGasPrice;
    address owner;
    address guardian;
  }

  // Chainlink "Fast Gas / Gwei" feed, the one the live `GasCappedVotingChainRobotKeeper` uses.
  address internal constant FAST_GAS_ORACLE_ETHEREUM = 0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C;

  // Max gas price the live `GasCappedVotingChainRobotKeeper` is configured with.
  uint256 internal constant MAX_GAS_PRICE_ETHEREUM = 150 gwei;

  function run() external returns (address) {
    DeployConfig memory config = getDeployConfig(block.chainid);

    vm.startBroadcast();
    VotingChainRobotReceiver receiver = new VotingChainRobotReceiver(
      config.votingMachine,
      config.gasPriceOracle,
      config.maxGasPrice,
      config.owner,
      config.guardian
    );
    vm.stopBroadcast();

    return address(receiver);
  }

  /// @dev Only Ethereum caps the gas price, as BGD's keepers do.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory config) {
    if (chainId == ChainIds.MAINNET) {
      config.votingMachine = GovernanceV3Ethereum.VOTING_MACHINE;
      config.gasPriceOracle = FAST_GAS_ORACLE_ETHEREUM;
      config.maxGasPrice = MAX_GAS_PRICE_ETHEREUM;
    } else if (chainId == ChainIds.AVALANCHE) {
      config.votingMachine = GovernanceV3Avalanche.VOTING_MACHINE;
      config.gasPriceOracle = address(0); // no gas price oracle: uncapped
      config.maxGasPrice = 0; // must be 0 without an oracle
    } else if (chainId == ChainIds.POLYGON) {
      config.votingMachine = GovernanceV3Polygon.VOTING_MACHINE;
      config.gasPriceOracle = address(0); // no gas price oracle: uncapped
      config.maxGasPrice = 0; // must be 0 without an oracle
    } else {
      revert('unsupported chain');
    }
    (config.owner, config.guardian) = GovernanceOwners.get(chainId);
  }
}
