// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IWorkflowsBase} from 'aave-cre/IWorkflowsBase.sol';

/// @notice Minimal view of a GHO GSM (Gho Stability Module) fee surface.
interface IGsmFees {
  /// @notice Sends the accrued fees to the GHO treasury. Permissionless, no-op without fees.
  function distributeFeesToTreasury() external;

  /// @notice Fees accrued by the GSM and not yet sent to the GHO treasury.
  function getAccruedFees() external view returns (uint256);
}

/// @title IGsmFeeClaimerReceiver
/// @notice Robot that pushes accrued GSM fees to the GHO treasury.
/// @dev `checkData` is `abi.encode(address[] gsms, uint256 minFees)`. `checkUpkeep`
/// returns the GSMs holding at least `minFees` as `abi.encode(address[])`, which the
/// workflow signs and passes as `report`.
interface IGsmFeeClaimerReceiver is IWorkflowsBase {}
