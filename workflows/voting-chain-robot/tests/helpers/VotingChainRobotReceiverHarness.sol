// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';

import {VotingChainRobotReceiver} from '../../src/VotingChainRobotReceiver.sol';

/// @dev Exposes the internal decision functions to the tests.
contract VotingChainRobotReceiverHarness is VotingChainRobotReceiver {
  constructor(
    address votingMachine_,
    address rootsConsumer_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  )
    VotingChainRobotReceiver(
      votingMachine_,
      rootsConsumer_,
      gasPriceOracle_,
      maxGasPrice_,
      initialOwner_,
      initialGuardian_
    )
  {}

  function getAction(uint256 proposalId) external view returns (bool, ProposalAction) {
    return _getAction(proposalId);
  }

  function canSubmitRoots(
    IVotingMachineWithProofs.ProposalState state,
    bytes32 blockHash
  ) external view returns (bool) {
    return _canSubmitRoots(state, blockHash);
  }

  function canCreateVote(
    IVotingMachineWithProofs.ProposalState state,
    bytes32 blockHash
  ) external view returns (bool) {
    return _canCreateVote(state, blockHash);
  }

  function hasRequiredRoots(bytes32 blockHash) external view returns (bool) {
    return _hasRequiredRoots(blockHash);
  }

  function setRootsRequested(bytes32 blockHash, bool requested) external {
    _rootsRequested[blockHash] = requested;
  }
}
