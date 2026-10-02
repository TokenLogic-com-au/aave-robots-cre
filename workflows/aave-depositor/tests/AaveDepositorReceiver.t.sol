// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {AaveDepositorReceiver} from '../src/AaveDepositorReceiver.sol';
import {IAaveDepositorReceiver, IRolesModifier, IPoolExposureSteward} from '../src/IAaveDepositorReceiver.sol';

contract AaveDepositorReceiverTest is Test {
  bytes32 internal constant ROLE_KEY = bytes32('aave_depositor');
  bytes32 internal constant WORKFLOW_ID = keccak256('workflow');

  AaveDepositorReceiver internal robot;

  address internal owner;
  address internal guardian;
  address internal bob;
  address internal forwarder;
  address internal roles;
  address internal steward;
  address internal pool;
  address internal token;

  function setUp() public {
    owner = makeAddr('owner');
    guardian = makeAddr('guardian');
    bob = makeAddr('bob');
    forwarder = makeAddr('forwarder');
    roles = makeAddr('roles');
    steward = makeAddr('steward');
    pool = makeAddr('pool');
    token = makeAddr('token');

    robot = new AaveDepositorReceiver(forwarder, roles, steward, ROLE_KEY, owner, guardian);
    vm.mockCall(
      roles,
      abi.encodeWithSelector(IRolesModifier.execTransactionWithRole.selector),
      abi.encode(true)
    );
  }

  function test_constructor_setsImmutables() public view {
    assertEq(robot.owner(), owner, 'owner not set');
    assertEq(robot.guardian(), guardian, 'guardian not set');
    assertEq(robot.FORWARDER(), forwarder, 'forwarder not set');
    assertEq(address(robot.ROLES()), roles, 'roles not set');
    assertEq(robot.STEWARD(), steward, 'steward not set');
    assertEq(robot.ROLE_KEY(), ROLE_KEY, 'role key not set');
    assertEq(robot.expectedWorkflowId(), bytes32(0), 'workflow id should start unpinned');
  }

  function test_constructor_revertsWith_ZeroAddress_forwarder() public {
    vm.expectRevert(IAaveDepositorReceiver.ZeroAddress.selector);
    new AaveDepositorReceiver(address(0), roles, steward, ROLE_KEY, owner, guardian);
  }

  function test_constructor_revertsWith_ZeroAddress_roles() public {
    vm.expectRevert(IAaveDepositorReceiver.ZeroAddress.selector);
    new AaveDepositorReceiver(forwarder, address(0), steward, ROLE_KEY, owner, guardian);
  }

  function test_constructor_revertsWith_ZeroAddress_steward() public {
    vm.expectRevert(IAaveDepositorReceiver.ZeroAddress.selector);
    new AaveDepositorReceiver(forwarder, roles, address(0), ROLE_KEY, owner, guardian);
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId), 'IReceiver unsupported');
    assertTrue(
      robot.supportsInterface(type(IAaveCREReceiver).interfaceId),
      'IAaveCREReceiver unsupported'
    );
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId), 'IERC165 unsupported');
    assertFalse(robot.supportsInterface(0xffffffff), 'invalid interface reported supported');
  }

  function test_checkUpkeep_returnsFalse_whenCheckDataEmpty() public view {
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed with empty checkData');
  }

  function test_checkUpkeep_returnsFalse_whenNoCalls() public view {
    (bool needed, ) = robot.checkUpkeep(abi.encode(new bytes[](0)));
    assertFalse(needed, 'upkeep needed with no calls');
  }

  function test_checkUpkeep_returnsCalls_whenAllAllowed() public view {
    bytes memory checkData = _report(_deposit(1e6), _migration(2e6));
    (bool needed, bytes memory performData) = robot.checkUpkeep(checkData);
    assertTrue(needed, 'upkeep not needed with allowed calls');
    assertEq(performData, checkData, 'performData should echo checkData');
  }

  function test_checkUpkeep_returnsFalse_whenAnySelectorNotAllowed() public view {
    bytes memory checkData = _report(_deposit(1e6), _multicall());
    (bool needed, ) = robot.checkUpkeep(checkData);
    assertFalse(needed, 'upkeep needed with a disallowed selector');
  }

  function test_checkUpkeep_returnsFalse_whenCallTooShort() public view {
    bytes[] memory calls = new bytes[](1);
    calls[0] = hex'a3f9';
    (bool needed, ) = robot.checkUpkeep(abi.encode(calls));
    assertFalse(needed, 'upkeep needed with a truncated call');
  }

  function test_checkUpkeep_returnsFalse_whenDisabled() public {
    vm.prank(owner);
    robot.setDisabled(true);
    (bool needed, ) = robot.checkUpkeep(_report(_deposit(1e6), _migration(2e6)));
    assertFalse(needed, 'upkeep needed while disabled');
  }

  function test_onReport_executesEachCallThroughRoles() public {
    bytes memory deposit = _deposit(1e6);
    bytes memory migration = _migration(2e6);

    vm.expectCall(roles, _rolesCall(deposit), 1);
    vm.expectCall(roles, _rolesCall(migration), 1);
    vm.expectEmit(address(robot));
    emit IAaveDepositorReceiver.StewardCallExecuted(0, IPoolExposureSteward.depositV3.selector);
    vm.expectEmit(address(robot));
    emit IAaveDepositorReceiver.StewardCallExecuted(1, IPoolExposureSteward.migrateV2toV3.selector);

    vm.prank(forwarder);
    robot.onReport('', _report(deposit, migration));
  }

  function test_onReport_ignoresMetadata_whenUnpinned() public {
    vm.prank(forwarder);
    robot.onReport(
      abi.encodePacked(keccak256('any'), bytes10('name')),
      _report(_deposit(1e6), _migration(2e6))
    );
  }

  function test_onReport_revertsWith_SelectorNotAllowed_whenCallTooShort() public {
    bytes[] memory calls = new bytes[](1);
    calls[0] = hex'a3f9';
    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSelector(IAaveDepositorReceiver.SelectorNotAllowed.selector, bytes4(0))
    );
    robot.onReport('', abi.encode(calls));
  }

  function test_onReport_revertsWith_InvalidSender_whenNotForwarder() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IAaveDepositorReceiver.InvalidSender.selector, bob));
    robot.onReport('', _report(_deposit(1e6), _migration(2e6)));
  }

  function test_onReport_revertsWith_SelectorNotAllowed() public {
    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAaveDepositorReceiver.SelectorNotAllowed.selector,
        bytes4(keccak256('multicall(bytes[])'))
      )
    );
    robot.onReport('', _report(_deposit(1e6), _multicall()));
  }

  function test_onReport_revertsWith_NothingToExecute_whenEmpty() public {
    vm.prank(forwarder);
    vm.expectRevert(IAaveDepositorReceiver.NothingToExecute.selector);
    robot.onReport('', abi.encode(new bytes[](0)));
  }

  function test_onReport_revertsWith_NothingToExecute_whenDisabled() public {
    vm.prank(guardian);
    robot.setDisabled(true);
    vm.prank(forwarder);
    vm.expectRevert(IAaveDepositorReceiver.NothingToExecute.selector);
    robot.onReport('', _report(_deposit(1e6), _migration(2e6)));
  }

  function test_onReport_bubblesRolesRevert() public {
    vm.mockCallRevert(
      roles,
      abi.encodeWithSelector(IRolesModifier.execTransactionWithRole.selector),
      'not allowed'
    );
    vm.prank(forwarder);
    vm.expectRevert('not allowed');
    robot.onReport('', _report(_deposit(1e6), _migration(2e6)));
  }

  function test_onReport_acceptsMatchingWorkflowId_whenPinned() public {
    vm.prank(owner);
    robot.setExpectedWorkflowId(WORKFLOW_ID);

    vm.prank(forwarder);
    robot.onReport(
      abi.encodePacked(WORKFLOW_ID, bytes10('name')),
      _report(_deposit(1e6), _migration(2e6))
    );
  }

  function test_onReport_revertsWith_InvalidWorkflowId_whenPinned() public {
    vm.prank(owner);
    robot.setExpectedWorkflowId(WORKFLOW_ID);
    bytes32 other = keccak256('other');

    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSelector(IAaveDepositorReceiver.InvalidWorkflowId.selector, other, WORKFLOW_ID)
    );
    robot.onReport(abi.encodePacked(other), _report(_deposit(1e6), _migration(2e6)));
  }

  function test_onReport_revertsWith_InvalidWorkflowId_whenPinnedAndMetadataShort() public {
    vm.prank(owner);
    robot.setExpectedWorkflowId(WORKFLOW_ID);

    vm.prank(forwarder);
    vm.expectRevert(
      abi.encodeWithSelector(
        IAaveDepositorReceiver.InvalidWorkflowId.selector,
        bytes32(0),
        WORKFLOW_ID
      )
    );
    robot.onReport('', _report(_deposit(1e6), _migration(2e6)));
  }

  function test_setExpectedWorkflowId_byOwner() public {
    vm.expectEmit(address(robot));
    emit IAaveDepositorReceiver.ExpectedWorkflowIdSet(WORKFLOW_ID);
    vm.prank(owner);
    robot.setExpectedWorkflowId(WORKFLOW_ID);
    assertEq(robot.expectedWorkflowId(), WORKFLOW_ID, 'workflow id not pinned');
  }

  function test_setExpectedWorkflowId_zeroUnpins() public {
    vm.startPrank(owner);
    robot.setExpectedWorkflowId(WORKFLOW_ID);
    robot.setExpectedWorkflowId(bytes32(0));
    vm.stopPrank();
    assertEq(robot.expectedWorkflowId(), bytes32(0), 'workflow id not unpinned');

    vm.prank(forwarder);
    robot.onReport(abi.encodePacked(keccak256('other')), _report(_deposit(1e6), _migration(2e6)));
  }

  function test_setExpectedWorkflowId_revertsWith_NotOwner() public {
    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
    robot.setExpectedWorkflowId(WORKFLOW_ID);
  }

  function test_setDisabled_byOwner() public {
    vm.expectEmit(address(robot));
    emit IAaveDepositorReceiver.AutomationDisabled(true);
    vm.prank(owner);
    robot.setDisabled(true);
    assertTrue(robot.isDisabled(), 'not disabled by owner');
  }

  function test_setDisabled_byGuardian() public {
    vm.prank(guardian);
    robot.setDisabled(true);
    assertTrue(robot.isDisabled(), 'not disabled by guardian');
  }

  function test_setDisabled_false_resumesAutomation() public {
    vm.startPrank(owner);
    robot.setDisabled(true);
    robot.setDisabled(false);
    vm.stopPrank();
    assertFalse(robot.isDisabled(), 'still disabled');

    bytes memory report = _report(_deposit(1e6), _migration(2e6));
    (bool needed, ) = robot.checkUpkeep(report);
    assertTrue(needed, 'upkeep not resumed');
    vm.prank(forwarder);
    robot.onReport('', report);
  }

  function test_setDisabled_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.setDisabled(true);
  }

  function test_setDisabled_revertsWith_StateUnchanged_whenSameValue() public {
    vm.prank(owner);
    vm.expectRevert(IAaveDepositorReceiver.StateUnchanged.selector);
    robot.setDisabled(false);
  }

  function _deposit(uint256 amount) internal view returns (bytes memory) {
    return abi.encodeCall(IPoolExposureSteward.depositV3, (pool, token, amount));
  }

  function _migration(uint256 amount) internal view returns (bytes memory) {
    return abi.encodeCall(IPoolExposureSteward.migrateV2toV3, (pool, pool, token, amount));
  }

  function _multicall() internal pure returns (bytes memory) {
    return abi.encodeWithSignature('multicall(bytes[])', new bytes[](0));
  }

  function _report(bytes memory a, bytes memory b) internal pure returns (bytes memory) {
    bytes[] memory calls = new bytes[](2);
    calls[0] = a;
    calls[1] = b;
    return abi.encode(calls);
  }

  function _rolesCall(bytes memory call) internal view returns (bytes memory) {
    return
      abi.encodeCall(IRolesModifier.execTransactionWithRole, (steward, 0, call, 0, ROLE_KEY, true));
  }
}
