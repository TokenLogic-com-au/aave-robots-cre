// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';

import {ExecutionChainRobotReceiver} from '../src/ExecutionChainRobotReceiver.sol';
import {DeployExecutionChainRobotReceiver} from '../scripts/DeployExecutionChainRobotReceiver.s.sol';

contract DeployExecutionChainRobotReceiverTest is Test {
  string internal constant OFFCHAIN_CONFIG =
    'workflows/execution-chain-robot/offchain/config.production.json';

  DeployExecutionChainRobotReceiver internal script;

  function setUp() public {
    script = new DeployExecutionChainRobotReceiver();
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
      assertEq(_chainId(chainName), supported[i], string.concat(chainName, ': unexpected order'));
    }
  }

  /// Every supported chain has a controller; only Ethereum is gas capped.
  function test_getDeployConfig_perChain() public view {
    uint256[] memory supported = _supportedChainIds();
    for (uint256 i = 0; i < supported.length; i++) {
      DeployExecutionChainRobotReceiver.DeployConfig memory config = script.getDeployConfig(
        supported[i]
      );
      string memory chain = vm.toString(supported[i]);
      assertTrue(config.payloadsController != address(0), string.concat(chain, ': no controller'));

      bool capped = supported[i] == ChainIds.MAINNET;
      assertEq(
        config.gasPriceOracle != address(0),
        capped,
        string.concat(chain, ': unexpected gas oracle')
      );
      assertEq(
        config.maxGasPrice,
        capped ? script.ETHEREUM_MAX_GAS_PRICE() : 0,
        string.concat(chain, ': unexpected cap')
      );
    }
  }

  function test_getDeployConfig_revertsOnUnsupportedChain() public {
    vm.expectRevert(bytes('unsupported chain'));
    script.getDeployConfig(ChainIds.MONAD);
  }

  function test_run_deploysWithChainConfig() public {
    vm.chainId(ChainIds.MAINNET);
    DeployExecutionChainRobotReceiver.DeployConfig memory config = script.getDeployConfig(
      ChainIds.MAINNET
    );

    (address owner, address guardian) = GovernanceOwners.get(ChainIds.MAINNET);

    ExecutionChainRobotReceiver receiver = ExecutionChainRobotReceiver(script.run());

    assertEq(address(receiver.PAYLOADS_CONTROLLER()), config.payloadsController, 'controller');
    assertEq(receiver.GAS_PRICE_ORACLE(), config.gasPriceOracle, 'gas price oracle mismatch');
    assertEq(receiver.getMaxGasPrice(), config.maxGasPrice, 'max gas price mismatch');
    assertEq(receiver.owner(), owner, 'owner mismatch');
    assertEq(receiver.guardian(), guardian, 'guardian mismatch');
  }

  /// In `config.production.json` order.
  function _supportedChainIds() internal pure returns (uint256[] memory ids) {
    ids = new uint256[](8);
    ids[0] = ChainIds.MAINNET;
    ids[1] = ChainIds.AVALANCHE;
    ids[2] = ChainIds.POLYGON;
    ids[3] = ChainIds.OPTIMISM;
    ids[4] = ChainIds.ARBITRUM;
    ids[5] = ChainIds.BASE;
    ids[6] = ChainIds.BNB;
    ids[7] = ChainIds.PLASMA;
  }

  function _chainId(string memory chainName) internal pure returns (uint256) {
    bytes32 name = keccak256(bytes(chainName));
    if (name == keccak256('ethereum-mainnet')) return ChainIds.MAINNET;
    if (name == keccak256('avalanche-mainnet')) return ChainIds.AVALANCHE;
    if (name == keccak256('polygon-mainnet')) return ChainIds.POLYGON;
    if (name == keccak256('ethereum-mainnet-optimism-1')) return ChainIds.OPTIMISM;
    if (name == keccak256('ethereum-mainnet-arbitrum-1')) return ChainIds.ARBITRUM;
    if (name == keccak256('ethereum-mainnet-base-1')) return ChainIds.BASE;
    if (name == keccak256('binance_smart_chain-mainnet')) return ChainIds.BNB;
    if (name == keccak256('plasma-mainnet')) return ChainIds.PLASMA;
    revert(string.concat('unknown CRE chain name: ', chainName));
  }
}
