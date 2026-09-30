// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {UmbrellaEthereum} from 'aave-address-book/UmbrellaEthereum.sol';
import {IUmbrella} from 'aave-address-book/common/IUmbrella.sol';
import {IPool} from 'aave-v3-origin/contracts/interfaces/IPool.sol';

import {ISlashingReceiver, IUmbrellaStakeToken} from '../src/ISlashingReceiver.sol';
import {SlashingReceiverHarness} from './helpers/SlashingReceiverHarness.sol';

contract SlashingReceiverForkTest is Test {
  SlashingReceiverHarness internal robot;
  address internal owner = makeAddr('fork-owner');
  address internal guardian = makeAddr('fork-guardian');
  address internal anyone = makeAddr('fork-anyone');

  IUmbrella internal umbrella = UmbrellaEthereum.UMBRELLA;

  function setUp() public {
    vm.createSelectFork('mainnet');
    robot = new SlashingReceiverHarness(address(umbrella), owner, guardian);
  }

  /// Checks the local `IUmbrellaStakeToken` and the address-book `IUmbrella` match the
  /// deployed contracts for every stake token.
  function test_fork_readPath_interfacesMatch() public view {
    address[] memory stkTokens = umbrella.getStkTokens();
    assertGt(stkTokens.length, 0, 'umbrella has no stake tokens');
    for (uint256 i = 0; i < stkTokens.length; i++) {
      address reserve = umbrella.getStakeTokenData(stkTokens[i]).reserve;
      assertTrue(reserve != address(0), 'stake token without reserve');
      IUmbrellaStakeToken(stkTokens[i]).paused();
      IUmbrellaStakeToken(stkTokens[i]).getMaxSlashableAssets();
      robot.isSlashable(reserve);
    }
  }

  function test_fork_onReport_revertsNoSlashes_whenReserveNotSlashable() public {
    address reserve = _findNonSlashableReserve();
    require(reserve != address(0), 'no non-slashable reserve on the fork');

    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(_one(reserve)));
  }

  /// Mocks the Pool's reported deficit above Umbrella's non-slashable part (offset +
  /// pending), then checks the robot slashes on the real Umbrella.
  function test_fork_onReport_slashes_whenDeficitAppears() public {
    address reserve = umbrella.getStakeTokenData(umbrella.getStkTokens()[0]).reserve;
    uint256 newDeficit = 1_000e6;
    vm.mockCall(
      umbrella.POOL(),
      abi.encodeWithSelector(IPool.getReserveDeficit.selector, reserve),
      abi.encode(
        umbrella.getDeficitOffset(reserve) + umbrella.getPendingDeficit(reserve) + newDeficit
      )
    );
    uint256 pendingBefore = umbrella.getPendingDeficit(reserve);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'checkUpkeep should flag the reserve');
    assertEq(abi.decode(performData, (address[])), _one(reserve), 'performData mismatch');

    vm.recordLogs();
    vm.prank(anyone);
    robot.onReport('', performData);

    uint256 slashedAmount = _slashedAmount(vm.getRecordedLogs(), reserve);
    assertGt(slashedAmount, 0, 'nothing slashed');
    assertEq(
      umbrella.getPendingDeficit(reserve) - pendingBefore,
      slashedAmount,
      'pending deficit increase does not match the slashed amount'
    );
    assertFalse(robot.isSlashable(reserve), 'reserve still slashable after slash');
  }

  function _slashedAmount(Vm.Log[] memory logs, address reserve) internal view returns (uint256) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (
        logs[i].emitter == address(robot) &&
        logs[i].topics[0] == ISlashingReceiver.ReserveSlashed.selector &&
        address(uint160(uint256(logs[i].topics[1]))) == reserve
      ) return abi.decode(logs[i].data, (uint256));
    }
    return 0;
  }

  function _findNonSlashableReserve() internal view returns (address) {
    address[] memory stkTokens = umbrella.getStkTokens();
    for (uint256 i = 0; i < stkTokens.length; i++) {
      address reserve = umbrella.getStakeTokenData(stkTokens[i]).reserve;
      if (!robot.isSlashable(reserve)) return reserve;
    }
    return address(0);
  }

  function _one(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }
}
