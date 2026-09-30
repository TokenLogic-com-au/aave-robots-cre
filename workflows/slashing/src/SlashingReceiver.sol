// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {Rescuable} from 'aave-v4/utils/Rescuable.sol';
import {IUmbrella} from 'aave-address-book/common/IUmbrella.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {ISlashingReceiver, IUmbrellaStakeToken} from './ISlashingReceiver.sol';

/// @title SlashingReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and triggers Umbrella slashing on
/// reserves with a slashable deficit. Native CRE port of BGD Labs' `SlashingRobot`.
/// @dev Needs no on-chain role: `Umbrella.slash` is permissionless.
contract SlashingReceiver is ISlashingReceiver, OwnableWithGuardian, Rescuable {
  /// @inheritdoc ISlashingReceiver
  IUmbrella public immutable override UMBRELLA;

  /// @inheritdoc ISlashingReceiver
  uint256 public constant override MAX_CHECK_SIZE = 10;

  mapping(address reserve => bool) internal _disabled;

  /// @param umbrella_ The Umbrella coordinator to slash through.
  /// @param initialOwner_ The address of the initial owner.
  /// @param initialGuardian_ The address of the initial guardian.
  constructor(
    address umbrella_,
    address initialOwner_,
    address initialGuardian_
  ) OwnableWithGuardian(initialOwner_, initialGuardian_) {
    require(umbrella_ != address(0), InvalidUmbrella());
    UMBRELLA = IUmbrella(umbrella_);
  }

  /// @inheritdoc ISlashingReceiver
  function disableReserve(address reserve) external onlyOwnerOrGuardian {
    require(!_disabled[reserve], ReserveStatusUnchanged(reserve, true));
    _disabled[reserve] = true;
    emit ReserveDisabled(reserve, true);
  }

  /// @inheritdoc ISlashingReceiver
  function enableReserve(address reserve) external onlyOwner {
    require(_disabled[reserve], ReserveStatusUnchanged(reserve, false));
    _disabled[reserve] = false;
    emit ReserveDisabled(reserve, false);
  }

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata /* checkData */
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    address[] memory stkTokens = UMBRELLA.getStkTokens();
    uint256 maxCount = stkTokens.length < MAX_CHECK_SIZE ? stkTokens.length : MAX_CHECK_SIZE;
    address[] memory buffer = new address[](maxCount);
    uint256 count = 0;

    for (uint256 i = 0; i < stkTokens.length && count < maxCount; i++) {
      address reserve = UMBRELLA.getStakeTokenData(stkTokens[i]).reserve;
      if (_canStakeBeSlashed(reserve, stkTokens[i])) {
        buffer[count++] = reserve;
      }
    }
    if (count == 0) return (false, '');

    address[] memory reserves = new address[](count);
    for (uint256 i = 0; i < count; i++) reserves[i] = buffer[i];
    return (true, abi.encode(reserves));
  }

  /// @inheritdoc IReceiver
  /// @dev Skips reserves that are disabled or no longer slashable, and catches a reverting
  /// `slash` so one reserve can't block the rest of the batch. Reverts `NoSlashesPerformed`
  /// if nothing was slashed, so a stale report fails `estimateGas`.
  function onReport(bytes calldata /* metadata */, bytes calldata report) external override {
    address[] memory reserves = abi.decode(report, (address[]));
    bool slashed = false;

    for (uint256 i = 0; i < reserves.length; i++) {
      if (!_isSlashable(reserves[i])) continue;
      try UMBRELLA.slash(reserves[i]) returns (uint256 amount) {
        slashed = true;
        emit ReserveSlashed(reserves[i], amount);
      } catch {}
    }
    require(slashed, NoSlashesPerformed());
  }

  /// @inheritdoc ISlashingReceiver
  function isDisabled(address reserve) external view returns (bool) {
    return _disabled[reserve];
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev Whether the reserve is slashable and its stake token is unpaused and holds
  /// slashable funds.
  function _canStakeBeSlashed(address reserve, address stkToken) internal view returns (bool) {
    return
      _isSlashable(reserve) &&
      !IUmbrellaStakeToken(stkToken).paused() &&
      IUmbrellaStakeToken(stkToken).getMaxSlashableAssets() > 0;
  }

  /// @dev Whether the reserve is not disabled and Umbrella reports a slashable deficit.
  function _isSlashable(address reserve) internal view returns (bool) {
    if (reserve == address(0) || _disabled[reserve]) return false;
    (bool slashable, ) = UMBRELLA.isReserveSlashable(reserve);
    return slashable;
  }

  /// @inheritdoc Rescuable
  function _rescueGuardian() internal view override returns (address) {
    return owner();
  }
}
