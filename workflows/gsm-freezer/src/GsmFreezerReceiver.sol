// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';
import {IPoolAddressesProvider} from 'aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from 'aave-v3-origin/contracts/interfaces/IPriceOracleGetter.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IGsmFreezerReceiver, IGsm} from './IGsmFreezerReceiver.sol';

/// @title GsmFreezerReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and freezes (or unfreezes) GSM swaps
/// when the underlying's oracle price leaves a configured band. Native CRE port of the
/// GSM `OracleSwapFreezer`.
/// @dev Must hold `SWAP_FREEZER_ROLE` on the GSM. Unfreezing is permissionless too, so a
/// manual freeze made while the price is in the unfreeze band needs `disableAutomation()`
/// to stick.
contract GsmFreezerReceiver is IGsmFreezerReceiver, OwnableWithGuardian, Rescuable {
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

  bool internal _disabled;

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
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
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

  /// @inheritdoc IGsmFreezerReceiver
  function disableAutomation() external onlyOwnerOrGuardian {
    require(!_disabled, AutomationStatusUnchanged(true));
    _disabled = true;
    emit AutomationDisabled(true);
  }

  /// @inheritdoc IGsmFreezerReceiver
  function enableAutomation() external onlyOwner {
    require(_disabled, AutomationStatusUnchanged(false));
    _disabled = false;
    emit AutomationDisabled(false);
  }

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata /* checkData */
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    Action action = _getAction();
    if (action == Action.NONE) return (false, '');
    return (true, abi.encode(action));
  }

  /// @inheritdoc IReceiver
  /// @dev Ignores the report and derives the action from live state. Reverts
  /// `NoActionPossible` when there is nothing to do, so a stale report fails `estimateGas`.
  function onReport(bytes calldata /* metadata */, bytes calldata /* report */) external override {
    Action action = _getAction();
    require(action != Action.NONE, NoActionPossible());
    bool freeze = action == Action.FREEZE;
    GSM.setSwapFreeze(freeze);
    emit SwapFreezeSet(freeze);
  }

  /// @inheritdoc IGsmFreezerReceiver
  function isDisabled() external view returns (bool) {
    return _disabled;
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev Same decision as `OracleSwapFreezer`: freeze when the price leaves the freeze
  /// band, unfreeze when it is back in the unfreeze band. `NONE` when disabled, without the
  /// role, once the GSM is seized, or on a zero price.
  function _getAction() internal view returns (Action) {
    if (_disabled) return Action.NONE;
    if (!GSM.hasRole(GSM.SWAP_FREEZER_ROLE(), address(this))) return Action.NONE;
    if (GSM.getIsSeized()) return Action.NONE;

    uint256 price = IPriceOracleGetter(ADDRESS_PROVIDER.getPriceOracle()).getAssetPrice(
      UNDERLYING_ASSET
    );
    if (price == 0) return Action.NONE;

    if (!GSM.getIsFrozen()) {
      if (price <= FREEZE_LOWER_BOUND || price >= FREEZE_UPPER_BOUND) return Action.FREEZE;
    } else if (ALLOW_UNFREEZE) {
      if (price >= UNFREEZE_LOWER_BOUND && price <= UNFREEZE_UPPER_BOUND) return Action.UNFREEZE;
    }
    return Action.NONE;
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

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
