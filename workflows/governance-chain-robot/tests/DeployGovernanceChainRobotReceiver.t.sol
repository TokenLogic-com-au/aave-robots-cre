// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {ChainlinkEthereum} from 'aave-address-book/ChainlinkEthereum.sol';

import {DeployGovernanceChainRobotReceiver} from '../scripts/DeployGovernanceChainRobotReceiver.s.sol';

contract DeployGovernanceChainRobotReceiverTest is Test {
  string internal constant OFFCHAIN_CONFIG =
    'workflows/governance-chain-robot/offchain/config.production.json';

  DeployGovernanceChainRobotReceiver internal script;

  function setUp() public {
    script = new DeployGovernanceChainRobotReceiver();
  }

  /// The offchain config must cover exactly the chain the deploy script supports.
  function test_getDeployConfig_matchesOffchainConfig() public view {
    string memory json = vm.readFile(OFFCHAIN_CONFIG);
    assertTrue(vm.keyExistsJson(json, '.evms[0]'), 'offchain config has no chains');
    assertFalse(vm.keyExistsJson(json, '.evms[1]'), 'offchain config has more than one chain');
    assertEq(
      vm.parseJsonString(json, '.evms[0].chainName'),
      'ethereum-mainnet',
      'offchain config chain is not Ethereum'
    );
    script.getDeployConfig(ChainIds.MAINNET);
  }

  function test_getDeployConfig_mainnet() public view {
    DeployGovernanceChainRobotReceiver.DeployConfig memory config = script.getDeployConfig(
      ChainIds.MAINNET
    );
    assertEq(config.governance, address(GovernanceV3Ethereum.GOVERNANCE), 'governance mismatch');
    assertEq(config.gasPriceOracle, ChainlinkEthereum.Fast_Gas__Gwei, 'oracle mismatch');
    assertEq(config.maxGasPrice, script.MAX_GAS_PRICE(), 'max gas price mismatch');
    assertEq(config.owner, GovernanceV3Ethereum.EXECUTOR_LVL_1, 'owner mismatch');
    assertEq(config.guardian, GovernanceV3Ethereum.GOVERNANCE_GUARDIAN, 'guardian mismatch');
  }

  function test_fuzz_getDeployConfig_revertsOnUnsupportedChain(uint256 chainId) public {
    vm.assume(chainId != ChainIds.MAINNET);
    vm.expectRevert(bytes('unsupported chain'));
    script.getDeployConfig(chainId);
  }

  function test_run_revertsWhenGovernanceNotDeployed() public {
    vm.chainId(ChainIds.MAINNET);
    vm.expectRevert(bytes('governance not deployed on this chain'));
    script.run();
  }
}
