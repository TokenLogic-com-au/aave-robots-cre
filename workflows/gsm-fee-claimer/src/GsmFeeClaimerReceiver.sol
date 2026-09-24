// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IGsmFeeClaimerReceiver, IGsmFees} from './IGsmFeeClaimerReceiver.sol';

/// @title GsmFeeClaimerReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and sends accrued GSM fees to the
/// GHO treasury.
/// @dev `onReport` is permissionless, like `distributeFeesToTreasury` itself. The
/// contract never holds tokens (the GSM pays the treasury directly), so it is not
/// `Rescuable`.
contract GsmFeeClaimerReceiver is IGsmFeeClaimerReceiver, OwnableWithGuardian {
  bool internal _disabled;

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
    if (_disabled || checkData.length == 0) return (false, '');
    address[] memory gsms = abi.decode(checkData, (address[]));

    address[] memory buffer = new address[](gsms.length);
    uint256 count;
    for (uint256 i = 0; i < gsms.length; i++) {
      if (_accruedFees(gsms[i]) > 0) buffer[count++] = gsms[i];
    }
    if (count == 0) return (false, '');

    address[] memory withFees = new address[](count);
    for (uint256 i = 0; i < count; i++) withFees[i] = buffer[i];
    return (true, abi.encode(withFees));
  }

  /// @inheritdoc IReceiver
  /// @dev Re-reads every GSM's fees, so a stale report can't distribute what isn't there.
  /// A single reverting GSM does not block the rest of the batch.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    if (_disabled) revert Disabled();
    address[] memory gsms = abi.decode(report, (address[]));

    uint256 distributed;
    for (uint256 i = 0; i < gsms.length; i++) {
      uint256 fees = _accruedFees(gsms[i]);
      if (fees == 0) continue;
      try IGsmFees(gsms[i]).distributeFeesToTreasury() {
        emit FeesDistributed(gsms[i], fees);
        distributed++;
      } catch (bytes memory reason) {
        emit FeeDistributionFailed(gsms[i], reason);
      }
    }
    if (distributed == 0) revert NothingToDistribute();
  }

  /// @inheritdoc IGsmFeeClaimerReceiver
  function isDisabled() public view returns (bool) {
    return _disabled;
  }

  /// @inheritdoc IGsmFeeClaimerReceiver
  function setDisabled(bool disabled) external onlyOwnerOrGuardian {
    require(_disabled != disabled, StateUnchanged());
    _disabled = disabled;
    emit AutomationDisabled(disabled);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev A GSM that reverts, has no code, or returns no data (an EOA with EIP-7702
  /// delegation, a wrong contract) is treated as having no fees, so one bad entry in
  /// `checkData` cannot block the others. A low-level call is used because `try` only
  /// catches reverts inside the callee, not a failed decode in the caller.
  function _accruedFees(address gsm) internal view returns (uint256) {
    (bool ok, bytes memory data) = gsm.staticcall(abi.encodeCall(IGsmFees.getAccruedFees, ()));
    return ok && data.length == 32 ? abi.decode(data, (uint256)) : 0;
  }
}
