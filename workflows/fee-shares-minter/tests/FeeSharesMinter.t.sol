// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {PercentageMath} from 'aave-v4/libraries/math/PercentageMath.sol';
import {IRescuable} from 'aave-v4/interfaces/IRescuable.sol';
import {IHub} from 'aave-v4/hub/interfaces/IHub.sol';

import {FeeSharesMinter} from '../src/FeeSharesMinter.sol';
import {IFeeSharesMinter} from '../src/IFeeSharesMinter.sol';
import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {MockHubHelpers} from './helpers/MockHubHelpers.sol';

contract FeeSharesMinterTest is Test {
  FeeSharesMinter internal minter;

  address internal admin;
  address internal hub;
  uint256 internal constant ASSET_ID = 1;
  uint256 internal constant OTHER_ASSET_ID = 2;
  uint256 internal constant THIRD_ASSET_ID = 3;
  uint256 internal constant ASSET_COUNT = 5;

  uint16 internal constant HAPPY_THRESHOLD_BPS = 5_00;
  uint256 internal constant HAPPY_ADDED = 1000e18;
  uint256 internal constant HAPPY_FEES = 100e18; // 10% of HAPPY_ADDED — above threshold
  uint256 internal constant HAPPY_PREVIEW_SHARES = 90e18;

  address internal guardian;
  address internal bob;
  address internal anyone;

  function setUp() public {
    admin = makeAddr('admin');
    guardian = makeAddr('guardian');
    bob = makeAddr('bob');
    anyone = makeAddr('anyone');
    hub = makeAddr('hub');

    MockHubHelpers.setAssetCount(hub, ASSET_COUNT);

    minter = new FeeSharesMinter(admin, guardian);
  }

  function test_constructor_setsOwnerAndGuardian() public view {
    assertEq(minter.owner(), admin);
    assertEq(minter.guardian(), guardian);
  }

  function test_DISABLED_THRESHOLD_equalsUint16Max() public view {
    assertEq(minter.DISABLED_THRESHOLD(), type(uint16).max);
  }

  function test_supportsInterface() public view {
    assertTrue(minter.supportsInterface(type(IReceiver).interfaceId));
    assertTrue(minter.supportsInterface(type(IAaveCREReceiver).interfaceId));
    assertTrue(minter.supportsInterface(type(IERC165).interfaceId));
    assertFalse(minter.supportsInterface(0xffffffff));
  }

  function test_updateFeesToAssetsThreshold_revertsWith_OwnableUnauthorized() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
    minter.updateFeesToAssetsThreshold(hub, ASSET_ID, 100);
  }

  function test_updateFeesToAssetsThreshold_revertsWhenCalledByGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
    minter.updateFeesToAssetsThreshold(hub, ASSET_ID, 100);
  }

  function test_fuzz_updateFeesToAssetsThreshold(uint16 minAccruedFeesPercent) public {
    minAccruedFeesPercent = uint16(
      bound(minAccruedFeesPercent, 1, PercentageMath.PERCENTAGE_FACTOR)
    );

    vm.expectEmit(address(minter));
    emit IFeeSharesMinter.FeesToAssetsThresholdUpdated(hub, ASSET_ID, minAccruedFeesPercent);

    vm.prank(admin);
    minter.updateFeesToAssetsThreshold(hub, ASSET_ID, minAccruedFeesPercent);

    assertEq(minter.getFeesToAssetsThreshold(hub, ASSET_ID), minAccruedFeesPercent);
  }

  function test_updateFeesToAssetsThreshold_independentPerPair() public {
    vm.startPrank(admin);
    minter.updateFeesToAssetsThreshold(hub, ASSET_ID, 100);
    minter.updateFeesToAssetsThreshold(hub, OTHER_ASSET_ID, 200);
    vm.stopPrank();

    assertEq(minter.getFeesToAssetsThreshold(hub, ASSET_ID), 100);
    assertEq(minter.getFeesToAssetsThreshold(hub, OTHER_ASSET_ID), 200);
    assertEq(minter.getFeesToAssetsThreshold(hub, 3), 0);
  }

  function test_updateFeesToAssetsThreshold_independentPerHub() public {
    address otherHub = makeAddr('otherHub');
    MockHubHelpers.setAssetCount(otherHub, 10);

    vm.startPrank(admin);
    minter.updateFeesToAssetsThreshold(hub, ASSET_ID, 100);
    minter.updateFeesToAssetsThreshold(otherHub, ASSET_ID, 200);
    vm.stopPrank();

    assertEq(minter.getFeesToAssetsThreshold(hub, ASSET_ID), 100);
    assertEq(minter.getFeesToAssetsThreshold(otherHub, ASSET_ID), 200);
  }

  function test_updateFeesToAssetsThreshold_revertsWith_InvalidFeesToAssetsThreshold_whenZero()
    public
  {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IFeeSharesMinter.InvalidFeesToAssetsThreshold.selector, uint16(0))
    );
    minter.updateFeesToAssetsThreshold(hub, ASSET_ID, 0);
  }

  function test_fuzz_updateFeesToAssetsThreshold_revertsWith_InvalidFeesToAssetsThreshold_whenAboveMax(
    uint16 minAccruedFeesPercent
  ) public {
    minAccruedFeesPercent = uint16(
      bound(minAccruedFeesPercent, PercentageMath.PERCENTAGE_FACTOR + 1, type(uint16).max)
    );

    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(
        IFeeSharesMinter.InvalidFeesToAssetsThreshold.selector,
        minAccruedFeesPercent
      )
    );
    minter.updateFeesToAssetsThreshold(hub, ASSET_ID, minAccruedFeesPercent);
  }

  function test_updateFeesToAssetsThreshold_revertsWith_AssetNotListed() public {
    vm.prank(admin);
    vm.expectRevert(IHub.AssetNotListed.selector);
    minter.updateFeesToAssetsThreshold(hub, ASSET_COUNT, 100);
  }

  function test_disableFeeSharesMinting_byOwner() public {
    _setMinPercent(ASSET_ID, HAPPY_THRESHOLD_BPS);

    vm.expectEmit(address(minter));
    emit IFeeSharesMinter.FeesToAssetsThresholdUpdated(hub, ASSET_ID, minter.DISABLED_THRESHOLD());

    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_ID);

    assertEq(minter.getFeesToAssetsThreshold(hub, ASSET_ID), minter.DISABLED_THRESHOLD());
  }

  function test_disableFeeSharesMinting_byGuardian() public {
    _setMinPercent(ASSET_ID, HAPPY_THRESHOLD_BPS);

    vm.prank(guardian);
    minter.disableFeeSharesMinting(hub, ASSET_ID);

    assertEq(minter.getFeesToAssetsThreshold(hub, ASSET_ID), minter.DISABLED_THRESHOLD());
  }

  function test_disableFeeSharesMinting_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    minter.disableFeeSharesMinting(hub, ASSET_ID);
  }

  function test_disableFeeSharesMinting_isIdempotent_whenAlreadyDisabled() public {
    vm.startPrank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_ID);
    minter.disableFeeSharesMinting(hub, ASSET_ID);
    vm.stopPrank();

    assertEq(minter.getFeesToAssetsThreshold(hub, ASSET_ID), minter.DISABLED_THRESHOLD());
  }

  function test_disableFeeSharesMinting_onUnconfiguredAsset_doesNotRevert() public {
    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_ID);

    assertEq(minter.getFeesToAssetsThreshold(hub, ASSET_ID), minter.DISABLED_THRESHOLD());
  }

  function test_disableFeeSharesMinting_doesNotValidateAssetId() public {
    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_COUNT + 100);

    assertEq(minter.getFeesToAssetsThreshold(hub, ASSET_COUNT + 100), minter.DISABLED_THRESHOLD());
  }

  function test_disableFeeSharesMinting_makesCanMintFalse() public {
    _setupHappyPath();
    _assertCanMint(true);

    vm.prank(guardian);
    minter.disableFeeSharesMinting(hub, ASSET_ID);

    _assertCanMint(false);
  }

  function test_updateFeesToAssetsThreshold_reEnablesPreviouslyDisabledPair() public {
    _setupHappyPath();

    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_ID);
    _assertCanMint(false);

    vm.prank(admin);
    minter.updateFeesToAssetsThreshold(hub, ASSET_ID, HAPPY_THRESHOLD_BPS);
    _assertCanMint(true);
  }

  function test_canMint_returnsTrue_onHappyPath() public {
    _setupHappyPath();
    _assertCanMint(true);
  }

  function test_canMint_returnsFalse_whenDisabled() public {
    _setupHappyPath();
    _assertCanMint(true);

    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_ID);
    _assertCanMint(false);
  }

  function test_canMint_returnsFalse_whenAddedAssetsDropToZero() public {
    _setupHappyPath();
    _assertCanMint(true);

    MockHubHelpers.setAddedAssets(hub, ASSET_ID, 0);
    _assertCanMint(false);
  }

  function test_canMint_returnsFalse_whenThresholdRaisedAboveRatio() public {
    _setupHappyPath();
    _assertCanMint(true);

    _setMinPercent(ASSET_ID, 50_00);
    _assertCanMint(false);
  }

  function test_canMint_returnsFalse_whenSharesPreviewRoundsToZero() public {
    _setupHappyPath();
    _assertCanMint(true);

    MockHubHelpers.setPreviewShares(hub, ASSET_ID, HAPPY_FEES, 0);
    _assertCanMint(false);
  }

  function test_canMint_revertsWith_NotConfigured() public {
    vm.expectRevert(abi.encodeWithSelector(IFeeSharesMinter.NotConfigured.selector, hub, ASSET_ID));
    minter.canMint(hub, ASSET_ID);
  }

  function test_canMint_returnsFalse_whenDisabled_evenIfRatioExceedsSentinel() public {
    _setupHappyPath();

    MockHubHelpers.setAddedAssets(hub, ASSET_ID, 1);
    MockHubHelpers.setAccruedFees(hub, ASSET_ID, 10);
    MockHubHelpers.setPreviewShares(hub, ASSET_ID, 10, 5);

    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_ID);

    _assertCanMint(false);
  }

  function test_checkUpkeep_returnsAllMintable_whenAllPass() public {
    _setupHappyPath();

    bytes memory checkData = _encodePairs(_pairsOne(hub, ASSET_ID));
    (bool upkeepNeeded, bytes memory performData) = minter.checkUpkeep(checkData);
    assertTrue(upkeepNeeded);
    assertEq(performData, checkData);
  }

  function test_checkUpkeep_returnsEmpty_whenInputEmpty() public view {
    IFeeSharesMinter.HubAssetPair[] memory empty = new IFeeSharesMinter.HubAssetPair[](0);
    (bool upkeepNeeded, bytes memory performData) = minter.checkUpkeep(abi.encode(empty));
    assertFalse(upkeepNeeded);
    assertEq(performData, abi.encode(empty));
  }

  function test_checkUpkeep_skipsUnconfigured() public view {
    IFeeSharesMinter.HubAssetPair[] memory pairs = _pairsOne(hub, ASSET_ID);
    (bool upkeepNeeded, bytes memory performData) = minter.checkUpkeep(abi.encode(pairs));
    assertFalse(upkeepNeeded);
    assertEq(performData, abi.encode(new IFeeSharesMinter.HubAssetPair[](0)));
  }

  function test_checkUpkeep_skipsDisabled() public {
    _setupHappyPath();
    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_ID);

    (bool upkeepNeeded, bytes memory performData) = minter.checkUpkeep(
      abi.encode(_pairsOne(hub, ASSET_ID))
    );
    assertFalse(upkeepNeeded);
    assertEq(performData, abi.encode(new IFeeSharesMinter.HubAssetPair[](0)));
  }

  function test_checkUpkeep_filtersToMintableSubset() public {
    _setupHappyPath();
    _setMinPercent(OTHER_ASSET_ID, HAPPY_THRESHOLD_BPS);
    MockHubHelpers.setAddedAssets(hub, OTHER_ASSET_ID, HAPPY_ADDED);
    MockHubHelpers.setAccruedFees(hub, OTHER_ASSET_ID, 1);
    MockHubHelpers.setPreviewShares(hub, OTHER_ASSET_ID, 1, 1);

    IFeeSharesMinter.HubAssetPair[] memory pairs = new IFeeSharesMinter.HubAssetPair[](3);
    pairs[0] = IFeeSharesMinter.HubAssetPair(hub, ASSET_ID);
    pairs[1] = IFeeSharesMinter.HubAssetPair(hub, OTHER_ASSET_ID);
    pairs[2] = IFeeSharesMinter.HubAssetPair(hub, THIRD_ASSET_ID);

    (bool upkeepNeeded, bytes memory performData) = minter.checkUpkeep(abi.encode(pairs));
    assertTrue(upkeepNeeded);

    IFeeSharesMinter.HubAssetPair[] memory mintable = abi.decode(
      performData,
      (IFeeSharesMinter.HubAssetPair[])
    );
    assertEq(mintable.length, 1);
    assertEq(mintable[0].hub, hub);
    assertEq(mintable[0].assetId, ASSET_ID);
  }

  function test_checkUpkeep_filtersAcrossMultipleHubs() public {
    address otherHub = makeAddr('otherHub');
    MockHubHelpers.setAssetCount(otherHub, 5);
    _setupHappyPath();
    _setupHappyPathOn(otherHub, ASSET_ID);

    IFeeSharesMinter.HubAssetPair[] memory pairs = new IFeeSharesMinter.HubAssetPair[](2);
    pairs[0] = IFeeSharesMinter.HubAssetPair(hub, ASSET_ID);
    pairs[1] = IFeeSharesMinter.HubAssetPair(otherHub, ASSET_ID);

    (bool upkeepNeeded, bytes memory performData) = minter.checkUpkeep(abi.encode(pairs));
    assertTrue(upkeepNeeded);

    IFeeSharesMinter.HubAssetPair[] memory mintable = abi.decode(
      performData,
      (IFeeSharesMinter.HubAssetPair[])
    );
    assertEq(mintable.length, 2);
    assertEq(mintable[0].hub, hub);
    assertEq(mintable[1].hub, otherHub);
  }

  function test_onReport_succeeds_whenAnyoneCalls() public {
    _setupHappyPath();
    MockHubHelpers.expectMintFeeShares(hub, ASSET_ID);

    vm.prank(anyone);
    minter.onReport(_arbitraryMetadata(), abi.encode(_pairsOne(hub, ASSET_ID)));
  }

  function test_onReport_succeeds_withEmptyMetadata() public {
    _setupHappyPath();
    MockHubHelpers.expectMintFeeShares(hub, ASSET_ID);

    vm.prank(anyone);
    minter.onReport('', abi.encode(_pairsOne(hub, ASSET_ID)));
  }

  function test_onReport_ignoresMetadataContents() public {
    _setupHappyPath();
    MockHubHelpers.expectMintFeeShares(hub, ASSET_ID);

    bytes memory junk = abi.encodePacked(
      bytes32(uint256(0xdead)),
      bytes10('junk'),
      address(0xBEEF)
    );
    vm.prank(anyone);
    minter.onReport(junk, abi.encode(_pairsOne(hub, ASSET_ID)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenSingleDisabled() public {
    _setupHappyPath();
    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, ASSET_ID);

    vm.prank(anyone);
    vm.expectRevert(IFeeSharesMinter.ConditionsNotMet.selector);
    minter.onReport('', abi.encode(_pairsOne(hub, ASSET_ID)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenSingleBelowThreshold() public {
    _setupHappyPath();
    _setMinPercent(ASSET_ID, 50_00);

    vm.prank(anyone);
    vm.expectRevert(IFeeSharesMinter.ConditionsNotMet.selector);
    minter.onReport('', abi.encode(_pairsOne(hub, ASSET_ID)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenInputEmpty() public {
    vm.prank(anyone);
    vm.expectRevert(IFeeSharesMinter.ConditionsNotMet.selector);
    minter.onReport('', abi.encode(new IFeeSharesMinter.HubAssetPair[](0)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenAllUnconfigured() public {
    IFeeSharesMinter.HubAssetPair[] memory pairs = new IFeeSharesMinter.HubAssetPair[](2);
    pairs[0] = IFeeSharesMinter.HubAssetPair(hub, ASSET_ID);
    pairs[1] = IFeeSharesMinter.HubAssetPair(hub, OTHER_ASSET_ID);

    vm.prank(anyone);
    vm.expectRevert(IFeeSharesMinter.ConditionsNotMet.selector);
    minter.onReport('', abi.encode(pairs));
  }

  function test_onReport_skipsStaleUnmintable_andMintsRest() public {
    _setupHappyPath();
    _setupHappyPathOn(hub, OTHER_ASSET_ID);
    vm.prank(admin);
    minter.disableFeeSharesMinting(hub, OTHER_ASSET_ID);

    IFeeSharesMinter.HubAssetPair[] memory pairs = new IFeeSharesMinter.HubAssetPair[](2);
    pairs[0] = IFeeSharesMinter.HubAssetPair(hub, ASSET_ID);
    pairs[1] = IFeeSharesMinter.HubAssetPair(hub, OTHER_ASSET_ID);

    MockHubHelpers.expectMintFeeShares(hub, ASSET_ID);

    vm.prank(anyone);
    minter.onReport('', abi.encode(pairs));
  }

  function test_onReport_mintsMultipleSameHub() public {
    _setupHappyPath();
    _setupHappyPathOn(hub, OTHER_ASSET_ID);

    IFeeSharesMinter.HubAssetPair[] memory pairs = new IFeeSharesMinter.HubAssetPair[](2);
    pairs[0] = IFeeSharesMinter.HubAssetPair(hub, ASSET_ID);
    pairs[1] = IFeeSharesMinter.HubAssetPair(hub, OTHER_ASSET_ID);

    MockHubHelpers.expectMintFeeShares(hub, ASSET_ID);
    MockHubHelpers.expectMintFeeShares(hub, OTHER_ASSET_ID);

    vm.prank(anyone);
    minter.onReport('', abi.encode(pairs));
  }

  function test_onReport_mintsAcrossHubs() public {
    address otherHub = makeAddr('otherHub');
    MockHubHelpers.setAssetCount(otherHub, 5);
    _setupHappyPath();
    _setupHappyPathOn(otherHub, ASSET_ID);

    IFeeSharesMinter.HubAssetPair[] memory pairs = new IFeeSharesMinter.HubAssetPair[](2);
    pairs[0] = IFeeSharesMinter.HubAssetPair(hub, ASSET_ID);
    pairs[1] = IFeeSharesMinter.HubAssetPair(otherHub, ASSET_ID);

    MockHubHelpers.expectMintFeeShares(hub, ASSET_ID);
    MockHubHelpers.expectMintFeeShares(otherHub, ASSET_ID);

    vm.prank(anyone);
    minter.onReport('', abi.encode(pairs));
  }

  function test_rescueToken_onlyOwner() public {
    address token = makeAddr('token');
    vm.mockCall(
      token,
      abi.encodeWithSignature('balanceOf(address)', address(minter)),
      abi.encode(uint256(0))
    );

    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(IRescuable.OnlyRescueGuardian.selector));
    minter.rescueToken(token, bob, 100);
  }

  function test_updateGuardian_byOwner() public {
    address newGuardian = makeAddr('newGuardian');

    vm.expectEmit(address(minter));
    emit IWithGuardian.GuardianUpdated(guardian, newGuardian);

    vm.prank(admin);
    minter.updateGuardian(newGuardian);

    assertEq(minter.guardian(), newGuardian);
  }

  function test_updateGuardian_byGuardian() public {
    address newGuardian = makeAddr('newGuardian');

    vm.prank(guardian);
    minter.updateGuardian(newGuardian);

    assertEq(minter.guardian(), newGuardian);
  }

  function test_updateGuardian_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    minter.updateGuardian(bob);
  }

  function test_transferOwnership() public {
    address newOwner = makeAddr('newOwner');

    vm.prank(admin);
    minter.transferOwnership(newOwner);

    assertEq(minter.owner(), newOwner);
  }

  function test_transferOwnership_revertsWith_OwnableUnauthorized() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
    minter.transferOwnership(bob);
  }

  function _setMinPercent(uint256 assetId, uint16 percent) internal {
    vm.prank(admin);
    minter.updateFeesToAssetsThreshold(hub, assetId, percent);
  }

  function _setupHappyPath() internal {
    _setupHappyPathOn(hub, ASSET_ID);
  }

  function _setupHappyPathOn(address h, uint256 assetId) internal {
    vm.prank(admin);
    minter.updateFeesToAssetsThreshold(h, assetId, HAPPY_THRESHOLD_BPS);
    MockHubHelpers.setAddedAssets(h, assetId, HAPPY_ADDED);
    MockHubHelpers.setAccruedFees(h, assetId, HAPPY_FEES);
    MockHubHelpers.setPreviewShares(h, assetId, HAPPY_FEES, HAPPY_PREVIEW_SHARES);
  }

  function _assertCanMint(bool expected) internal view {
    assertEq(minter.canMint(hub, ASSET_ID), expected);
  }

  function _pairsOne(
    address h,
    uint256 aid
  ) internal pure returns (IFeeSharesMinter.HubAssetPair[] memory pairs) {
    pairs = new IFeeSharesMinter.HubAssetPair[](1);
    pairs[0] = IFeeSharesMinter.HubAssetPair(h, aid);
  }

  function _encodePairs(
    IFeeSharesMinter.HubAssetPair[] memory pairs
  ) internal pure returns (bytes memory) {
    return abi.encode(pairs);
  }

  function _arbitraryMetadata() internal pure returns (bytes memory) {
    return abi.encodePacked(bytes32(uint256(1)), bytes10('any-name'), address(0xCAFE));
  }
}
