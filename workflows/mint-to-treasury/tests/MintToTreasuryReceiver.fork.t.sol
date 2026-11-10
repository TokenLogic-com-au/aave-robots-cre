// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {IPool} from 'aave-v3-origin/contracts/interfaces/IPool.sol';
import {IAToken} from 'aave-v3-origin/contracts/interfaces/IAToken.sol';
import {DataTypes} from 'aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from 'aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {WadRayMath} from 'aave-v3-origin/contracts/protocol/libraries/math/WadRayMath.sol';
import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3EthereumLido} from 'aave-address-book/AaveV3EthereumLido.sol';
import {AaveV3EthereumEtherFi} from 'aave-address-book/AaveV3EthereumEtherFi.sol';
import {AaveV3EthereumHorizon} from 'aave-address-book/AaveV3EthereumHorizon.sol';
import {AaveV3Arbitrum} from 'aave-address-book/AaveV3Arbitrum.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';

import {MintToTreasuryReceiver} from '../src/MintToTreasuryReceiver.sol';
import {IMintToTreasuryReceiver} from '../src/IMintToTreasuryReceiver.sol';
import {DeployMintToTreasuryReceiver} from '../scripts/DeployMintToTreasuryReceiver.s.sol';

abstract contract MintToTreasuryForkBase is Test {
  using WadRayMath for uint256;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  /// @dev The lowest CRE write gas quota (`MAX_WRITE_GAS` in the shared offchain `constants.ts`).
  uint256 internal constant MAX_WRITE_GAS = 10_000_000;

  address internal owner = makeAddr('fork-owner');
  address internal guardian = makeAddr('fork-guardian');
  address internal anyone = makeAddr('fork-anyone');

  struct Expected {
    address pool;
    address asset;
    address aToken;
    address collector;
    uint256 amount;
    uint256 collectorBalance;
  }

  function _deploy(address[] memory pools) internal returns (MintToTreasuryReceiver) {
    IMintToTreasuryReceiver.PoolThreshold[]
      memory thresholds = new IMintToTreasuryReceiver.PoolThreshold[](pools.length);
    for (uint256 i = 0; i < pools.length; i++) {
      thresholds[i] = IMintToTreasuryReceiver.PoolThreshold(pools[i], 1);
    }
    return new MintToTreasuryReceiver(owner, guardian, thresholds);
  }

  /// Sends every pool through checkUpkeep + onReport, expecting exactly `mintable` to be minted,
  /// and checks, per reserve with an amount accrued, the MintedToTreasury event, the zeroed
  /// accruedToTreasury and the collector's aToken balance.
  function _mintAndCheck(
    address[] memory pools,
    address[] memory collectors,
    address[] memory mintable
  ) internal {
    MintToTreasuryReceiver robot = _deploy(pools);

    for (uint256 i = 0; i < mintable.length; i++) {
      assertGt(robot.getAccruedUsd(mintable[i]), 0, 'pool has nothing accrued to the treasury');
      assertTrue(robot.canMint(mintable[i]), 'pool should be mintable');
    }

    Expected[] memory expected = _snapshot(pools, collectors);
    assertGt(expected.length, 0, 'no reserve with an amount accrued');

    (bool upkeepNeeded, bytes memory performData) = robot.checkUpkeep(abi.encode(pools));
    assertTrue(upkeepNeeded, 'upkeep should be needed');
    assertEq(performData, abi.encode(mintable), 'unexpected mintable pools');

    vm.recordLogs();
    vm.prank(anyone);
    uint256 gasBefore = gasleft();
    robot.onReport('', abi.encode(pools));
    uint256 gasUsed = gasBefore - gasleft();
    Vm.Log[] memory logs = vm.getRecordedLogs();

    assertLt(gasUsed, MAX_WRITE_GAS, 'onReport does not fit a CRE write');
    _checkMinted(expected, logs);

    for (uint256 i = 0; i < pools.length; i++) {
      assertFalse(robot.canMint(pools[i]), 'pool still mintable after onReport');
    }
  }

  function _snapshot(
    address[] memory pools,
    address[] memory collectors
  ) internal view returns (Expected[] memory expected) {
    uint256 total = 0;
    for (uint256 i = 0; i < pools.length; i++) total += IPool(pools[i]).getReservesList().length;
    expected = new Expected[](total);
    uint256 count = 0;

    for (uint256 i = 0; i < pools.length; i++) {
      IPool pool = IPool(pools[i]);
      address[] memory reserves = pool.getReservesList();

      for (uint256 j = 0; j < reserves.length; j++) {
        DataTypes.ReserveDataLegacy memory data = pool.getReserveData(reserves[j]);
        if (data.accruedToTreasury == 0 || !data.configuration.getActive()) continue;

        assertEq(
          IAToken(data.aTokenAddress).RESERVE_TREASURY_ADDRESS(),
          collectors[i],
          'aToken treasury is not the collector'
        );
        expected[count++] = Expected({
          pool: pools[i],
          asset: reserves[j],
          aToken: data.aTokenAddress,
          collector: collectors[i],
          amount: uint256(data.accruedToTreasury).rayMul(
            pool.getReserveNormalizedIncome(reserves[j])
          ),
          collectorBalance: IERC20(data.aTokenAddress).balanceOf(collectors[i])
        });
      }
    }

    assembly {
      mstore(expected, count)
    }
  }

  function _checkMinted(Expected[] memory expected, Vm.Log[] memory logs) internal view {
    for (uint256 i = 0; i < expected.length; i++) {
      Expected memory e = expected[i];
      uint256 minted = _findMinted(logs, e.pool, e.asset);

      assertApproxEqAbs(minted, e.amount, 1, 'MintedToTreasury amount mismatch');
      assertEq(
        IPool(e.pool).getReserveData(e.asset).accruedToTreasury,
        0,
        'accruedToTreasury not reset'
      );
      assertApproxEqAbs(
        IERC20(e.aToken).balanceOf(e.collector) - e.collectorBalance,
        minted,
        2,
        'collector aToken balance did not grow by the minted amount'
      );
    }
  }

  function _findMinted(
    Vm.Log[] memory logs,
    address pool,
    address asset
  ) internal pure returns (uint256) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (
        logs[i].emitter == pool &&
        logs[i].topics[0] == IPool.MintedToTreasury.selector &&
        logs[i].topics[1] == bytes32(uint256(uint160(asset)))
      ) return abi.decode(logs[i].data, (uint256));
    }
    revert('MintedToTreasury not emitted');
  }

  function _one(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }
}

