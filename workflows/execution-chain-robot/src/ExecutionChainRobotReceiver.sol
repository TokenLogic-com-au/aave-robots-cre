// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPayloadsControllerCore} from 'aave-address-book/governance-v3/IPayloadsControllerCore.sol';

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {GasCappedWorkflowsBase} from 'aave-cre/GasCappedWorkflowsBase.sol';
import {IdDenylist} from 'aave-cre/IdDenylist.sol';
import {IExecutionChainRobotReceiver} from './IExecutionChainRobotReceiver.sol';

/// @title ExecutionChainRobotReceiver
/// @author Aave Labs
/// @notice Native CRE port of BGD's `ExecutionChainRobotKeeper` and, with a gas price oracle,
/// `GasCappedExecutionChainRobotKeeper`: executes Governance V3 payloads past their timelock.
/// @dev Needs no on-chain role: `PayloadsController.executePayload` is permissionless.
contract ExecutionChainRobotReceiver is
  IExecutionChainRobotReceiver,
  GasCappedWorkflowsBase,
  IdDenylist
{
  /// @inheritdoc IExecutionChainRobotReceiver
  uint256 public constant override MAX_ACTIONS = 5;

  /// @inheritdoc IExecutionChainRobotReceiver
  uint256 public constant override MAX_SKIP = 20;

  /// @inheritdoc IExecutionChainRobotReceiver
  uint256 public constant override MAX_SCANNED_PAYLOADS = 100;

  /// @inheritdoc IExecutionChainRobotReceiver
  uint256 public constant override MAX_STATE_READ_GAS = 150_000;

  /// @inheritdoc IExecutionChainRobotReceiver
  IPayloadsControllerCore public immutable override PAYLOADS_CONTROLLER;

  /// @param payloadsController_ The PayloadsController whose payloads to execute.
  /// @param gasPriceOracle_ Chainlink gas price feed, or the zero address for no cap.
  /// @param maxGasPrice_ The initial gas price cap, in wei. Must be 0 without an oracle.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address payloadsController_,
    address gasPriceOracle_,
    uint256 maxGasPrice_,
    address initialOwner_,
    address initialGuardian_
  )
    WorkflowsBase(initialOwner_, initialGuardian_)
    GasCappedWorkflowsBase(gasPriceOracle_, maxGasPrice_)
  {
    require(payloadsController_ != address(0), InvalidPayloadsController());

    PAYLOADS_CONTROLLER = IPayloadsControllerCore(payloadsController_);
  }

  /// @dev Permissionless. Executes exactly the payloads in the report, in order, skipping the
  /// disabled and the no longer executable ones; reverts `NoActionCanBePerformed` if none was
  /// executed, so a stale report fails `estimateGas`.
  function _onReport(bytes calldata /* metadata */, bytes calldata report) internal override {
    uint40[] memory payloadIds = abi.decode(report, (uint40[]));
    bool executed = false;

    for (uint256 i = 0; i < payloadIds.length; i++) {
      uint40 payloadId = payloadIds[i];
      if (isIdDisabled(payloadId) || !_canPayloadBeExecuted(payloadId)) continue;
      PAYLOADS_CONTROLLER.executePayload(payloadId);
      executed = true;
      emit ActionSucceeded(payloadId);
    }
    require(executed, NoActionCanBePerformed());
  }

  /// @dev Walks back from the latest payload until `MAX_SKIP` + 1 consecutive non-executable
  /// ones, `MAX_ACTIONS` found or `MAX_SCANNED_PAYLOADS` scanned. A `Queued` payload past its
  /// delay is collected and resets the count; one still in its timelock, or `Executed`,
  /// `Cancelled` or `Expired`, counts. `Created` ones don't count, since anyone can create
  /// payloads, nor do disabled ones or ones whose state can't be read within
  /// `MAX_STATE_READ_GAS`.
  function _checkUpkeep(
    bytes calldata /* checkData */
  ) internal view override returns (bool, bytes memory) {
    uint40[] memory found = new uint40[](MAX_ACTIONS);
    uint256 count = 0;
    uint256 skipCount = 0;
    uint256 scanned = 0;
    uint40 index = PAYLOADS_CONTROLLER.getPayloadsCount();

    while (
      index != 0 && skipCount <= MAX_SKIP && count < MAX_ACTIONS && scanned < MAX_SCANNED_PAYLOADS
    ) {
      index--;
      scanned++;
      if (isIdDisabled(index)) continue;

      // `getPayloadState` copies the whole payload, so junk with large actions could otherwise
      // push checkUpkeep past the eth_call gas cap.
      IPayloadsControllerCore.PayloadState state;
      try PAYLOADS_CONTROLLER.getPayloadState{gas: MAX_STATE_READ_GAS}(index) returns (
        IPayloadsControllerCore.PayloadState s
      ) {
        state = s;
      } catch {
        continue;
      }

      if (state == IPayloadsControllerCore.PayloadState.Queued) {
        if (_isPastDelay(index)) {
          found[count++] = index;
          skipCount = 0;
        } else {
          skipCount++;
        }
      } else if (state != IPayloadsControllerCore.PayloadState.Created) {
        skipCount++;
      }
    }
    if (count == 0) return (false, '');

    // Oldest first, so payloads of one proposal execute in creation order.
    uint40[] memory payloadIds = new uint40[](count);
    for (uint256 i = 0; i < count; i++) payloadIds[i] = found[count - 1 - i];
    return (true, abi.encode(payloadIds));
  }

  /// @dev Same condition `executePayload` enforces: queued (not expired) and past its delay.
  function _canPayloadBeExecuted(uint40 payloadId) internal view returns (bool) {
    return
      PAYLOADS_CONTROLLER.getPayloadState(payloadId) ==
      IPayloadsControllerCore.PayloadState.Queued &&
      _isPastDelay(payloadId);
  }

  /// @dev Only called on queued payloads, so the full payload is never loaded for junk ones.
  function _isPastDelay(uint40 payloadId) internal view returns (bool) {
    IPayloadsControllerCore.Payload memory payload = PAYLOADS_CONTROLLER.getPayloadById(payloadId);
    return block.timestamp > payload.queuedAt + payload.delay;
  }
}
