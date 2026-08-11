// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IAccessControl} from 'openzeppelin-contracts/contracts/access/IAccessControl.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GhoEthereum} from 'aave-address-book/GhoEthereum.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';

import {GsmFreezerReceiver} from '../src/GsmFreezerReceiver.sol';
import {IGsmFreezerReceiver, IGsm, IPoolAddressesProvider, IPriceOracle} from '../src/IGsmFreezerReceiver.sol';

contract GsmFreezerReceiverForkTest is Test {
  address internal constant GSM = GhoEthereum.GSM_USDC;
  address internal constant UNDERLYING = AaveV3EthereumAssets.USDC_UNDERLYING;

  GsmFreezerReceiver internal robot;
  address internal owner = makeAddr('owner');
  address internal guardian = makeAddr('guardian');
  address internal anyone = makeAddr('anyone');

  function setUp() public {
    vm.createSelectFork(vm.envString('RPC_MAINNET'));
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

  // Locks the read-path ABI against the real deployed GSM + Aave oracle. Runs
  // unconditionally (no vm.skip): a signature drift on any of these reverts here.
  function test_fork_readPath_matchesRealGsm() public view {
    IGsm gsm = IGsm(GSM);
    assertFalse(gsm.getIsSeized());
    // SWAP_FREEZER_ROLE on the GSM equals the well-known constant, and the
    // freshly-deployed robot does not hold it yet.
    bytes32 role = gsm.SWAP_FREEZER_ROLE();
    assertEq(role, 0x6dac4cc0544e34aa1a4ed2862f6de78290e3f18f00fe77179ee8ef34de9dfa24);
    assertFalse(gsm.hasRole(role, address(robot)));

    // The Aave oracle prices USDC ~ $1 (8 decimals), so checkUpkeep is a no-op
    // that returns cleanly (also proves the price read matches the real oracle).
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  // End-to-end against the REAL GSM: grant the role (as governance would), simulate
  // a depeg, and confirm an unpermissioned onReport freezes the real GSM.
  function test_fork_onReport_freezesRealGsm_whenDepegged() public {
    _grantFreezerRole();
    _mockPrice(0.90e8);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed);
    assertEq(
      uint256(abi.decode(performData, (IGsmFreezerReceiver.Action))),
      uint256(IGsmFreezerReceiver.Action.FREEZE)
    );

    vm.prank(anyone);
    robot.onReport('', '');

    assertTrue(IGsm(GSM).getIsFrozen());
  }

  // Once frozen and the price has recovered into the inner band, onReport unfreezes
  // the real GSM (allowUnfreeze == true).
  function test_fork_onReport_unfreezesRealGsm_whenRecovered() public {
    _grantFreezerRole();
    _mockPrice(0.90e8);
    robot.onReport('', '');
    assertTrue(IGsm(GSM).getIsFrozen());

    _mockPrice(1e8);
    (bool needed, ) = robot.checkUpkeep('');
    assertTrue(needed);

    robot.onReport('', '');
    assertFalse(IGsm(GSM).getIsFrozen());
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
      abi.encodeCall(IPriceOracle.getAssetPrice, (UNDERLYING)),
      abi.encode(price)
    );
  }
}
