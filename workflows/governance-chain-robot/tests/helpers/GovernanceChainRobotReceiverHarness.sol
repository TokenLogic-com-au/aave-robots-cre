// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IGovernanceCore} from 'aave-address-book/governance-v3/IGovernanceCore.sol';

import {GovernanceChainRobotReceiver} from '../../src/GovernanceChainRobotReceiver.sol';

/// @dev Exposes the proposal predicates to the tests.
contract GovernanceChainRobotReceiverHarness is GovernanceChainRobotReceiver {
  constructor(
    address governance_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  )
    GovernanceChainRobotReceiver(
      governance_,
      gasPriceOracle_,
      maxGasPrice_,
      initialOwner_,
      initialGuardian_
    )
  {}

  function isProposalInFinalState(IGovernanceCore.State state) external pure returns (bool) {
    return _isProposalInFinalState(state);
  }

  function canVotingBeActivated(
    IGovernanceCore.Proposal memory proposal
  ) external view returns (bool) {
    return _canVotingBeActivated(proposal);
  }

  function canProposalBeExecuted(
    IGovernanceCore.Proposal memory proposal
  ) external view returns (bool) {
    return _canProposalBeExecuted(proposal);
  }

  function canProposalBeCancelled(
    IGovernanceCore.Proposal memory proposal
  ) external view returns (bool) {
    return _canProposalBeCancelled(proposal);
  }
}
