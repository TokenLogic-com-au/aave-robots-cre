// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {IRescuable} from 'aave-v4/interfaces/IRescuable.sol';
import {IUmbrella, IUmbrellaConfiguration} from 'aave-address-book/common/IUmbrella.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {SlashingReceiver} from '../src/SlashingReceiver.sol';
import {ISlashingReceiver, IUmbrellaStakeToken} from '../src/ISlashingReceiver.sol';

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
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
    assertEq(address(robot.UMBRELLA()), umbrella, 'umbrella mismatch');
  }

  function test_constructor_revertsWith_InvalidUmbrella() public {
    vm.expectRevert(ISlashingReceiver.InvalidUmbrella.selector);
    new SlashingReceiver(address(0), owner, guardian);
  }

  function test_MAX_CHECK_SIZE_isTen() public view {
    assertEq(robot.MAX_CHECK_SIZE(), 10, 'unexpected MAX_CHECK_SIZE');
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId), 'IReceiver not supported');
    assertTrue(
      robot.supportsInterface(type(IAaveCREReceiver).interfaceId),
      'IAaveCREReceiver not supported'
    );
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId), 'IERC165 not supported');
    assertFalse(robot.supportsInterface(0xffffffff), 'invalid interface id supported');
  }

  function test_checkUpkeep_returnsFalse_whenNoStkTokens() public {
    _mockStkTokens(new address[](0));

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed without stake tokens');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_fuzz_checkUpkeep_flagsSlashableUnpausedFundedStake(
    bool slashable,
    bool paused,
    bool hasFunds
  ) public {
    _mockStkTokens(_one(stkA));
    _setupStake(stkA, reserveA, StakeSetup(slashable, paused, hasFunds ? 1e18 : 0));

    (bool needed, bytes memory performData) = robot.checkUpkeep('');

    bool expected = slashable && !paused && hasFunds;
    assertEq(needed, expected, 'unexpected upkeepNeeded');
    if (expected) {
      assertEq(abi.decode(performData, (address[])), _one(reserveA), 'performData mismatch');
    } else {
      assertEq(performData.length, 0, 'performData should be empty');
    }
  }

  function test_checkUpkeep_returnsOnlySlashableReserves() public {
    _mockStkTokens(_two(stkA, stkB));
    _setupStake(stkA, reserveA, StakeSetup(false, false, 1e18));
    _setupStake(stkB, reserveB, StakeSetup(true, false, 1e18));

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    assertEq(abi.decode(performData, (address[])), _one(reserveB), 'performData mismatch');
  }

  function test_checkUpkeep_checksEachReserveAgainstItsOwnStakeToken() public {
    _mockStkTokens(_two(stkA, stkB));
    _setupStake(stkA, reserveA, StakeSetup(true, false, 1e18));
    _setupStake(stkB, reserveB, StakeSetup(true, true, 1e18));

    (, bytes memory performData) = robot.checkUpkeep('');
    assertEq(abi.decode(performData, (address[])), _one(reserveA), 'paused stkB not skipped');
  }

  function test_checkUpkeep_flagsStake_withMinimalSlashableAssets() public {
    _mockStkTokens(_one(stkA));
    _setupStake(stkA, reserveA, StakeSetup(true, false, 1));

    (bool needed, ) = robot.checkUpkeep('');
    assertTrue(needed, '1 wei of slashable assets should be enough');
  }

  function test_checkUpkeep_returnsFalse_whenReserveDisabled() public {
    _mockStkTokens(_one(stkA));
    _setupStake(stkA, reserveA, StakeSetup(true, false, 1e18));

    vm.prank(guardian);
    robot.disableReserve(reserveA);

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed for disabled reserve');
  }

  function test_checkUpkeep_returnsFalse_whenReserveIsZero() public {
    _mockStkTokens(_one(stkA));
    _mockReserveOf(stkA, address(0));
    _setupStake(stkA, address(0), StakeSetup(true, false, 1e18));

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed for zero reserve');
  }

  function test_checkUpkeep_capsAtMaxCheckSize_skippingNonSlashable() public {
    uint256 maxCheckSize = robot.MAX_CHECK_SIZE();
    uint256 total = maxCheckSize * 2 + 3;
    address[] memory stks = new address[](total);
    address[] memory expected = new address[](maxCheckSize);
    uint256 count = 0;
    for (uint256 i = 0; i < total; i++) {
      stks[i] = makeAddr(string.concat('stk', vm.toString(i)));
      address reserve = makeAddr(string.concat('reserve', vm.toString(i)));
      _mockReserveOf(stks[i], reserve);
      // Every other reserve has no deficit and must be skipped.
      bool slashable = i % 2 == 1;
      _setupStake(stks[i], reserve, StakeSetup(slashable, false, 1e18));
      if (slashable && count < maxCheckSize) expected[count++] = reserve;
    }
    _mockStkTokens(stks);

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    assertEq(
      abi.decode(performData, (address[])),
      expected,
      'should pick the first MAX_CHECK_SIZE slashable reserves'
    );
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

  function test_onReport_skipsNonSlashableAndRevertingSlash_andSlashesRest() public {
    address reserveC = makeAddr('reserveC');
    _mockSlashable(reserveA, false);
    _mockSlashable(reserveB, true);
    _mockSlashRevert(reserveB);
    _mockSlashable(reserveC, true);
    _mockSlash(reserveC, 7e18);

    vm.expectCall(umbrella, abi.encodeWithSelector(IUmbrella.slash.selector, reserveA), 0);

    vm.recordLogs();
    vm.prank(anyone);
    robot.onReport('', abi.encode(_three(reserveA, reserveB, reserveC)));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 1, 'expected a single ReserveSlashed');
    assertEq(logs[0].topics[0], ISlashingReceiver.ReserveSlashed.selector, 'wrong event');
    assertEq(address(uint160(uint256(logs[0].topics[1]))), reserveC, 'event for wrong reserve');
    assertEq(abi.decode(logs[0].data, (uint256)), 7e18, 'wrong slashed amount');
  }

  function test_onReport_revertsWith_NoSlashesPerformed_whenNothingSlashable() public {
    _mockSlashable(reserveA, false);

    vm.expectCall(umbrella, abi.encodeWithSelector(IUmbrella.slash.selector, reserveA), 0);
    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(_one(reserveA)));
  }

  function test_onReport_revertsWith_NoSlashesPerformed_whenReserveDisabled() public {
    _mockSlashable(reserveA, true);
    _mockSlash(reserveA, 1e18);
    vm.prank(guardian);
    robot.disableReserve(reserveA);

    vm.expectCall(umbrella, abi.encodeWithSelector(IUmbrella.slash.selector, reserveA), 0);
    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(_one(reserveA)));
  }

  function test_onReport_revertsWith_NoSlashesPerformed_whenAllSlashesRevert() public {
    _mockSlashable(reserveA, true);
    _mockSlashRevert(reserveA);

    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(_one(reserveA)));
  }

  function test_onReport_revertsWith_NoSlashesPerformed_whenEmptyBatch() public {
    vm.prank(anyone);
    vm.expectRevert(ISlashingReceiver.NoSlashesPerformed.selector);
    robot.onReport('', abi.encode(new address[](0)));
  }

  function test_disableReserve_byOwner() public {
    vm.expectEmit(address(robot));
    emit ISlashingReceiver.ReserveDisabled(reserveA, true);

    vm.prank(owner);
    robot.disableReserve(reserveA);
    assertTrue(robot.isDisabled(reserveA), 'reserve not disabled');
  }

  function test_disableReserve_byGuardian() public {
    vm.prank(guardian);
    robot.disableReserve(reserveA);
    assertTrue(robot.isDisabled(reserveA), 'reserve not disabled');
  }

  function test_disableReserve_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.disableReserve(reserveA);
  }

  function test_disableReserve_revertsWith_ReserveStatusUnchanged() public {
    vm.prank(guardian);
    robot.disableReserve(reserveA);

    vm.prank(guardian);
    vm.expectRevert(
      abi.encodeWithSelector(ISlashingReceiver.ReserveStatusUnchanged.selector, reserveA, true)
    );
    robot.disableReserve(reserveA);
  }

  function test_enableReserve() public {
    vm.prank(guardian);
    robot.disableReserve(reserveA);

    vm.expectEmit(address(robot));
    emit ISlashingReceiver.ReserveDisabled(reserveA, false);

    vm.prank(owner);
    robot.enableReserve(reserveA);
    assertFalse(robot.isDisabled(reserveA), 'reserve still disabled');
  }

  function test_enableReserve_revertsWhenCalledByGuardian() public {
    vm.prank(guardian);
    robot.disableReserve(reserveA);

    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
    robot.enableReserve(reserveA);
  }

  function test_enableReserve_revertsWith_ReserveStatusUnchanged() public {
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(ISlashingReceiver.ReserveStatusUnchanged.selector, reserveA, false)
    );
    robot.enableReserve(reserveA);
  }

  function test_rescueGuardian_isOwner() public view {
    assertEq(robot.rescueGuardian(), owner, 'rescue guardian is not the owner');
  }

  function test_rescueToken_revertsWith_OnlyRescueGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(IRescuable.OnlyRescueGuardian.selector);
    robot.rescueToken(makeAddr('token'), bob, 100);
  }

  struct StakeSetup {
    bool slashable;
    bool paused;
    uint256 maxSlashable;
  }

  function _setupStake(address stk, address reserve, StakeSetup memory s) internal {
    _mockSlashable(reserve, s.slashable);
    vm.mockCall(
      stk,
      abi.encodeWithSelector(IUmbrellaStakeToken.paused.selector),
      abi.encode(s.paused)
    );
    vm.mockCall(
      stk,
      abi.encodeWithSelector(IUmbrellaStakeToken.getMaxSlashableAssets.selector),
      abi.encode(s.maxSlashable)
    );
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
      abi.encode(
        IUmbrellaConfiguration.StakeTokenData({underlyingOracle: address(0), reserve: reserve})
      )
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

  function _one(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function _two(address a, address b) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
  }

  function _three(address a, address b, address c) internal pure returns (address[] memory arr) {
    arr = new address[](3);
    arr[0] = a;
    arr[1] = b;
    arr[2] = c;
  }
}
