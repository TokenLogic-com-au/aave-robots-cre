// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IProofOfReserveReceiver, IProofOfReserveExecutor} from './IProofOfReserveReceiver.sol';

/// @title ProofOfReserveReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and runs a Proof of Reserve
/// executor's emergency action when a reserve becomes unbacked. Native CRE
/// re-implementation of BGD Labs' `ProofOfReserveKeeper`.
/// @dev Needs no on-chain role: `executeEmergencyAction` is permissionless.
contract ProofOfReserveReceiver is IProofOfReserveReceiver, OwnableWithGuardian, Rescuable {
  mapping(address executor => bool) internal _enabled;

  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  /// @param initialExecutors_ The executors enabled for automation at deployment.
  constructor(
    address initialOwner_,
    address initialGuardian_,
    address[] memory initialExecutors_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
    for (uint256 i = 0; i < initialExecutors_.length; i++) {
      _enableExecutor(initialExecutors_[i]);
    }
  }

  /// @inheritdoc IProofOfReserveReceiver
  function enableExecutor(address executor) external onlyOwner {
    _enableExecutor(executor);
  }

  /// @inheritdoc IProofOfReserveReceiver
  function disableExecutor(address executor) external onlyOwnerOrGuardian {
    require(_enabled[executor], ExecutorStatusUnchanged(executor, false));
    _enabled[executor] = false;
    emit ExecutorStatusUpdated(executor, false);
  }

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
  function isExecutorEnabled(address executor) external view returns (bool) {
    return _enabled[executor];
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  function _enableExecutor(address executor) internal {
    require(executor != address(0), InvalidExecutor());
    require(!_enabled[executor], ExecutorStatusUnchanged(executor, true));
    _enabled[executor] = true;
    emit ExecutorStatusUpdated(executor, true);
  }

  /// @dev Returns true only when:
  /// - the executor is enabled (the zero address never is);
  /// - not all of its reserves are backed;
  /// - the emergency action would change state.
  function _shouldExecute(address executor) internal view returns (bool) {
    if (!_enabled[executor]) return false;
    IProofOfReserveExecutor e = IProofOfReserveExecutor(executor);
    return !e.areAllReservesBacked() && e.isEmergencyActionPossible();
  }

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
