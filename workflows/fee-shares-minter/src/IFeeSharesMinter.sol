// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @title IFeeSharesMinter
/// @notice Robot that mints accrued fee shares on Aave v4 Hubs once an
/// owner-configured per-(hub, asset) ratio is crossed. `checkData` and `report`
/// are both `abi.encode(HubAssetPair[])`.
interface IFeeSharesMinter is IAaveCREReceiver {
  struct HubAssetPair {
    address hub;
    uint256 assetId;
  }

  /// @notice Emitted when the fees-to-assets threshold for a (hub, asset) pair is updated.
  /// @param hub Hub the threshold applies to.
  /// @param assetId Asset identifier within `hub`.
  /// @param feesToAssetsThreshold New threshold in BPS.
  event FeesToAssetsThresholdUpdated(
    address indexed hub,
    uint256 indexed assetId,
    uint16 feesToAssetsThreshold
  );

  /// @notice Thrown when `canMint` is queried for a pair with no threshold set.
  /// @param hub Hub queried.
  /// @param assetId Asset identifier within `hub`.
  error NotConfigured(address hub, uint256 assetId);

  /// @notice Thrown when `onReport` runs but no pair in the batch was mintable.
  error ConditionsNotMet();

  /// @notice Thrown when `updateFeesToAssetsThreshold` is called with a value outside `(0, PercentageMath.PERCENTAGE_FACTOR]`.
  /// @param feesToAssetsThreshold Rejected value.
  error InvalidFeesToAssetsThreshold(uint16 feesToAssetsThreshold);

  /// @notice Set the fees-to-assets threshold for a (hub, asset) pair. Owner-only.
  /// @param hub Hub the threshold applies to.
  /// @param assetId Asset identifier within `hub`. Must be listed on the hub.
  /// @param feesToAssetsThreshold Threshold in BPS, in `(0, PercentageMath.PERCENTAGE_FACTOR]`.
  function updateFeesToAssetsThreshold(
    address hub,
    uint256 assetId,
    uint16 feesToAssetsThreshold
  ) external;

  /// @notice Disable fee shares minting for a (hub, asset) pair. Owner or guardian.
  /// @param hub Hub the threshold applies to.
  /// @param assetId Asset identifier within `hub`.
  function disableFeeSharesMinting(address hub, uint256 assetId) external;

  /// @notice Returns the fees-to-assets threshold for a (hub, asset) pair, in BPS.
  /// @param hub Hub the threshold applies to.
  /// @param assetId Asset identifier within `hub`.
  function getFeesToAssetsThreshold(address hub, uint256 assetId) external view returns (uint16);

  /// @notice Returns whether `onReport` would mint fee shares for a (hub, asset) pair.
  /// @param hub Hub to evaluate against.
  /// @param assetId Asset identifier within `hub`.
  function canMint(address hub, uint256 assetId) external view returns (bool);

  /// @notice The sentinel value used to disable minting for a (hub, asset) pair.
  function DISABLED_THRESHOLD() external pure returns (uint16);
}
