// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from 'forge-std/Script.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';

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

    console.log('VotingChainRobotReceiver deployed at:', address(receiver));
    console.log('Voting machine:', config.votingMachine);
    console.log('Gas price oracle:', config.gasPriceOracle);
    console.log('Max gas price:', config.maxGasPrice);
    console.log('Owner:', config.owner);
    console.log('Guardian:', config.guardian);
    return address(receiver);
  }

  /// @dev The chain's voting machine, and its governance executor / guardian as owner / guardian. Only Ethereum caps the gas price, as BGD's keepers do.
  function getDeployConfig(uint256 chainId) public pure returns (DeployConfig memory) {
    if (chainId == ChainIds.MAINNET)
      return
        DeployConfig({
          votingMachine: GovernanceV3Ethereum.VOTING_MACHINE,
          gasPriceOracle: FAST_GAS_ORACLE_ETHEREUM,
          maxGasPrice: MAX_GAS_PRICE_ETHEREUM,
          owner: GovernanceV3Ethereum.EXECUTOR_LVL_1,
          guardian: GovernanceV3Ethereum.GOVERNANCE_GUARDIAN
        });

    if (chainId == ChainIds.AVALANCHE)
      return
        DeployConfig({
          votingMachine: GovernanceV3Avalanche.VOTING_MACHINE,
          gasPriceOracle: address(0),
          maxGasPrice: 0,
          owner: GovernanceV3Avalanche.EXECUTOR_LVL_1,
          guardian: GovernanceV3Avalanche.GOVERNANCE_GUARDIAN
        });

    if (chainId == ChainIds.POLYGON)
      return
        DeployConfig({
          votingMachine: GovernanceV3Polygon.VOTING_MACHINE,
          gasPriceOracle: address(0),
          maxGasPrice: 0,
          owner: GovernanceV3Polygon.EXECUTOR_LVL_1,
          guardian: GovernanceV3Polygon.GOVERNANCE_GUARDIAN
        });

    revert('unsupported chain');
  }
}
