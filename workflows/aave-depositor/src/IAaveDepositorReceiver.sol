// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice Minimal view of the Zodiac Roles Modifier (v2).
interface IRolesModifier {
  /// @notice Executes `data` on `to` under `roleKey`. Reverts when the role does not allow it.
  function execTransactionWithRole(
    address to,
    uint256 value,
    bytes calldata data,
    uint8 operation,
    bytes32 roleKey,
    bool shouldRevert
  ) external returns (bool success);
}

/// @notice The two Aave PoolExposureSteward functions the `aave_depositor` role allows.
interface IPoolExposureSteward {
  /// @notice Supplies `amount` of `reserve` from the Collector into `pool`.
  function depositV3(address pool, address reserve, uint256 amount) external;

  /// @notice Withdraws `amount` of `underlying` from `v2Pool` and supplies it into `v3Pool`.
  function migrateV2toV3(
    address v2Pool,
    address v3Pool,
    address underlying,
    uint256 amount
  ) external;
}

/// @title IAaveDepositorReceiver
/// @notice Robot that puts idle Collector funds to work: it forwards Steward
/// deposits and V2 to V3 migrations through the Zodiac Roles Modifier.
/// @dev Both `checkData` and `report` are `abi.encode(bytes[] calls)`, each call being
/// Steward calldata for one of the allowed selectors. `onReport` is permissioned: only
/// the CRE forwarder may call it, optionally pinned to one workflow id.
interface IAaveDepositorReceiver is IAaveCREReceiver {
  /// @notice Emitted for every Steward call executed through the Roles Modifier.
  /// @param index Position of the call in the report.
  /// @param selector The Steward function executed.
  event StewardCallExecuted(uint256 indexed index, bytes4 indexed selector);

  /// @notice Emitted when the accepted workflow id changes. Zero accepts any workflow.
  /// @param workflowId The new expected workflow id.
  event ExpectedWorkflowIdSet(bytes32 workflowId);

  /// @notice Emitted when the robot is excluded from / included in automation.
  /// @param disabled Whether the robot is now excluded from automation.
  event AutomationDisabled(bool disabled);

  /// @notice Thrown when a constructor address is zero.
  error ZeroAddress();

  /// @notice Thrown when `onReport` is not called by the forwarder.
  error InvalidSender(address sender);

  /// @notice Thrown when the report's workflow id does not match the expected one.
  error InvalidWorkflowId(bytes32 received, bytes32 expected);

  /// @notice Thrown when a call targets a Steward function the role does not allow.
  error SelectorNotAllowed(bytes4 selector);

  /// @notice Thrown when `onReport` runs disabled or with an empty report.
  error NothingToExecute();

  /// @notice Thrown when `setDisabled` is passed the current state.
  error StateUnchanged();

  /// @notice The CRE forwarder allowed to call `onReport`.
  function FORWARDER() external view returns (address);

  /// @notice The Zodiac Roles Modifier the calls go through.
  function ROLES() external view returns (IRolesModifier);

  /// @notice The Aave PoolExposureSteward the calls target.
  function STEWARD() external view returns (address);

  /// @notice The Roles Modifier role key granted to this robot.
  function ROLE_KEY() external view returns (bytes32);

  /// @notice The workflow id `onReport` accepts, or zero for any.
  function expectedWorkflowId() external view returns (bytes32);

  /// @notice Pin `onReport` to one workflow id, or zero to accept any. Owner only.
  /// @param workflowId The workflow id to accept.
  function setExpectedWorkflowId(bytes32 workflowId) external;

  /// @notice Whether the robot is excluded from automation.
  function isDisabled() external view returns (bool);

  /// @notice Exclude or include the robot from automation. Owner or guardian.
  /// @param disabled Whether to exclude the robot from automation.
  function setDisabled(bool disabled) external;
}
