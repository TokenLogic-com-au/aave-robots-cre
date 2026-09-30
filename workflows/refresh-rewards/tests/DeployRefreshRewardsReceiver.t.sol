// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';

import {RefreshRewardsReceiver} from '../src/RefreshRewardsReceiver.sol';
import {DeployRefreshRewardsReceiver} from '../scripts/DeployRefreshRewardsReceiver.s.sol';

contract DeployRefreshRewardsReceiverTest is Test {
  string internal constant OFFCHAIN_CONFIG =
    'workflows/refresh-rewards/offchain/config.production.json';

  DeployRefreshRewardsReceiver internal script;

  function setUp() public {
    script = new DeployRefreshRewardsReceiver();
  }

  /// The offchain config and the deploy script must cover the same chains, with the same factories.
  function test_getDeployConfig_matchesOffchainConfig() public view {
    string memory json = vm.readFile(OFFCHAIN_CONFIG);
    uint256 chains = 0;
    while (vm.keyExistsJson(json, string.concat('.evms[', vm.toString(chains), ']'))) chains++;
    assertGt(chains, 0, 'offchain config has no chains');

    uint256[] memory configChainIds = new uint256[](chains);
    for (uint256 i = 0; i < chains; i++) {
      string memory path = string.concat('.evms[', vm.toString(i), ']');
      string memory chainName = vm.parseJsonString(json, string.concat(path, '.chainName'));
      configChainIds[i] = _chainId(chainName);
      address[] memory factories = vm.parseJsonAddressArray(
        json,
        string.concat(path, '.factories')
      );

      DeployRefreshRewardsReceiver.DeployConfig memory config = script.getDeployConfig(
        _chainId(chainName)
      );
      assertTrue(config.owner != address(0), string.concat(chainName, ': owner is zero'));
      assertTrue(config.guardian != address(0), string.concat(chainName, ': guardian is zero'));
      assertEq(config.factories, factories, string.concat(chainName, ': factories mismatch'));
    }

    uint256[] memory supported = _supportedChainIds();
    assertEq(chains, supported.length, 'offchain config and deploy script cover different chains');
    for (uint256 i = 0; i < supported.length; i++) {
      bool found = false;
      for (uint256 j = 0; j < chains; j++) found = found || configChainIds[j] == supported[i];
      assertTrue(found, string.concat(vm.toString(supported[i]), ': missing from offchain config'));
    }
  }

  function test_getDeployConfig_revertsOnUnsupportedChain() public {
    vm.expectRevert(bytes('unsupported chain'));
    script.getDeployConfig(ChainIds.POLYGON);
  }

  function test_run_deploysWithChainConfig() public {
    vm.chainId(ChainIds.MAINNET);
    DeployRefreshRewardsReceiver.DeployConfig memory config = script.getDeployConfig(
      ChainIds.MAINNET
    );

    RefreshRewardsReceiver receiver = RefreshRewardsReceiver(script.run());

    assertEq(receiver.owner(), config.owner, 'owner mismatch');
    assertEq(receiver.guardian(), config.guardian, 'guardian mismatch');
    assertEq(config.factories.length, 2, 'expected Core and Lido factories');
    for (uint256 i = 0; i < config.factories.length; i++) {
      assertTrue(receiver.isFactoryEnabled(config.factories[i]), 'factory not enabled');
    }
  }

  function _supportedChainIds() internal pure returns (uint256[] memory ids) {
    ids = new uint256[](5);
    ids[0] = ChainIds.MAINNET;
    ids[1] = ChainIds.AVALANCHE;
    ids[2] = ChainIds.OPTIMISM;
    ids[3] = ChainIds.ARBITRUM;
    ids[4] = ChainIds.BASE;
  }

  function _chainId(string memory chainName) internal pure returns (uint256) {
    bytes32 name = keccak256(bytes(chainName));
    if (name == keccak256('ethereum-mainnet')) return ChainIds.MAINNET;
    if (name == keccak256('avalanche-mainnet')) return ChainIds.AVALANCHE;
    if (name == keccak256('ethereum-mainnet-optimism-1')) return ChainIds.OPTIMISM;
    if (name == keccak256('ethereum-mainnet-arbitrum-1')) return ChainIds.ARBITRUM;
    if (name == keccak256('ethereum-mainnet-base-1')) return ChainIds.BASE;
    revert(string.concat('unknown CRE chain name: ', chainName));
  }
}
