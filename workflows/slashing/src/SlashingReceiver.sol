// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableWithGuardian} from 'solidity-utils/contracts/access-control/OwnableWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';
import {ISlashingReceiver, IUmbrella, IUmbrellaStakeToken} from './ISlashingReceiver.sol';

/// @title SlashingReceiver
/// @author Aave Labs
/// @notice Receives reports from the CRE workflow and triggers Umbrella slashing
/// on reserves with a slashable deficit. Native CRE re-implementation of BGD
/// Labs' `SlashingRobot`.
/// @dev `Umbrella.slash` is permissionless (gated by its own deficit check), so
/// this contract needs no on-chain role. It only reads state and forwards the call.
contract SlashingReceiver is ISlashingReceiver, OwnableWithGuardian {
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
    UMBRELLA = IUmbrella(umbrella_);
  }

  /// @inheritdoc IAaveCREReceiver
  function checkUpkeep(
    bytes calldata /* checkData */
  ) external view returns (bool upkeepNeeded, bytes memory performData) {
    address[] memory stkTokens = UMBRELLA.getStkTokens();
    address[] memory buffer = new address[](stkTokens.length);
    uint256 count = 0;

    for (uint256 i = 0; i < stkTokens.length && count < MAX_CHECK_SIZE; i++) {
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
  /// @dev Re-validates each reserve and wraps `slash` in try/catch, so a stale
  /// report (front-run, racing keepers) just skips instead of reverting the batch.
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
  function isDisabled(address reserve) public view returns (bool) {
    return _disabled[reserve];
  }

  /// @inheritdoc ISlashingReceiver
  function setDisabled(address reserve, bool disabled) external onlyOwnerOrGuardian {
    _disabled[reserve] = disabled;
    emit ReserveDisabled(reserve, disabled);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return
      interfaceId == type(IReceiver).interfaceId ||
      interfaceId == type(IAaveCREReceiver).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /// @dev A reserve's stake can be slashed when the reserve has a slashable
  /// deficit, the stake token is not paused, and it holds slashable funds.
  function _canStakeBeSlashed(address reserve, address stkToken) internal view returns (bool) {
    return
      _isSlashable(reserve) &&
      !IUmbrellaStakeToken(stkToken).paused() &&
      IUmbrellaStakeToken(stkToken).getMaxSlashableAssets() > 0;
  }

  /// @dev A reserve is slashable when it is enabled for automation and Umbrella
  /// reports a deficit for it.
  function _isSlashable(address reserve) internal view returns (bool) {
    if (reserve == address(0) || _disabled[reserve]) return false;
    (bool slashable, ) = UMBRELLA.isReserveSlashable(reserve);
    return slashable;
  }
}
