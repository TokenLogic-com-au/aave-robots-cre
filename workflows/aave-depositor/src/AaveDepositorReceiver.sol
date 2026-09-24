// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IAaveDepositorReceiver, IRolesModifier, IPoolExposureSteward} from './IAaveDepositorReceiver.sol';

/// @title AaveDepositorReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and executes Steward deposits and
/// V2 to V3 migrations through the Zodiac Roles Modifier, one call at a time.
/// @dev The Roles Modifier only allows `depositV3` and `migrateV2toV3` on the Steward,
/// so calls are executed individually instead of through `multicall`. `onReport` is
/// permissioned because these calls move Collector funds.
contract AaveDepositorReceiver is IAaveDepositorReceiver, OwnableWithGuardian {
  /// @inheritdoc IAaveDepositorReceiver
  address public immutable override FORWARDER;

  /// @inheritdoc IAaveDepositorReceiver
  IRolesModifier public immutable override ROLES;

  /// @inheritdoc IAaveDepositorReceiver
  address public immutable override STEWARD;

  /// @inheritdoc IAaveDepositorReceiver
  bytes32 public immutable override ROLE_KEY;

  bytes32 internal _expectedWorkflowId;
  bool internal _disabled;

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
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
    require(
      forwarder_ != address(0) && roles_ != address(0) && steward_ != address(0),
      ZeroAddress()
    );
    FORWARDER = forwarder_;
    ROLES = IRolesModifier(roles_);
    STEWARD = steward_;
    ROLE_KEY = roleKey_;
  }

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata checkData
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    if (_disabled || checkData.length == 0) return (false, '');
    bytes[] memory calls = abi.decode(checkData, (bytes[]));
    if (calls.length == 0) return (false, '');
    for (uint256 i = 0; i < calls.length; i++) {
      if (!_isAllowed(_selector(calls[i]))) return (false, '');
    }
    return (true, checkData);
  }

  /// @inheritdoc IReceiver
  /// @dev All-or-nothing: a call the Roles Modifier rejects reverts the whole report.
  function onReport(bytes calldata metadata, bytes calldata report) external override {
    require(msg.sender == FORWARDER, InvalidSender(msg.sender));
    bytes32 expected = _expectedWorkflowId;
    if (expected != bytes32(0)) {
      bytes32 received = metadata.length >= 32 ? bytes32(metadata[:32]) : bytes32(0);
      require(received == expected, InvalidWorkflowId(received, expected));
    }
    if (_disabled) revert NothingToExecute();

    bytes[] memory calls = abi.decode(report, (bytes[]));
    if (calls.length == 0) revert NothingToExecute();
    for (uint256 i = 0; i < calls.length; i++) {
      bytes4 selector = _selector(calls[i]);
      require(_isAllowed(selector), SelectorNotAllowed(selector));
      ROLES.execTransactionWithRole(STEWARD, 0, calls[i], 0, ROLE_KEY, true);
      emit StewardCallExecuted(i, selector);
    }
  }

  /// @inheritdoc IAaveDepositorReceiver
  function expectedWorkflowId() external view returns (bytes32) {
    return _expectedWorkflowId;
  }

  /// @inheritdoc IAaveDepositorReceiver
  function setExpectedWorkflowId(bytes32 workflowId) external onlyOwner {
    _expectedWorkflowId = workflowId;
    emit ExpectedWorkflowIdSet(workflowId);
  }

  /// @inheritdoc IAaveDepositorReceiver
  function isDisabled() public view returns (bool) {
    return _disabled;
  }

  /// @inheritdoc IAaveDepositorReceiver
  function setDisabled(bool disabled) external onlyOwnerOrGuardian {
    require(_disabled != disabled, StateUnchanged());
    _disabled = disabled;
    emit AutomationDisabled(disabled);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  function _isAllowed(bytes4 selector) internal pure returns (bool) {
    return
      selector == IPoolExposureSteward.depositV3.selector ||
      selector == IPoolExposureSteward.migrateV2toV3.selector;
  }

  function _selector(bytes memory data) internal pure returns (bytes4) {
    return data.length < 4 ? bytes4(0) : bytes4(data);
  }
}
