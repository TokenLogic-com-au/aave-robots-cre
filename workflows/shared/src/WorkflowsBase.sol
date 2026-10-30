// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';

import {IReceiver} from './IReceiver.sol';
import {IAaveCREReceiver} from './IAaveCREReceiver.sol';
import {IWorkflowsBase} from './IWorkflowsBase.sol';

/// @title WorkflowsBase
/// @author Aave Labs
/// @notice Base contract of every Aave CRE robot: owner / guardian access control, token
/// rescue by the owner, ERC165 and the global automation switch.
/// @dev Robots implement `_onReport` and `_checkUpkeep`. The switch is applied here rather
/// than by each robot so that none can forget it.
abstract contract WorkflowsBase is IWorkflowsBase, OwnableWithGuardian, Rescuable {
  bool internal _automationDisabled;

  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address initialOwner_,
    address initialGuardian_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {}

  /// @inheritdoc IReceiver
  function onReport(bytes calldata metadata, bytes calldata report) external {
    require(!_automationDisabled, AutomationIsDisabled());
    _onReport(metadata, report);
  }

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata checkData
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    if (!_isUpkeepAllowed()) return (false, '');
    return _checkUpkeep(checkData);
  }

  /// @inheritdoc IWorkflowsBase
  function enableAutomation() external onlyOwner {
    require(_automationDisabled, StateUnchanged());
    _automationDisabled = false;
    emit AutomationDisabled(false);
  }

  /// @inheritdoc IWorkflowsBase
  function disableAutomation() external onlyOwnerOrGuardian {
    require(!_automationDisabled, StateUnchanged());
    _automationDisabled = true;
    emit AutomationDisabled(true);
  }

  /// @inheritdoc IWorkflowsBase
  function isDisabled() public view returns (bool) {
    return _automationDisabled;
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IWorkflowsBase).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev The robot's `onReport`, only reached while automation is enabled.
  function _onReport(bytes calldata metadata, bytes calldata report) internal virtual;

  /// @dev The robot's `checkUpkeep`, only reached while `_isUpkeepAllowed` holds.
  function _checkUpkeep(
    bytes calldata checkData
  ) internal view virtual returns (bool upkeepNeeded, bytes memory performData);

  /// @dev Gate checked before `_checkUpkeep`; extensions add conditions through `super`.
  function _isUpkeepAllowed() internal view virtual returns (bool) {
    return !_automationDisabled;
  }

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
