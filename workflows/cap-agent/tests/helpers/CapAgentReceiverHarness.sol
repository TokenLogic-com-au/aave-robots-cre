// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CapAgentReceiver} from '../../src/CapAgentReceiver.sol';
import {IAgentHub} from '../../src/ICapAgentReceiver.sol';

/// @dev Exposes `_executableAgents`, `_capActions` and `_enabledActions` to the tests.
contract CapAgentReceiverHarness is CapAgentReceiver {
  constructor(
    address agentHub_,
    address initialOwner_,
    address initialGuardian_,
    uint256[] memory initialAgentIds_
  ) CapAgentReceiver(agentHub_, initialOwner_, initialGuardian_, initialAgentIds_) {}

  function executableAgents() external view returns (uint256[] memory) {
    return _executableAgents();
  }

  function capActions(
    IAgentHub.ActionData[] memory actions
  ) external pure returns (IAgentHub.ActionData[] memory) {
    return _capActions(actions);
  }

  function enabledActions(
    IAgentHub.ActionData[] memory actions
  ) external view returns (IAgentHub.ActionData[] memory) {
    return _enabledActions(actions);
  }
}