contract MintToTreasuryArbitrumFork is MintToTreasuryForkBase {
  address internal constant POOL = address(AaveV3Arbitrum.POOL);

  function setUp() public {
    vm.createSelectFork('arbitrum', 517352210);
  }

  function test_fork_onReport_mintsToCollector() public {
    _mintAndCheck(_one(POOL), _one(address(AaveV3Arbitrum.COLLECTOR)), _one(POOL));
  }

  function test_fork_canMint_followsThreshold() public {
    MintToTreasuryReceiver robot = _deploy(_one(POOL));
    uint256 accruedUsd = robot.getAccruedUsd(POOL);
    assertGt(accruedUsd, 0, 'pool has nothing accrued to the treasury');

    vm.prank(owner);
    robot.updateUsdThreshold(POOL, accruedUsd + 1);
    assertFalse(robot.canMint(POOL), 'mintable below threshold');

    vm.prank(anyone);
    vm.expectRevert(IMintToTreasuryReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(_one(POOL)));

    vm.prank(owner);
    robot.updateUsdThreshold(POOL, accruedUsd);
    assertTrue(robot.canMint(POOL), 'not mintable at threshold');
  }

  function test_fork_deployScript_enablesPoolAtInitialThreshold() public {
    DeployMintToTreasuryReceiver script = new DeployMintToTreasuryReceiver();
    MintToTreasuryReceiver robot = MintToTreasuryReceiver(script.run());

    (address expectedOwner, ) = GovernanceOwners.get(block.chainid);
    assertEq(robot.owner(), expectedOwner, 'owner mismatch');
    assertEq(
      robot.getUsdThreshold(POOL),
      script.INITIAL_USD_THRESHOLD(),
      'pool not enabled at the initial threshold'
    );
  }
}

contract MintToTreasuryEthereumFork is MintToTreasuryForkBase {
  function setUp() public {
    vm.createSelectFork('mainnet', 26251119);
  }

  function test_fork_onReport_mintsCorePool() public {
    address pool = address(AaveV3Ethereum.POOL);
    _mintAndCheck(_one(pool), _one(address(AaveV3Ethereum.COLLECTOR)), _one(pool));
  }

  /// All four Ethereum pools in the single report the workflow sends. EtherFi has nothing
  /// accrued at this block, so onReport skips it and mints the other three.
  function test_fork_onReport_mintsAllPoolsInOneReport() public {
    DeployMintToTreasuryReceiver script = new DeployMintToTreasuryReceiver();
    address[] memory pools = script.getPools(block.chainid);
    assertEq(pools.length, 4, 'expected Core, Prime, EtherFi and Horizon');

    address[] memory collectors = new address[](4);
    collectors[0] = address(AaveV3Ethereum.COLLECTOR);
    collectors[1] = address(AaveV3EthereumLido.COLLECTOR);
    collectors[2] = address(AaveV3EthereumEtherFi.COLLECTOR);
    collectors[3] = address(AaveV3EthereumHorizon.COLLECTOR);

    address[] memory mintable = new address[](3);
    mintable[0] = pools[0];
    mintable[1] = pools[1];
    mintable[2] = pools[3];

    _mintAndCheck(pools, collectors, mintable);
  }
}

/// Forking Monad needs forge's Monad EVM, which only `--network monad` selects.
contract MintToTreasuryMonadFork is MintToTreasuryForkBase {
  // AaveV3Monad is not in the pinned address book yet; value from
  // https://github.com/bgd-labs/aave-address-book/blob/main/src/AaveV3Monad.sol
  address internal constant COLLECTOR = 0x22A14267f9F8bA21D11898F0772e652B09e6A8A1;

  function setUp() public {
    vm.skip(!vm.envOr('FORK_MONAD', false), 'set FORK_MONAD=true and run with --network monad');
    vm.createSelectFork('monad');
  }

  function test_fork_onReport_mintsToCollector() public {
    DeployMintToTreasuryReceiver script = new DeployMintToTreasuryReceiver();
    address[] memory pools = script.getPools(block.chainid);
    _mintAndCheck(pools, _one(COLLECTOR), pools);
  }
}
