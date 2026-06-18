// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IReceiver} from './IReceiver.sol';

/// @title IAaveCREReceiver
/// @notice Base interface every Aave CRE robot implements. The off-chain
/// workflow calls `checkUpkeep`; when `upkeepNeeded` is true it signs the
/// returned `performData` and submits it as the `report` argument of `onReport`.
interface IAaveCREReceiver is IReceiver {
  /// @notice Read-only probe for the off-chain workflow.
  /// @param checkData Per-workflow payload (e.g. abi-encoded targets). `0x` if unused.
  /// @return upkeepNeeded Whether `onReport` would succeed at this moment.
  /// @return performData Bytes the workflow should sign and pass as `report`.
  function checkUpkeep(
    bytes calldata checkData
  ) external view returns (bool upkeepNeeded, bytes memory performData);
}
