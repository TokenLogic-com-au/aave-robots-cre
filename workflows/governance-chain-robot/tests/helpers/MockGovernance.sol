// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IGovernanceCore} from 'aave-address-book/governance-v3/IGovernanceCore.sol';
import {PayloadsControllerUtils} from 'aave-address-book/governance-v3/PayloadsControllerUtils.sol';

/// @dev The subset of Governance V3 the robot reads and calls. Also acts as its own power
/// strategy. Actions only flip the stored state; `revertOn` makes one revert.
contract MockGovernance {
  uint256 public constant PRECISION_DIVIDER = 1 ether;

  uint256 public COOLDOWN_PERIOD;

  mapping(uint256 => IGovernanceCore.Proposal) internal _proposals;
  uint256 internal _count;

  mapping(PayloadsControllerUtils.AccessControl => IGovernanceCore.VotingConfig) internal _configs;

  mapping(address => uint256) public propositionPower;

  mapping(uint256 => bool) public revertOn;

  function setProposal(uint256 id, IGovernanceCore.State state, uint40 creationTime) external {
    _proposals[id].state = state;
    _proposals[id].accessLevel = PayloadsControllerUtils.AccessControl.Level_1;
    _proposals[id].creationTime = creationTime;
    if (id >= _count) _count = id + 1;
  }

  function setCreator(uint256 id, address creator) external {
    _proposals[id].creator = creator;
  }

  function setQueuingTime(uint256 id, uint40 queuingTime) external {
    _proposals[id].queuingTime = queuingTime;
  }

  function setVotingConfig(
    PayloadsControllerUtils.AccessControl level,
    IGovernanceCore.VotingConfig memory config
  ) external {
    _configs[level] = config;
  }

  function setCooldownPeriod(uint256 cooldown) external {
    COOLDOWN_PERIOD = cooldown;
  }

  function setPropositionPower(address user, uint256 power) external {
    propositionPower[user] = power;
  }

  function setRevertOn(uint256 id, bool shouldRevert) external {
    revertOn[id] = shouldRevert;
  }

  function getProposalsCount() external view returns (uint256) {
    return _count;
  }

  function getProposal(uint256 id) external view returns (IGovernanceCore.Proposal memory) {
    return _proposals[id];
  }

  function getVotingConfig(
    PayloadsControllerUtils.AccessControl level
  ) external view returns (IGovernanceCore.VotingConfig memory) {
    return _configs[level];
  }

  function getPowerStrategy() external view returns (address) {
    return address(this);
  }

  function getFullPropositionPower(address user) external view returns (uint256) {
    return propositionPower[user];
  }

  function activateVoting(uint256 id) external {
    _act(id, IGovernanceCore.State.Active);
  }

  function executeProposal(uint256 id) external {
    _act(id, IGovernanceCore.State.Executed);
  }

  function cancelProposal(uint256 id) external {
    _act(id, IGovernanceCore.State.Cancelled);
  }

  function _act(uint256 id, IGovernanceCore.State newState) internal {
    require(!revertOn[id], 'mock revert');
    _proposals[id].state = newState;
  }
}
