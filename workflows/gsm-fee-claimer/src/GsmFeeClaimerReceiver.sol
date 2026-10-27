// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {IGsmFeeClaimerReceiver, IGsmFees} from './IGsmFeeClaimerReceiver.sol';

/// @title GsmFeeClaimerReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and sends accrued GSM fees to the
/// GHO treasury.
/// @dev `onReport` is permissionless, like `distributeFeesToTreasury` itself, and the
/// GSM emits the authoritative `FeesDistributedToTreasury` event.
contract GsmFeeClaimerReceiver is IGsmFeeClaimerReceiver, WorkflowsBase {
  /// @dev Size of the ABI-encoded `getAccruedFees` return value.
  uint256 internal constant FEES_RETURN_LENGTH = 32;

  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address initialOwner_,
    address initialGuardian_
  ) WorkflowsBase(initialOwner_, initialGuardian_) {}

  /// @dev A reverting GSM reverts the whole report; the workflow's gas estimate skips it.
  function _onReport(bytes calldata /* metadata */, bytes calldata report) internal override {
    address[] memory gsms = abi.decode(report, (address[]));
    for (uint256 i = 0; i < gsms.length; i++) {
      IGsmFees(gsms[i]).distributeFeesToTreasury();
    }
  }

  function _checkUpkeep(
    bytes calldata checkData
  ) internal view override returns (bool upkeepNeeded, bytes memory performData) {
    if (checkData.length == 0) return (false, '');
    (address[] memory gsms, uint256 minFees) = abi.decode(checkData, (address[], uint256));

    address[] memory buffer = new address[](gsms.length);
    uint256 count;
    for (uint256 i = 0; i < gsms.length; i++) {
      uint256 fees = _accruedFees(gsms[i]);
      if (fees > 0 && fees >= minFees) buffer[count++] = gsms[i];
    }
    if (count == 0) return (false, '');

    address[] memory withFees = new address[](count);
    for (uint256 i = 0; i < count; i++) withFees[i] = buffer[i];
    return (true, abi.encode(withFees));
  }

  /// @dev A GSM that reverts, has no code or returns no data is treated as having no
  /// fees, so one bad entry in `checkData` cannot block the others. A low-level call is
  /// used because `try` only catches reverts inside the callee, not a failed decode.
  function _accruedFees(address gsm) internal view returns (uint256) {
    (bool ok, bytes memory data) = gsm.staticcall(abi.encodeCall(IGsmFees.getAccruedFees, ()));
    return ok && data.length == FEES_RETURN_LENGTH ? abi.decode(data, (uint256)) : 0;
  }
}
