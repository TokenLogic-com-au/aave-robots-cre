// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {UmbrellaEthereum} from 'aave-address-book/UmbrellaEthereum.sol';

import {SlashingReceiver} from '../src/SlashingReceiver.sol';
import {ISlashingReceiver, IUmbrella, IUmbrellaStakeToken} from '../src/ISlashingReceiver.sol';

contract SlashingReceiverForkTest is Test {
  SlashingReceiver internal robot;
  address internal owner = makeAddr('fork-owner');
  address internal guardian = makeAddr('fork-guardian');
  address internal anyone = makeAddr('fork-anyone');

  IUmbrella internal umbrella = IUmbrella(address(UmbrellaEthereum.UMBRELLA));

  function setUp() public {
    vm.createSelectFork(vm.envString('RPC_MAINNET'));
    robot = new SlashingReceiver(address(umbrella), owner, guardian);
  }

  function test_fork_umbrella_hasStkTokens() public view {
    assertGt(umbrella.getStkTokens().length, 0);
  }

  /// The minimal local interfaces must match the real deployed ABIs — exercise
  /// the full read path checkUpkeep relies on, against real contracts.
  function test_fork_readPath_interfacesMatch() public view {
    address[] memory stkTokens = umbrella.getStkTokens();
    address stk = stkTokens[0];
    address reserve = umbrella.getStakeTokenData(stk).reserve;
    assertTrue(reserve != address(0));

    umbrella.isReserveSlashable(reserve); // must not revert
    IUmbrellaStakeToken(stk).paused();
    IUmbrellaStakeToken(stk).getMaxSlashableAssets();
  }

  function test_fork_checkUpkeep_doesNotRevert() public view {
    // Enumerates every real stake token; just assert it returns without reverting.
    robot.checkUpkeep('');
  }

  function test_fork_onReport_revertsNoSlashes_whenReserveNotSlashable() public {
    (bool found, address reserve) = _findNonSlashableReserve();
    if (!found) {
      vm.skip(true);
    }
    address[] memory batch = new address[](1);
    batch[0] = reserve;

    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(batch));
  }

  function test_fork_onReport_slashes_whenSlashable() public {
    (bool found, address reserve) = _findSlashableReserve();
    if (!found) {
      vm.skip(true);
    }
    address[] memory batch = new address[](1);
    batch[0] = reserve;

    vm.prank(anyone);
    robot.onReport('', abi.encode(batch));

    (bool stillSlashable, ) = umbrella.isReserveSlashable(reserve);
    assertFalse(stillSlashable);
  }

  function _findNonSlashableReserve() internal view returns (bool, address) {
    address[] memory stkTokens = umbrella.getStkTokens();
    for (uint256 i = 0; i < stkTokens.length; i++) {
      address reserve = umbrella.getStakeTokenData(stkTokens[i]).reserve;
      (bool slashable, ) = umbrella.isReserveSlashable(reserve);
      if (!slashable) return (true, reserve);
    }
    return (false, address(0));
  }

  function _findSlashableReserve() internal view returns (bool, address) {
    address[] memory stkTokens = umbrella.getStkTokens();
    for (uint256 i = 0; i < stkTokens.length; i++) {
      address reserve = umbrella.getStakeTokenData(stkTokens[i]).reserve;
      (bool slashable, ) = umbrella.isReserveSlashable(reserve);
      if (slashable) return (true, reserve);
    }
    return (false, address(0));
  }
}
