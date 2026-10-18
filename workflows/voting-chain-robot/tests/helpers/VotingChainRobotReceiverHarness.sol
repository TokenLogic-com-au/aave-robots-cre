// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';

import {VotingChainRobotReceiver} from '../../src/VotingChainRobotReceiver.sol';

/// @dev Exposes the internal decision functions to the tests.
contract VotingChainRobotReceiverHarness is VotingChainRobotReceiver {
  constructor(
    address votingMachine_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  )
    VotingChainRobotReceiver(
      votingMachine_,
      gasPriceOracle_,
      maxGasPrice_,
      initialOwner_,
      initialGuardian_
    )
  {}

  function getAction(uint256 proposalId) external view returns (bool, ProposalAction) {
    return _getAction(proposalId);
  }

  function canCreateVote(
    IVotingMachineWithProofs.ProposalState state,
    uint256 proposalId
  ) external view returns (bool) {
    return _canCreateVote(state, proposalId);
  }

  function hasRequiredRoots(bytes32 blockHash) external view returns (bool) {
    return _hasRequiredRoots(blockHash);
  }
}
