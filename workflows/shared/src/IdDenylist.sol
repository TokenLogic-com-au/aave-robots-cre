// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';

import {IIdDenylist} from './IIdDenylist.sol';

/// @title IdDenylist
/// @author Aave Labs
/// @notice Lets the owner or guardian exclude single ids from automation, e.g. a proposal the
/// robot should leave alone. Mixed into a `WorkflowsBase` robot next to its global switch.
/// @dev Not a `WorkflowsBase` itself so it combines with `GasCappedWorkflowsBase` without
/// override boilerplate. Robots skip ids for which `isDisabled(id)` holds in both
/// `_checkUpkeep` and `_onReport`.
abstract contract IdDenylist is OwnableWithGuardian, IIdDenylist {
  mapping(uint256 id => bool) internal _disabledIds;

  /// @inheritdoc IIdDenylist
  function enableAutomation(uint256 id) external onlyOwner {
    require(_disabledIds[id], AutomationStatusUnchanged(id));
    _disabledIds[id] = false;
    emit AutomationDisabled(id, false);
  }

  /// @inheritdoc IIdDenylist
  function disableAutomation(uint256 id) external onlyOwnerOrGuardian {
    require(!_disabledIds[id], AutomationStatusUnchanged(id));
    _disabledIds[id] = true;
    emit AutomationDisabled(id, true);
  }

  /// @inheritdoc IIdDenylist
  function isDisabled(uint256 id) public view returns (bool) {
    return _disabledIds[id];
  }
}
