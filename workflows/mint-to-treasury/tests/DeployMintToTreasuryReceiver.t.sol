// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';

import {MintToTreasuryReceiver} from '../src/MintToTreasuryReceiver.sol';
import {DeployMintToTreasuryReceiver} from '../scripts/DeployMintToTreasuryReceiver.s.sol';

contract DeployMintToTreasuryReceiverTest is Test {
  uint256 internal constant CONFIG_COUNT = 3;

  DeployMintToTreasuryReceiver internal script;

  function setUp() public {
    script = new DeployMintToTreasuryReceiver();
  }

  /// The offchain configs and the deploy script must cover the same chains.
  function test_getPools_matchesOffchainConfigs() public view {
    uint256[] memory supported = _supportedChainIds();
    uint256[] memory configChainIds = new uint256[](supported.length);
    uint256 chains = 0;

    for (uint256 c = 1; c <= CONFIG_COUNT; c++) {
      string memory json = vm.readFile(
        string.concat(
          'workflows/mint-to-treasury/offchain/config.production-',
          vm.toString(c),
          '.json'
        )
      );

      for (uint256 i = 0; vm.keyExistsJson(json, _evm(i)); i++) {
        string memory chainName = vm.parseJsonString(json, string.concat(_evm(i), '.chainName'));
        uint256 chainId = _chainId(chainName);

        address[] memory pools = script.getPools(chainId);
        assertGt(pools.length, 0, string.concat(chainName, ': no pools'));
        for (uint256 p = 0; p < pools.length; p++) {
          assertNotEq(pools[p], address(0), string.concat(chainName, ': pool is zero'));
        }

        assertLt(chains, supported.length, 'offchain configs list more chains than the script');
        configChainIds[chains++] = chainId;
      }
    }

    assertEq(chains, supported.length, 'offchain configs and deploy script cover different chains');
    for (uint256 i = 0; i < supported.length; i++) {
      uint256 found = 0;
      for (uint256 j = 0; j < chains; j++) if (configChainIds[j] == supported[i]) found++;
      assertEq(found, 1, string.concat(vm.toString(supported[i]), ': not in exactly one config'));
    }
  }

  function test_fuzz_getPools_revertsOnUnsupportedChain(uint256 chainId) public {
    uint256[] memory supported = _supportedChainIds();
    for (uint256 i = 0; i < supported.length; i++) vm.assume(chainId != supported[i]);

    vm.expectRevert(bytes('unsupported chain'));
    script.getPools(chainId);
  }

  function test_getPools_revertsOnCreUnsupportedChains() public {
    vm.expectRevert(bytes('unsupported chain'));
    script.getPools(ChainIds.METIS);

    vm.expectRevert(bytes('unsupported chain'));
    script.getPools(ChainIds.SONEIUM);
  }

  function test_run_deploysWithChainConfig() public {
    vm.chainId(ChainIds.MAINNET);
    address[] memory pools = script.getPools(ChainIds.MAINNET);

    MintToTreasuryReceiver robot = MintToTreasuryReceiver(script.run());

    assertEq(robot.owner(), GovernanceV3Ethereum.EXECUTOR_LVL_1, 'owner mismatch');
    assertEq(robot.guardian(), GovernanceV3Ethereum.GOVERNANCE_GUARDIAN, 'guardian mismatch');
    assertEq(pools.length, 4, 'expected Core, Prime, EtherFi and Horizon');
    assertEq(pools[0], address(AaveV3Ethereum.POOL), 'Core pool should come first');
    for (uint256 i = 0; i < pools.length; i++) {
      assertEq(
        robot.getUsdThreshold(pools[i]),
        script.INITIAL_USD_THRESHOLD(),
        'pool not enabled at the initial threshold'
      );
    }
  }

  function _evm(uint256 i) internal pure returns (string memory) {
    return string.concat('.evms[', vm.toString(i), ']');
  }

  function _supportedChainIds() internal pure returns (uint256[] memory ids) {
    ids = new uint256[](19);
    ids[0] = ChainIds.MAINNET;
    ids[1] = ChainIds.ARBITRUM;
    ids[2] = ChainIds.AVALANCHE;
    ids[3] = ChainIds.BNB;
    ids[4] = ChainIds.BASE;
    ids[5] = ChainIds.CELO;
    ids[6] = ChainIds.GNOSIS;
    ids[7] = ChainIds.INK;
    ids[8] = ChainIds.LINEA;
    ids[9] = ChainIds.MANTLE;
    ids[10] = ChainIds.MEGAETH;
    ids[11] = ChainIds.MONAD;
    ids[12] = ChainIds.OPTIMISM;
    ids[13] = ChainIds.PLASMA;
    ids[14] = ChainIds.POLYGON;
    ids[15] = ChainIds.SCROLL;
    ids[16] = ChainIds.SONIC;
    ids[17] = ChainIds.XLAYER;
    ids[18] = ChainIds.ZKSYNC;
  }

  function _chainId(string memory chainName) internal pure returns (uint256) {
    bytes32 name = keccak256(bytes(chainName));
    if (name == keccak256('ethereum-mainnet')) return ChainIds.MAINNET;
    if (name == keccak256('ethereum-mainnet-arbitrum-1')) return ChainIds.ARBITRUM;
    if (name == keccak256('avalanche-mainnet')) return ChainIds.AVALANCHE;
    if (name == keccak256('binance_smart_chain-mainnet')) return ChainIds.BNB;
    if (name == keccak256('ethereum-mainnet-base-1')) return ChainIds.BASE;
    if (name == keccak256('celo-mainnet')) return ChainIds.CELO;
    if (name == keccak256('gnosis_chain-mainnet')) return ChainIds.GNOSIS;
    if (name == keccak256('ethereum-mainnet-ink-1')) return ChainIds.INK;
    if (name == keccak256('ethereum-mainnet-linea-1')) return ChainIds.LINEA;
    if (name == keccak256('ethereum-mainnet-mantle-1')) return ChainIds.MANTLE;
    if (name == keccak256('megaeth-mainnet')) return ChainIds.MEGAETH;
    if (name == keccak256('monad-mainnet')) return ChainIds.MONAD;
    if (name == keccak256('ethereum-mainnet-optimism-1')) return ChainIds.OPTIMISM;
    if (name == keccak256('plasma-mainnet')) return ChainIds.PLASMA;
    if (name == keccak256('polygon-mainnet')) return ChainIds.POLYGON;
    if (name == keccak256('ethereum-mainnet-scroll-1')) return ChainIds.SCROLL;
    if (name == keccak256('sonic-mainnet')) return ChainIds.SONIC;
    if (name == keccak256('ethereum-mainnet-xlayer-1')) return ChainIds.XLAYER;
    if (name == keccak256('ethereum-mainnet-zksync-1')) return ChainIds.ZKSYNC;
    revert(string.concat('unknown CRE chain name: ', chainName));
  }
}
