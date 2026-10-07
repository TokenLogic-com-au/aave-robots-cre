// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IAccessControl} from 'openzeppelin-contracts/contracts/access/IAccessControl.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GhoEthereum} from 'aave-address-book/GhoEthereum.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';

import {GsmFreezerReceiver} from '../src/GsmFreezerReceiver.sol';
import {IPoolAddressesProvider} from 'aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from 'aave-v3-origin/contracts/interfaces/IPriceOracleGetter.sol';

import {IGsmFreezerReceiver, IGsm} from '../src/IGsmFreezerReceiver.sol';
import {DeployGsmFreezerReceiver} from '../scripts/DeployGsmFreezerReceiver.s.sol';

contract GsmFreezerReceiverForkTest is Test {
  address internal constant GSM = GhoEthereum.GSM_USDC;
  address internal constant UNDERLYING = AaveV3EthereumAssets.USDC_UNDERLYING;

  GsmFreezerReceiver internal robot;
  address internal owner = makeAddr('owner');
  address internal guardian = makeAddr('guardian');
  address internal anyone = makeAddr('anyone');

  function setUp() public {
    vm.createSelectFork('mainnet');
    robot = new GsmFreezerReceiver(
      GSM,
      UNDERLYING,
      address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER),
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: 0.99e8,
        freezeUpperBound: 1.01e8,
        unfreezeLowerBound: 0.995e8,
        unfreezeUpperBound: 1.005e8
      }),
      true,
      owner,
      guardian
    );
  }

  /// Checks the local `IGsm` matches the deployed GSM.
  function test_fork_readPath_matchesRealGsm() public view {
    IGsm gsm = IGsm(GSM);
    assertFalse(gsm.getIsSeized(), 'gsm is seized');
    assertFalse(gsm.getIsFrozen(), 'gsm already frozen on the fork');
    bytes32 role = gsm.SWAP_FREEZER_ROLE();
    assertEq(role, keccak256('SWAP_FREEZER_ROLE'), 'unexpected SWAP_FREEZER_ROLE');
    assertFalse(gsm.hasRole(role, address(robot)), 'robot should not hold the role yet');

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed without the role');
  }

  function test_fork_onReport_freezesRealGsm_whenDepegged() public {
    _grantFreezerRole();
    _mockPrice(0.90e8);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    assertEq(
      uint256(abi.decode(performData, (IGsmFreezerReceiver.Action))),
      uint256(IGsmFreezerReceiver.Action.FREEZE),
      'expected FREEZE'
    );

    vm.prank(anyone);
    robot.onReport('', '');

    assertTrue(IGsm(GSM).getIsFrozen(), 'gsm not frozen');
  }

  function test_fork_onReport_unfreezesRealGsm_whenRecovered() public {
    _grantFreezerRole();
    _mockPrice(0.90e8);
    vm.prank(anyone);
    robot.onReport('', '');
    assertTrue(IGsm(GSM).getIsFrozen(), 'gsm not frozen');

    _mockPrice(1e8);
    (bool needed, ) = robot.checkUpkeep('');
    assertTrue(needed, 'unfreeze should be needed');

    vm.prank(anyone);
    robot.onReport('', '');
    assertFalse(IGsm(GSM).getIsFrozen(), 'gsm still frozen');
  }

  function _grantFreezerRole() internal {
    bytes32 role = IGsm(GSM).SWAP_FREEZER_ROLE();
    vm.prank(GovernanceV3Ethereum.EXECUTOR_LVL_1);
    IAccessControl(GSM).grantRole(role, address(robot));
  }

  function _mockPrice(uint256 price) internal {
    address oracle = IPoolAddressesProvider(address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER))
      .getPriceOracle();
    vm.mockCall(
      oracle,
      abi.encodeCall(IPriceOracleGetter.getAssetPrice, (UNDERLYING)),
      abi.encode(price)
    );
  }
}

contract GsmFreezerDeployScriptForkTest is Test {
  address internal anyone = makeAddr('anyone');

  function test_fork_ethereum_deployScriptFreezesEveryGsm() public {
    _deployAndFreeze('mainnet');
  }

  function test_fork_plasma_deployScriptFreezesEveryGsm() public {
    vm.skip(!vm.envExists('RPC_PLASMA'), 'RPC_PLASMA not set');
    _deployAndFreeze('plasma');
  }

  function test_fork_monad_deployScriptFreezesEveryGsm() public {
    vm.skip(!vm.envExists('RPC_MONAD'), 'RPC_MONAD not set');
    _deployAndFreeze('monad');
  }

  /// Runs the deploy script on `chain`, grants each receiver the freezer role as governance
  /// would, and checks a depeg freezes the live GSM.
  function _deployAndFreeze(string memory chain) internal {
    vm.createSelectFork(chain);
    DeployGsmFreezerReceiver script = new DeployGsmFreezerReceiver();
    DeployGsmFreezerReceiver.DeployConfig memory config = script.getDeployConfig(block.chainid);
    address[] memory receivers = script.run();
    assertEq(receivers.length, config.freezers.length, 'one receiver per GSM');

    address oracle = IPoolAddressesProvider(config.addressesProvider).getPriceOracle();
    for (uint256 i = 0; i < receivers.length; i++) {
      GsmFreezerReceiver receiver = GsmFreezerReceiver(receivers[i]);
      IGsm gsm = IGsm(config.freezers[i].gsm);
      assertEq(address(receiver.GSM()), address(gsm), 'receiver points to another GSM');
      assertEq(receiver.owner(), config.owner, 'unexpected owner');
      assertFalse(gsm.getIsSeized(), 'gsm is seized');
      assertFalse(gsm.getIsFrozen(), 'gsm already frozen on the fork');

      bytes32 role = gsm.SWAP_FREEZER_ROLE();
      vm.prank(config.owner);
      IAccessControl(address(gsm)).grantRole(role, address(receiver));
      (bool needed, ) = receiver.checkUpkeep('');
      assertFalse(needed, 'upkeep needed at peg');

      vm.mockCall(
        oracle,
        abi.encodeCall(IPriceOracleGetter.getAssetPrice, (config.freezers[i].underlying)),
        abi.encode(0.90e8)
      );
      vm.prank(anyone);
      receiver.onReport('', '');
      assertTrue(gsm.getIsFrozen(), 'gsm not frozen');
    }
  }
}
