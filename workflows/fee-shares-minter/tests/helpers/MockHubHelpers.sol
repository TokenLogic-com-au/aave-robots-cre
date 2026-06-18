// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm} from 'forge-std/Vm.sol';
import {IHub} from 'aave-v4/hub/interfaces/IHub.sol';
import {IHubBase} from 'aave-v4/hub/interfaces/IHubBase.sol';

library MockHubHelpers {
  bool public constant IS_TEST = true;
  Vm internal constant VM = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  function setAssetCount(address hub, uint256 count) internal {
    VM.mockCall(hub, abi.encodeWithSelector(IHub.getAssetCount.selector), abi.encode(count));
  }

  function setAddedAssets(address hub, uint256 assetId, uint256 totalAdded) internal {
    VM.mockCall(
      hub,
      abi.encodeWithSelector(IHubBase.getAddedAssets.selector, assetId),
      abi.encode(totalAdded)
    );
  }

  function setAccruedFees(address hub, uint256 assetId, uint256 fees) internal {
    VM.mockCall(
      hub,
      abi.encodeWithSelector(IHub.getAssetAccruedFees.selector, assetId),
      abi.encode(fees)
    );
  }

  function setPreviewShares(address hub, uint256 assetId, uint256 assets, uint256 shares) internal {
    VM.mockCall(
      hub,
      abi.encodeWithSelector(IHubBase.previewAddByAssets.selector, assetId, assets),
      abi.encode(shares)
    );
  }

  function expectMintFeeShares(address hub, uint256 assetId) internal {
    // mintFeeShares returns uint256 — mock must supply 32 bytes or the caller's decode reverts.
    VM.mockCall(
      hub,
      abi.encodeWithSelector(IHub.mintFeeShares.selector, assetId),
      abi.encode(uint256(0))
    );
    VM.expectCall(hub, abi.encodeWithSelector(IHub.mintFeeShares.selector, assetId));
  }
}
