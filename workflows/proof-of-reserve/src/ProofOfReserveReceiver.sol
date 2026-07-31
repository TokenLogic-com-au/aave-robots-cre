// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IProofOfReserveReceiver, IProofOfReserveExecutor} from './IProofOfReserveReceiver.sol';

/// @title ProofOfReserveReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and runs a Proof of Reserve
/// executor's emergency action when a reserve becomes unbacked. Native CRE
/// re-implementation of BGD Labs' `ProofOfReserveKeeper`.
/// @dev `executeEmergencyAction` is permissionless (gated by the executor's own
/// backing check), so this contract needs no on-chain role. It only reads state
/// and forwards the call.
contract ProofOfReserveReceiver is IProofOfReserveReceiver, OwnableWithGuardian {
  mapping(address executor => bool) internal _disabled;

  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address initialOwner_,
    address initialGuardian_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {}

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata checkData
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    address executor = abi.decode(checkData, (address));
    if (!_shouldExecute(executor)) return (false, '');
    return (true, abi.encode(executor));
  }

  /// @inheritdoc IReceiver
  /// @dev Re-validates the executor so a stale report can't force a pointless run.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    address executor = abi.decode(report, (address));
    require(_shouldExecute(executor), EmergencyActionNotPossible());
    IProofOfReserveExecutor(executor).executeEmergencyAction();
    emit EmergencyActionExecuted(executor);
  }

  /// @inheritdoc IProofOfReserveReceiver
  function isDisabled(address executor) public view returns (bool) {
    return _disabled[executor];
  }

  /// @inheritdoc IProofOfReserveReceiver
  function setDisabled(address executor, bool disabled) external onlyOwnerOrGuardian {
    _disabled[executor] = disabled;
    emit ExecutorDisabled(executor, disabled);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev The emergency action should run when the executor is enabled for
  /// automation, not all of its reserves are backed, and the action would change
  /// state.
  function _shouldExecute(address executor) internal view returns (bool) {
    if (executor == address(0) || _disabled[executor]) return false;
    IProofOfReserveExecutor e = IProofOfReserveExecutor(executor);
    return !e.areAllReservesBacked() && e.isEmergencyActionPossible();
  }
}
