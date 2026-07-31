// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {SlashingReceiver} from '../src/SlashingReceiver.sol';
import {ISlashingReceiver, IUmbrella, IUmbrellaStakeToken} from '../src/ISlashingReceiver.sol';

contract SlashingReceiverTest is Test {
  SlashingReceiver internal robot;

  address internal owner;
  address internal guardian;
  address internal bob;
  address internal anyone;

  address internal umbrella;
  address internal stkA;
  address internal stkB;
  address internal reserveA;
  address internal reserveB;

  function setUp() public {
    owner = makeAddr('owner');
    guardian = makeAddr('guardian');
    bob = makeAddr('bob');
    anyone = makeAddr('anyone');

    umbrella = makeAddr('umbrella');
    stkA = makeAddr('stkA');
    stkB = makeAddr('stkB');
    reserveA = makeAddr('reserveA');
    reserveB = makeAddr('reserveB');

    _mockReserveOf(stkA, reserveA);
    _mockReserveOf(stkB, reserveB);

    robot = new SlashingReceiver(umbrella, owner, guardian);
  }

  function test_constructor_setsOwnerGuardianAndUmbrella() public view {
    assertEq(robot.owner(), owner);
    assertEq(robot.guardian(), guardian);
    assertEq(address(robot.UMBRELLA()), umbrella);
  }

  function test_MAX_CHECK_SIZE_isTen() public view {
    assertEq(robot.MAX_CHECK_SIZE(), 10);
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId));
    assertTrue(robot.supportsInterface(type(IAaveCREReceiver).interfaceId));
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId));
    assertFalse(robot.supportsInterface(0xffffffff));
  }

  function test_checkUpkeep_returnsFalse_whenNoStkTokens() public {
    _mockStkTokens(new address[](0));
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertFalse(needed);
    assertEq(performData, '');
  }

  function test_checkUpkeep_returnsFalse_whenReserveNotSlashable() public {
    _mockStkTokens(_one(stkA));
    _setupStake(stkA, reserveA, StakeSetup({slashable: false, paused: false, maxSlashable: 1e18}));
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsFalse_whenStakePaused() public {
    _mockStkTokens(_one(stkA));
    _setupStake(stkA, reserveA, StakeSetup({slashable: true, paused: true, maxSlashable: 1e18}));
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsFalse_whenNoSlashableFunds() public {
    _mockStkTokens(_one(stkA));
    _setupStake(stkA, reserveA, StakeSetup({slashable: true, paused: false, maxSlashable: 0}));
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsReserve_whenSlashable() public {
    _mockStkTokens(_two(stkA, stkB));
    _setupStake(stkA, reserveA, StakeSetup({slashable: true, paused: false, maxSlashable: 1e18}));
    _setupStake(stkB, reserveB, StakeSetup({slashable: false, paused: false, maxSlashable: 1e18}));

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed);

    address[] memory reserves = abi.decode(performData, (address[]));
    assertEq(reserves.length, 1);
    assertEq(reserves[0], reserveA);
  }

  function test_checkUpkeep_skipsDisabledReserve() public {
    _mockStkTokens(_one(stkA));
    _setupStake(stkA, reserveA, StakeSetup({slashable: true, paused: false, maxSlashable: 1e18}));

    vm.prank(owner);
    robot.setDisabled(reserveA, true);

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_capsAtMaxCheckSize() public {
    uint256 total = robot.MAX_CHECK_SIZE() + 3;
    address[] memory stks = new address[](total);
    for (uint256 i = 0; i < total; i++) {
      address stk = makeAddr(string(abi.encodePacked('stk', vm.toString(i))));
      address reserve = makeAddr(string(abi.encodePacked('reserve', vm.toString(i))));
      stks[i] = stk;
      _mockReserveOf(stk, reserve);
      _setupStake(stk, reserve, StakeSetup({slashable: true, paused: false, maxSlashable: 1e18}));
    }
    _mockStkTokens(stks);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed);
    address[] memory picked = abi.decode(performData, (address[]));
    assertEq(picked.length, robot.MAX_CHECK_SIZE());
  }

  function test_onReport_slashes_whenAnyoneCalls() public {
    _mockSlashable(reserveA, true);
    _mockSlash(reserveA, 42e18);

    vm.expectCall(umbrella, abi.encodeWithSelector(IUmbrella.slash.selector, reserveA));
    vm.expectEmit(address(robot));
    emit ISlashingReceiver.ReserveSlashed(reserveA, 42e18);

    vm.prank(anyone);
    robot.onReport('', abi.encode(_one(reserveA)));
  }

  function test_onReport_revertsWith_NoSlashesPerformed_whenNothingSlashable() public {
    _mockSlashable(reserveA, false);

    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(_one(reserveA)));
  }

  function test_onReport_skipsDisabledReserve() public {
    _mockSlashable(reserveA, true);
    vm.prank(guardian);
    robot.setDisabled(reserveA, true);

    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(_one(reserveA)));
  }

  function test_onReport_skipsRevertingSlash_andSlashesRest() public {
    _mockSlashable(reserveA, true);
    _mockSlashable(reserveB, true);
    _mockSlashRevert(reserveA);
    _mockSlash(reserveB, 7e18);

    vm.expectCall(umbrella, abi.encodeWithSelector(IUmbrella.slash.selector, reserveB));
    vm.expectEmit(address(robot));
    emit ISlashingReceiver.ReserveSlashed(reserveB, 7e18);

    vm.prank(anyone);
    robot.onReport('', abi.encode(_two(reserveA, reserveB)));
  }

  function test_onReport_revertsWith_NoSlashesPerformed_whenAllSlashesRevert() public {
    _mockSlashable(reserveA, true);
    _mockSlashRevert(reserveA);

    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(_one(reserveA)));
  }

  function test_setDisabled_byOwner() public {
    vm.expectEmit(address(robot));
    emit ISlashingReceiver.ReserveDisabled(reserveA, true);

    vm.prank(owner);
    robot.setDisabled(reserveA, true);
    assertTrue(robot.isDisabled(reserveA));
  }

  function test_setDisabled_byGuardian() public {
    vm.prank(guardian);
    robot.setDisabled(reserveA, true);
    assertTrue(robot.isDisabled(reserveA));
  }

  function test_setDisabled_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.setDisabled(reserveA, true);
  }

  struct StakeSetup {
    bool slashable;
    bool paused;
    uint256 maxSlashable;
  }

  function _setupStake(address stk, address reserve, StakeSetup memory s) internal {
    _mockSlashable(reserve, s.slashable);
    _mockPaused(stk, s.paused);
    _mockMaxSlashable(stk, s.maxSlashable);
  }

  function _mockStkTokens(address[] memory tokens) internal {
    vm.mockCall(
      umbrella,
      abi.encodeWithSelector(IUmbrella.getStkTokens.selector),
      abi.encode(tokens)
    );
  }

  function _mockReserveOf(address stk, address reserve) internal {
    vm.mockCall(
      umbrella,
      abi.encodeWithSelector(IUmbrella.getStakeTokenData.selector, stk),
      abi.encode(IUmbrella.StakeTokenData({underlyingOracle: address(0), reserve: reserve}))
    );
  }

  function _mockSlashable(address reserve, bool slashable) internal {
    vm.mockCall(
      umbrella,
      abi.encodeWithSelector(IUmbrella.isReserveSlashable.selector, reserve),
      abi.encode(slashable, uint256(0))
    );
  }

  function _mockSlash(address reserve, uint256 amount) internal {
    vm.mockCall(
      umbrella,
      abi.encodeWithSelector(IUmbrella.slash.selector, reserve),
      abi.encode(amount)
    );
  }

  function _mockSlashRevert(address reserve) internal {
    vm.mockCallRevert(
      umbrella,
      abi.encodeWithSelector(IUmbrella.slash.selector, reserve),
      'slash failed'
    );
  }

  function _mockPaused(address stk, bool paused) internal {
    vm.mockCall(
      stk,
      abi.encodeWithSelector(IUmbrellaStakeToken.paused.selector),
      abi.encode(paused)
    );
  }

  function _mockMaxSlashable(address stk, uint256 amount) internal {
    vm.mockCall(
      stk,
      abi.encodeWithSelector(IUmbrellaStakeToken.getMaxSlashableAssets.selector),
      abi.encode(amount)
    );
  }

  function _one(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function _two(address a, address b) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
  }
}
