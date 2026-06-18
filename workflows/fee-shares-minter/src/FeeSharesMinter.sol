// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {PercentageMath} from 'aave-v4/libraries/math/PercentageMath.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';
import {IHub} from 'aave-v4/hub/interfaces/IHub.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IFeeSharesMinter} from './IFeeSharesMinter.sol';

/// @title FeeSharesMinter
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and mints fee shares on the hub when the configured threshold is crossed.
/// @dev The contract must hold `HUB_FEE_MINTER_ROLE` on each target hub to call `IHub.mintFeeShares`.
contract FeeSharesMinter is IFeeSharesMinter, OwnableWithGuardian, Rescuable {
  using PercentageMath for uint256;

  /// @inheritdoc IFeeSharesMinter
  uint16 public constant override DISABLED_THRESHOLD = type(uint16).max;

  mapping(address hub => mapping(uint256 assetId => uint16)) internal _feesToAssetsThreshold;

  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address initialOwner_,
    address initialGuardian_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {}

  /// @inheritdoc IFeeSharesMinter
  function updateFeesToAssetsThreshold(
    address hub,
    uint256 assetId,
    uint16 feesToAssetsThreshold
  ) external onlyOwner {
    require(
      _isActiveThreshold(feesToAssetsThreshold),
      InvalidFeesToAssetsThreshold(feesToAssetsThreshold)
    );
    require(assetId < IHub(hub).getAssetCount(), IHub.AssetNotListed());
    _feesToAssetsThreshold[hub][assetId] = feesToAssetsThreshold;
    emit FeesToAssetsThresholdUpdated(hub, assetId, feesToAssetsThreshold);
  }

  /// @inheritdoc IFeeSharesMinter
  function disableFeeSharesMinting(address hub, uint256 assetId) external onlyOwnerOrGuardian {
    _feesToAssetsThreshold[hub][assetId] = DISABLED_THRESHOLD;
    emit FeesToAssetsThresholdUpdated(hub, assetId, DISABLED_THRESHOLD);
  }

  /// @inheritdoc IReceiver
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    HubAssetPair[] memory pairs = abi.decode(report, (HubAssetPair[]));
    uint256 minted = 0;
    for (uint256 i = 0; i < pairs.length; i++) {
      if (!_canMint(pairs[i].hub, pairs[i].assetId)) continue;
      IHub(pairs[i].hub).mintFeeShares(pairs[i].assetId);
      minted++;
    }
    require(minted > 0, ConditionsNotMet());
  }

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata checkData
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    HubAssetPair[] memory pairs = abi.decode(checkData, (HubAssetPair[]));
    HubAssetPair[] memory buffer = new HubAssetPair[](pairs.length);
    uint256 count = 0;
    for (uint256 i = 0; i < pairs.length; i++) {
      if (_canMint(pairs[i].hub, pairs[i].assetId)) {
        buffer[count++] = pairs[i];
      }
    }
    HubAssetPair[] memory mintable = new HubAssetPair[](count);
    for (uint256 i = 0; i < count; i++) mintable[i] = buffer[i];
    return (count > 0, abi.encode(mintable));
  }

  /// @inheritdoc IFeeSharesMinter
  function getFeesToAssetsThreshold(address hub, uint256 assetId) external view returns (uint16) {
    return _feesToAssetsThreshold[hub][assetId];
  }

  /// @inheritdoc IFeeSharesMinter
  function canMint(address hub, uint256 assetId) external view returns (bool) {
    require(_feesToAssetsThreshold[hub][assetId] != 0, NotConfigured(hub, assetId));
    return _canMint(hub, assetId);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev Returns true only when every mint condition holds for the (hub, asset):
  /// - an active threshold is set (in `(0, PercentageMath.PERCENTAGE_FACTOR]`);
  /// - the hub has added assets for the id (`getAddedAssets > 0`);
  /// - the accrued-fees-to-added-assets ratio is at least the threshold;
  /// - the accrued fees preview to a non-zero amount of shares (`previewAddByAssets > 0`).
  function _canMint(address hub, uint256 assetId) internal view virtual returns (bool) {
    uint16 feesToAssetsThreshold = _feesToAssetsThreshold[hub][assetId];
    if (!_isActiveThreshold(feesToAssetsThreshold)) return false;

    IHub targetHub = IHub(hub);
    uint256 accruedFees = targetHub.getAssetAccruedFees(assetId);
    uint256 totalAddedAssets = targetHub.getAddedAssets(assetId);

    if (totalAddedAssets == 0) return false;
    if (accruedFees.percentDivDown(totalAddedAssets) < feesToAssetsThreshold) return false;

    return targetHub.previewAddByAssets(assetId, accruedFees) > 0;
  }

  function _isActiveThreshold(uint16 feesToAssetsThreshold) internal pure returns (bool) {
    return feesToAssetsThreshold > 0 && feesToAssetsThreshold <= PercentageMath.PERCENTAGE_FACTOR;
  }

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
