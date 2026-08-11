// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice Minimal view of a GHO GSM (Gho Stability Module) swap-freeze surface.
interface IGsm {
  /// @notice Freeze (`true`) or unfreeze (`false`) swaps on the GSM. Requires `SWAP_FREEZER_ROLE`.
  function setSwapFreeze(bool enable) external;

  /// @notice Whether swaps are currently frozen.
  function getIsFrozen() external view returns (bool);

  /// @notice Whether the GSM has been seized (a terminal state; no freeze action applies).
  function getIsSeized() external view returns (bool);

  /// @notice The role that gates `setSwapFreeze`.
  function SWAP_FREEZER_ROLE() external view returns (bytes32);

  /// @notice Whether `account` holds `role`.
  function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Minimal view of the Aave V3 `PoolAddressesProvider`.
interface IPoolAddressesProvider {
  /// @notice The Aave V3 price oracle for this pool.
  function getPriceOracle() external view returns (address);
}

/// @notice Minimal view of the Aave V3 price oracle.
interface IPriceOracle {
  /// @notice USD price of `asset`, 8 decimals.
  function getAssetPrice(address asset) external view returns (uint256);
}

/// @title IGsmFreezerReceiver
/// @notice Robot that freezes (and optionally unfreezes) GSM swaps when the
/// underlying asset's oracle price leaves a configured band. Native CRE
/// re-implementation of the GSM `ChainlinkOracleSwapFreezer`.
/// @dev `checkData` is unused (the GSM and bounds are immutables of the contract).
/// `onReport` re-derives the action from live state, so a stale report cannot force
/// a freeze/unfreeze that current prices do not warrant.
interface IGsmFreezerReceiver is IAaveCREReceiver {
  /// @notice The freeze action `checkUpkeep` selects and `onReport` executes.
  enum Action {
    NONE,
    FREEZE,
    UNFREEZE
  }

  /// @notice Freeze / unfreeze price band, in 8-decimal USD.
  /// @dev The unfreeze band must be strictly nested inside the freeze band (hysteresis).
  struct Bounds {
    uint256 freezeLowerBound;
    uint256 freezeUpperBound;
    uint256 unfreezeLowerBound;
    uint256 unfreezeUpperBound;
  }

  /// @notice Emitted when `onReport` freezes (`true`) or unfreezes (`false`) the GSM.
  /// @param frozen The new swap-freeze state.
  event SwapFreezeSet(bool frozen);

  /// @notice Emitted when the robot is excluded from / included in automation.
  /// @param disabled Whether the robot is now excluded from automation.
  event AutomationDisabled(bool disabled);

  /// @notice Thrown when the constructor bounds are not a valid nested band.
  error InvalidBounds();

  /// @notice Thrown when `onReport` runs but no freeze/unfreeze action currently applies.
  error NoActionPossible();

  /// @notice The GSM this robot freezes.
  function GSM() external view returns (IGsm);

  /// @notice The underlying asset whose oracle price drives the freeze decision.
  function UNDERLYING_ASSET() external view returns (address);

  /// @notice The Aave V3 addresses provider used to resolve the price oracle.
  function ADDRESS_PROVIDER() external view returns (IPoolAddressesProvider);

  /// @notice Price at or below which swaps are frozen.
  function FREEZE_LOWER_BOUND() external view returns (uint256);

  /// @notice Price at or above which swaps are frozen.
  function FREEZE_UPPER_BOUND() external view returns (uint256);

  /// @notice Lower edge of the band in which swaps may be unfrozen.
  function UNFREEZE_LOWER_BOUND() external view returns (uint256);

  /// @notice Upper edge of the band in which swaps may be unfrozen.
  function UNFREEZE_UPPER_BOUND() external view returns (uint256);

  /// @notice Whether this robot may unfreeze as well as freeze.
  function ALLOW_UNFREEZE() external view returns (bool);

  /// @notice Whether the robot is excluded from automation.
  function isDisabled() external view returns (bool);

  /// @notice Exclude or include the robot from automation. Owner or guardian.
  /// @param disabled Whether to exclude the robot from automation.
  function setDisabled(bool disabled) external;
}
