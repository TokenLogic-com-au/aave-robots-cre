// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPool} from 'aave-v3-origin/contracts/interfaces/IPool.sol';
import {IAaveOracle} from 'aave-v3-origin/contracts/interfaces/IAaveOracle.sol';
import {DataTypes} from 'aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from 'aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {WadRayMath} from 'aave-v3-origin/contracts/protocol/libraries/math/WadRayMath.sol';

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {IMintToTreasuryReceiver} from './IMintToTreasuryReceiver.sol';

/// @title MintToTreasuryReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and mints the amounts accrued to the treasury
/// on Aave v3 pools once their USD value crosses the configured per-pool threshold.
/// @dev `onReport` is permissionless, like `IPool.mintToTreasury` itself, so the robot needs no
/// role on the pools.
contract MintToTreasuryReceiver is IMintToTreasuryReceiver, WorkflowsBase {
  using WadRayMath for uint256;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  /// @inheritdoc IMintToTreasuryReceiver
  uint256 public constant override DISABLED_THRESHOLD = type(uint256).max;

  mapping(address pool => uint256 usdThreshold) internal _usdThreshold;

  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  /// @param initialThresholds_ The pools enabled at deployment, with their USD thresholds.
  constructor(
    address initialOwner_,
    address initialGuardian_,
    PoolThreshold[] memory initialThresholds_
  ) WorkflowsBase(initialOwner_, initialGuardian_) {
    for (uint256 i = 0; i < initialThresholds_.length; i++) {
      _updateUsdThreshold(initialThresholds_[i].pool, initialThresholds_[i].usdThreshold);
    }
  }

  /// @inheritdoc IMintToTreasuryReceiver
  function updateUsdThreshold(address pool, uint256 usdThreshold) external onlyOwner {
    _updateUsdThreshold(pool, usdThreshold);
  }

  /// @inheritdoc IMintToTreasuryReceiver
  function disableMinting(address pool) external onlyOwnerOrGuardian {
    _usdThreshold[pool] = DISABLED_THRESHOLD;
    emit UsdThresholdUpdated(pool, DISABLED_THRESHOLD);
  }

  /// @inheritdoc IMintToTreasuryReceiver
  function getUsdThreshold(address pool) external view returns (uint256) {
    return _usdThreshold[pool];
  }

  /// @inheritdoc IMintToTreasuryReceiver
  function getAccruedUsd(address pool) external view returns (uint256) {
    (uint256 accruedUsd, ) = _getAccrued(pool);
    return accruedUsd;
  }

  /// @inheritdoc IMintToTreasuryReceiver
  function canMint(address pool) external view returns (bool) {
    require(_usdThreshold[pool] != 0, NotConfigured(pool));
    (bool mintable, ) = _canMint(pool);
    return mintable;
  }

  /// @dev Skips pools no longer mintable and reverts `ConditionsNotMet` if none is left, so a
  /// stale report fails `estimateGas`.
  function _onReport(bytes calldata /* metadata */, bytes calldata report) internal override {
    address[] memory pools = abi.decode(report, (address[]));
    bool minted = false;

    for (uint256 i = 0; i < pools.length; i++) {
      (bool mintable, address[] memory assets) = _canMint(pools[i]);
      if (!mintable) continue;

      IPool(pools[i]).mintToTreasury(assets);
      minted = true;
    }

    require(minted, ConditionsNotMet());
  }

  function _checkUpkeep(
    bytes calldata checkData
  ) internal view override returns (bool upkeepNeeded, bytes memory performData) {
    if (checkData.length == 0) return (false, '');
    address[] memory pools = abi.decode(checkData, (address[]));

    address[] memory buffer = new address[](pools.length);
    uint256 count = 0;
    for (uint256 i = 0; i < pools.length; i++) {
      (bool mintable, ) = _canMint(pools[i]);
      if (mintable) buffer[count++] = pools[i];
    }
    if (count == 0) return (false, '');

    address[] memory mintablePools = new address[](count);
    for (uint256 i = 0; i < count; i++) mintablePools[i] = buffer[i];
    return (true, abi.encode(mintablePools));
  }

  function _updateUsdThreshold(address pool, uint256 usdThreshold) internal {
    require(
      usdThreshold != 0 && usdThreshold != DISABLED_THRESHOLD,
      InvalidUsdThreshold(usdThreshold)
    );
    _usdThreshold[pool] = usdThreshold;
    emit UsdThresholdUpdated(pool, usdThreshold);
  }

  /// @dev Whether the pool has an active threshold that its accrued USD value reaches, and the
  /// reserves to pass to `mintToTreasury`.
  function _canMint(address pool) internal view returns (bool, address[] memory) {
    uint256 usdThreshold = _usdThreshold[pool];
    if (usdThreshold == 0 || usdThreshold == DISABLED_THRESHOLD) {
      return (false, new address[](0));
    }

    (uint256 accruedUsd, address[] memory assets) = _getAccrued(pool);
    return (assets.length > 0 && accruedUsd >= usdThreshold, assets);
  }

  /// @dev Sums the value of every active reserve's `accruedToTreasury`, stored scaled, so it is
  /// converted with the reserve's normalized income as `mintToTreasury` does. A reserve whose
  /// price reverts or is zero adds no value but is still returned in `assets`.
  /// `getReserveData` returns the same layout on every v3 pool version (`ReserveDataLegacy`
  /// since v3.3), so one decoding works from v3.0 to v3.7.
  function _getAccrued(
    address pool
  ) internal view returns (uint256 accruedUsd, address[] memory assets) {
    IPool targetPool = IPool(pool);
    IAaveOracle oracle = IAaveOracle(targetPool.ADDRESSES_PROVIDER().getPriceOracle());
    address[] memory reserves = targetPool.getReservesList();
    address[] memory buffer = new address[](reserves.length);
    uint256 count = 0;

    for (uint256 i = 0; i < reserves.length; i++) {
      DataTypes.ReserveDataLegacy memory data = targetPool.getReserveData(reserves[i]);
      if (data.accruedToTreasury == 0 || !data.configuration.getActive()) continue;

      buffer[count++] = reserves[i];
      uint256 amount = uint256(data.accruedToTreasury).rayMul(
        targetPool.getReserveNormalizedIncome(reserves[i])
      );
      accruedUsd +=
        (amount * _getAssetPrice(oracle, reserves[i])) /
        10 ** data.configuration.getDecimals();
    }

    assets = new address[](count);
    for (uint256 i = 0; i < count; i++) assets[i] = buffer[i];
  }

  function _getAssetPrice(IAaveOracle oracle, address asset) internal view returns (uint256) {
    try oracle.getAssetPrice(asset) returns (uint256 price) {
      return price;
    } catch {
      return 0;
    }
  }
}
