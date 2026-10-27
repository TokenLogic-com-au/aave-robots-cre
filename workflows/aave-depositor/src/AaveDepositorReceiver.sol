// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {IAaveDepositorReceiver, IRolesModifier, IPoolExposureSteward} from './IAaveDepositorReceiver.sol';

/// @title AaveDepositorReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and executes Steward deposits and
/// V2 to V3 migrations through the Zodiac Roles Modifier, one call at a time.
/// @dev The Roles Modifier only allows `depositV3` and `migrateV2toV3` on the Steward,
/// so calls are executed individually instead of through `multicall`. `onReport` is
/// permissioned because these calls move Collector funds.
contract AaveDepositorReceiver is IAaveDepositorReceiver, WorkflowsBase {
  /// @dev Zodiac `Enum.Operation.Call`.
  uint8 internal constant OPERATION_CALL = 0;

  /// @dev CRE report metadata starts with the bytes32 workflow id.
  uint256 internal constant WORKFLOW_ID_LENGTH = 32;

  uint256 internal constant SELECTOR_LENGTH = 4;

  /// @inheritdoc IAaveDepositorReceiver
  address public immutable override FORWARDER;

  /// @inheritdoc IAaveDepositorReceiver
  IRolesModifier public immutable override ROLES;

  /// @inheritdoc IAaveDepositorReceiver
  address public immutable override STEWARD;

  /// @inheritdoc IAaveDepositorReceiver
  bytes32 public immutable override ROLE_KEY;

  bytes32 internal _expectedWorkflowId;

  /// @param forwarder_ The CRE forwarder allowed to call `onReport`.
  /// @param roles_ The Zodiac Roles Modifier.
  /// @param steward_ The Aave PoolExposureSteward.
  /// @param roleKey_ The role key granted to this robot.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address forwarder_,
    address roles_,
    address steward_,
    bytes32 roleKey_,
    address initialOwner_,
    address initialGuardian_
  ) WorkflowsBase(initialOwner_, initialGuardian_) {
    require(
      forwarder_ != address(0) && roles_ != address(0) && steward_ != address(0),
      ZeroAddress()
    );

    FORWARDER = forwarder_;
    ROLES = IRolesModifier(roles_);
    STEWARD = steward_;
    ROLE_KEY = roleKey_;
  }

  /// @inheritdoc IAaveDepositorReceiver
  function setExpectedWorkflowId(bytes32 workflowId) external onlyOwner {
    _expectedWorkflowId = workflowId;
    emit ExpectedWorkflowIdSet(workflowId);
  }

  /// @inheritdoc IAaveDepositorReceiver
  function expectedWorkflowId() external view returns (bytes32) {
    return _expectedWorkflowId;
  }

  /// @dev All-or-nothing: a call the Roles Modifier rejects reverts the whole report.
  function _onReport(bytes calldata metadata, bytes calldata report) internal override {
    require(msg.sender == FORWARDER, InvalidSender(msg.sender));

    bytes32 expected = _expectedWorkflowId;
    if (expected != bytes32(0)) {
      bytes32 received = metadata.length >= WORKFLOW_ID_LENGTH
        ? bytes32(metadata[:WORKFLOW_ID_LENGTH])
        : bytes32(0);
      require(received == expected, InvalidWorkflowId(received, expected));
    }

    bytes[] memory calls = abi.decode(report, (bytes[]));
    require(calls.length > 0, NothingToExecute());

    for (uint256 i = 0; i < calls.length; i++) {
      bytes4 selector = _selector(calls[i]);
      require(_isAllowed(selector), SelectorNotAllowed(selector));

      ROLES.execTransactionWithRole({
        to: STEWARD,
        value: 0,
        data: calls[i],
        operation: OPERATION_CALL,
        roleKey: ROLE_KEY,
        shouldRevert: true
      });
      emit StewardCallExecuted(i, selector);
    }
  }

  function _checkUpkeep(
    bytes calldata checkData
  ) internal pure override returns (bool upkeepNeeded, bytes memory performData) {
    if (checkData.length == 0) return (false, '');

    bytes[] memory calls = abi.decode(checkData, (bytes[]));
    if (calls.length == 0) return (false, '');

    for (uint256 i = 0; i < calls.length; i++) {
      if (!_isAllowed(_selector(calls[i]))) return (false, '');
    }

    return (true, checkData);
  }

  function _isAllowed(bytes4 selector) internal pure returns (bool) {
    return
      selector == IPoolExposureSteward.depositV3.selector ||
      selector == IPoolExposureSteward.migrateV2toV3.selector;
  }

  function _selector(bytes memory data) internal pure returns (bytes4) {
    return data.length < SELECTOR_LENGTH ? bytes4(0) : bytes4(data);
  }
}
