// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {IGsmFreezerReceiver, IGsm, IPoolAddressesProvider, IPriceOracle} from './IGsmFreezerReceiver.sol';

/// @title GsmFreezerReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and freezes (or unfreezes) GSM
/// swaps when the underlying's oracle price leaves a configured band. Native CRE
/// re-implementation of the GSM `ChainlinkOracleSwapFreezer`.
/// @dev The contract must hold `SWAP_FREEZER_ROLE` on the GSM. `onReport` re-derives
/// the action from live state, so a stale report cannot force a wrong freeze/unfreeze.
/// `onReport` is permissionless (like the legacy freezer and `FeeSharesMinter`): a caller
/// can only trigger the action live prices warrant. Note the unfreeze side is public too,
/// so a manual/emergency freeze made while the price is in the unfreeze band should be
/// paired with `setDisabled(true)` (or the GSM deployed with `allowUnfreeze == false`) to
/// stop the robot from unfreezing it.
contract GsmFreezerReceiver is IGsmFreezerReceiver, OwnableWithGuardian {
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
  /// @param underlyingAsset_ The underlying asset priced for the freeze decision.
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
      bounds_.freezeLowerBound < bounds_.unfreezeLowerBound &&
        bounds_.unfreezeLowerBound < bounds_.unfreezeUpperBound &&
        bounds_.unfreezeUpperBound < bounds_.freezeUpperBound,
      InvalidBounds()
    );
    GSM = IGsm(gsm_);
    UNDERLYING_ASSET = underlyingAsset_;
    ADDRESS_PROVIDER = IPoolAddressesProvider(addressProvider_);
    FREEZE_LOWER_BOUND = bounds_.freezeLowerBound;
    FREEZE_UPPER_BOUND = bounds_.freezeUpperBound;
    UNFREEZE_LOWER_BOUND = bounds_.unfreezeLowerBound;
    UNFREEZE_UPPER_BOUND = bounds_.unfreezeUpperBound;
    ALLOW_UNFREEZE = allowUnfreeze_;
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
  /// @dev Re-derives the action from live state and ignores the report payload, so a
  /// stale/forged report cannot force a freeze/unfreeze that current prices do not warrant.
  function onReport(bytes calldata /* metadata */, bytes calldata /* report */) external override {
    Action action = _getAction();
    if (action == Action.FREEZE) {
      GSM.setSwapFreeze(true);
      emit SwapFreezeSet(true);
    } else if (action == Action.UNFREEZE) {
      GSM.setSwapFreeze(false);
      emit SwapFreezeSet(false);
    } else {
      revert NoActionPossible();
    }
  }

  /// @inheritdoc IGsmFreezerReceiver
  function isDisabled() public view returns (bool) {
    return _disabled;
  }

  /// @inheritdoc IGsmFreezerReceiver
  function setDisabled(bool disabled) external onlyOwnerOrGuardian {
    _disabled = disabled;
    emit AutomationDisabled(disabled);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev Mirrors the legacy `ChainlinkOracleSwapFreezer`: freeze when the price leaves
  /// the outer band, unfreeze when it returns to the inner band. Returns `NONE` when
  /// disabled, the role is missing, the GSM is seized, the price is unavailable, or no
  /// threshold is crossed.
  function _getAction() internal view returns (Action) {
    if (_disabled) return Action.NONE;
    if (!GSM.hasRole(GSM.SWAP_FREEZER_ROLE(), address(this))) return Action.NONE;
    if (GSM.getIsSeized()) return Action.NONE;

    uint256 price = IPriceOracle(ADDRESS_PROVIDER.getPriceOracle()).getAssetPrice(UNDERLYING_ASSET);
    if (price == 0) return Action.NONE;

    if (!GSM.getIsFrozen()) {
      if (price <= FREEZE_LOWER_BOUND || price >= FREEZE_UPPER_BOUND) return Action.FREEZE;
    } else if (ALLOW_UNFREEZE) {
      if (price >= UNFREEZE_LOWER_BOUND && price <= UNFREEZE_UPPER_BOUND) return Action.UNFREEZE;
    }
    return Action.NONE;
  }
}
