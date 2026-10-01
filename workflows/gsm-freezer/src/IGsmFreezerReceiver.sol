// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolAddressesProvider} from 'aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

/// @notice GHO `Gsm` functions used by the robot.
interface IGsm {
  function setSwapFreeze(bool enable) external;

  function getIsFrozen() external view returns (bool);

  function getIsSeized() external view returns (bool);

  function SWAP_FREEZER_ROLE() external view returns (bytes32);

  function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title IGsmFreezerReceiver
/// @notice Robot that freezes (and optionally unfreezes) GSM swaps when the underlying
/// asset's oracle price leaves a configured band.
/// @dev `checkData` and the `report` are unused: the GSM and bounds are immutables, and
/// `onReport` derives the action from live state.
interface IGsmFreezerReceiver is IAaveCREReceiver {
  /// @notice The action `checkUpkeep` selects and `onReport` executes.
  enum Action {
    NONE,
    FREEZE,
    UNFREEZE
  }

  /// @notice Freeze / unfreeze price band, in 8-decimal USD. All bounds are inclusive.
  /// @dev The unfreeze band must be nested inside the freeze band; both unfreeze bounds
  /// must be 0 when unfreezing is not allowed.
  struct Bounds {
    uint256 freezeLowerBound;
    uint256 freezeUpperBound;
    uint256 unfreezeLowerBound;
    uint256 unfreezeUpperBound;
  }

  /// @notice Emitted when `onReport` freezes (`true`) or unfreezes (`false`) the GSM.
  /// @param frozen The new swap-freeze state.
  event SwapFreezeSet(bool frozen);

  /// @notice Emitted when the robot is excluded from or included back into automation.
  /// @param disabled Whether the robot is now excluded from automation.
  event AutomationDisabled(bool disabled);

  /// @notice Thrown when a constructor address is zero.
  error InvalidAddress();

  /// @notice Thrown when the constructor bounds are not a valid band.
  error InvalidBounds();

  /// @notice Thrown when `onReport` runs but no freeze/unfreeze action currently applies.
  error NoActionPossible();

  /// @notice Thrown when disabling / enabling automation that already has that status.
  /// @param disabled The status that was requested.
  error AutomationStatusUnchanged(bool disabled);

  /// @notice The GSM this robot freezes.
  function GSM() external view returns (IGsm);

  /// @notice The asset whose Aave oracle price drives the freeze decision.
  function UNDERLYING_ASSET() external view returns (address);

  /// @notice The Aave V3 addresses provider used to resolve the price oracle.
  function ADDRESS_PROVIDER() external view returns (IPoolAddressesProvider);

  /// @notice Price at or below which swaps are frozen.
  function FREEZE_LOWER_BOUND() external view returns (uint256);

  /// @notice Price at or above which swaps are frozen.
  function FREEZE_UPPER_BOUND() external view returns (uint256);

  /// @notice Lower edge of the band in which swaps are unfrozen.
  function UNFREEZE_LOWER_BOUND() external view returns (uint256);

  /// @notice Upper edge of the band in which swaps are unfrozen.
  function UNFREEZE_UPPER_BOUND() external view returns (uint256);

  /// @notice Whether this robot may unfreeze as well as freeze.
  function ALLOW_UNFREEZE() external view returns (bool);

  /// @notice Exclude the robot from automation. Owner or guardian.
  function disableAutomation() external;

  /// @notice Include the robot back into automation. Owner-only.
  function enableAutomation() external;

  /// @notice Whether the robot is excluded from automation.
  function isDisabled() external view returns (bool);
}
