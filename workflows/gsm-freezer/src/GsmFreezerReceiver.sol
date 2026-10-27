// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolAddressesProvider} from 'aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from 'aave-v3-origin/contracts/interfaces/IPriceOracleGetter.sol';

import {WorkflowsBase} from 'aave-cre/WorkflowsBase.sol';
import {IGsmFreezerReceiver, IGsm} from './IGsmFreezerReceiver.sol';

/// @title GsmFreezerReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and freezes (or unfreezes) GSM swaps
/// when the underlying's oracle price leaves a configured band. Native CRE port of the
/// GSM `OracleSwapFreezer`.
/// @dev Must hold `SWAP_FREEZER_ROLE` on the GSM. `onReport` is permissionless, unfreezing
/// included, so a manual freeze made while the price is in the unfreeze band needs
/// `disableAutomation()` to stick.
contract GsmFreezerReceiver is IGsmFreezerReceiver, WorkflowsBase {
  /// @inheritdoc IGsmFreezerReceiver
  IGsm public immutable override GSM;

  /// @inheritdoc IGsmFreezerReceiver
  address public immutable override UNDERLYING_ASSET;

  /// @inheritdoc IGsmFreezerReceiver
  IPoolAddressesProvider public immutable override ADDRESS_PROVIDER;

  /// @inheritdoc IGsmFreezerReceiver
  uint256 public immutable override FREEZE_LOWER_BOUND;

  /// @inheritdoc IGsmFreezerReceiver
  uint256 public immutable override FREEZE_UPPER_BOUND;

  /// @inheritdoc IGsmFreezerReceiver
  uint256 public immutable override UNFREEZE_LOWER_BOUND;

  /// @inheritdoc IGsmFreezerReceiver
  uint256 public immutable override UNFREEZE_UPPER_BOUND;

  /// @inheritdoc IGsmFreezerReceiver
  bool public immutable override ALLOW_UNFREEZE;

  /// @param gsm_ The GSM to freeze.
  /// @param underlyingAsset_ The asset priced for the freeze decision.
  /// @param addressProvider_ The Aave V3 addresses provider resolving the price oracle.
  /// @param bounds_ The freeze / unfreeze price band (8-decimal USD).
  /// @param allowUnfreeze_ Whether the robot may unfreeze as well as freeze.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address gsm_,
    address underlyingAsset_,
    address addressProvider_,
    Bounds memory bounds_,
    bool allowUnfreeze_,
    address initialOwner_,
    address initialGuardian_
  ) WorkflowsBase(initialOwner_, initialGuardian_) {
    require(
      gsm_ != address(0) && underlyingAsset_ != address(0) && addressProvider_ != address(0),
      InvalidAddress()
    );
    require(_validateBounds(bounds_, allowUnfreeze_), InvalidBounds());

    GSM = IGsm(gsm_);
    UNDERLYING_ASSET = underlyingAsset_;
    ADDRESS_PROVIDER = IPoolAddressesProvider(addressProvider_);
    FREEZE_LOWER_BOUND = bounds_.freezeLowerBound;
    FREEZE_UPPER_BOUND = bounds_.freezeUpperBound;
    UNFREEZE_LOWER_BOUND = bounds_.unfreezeLowerBound;
    UNFREEZE_UPPER_BOUND = bounds_.unfreezeUpperBound;
    ALLOW_UNFREEZE = allowUnfreeze_;
  }

  /// @dev Ignores the report and derives the action from live state. Reverts
  /// `NoActionPossible` when there is nothing to do, so a stale report fails `estimateGas`.
  function _onReport(bytes calldata /* metadata */, bytes calldata /* report */) internal override {
    Action action = _getAction();
    require(action != Action.NONE, NoActionPossible());

    bool freeze = action == Action.FREEZE;
    GSM.setSwapFreeze(freeze);
    emit SwapFreezeSet(freeze);
  }

  function _checkUpkeep(
    bytes calldata /* checkData */
  ) internal view override returns (bool, bytes memory) {
    Action action = _getAction();
    if (action == Action.NONE) return (false, '');
    return (true, abi.encode(action));
  }

  /// @dev Same decision as `OracleSwapFreezer`: freeze when the price leaves the freeze
  /// band, unfreeze when it is back in the unfreeze band. `NONE` without the role, once the
  /// GSM is seized, or on a zero price. The oracle is only read when an action is possible.
  function _getAction() internal view returns (Action) {
    if (!GSM.hasRole(GSM.SWAP_FREEZER_ROLE(), address(this))) return Action.NONE;
    if (GSM.getIsSeized()) return Action.NONE;

    if (!GSM.getIsFrozen()) {
      uint256 price = _getPrice();
      if (price != 0 && (price <= FREEZE_LOWER_BOUND || price >= FREEZE_UPPER_BOUND)) {
        return Action.FREEZE;
      }
    } else if (ALLOW_UNFREEZE) {
      uint256 price = _getPrice();
      if (price != 0 && price >= UNFREEZE_LOWER_BOUND && price <= UNFREEZE_UPPER_BOUND) {
        return Action.UNFREEZE;
      }
    }
    return Action.NONE;
  }

  function _getPrice() internal view returns (uint256) {
    return IPriceOracleGetter(ADDRESS_PROVIDER.getPriceOracle()).getAssetPrice(UNDERLYING_ASSET);
  }

  /// @dev Same rules as `OracleSwapFreezer._validateBounds`.
  function _validateBounds(Bounds memory b, bool allowUnfreeze) internal pure returns (bool) {
    if (b.freezeLowerBound >= b.freezeUpperBound) return false;
    if (!allowUnfreeze) return b.unfreezeLowerBound == 0 && b.unfreezeUpperBound == 0;
    return
      b.unfreezeLowerBound < b.unfreezeUpperBound &&
      b.freezeLowerBound < b.unfreezeLowerBound &&
      b.unfreezeUpperBound < b.freezeUpperBound;
  }
}
