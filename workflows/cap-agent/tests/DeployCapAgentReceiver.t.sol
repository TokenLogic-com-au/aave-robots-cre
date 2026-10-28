// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';

import {DeployCapAgentReceiver} from '../scripts/DeployCapAgentReceiver.s.sol';

contract DeployCapAgentReceiverTest is Test {
  string internal constant OFFCHAIN_CONFIG = 'workflows/cap-agent/offchain/config.production.json';

  DeployCapAgentReceiver internal script;

  function setUp() public {
    script = new DeployCapAgentReceiver();
  }

  /// The offchain config and the deploy script must cover the same chains.
  function test_getDeployConfig_matchesOffchainConfig() public view {
    string memory json = vm.readFile(OFFCHAIN_CONFIG);
    uint256 chains = 0;
    while (vm.keyExistsJson(json, string.concat('.evms[', vm.toString(chains), ']'))) chains++;

    uint256[] memory supported = _supportedChainIds();
    assertEq(chains, supported.length, 'offchain config and deploy script cover different chains');

    for (uint256 i = 0; i < chains; i++) {
      string memory chainName = vm.parseJsonString(
        json,
        string.concat('.evms[', vm.toString(i), '].chainName')
      );
      assertEq(_chainId(chainName), supported[i], string.concat(chainName, ': out of order'));
    }
  }

  function test_getDeployConfig_coversEverySupportedChain() public view {
    uint256[] memory supported = _supportedChainIds();
    for (uint256 i = 0; i < supported.length; i++) {
      DeployCapAgentReceiver.DeployConfig memory config = script.getDeployConfig(supported[i]);
      string memory chain = vm.toString(supported[i]);

      assertTrue(config.agentHub != address(0), string.concat(chain, ': agent hub is zero'));
      assertGt(config.agentIds.length, 0, string.concat(chain, ': no agents'));
      for (uint256 j = 0; j < config.agentIds.length; j++) {
        assertEq(config.agentIds[j], j, string.concat(chain, ': agent ids not sequential'));
      }
    }
  }

  function test_getDeployConfig_revertsOnUnsupportedChain() public {
    vm.expectRevert(bytes('unsupported chain'));
    script.getDeployConfig(ChainIds.MAINNET);
  }

  function test_run_revertsWhenAgentHubHasNoCode() public {
    vm.chainId(ChainIds.AVALANCHE);
    vm.expectRevert(bytes('agent hub not deployed on this chain'));
    script.run();
  }

  function _supportedChainIds() internal pure returns (uint256[] memory ids) {
    ids = new uint256[](6);
    ids[0] = ChainIds.AVALANCHE;
    ids[1] = ChainIds.POLYGON;
    ids[2] = ChainIds.OPTIMISM;
    ids[3] = ChainIds.ARBITRUM;
    ids[4] = ChainIds.BASE;
    ids[5] = ChainIds.BNB;
  }

  function _chainId(string memory chainName) internal pure returns (uint256) {
    bytes32 name = keccak256(bytes(chainName));
    if (name == keccak256('avalanche-mainnet')) return ChainIds.AVALANCHE;
    if (name == keccak256('polygon-mainnet')) return ChainIds.POLYGON;
    if (name == keccak256('ethereum-mainnet-optimism-1')) return ChainIds.OPTIMISM;
    if (name == keccak256('ethereum-mainnet-arbitrum-1')) return ChainIds.ARBITRUM;
    if (name == keccak256('ethereum-mainnet-base-1')) return ChainIds.BASE;
    if (name == keccak256('binance_smart_chain-mainnet')) return ChainIds.BNB;
    revert(string.concat('unknown CRE chain name: ', chainName));
  }
}
