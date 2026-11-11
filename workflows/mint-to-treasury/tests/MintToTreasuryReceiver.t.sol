// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IPool} from 'aave-v3-origin/contracts/interfaces/IPool.sol';
import {WadRayMath} from 'aave-v3-origin/contracts/protocol/libraries/math/WadRayMath.sol';

import {IWorkflowsBase} from 'aave-cre/IWorkflowsBase.sol';

import {MintToTreasuryReceiver} from '../src/MintToTreasuryReceiver.sol';
import {IMintToTreasuryReceiver} from '../src/IMintToTreasuryReceiver.sol';

import {MockPoolHelpers} from './helpers/MockPoolHelpers.sol';

contract MintToTreasuryReceiverTest is Test {
  using WadRayMath for uint256;

  MintToTreasuryReceiver internal robot;

  address internal admin = makeAddr('admin');
  address internal guardian = makeAddr('guardian');
  address internal bob = makeAddr('bob');
  address internal anyone = makeAddr('anyone');

  address internal pool = makeAddr('pool');
  address internal provider = makeAddr('provider');
  address internal oracle = makeAddr('oracle');

  address internal weth = makeAddr('weth');
  address internal usdc = makeAddr('usdc');
  address internal dai = makeAddr('dai');

  // 1 WETH scaled * 1.1 income * $2,000 + 1,000 USDC * $1 = $3,200 (8 decimals).
  uint256 internal constant ACCRUED_USD = 3_200e8;
  uint256 internal constant THRESHOLD = 3_000e8;

  function setUp() public {
    robot = new MintToTreasuryReceiver(
      admin,
      guardian,
      new IMintToTreasuryReceiver.PoolThreshold[](0)
    );
  }

  function test_constructor_setsOwnerAndGuardian() public view {
    assertEq(robot.owner(), admin, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
  }

  function test_constructor_setsInitialThresholds() public {
    address otherPool = makeAddr('otherPool');
    IMintToTreasuryReceiver.PoolThreshold[]
      memory initial = new IMintToTreasuryReceiver.PoolThreshold[](2);
    initial[0] = IMintToTreasuryReceiver.PoolThreshold(pool, 5_000e8);
    initial[1] = IMintToTreasuryReceiver.PoolThreshold(otherPool, 1_000e8);

    vm.expectEmit();
    emit IMintToTreasuryReceiver.UsdThresholdUpdated(pool, 5_000e8);
    vm.expectEmit();
    emit IMintToTreasuryReceiver.UsdThresholdUpdated(otherPool, 1_000e8);

    MintToTreasuryReceiver deployed = new MintToTreasuryReceiver(admin, guardian, initial);

    assertEq(deployed.getUsdThreshold(pool), 5_000e8, 'pool threshold mismatch');
    assertEq(deployed.getUsdThreshold(otherPool), 1_000e8, 'otherPool threshold mismatch');
  }

  function test_constructor_revertsWith_InvalidUsdThreshold() public {
    IMintToTreasuryReceiver.PoolThreshold[]
      memory initial = new IMintToTreasuryReceiver.PoolThreshold[](1);
    initial[0] = IMintToTreasuryReceiver.PoolThreshold(pool, 0);

    vm.expectRevert(
      abi.encodeWithSelector(IMintToTreasuryReceiver.InvalidUsdThreshold.selector, 0)
    );
    new MintToTreasuryReceiver(admin, guardian, initial);
  }

  function test_fuzz_updateUsdThreshold(uint256 usdThreshold) public {
    usdThreshold = bound(usdThreshold, 1, type(uint256).max - 1);

    vm.expectEmit(address(robot));
    emit IMintToTreasuryReceiver.UsdThresholdUpdated(pool, usdThreshold);

    vm.prank(admin);
    robot.updateUsdThreshold(pool, usdThreshold);

    assertEq(robot.getUsdThreshold(pool), usdThreshold, 'threshold not stored');
  }

  function test_updateUsdThreshold_revertsWith_OwnableUnauthorized() public {
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
    robot.updateUsdThreshold(pool, THRESHOLD);
  }

  function test_updateUsdThreshold_revertsWhenCalledByGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
    robot.updateUsdThreshold(pool, THRESHOLD);
  }

  function test_updateUsdThreshold_revertsWith_InvalidUsdThreshold_whenZero() public {
    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IMintToTreasuryReceiver.InvalidUsdThreshold.selector, 0)
    );
    robot.updateUsdThreshold(pool, 0);
  }

  function test_updateUsdThreshold_revertsWith_InvalidUsdThreshold_whenDisabledSentinel() public {
    uint256 sentinel = robot.DISABLED_THRESHOLD();

    vm.prank(admin);
    vm.expectRevert(
      abi.encodeWithSelector(IMintToTreasuryReceiver.InvalidUsdThreshold.selector, sentinel)
    );
    robot.updateUsdThreshold(pool, sentinel);
  }

  function test_updateUsdThreshold_independentPerPool() public {
    address otherPool = makeAddr('otherPool');

    vm.startPrank(admin);
    robot.updateUsdThreshold(pool, 100e8);
    robot.updateUsdThreshold(otherPool, 200e8);
    vm.stopPrank();

    assertEq(robot.getUsdThreshold(pool), 100e8, 'pool threshold mismatch');
    assertEq(robot.getUsdThreshold(otherPool), 200e8, 'otherPool threshold mismatch');
    assertEq(robot.getUsdThreshold(makeAddr('unknown')), 0, 'unknown pool should be unset');
  }

  function test_updateUsdThreshold_reEnablesDisabledPool() public {
    _setupHappyPath();

    vm.prank(guardian);
    robot.disableMinting(pool);
    assertFalse(robot.canMint(pool), 'disabled pool should not be mintable');

    vm.prank(admin);
    robot.updateUsdThreshold(pool, THRESHOLD);
    assertTrue(robot.canMint(pool), 're-enabled pool should be mintable');
  }

  function test_disableMinting_byOwner() public {
    _setThreshold(THRESHOLD);

    vm.expectEmit(address(robot));
    emit IMintToTreasuryReceiver.UsdThresholdUpdated(pool, robot.DISABLED_THRESHOLD());

    vm.prank(admin);
    robot.disableMinting(pool);

    assertEq(robot.getUsdThreshold(pool), robot.DISABLED_THRESHOLD(), 'pool not disabled');
  }

  function test_disableMinting_byGuardian() public {
    _setThreshold(THRESHOLD);

    vm.prank(guardian);
    robot.disableMinting(pool);

    assertEq(robot.getUsdThreshold(pool), robot.DISABLED_THRESHOLD(), 'pool not disabled');
  }

  function test_disableMinting_revertsWith_NotOwnerOrGuardian() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.disableMinting(pool);
  }

  function test_disableMinting_onUnconfiguredPool_doesNotRevert() public {
    vm.prank(guardian);
    robot.disableMinting(pool);

    assertEq(robot.getUsdThreshold(pool), robot.DISABLED_THRESHOLD(), 'pool not disabled');
  }

  function test_getAccruedUsd_sumsActiveReservesWithIncomeAndDecimals() public {
    _setupHappyPath();
    assertEq(robot.getAccruedUsd(pool), ACCRUED_USD, 'unexpected accrued USD');
  }

  function test_fuzz_getAccruedUsd(
    uint128 accruedToTreasury,
    uint256 decimals,
    uint256 normalizedIncome,
    uint256 price
  ) public {
    accruedToTreasury = uint128(bound(accruedToTreasury, 1, 1e36));
    decimals = bound(decimals, 0, 30);
    normalizedIncome = bound(normalizedIncome, 1e27, 100e27);
    price = bound(price, 0, 1e20);

    MockPoolHelpers.setOracle(pool, provider, oracle);
    MockPoolHelpers.setReservesList(pool, _one(weth));
    MockPoolHelpers.setReserve(
      pool,
      MockPoolHelpers.Reserve(weth, accruedToTreasury, decimals, true, normalizedIncome)
    );
    MockPoolHelpers.setPrice(oracle, weth, price);

    uint256 expected = (uint256(accruedToTreasury).rayMul(normalizedIncome) * price) /
      10 ** decimals;
    assertEq(robot.getAccruedUsd(pool), expected, 'unexpected accrued USD');
  }

  function test_getAccruedUsd_returnsZero_whenNoReserves() public {
    MockPoolHelpers.setOracle(pool, provider, oracle);
    MockPoolHelpers.setReservesList(pool, new address[](0));

    assertEq(robot.getAccruedUsd(pool), 0, 'expected no accrued USD');
  }

  function test_getAccruedUsd_countsZeroPriceAsZero() public {
    _setupHappyPath();
    MockPoolHelpers.setPrice(oracle, weth, 0);

    assertEq(robot.getAccruedUsd(pool), 1_000e8, 'only USDC should be valued');
  }

  function test_getAccruedUsd_countsRevertingOracleAsZero() public {
    _setupHappyPath();
    MockPoolHelpers.setPriceReverts(oracle, weth);

    assertEq(robot.getAccruedUsd(pool), 1_000e8, 'only USDC should be valued');
  }

  function test_getAccruedUsd_skipsInactiveReserve() public {
    _setupHappyPath();
    MockPoolHelpers.setReserve(pool, MockPoolHelpers.Reserve(weth, 1e18, 18, false, 1.1e27));

    assertEq(robot.getAccruedUsd(pool), 1_000e8, 'inactive WETH should not be valued');
  }

  function test_canMint_revertsWith_NotConfigured() public {
    vm.expectRevert(abi.encodeWithSelector(IMintToTreasuryReceiver.NotConfigured.selector, pool));
    robot.canMint(pool);
  }

  function test_canMint_returnsTrue_aboveThreshold() public {
    _setupHappyPath();
    assertTrue(robot.canMint(pool), 'should mint above threshold');
  }

  function test_canMint_returnsTrue_atThreshold() public {
    _setupHappyPath();
    _setThreshold(ACCRUED_USD);
    assertTrue(robot.canMint(pool), 'should mint at threshold');
  }

  function test_canMint_returnsFalse_belowThreshold() public {
    _setupHappyPath();
    _setThreshold(ACCRUED_USD + 1);
    assertFalse(robot.canMint(pool), 'should not mint below threshold');
  }

  function test_fuzz_canMint_matchesThreshold(uint256 usdThreshold) public {
    usdThreshold = bound(usdThreshold, 1, type(uint256).max - 1);
    _setupHappyPath();
    _setThreshold(usdThreshold);

    assertEq(robot.canMint(pool), ACCRUED_USD >= usdThreshold, 'canMint disagrees with threshold');
  }

  function test_canMint_returnsFalse_whenDisabled() public {
    _setupHappyPath();

    vm.prank(guardian);
    robot.disableMinting(pool);

    assertFalse(robot.canMint(pool), 'disabled pool should not be mintable');
  }

  function test_canMint_returnsFalse_whenNothingAccrued() public {
    _setupHappyPath();
    MockPoolHelpers.setReserve(pool, MockPoolHelpers.Reserve(weth, 0, 18, true, 1.1e27));
    MockPoolHelpers.setReserve(pool, MockPoolHelpers.Reserve(usdc, 0, 6, true, 1e27));

    assertFalse(robot.canMint(pool), 'nothing to mint');
  }

  function test_checkUpkeep_returnsMintablePools() public {
    _setupHappyPath();

    bytes memory checkData = abi.encode(_one(pool));
    (bool upkeepNeeded, bytes memory performData) = robot.checkUpkeep(checkData);

    assertTrue(upkeepNeeded, 'upkeep should be needed');
    assertEq(performData, checkData, 'performData should list the pool');
  }

  function test_checkUpkeep_returnsFalse_whenCheckDataEmpty() public view {
    (bool upkeepNeeded, bytes memory performData) = robot.checkUpkeep('');

    assertFalse(upkeepNeeded, 'upkeep should not be needed');
    assertEq(performData, '', 'performData should be empty');
  }

  function test_checkUpkeep_returnsFalse_whenNoPools() public view {
    (bool upkeepNeeded, bytes memory performData) = robot.checkUpkeep(abi.encode(new address[](0)));

    assertFalse(upkeepNeeded, 'upkeep should not be needed');
    assertEq(performData, '', 'performData should be empty');
  }

  function test_checkUpkeep_skipsUnconfigured() public view {
    (bool upkeepNeeded, bytes memory performData) = robot.checkUpkeep(abi.encode(_one(pool)));

    assertFalse(upkeepNeeded, 'upkeep should not be needed');
    assertEq(performData, '', 'performData should be empty');
  }

  function test_checkUpkeep_returnsFalse_whenAutomationDisabled() public {
    _setupHappyPath();
    vm.prank(guardian);
    robot.disableAutomation();

    (bool upkeepNeeded, ) = robot.checkUpkeep(abi.encode(_one(pool)));
    assertFalse(upkeepNeeded, 'disabled robot should not need upkeep');
  }

  function test_checkUpkeep_filtersToMintableSubset() public {
    _setupHappyPath();
    address belowPool = makeAddr('belowPool');
    address disabledPool = makeAddr('disabledPool');
    _setupPool(belowPool);
    _setupPool(disabledPool);

    vm.startPrank(admin);
    robot.updateUsdThreshold(belowPool, ACCRUED_USD + 1);
    robot.disableMinting(disabledPool);
    vm.stopPrank();

    address[] memory pools = new address[](4);
    pools[0] = belowPool;
    pools[1] = pool;
    pools[2] = disabledPool;
    pools[3] = makeAddr('unconfiguredPool');

    (bool upkeepNeeded, bytes memory performData) = robot.checkUpkeep(abi.encode(pools));

    assertTrue(upkeepNeeded, 'upkeep should be needed');
    assertEq(performData, abi.encode(_one(pool)), 'only the pool above threshold is mintable');
  }

  function test_onReport_mintsReservesWithAccruedToTreasury() public {
    _setupHappyPath();
    MockPoolHelpers.expectMintToTreasury(pool, _two(weth, usdc));

    vm.prank(anyone);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function test_onReport_ignoresMetadataContents() public {
    _setupHappyPath();
    MockPoolHelpers.expectMintToTreasury(pool, _two(weth, usdc));

    bytes memory junk = abi.encodePacked(
      bytes32(uint256(0xdead)),
      bytes10('junk'),
      address(0xBEEF)
    );
    vm.prank(anyone);
    robot.onReport(junk, abi.encode(_one(pool)));
  }

  function test_onReport_includesZeroPriceReserve() public {
    _setupHappyPath();
    _setThreshold(1_000e8);
    MockPoolHelpers.setPrice(oracle, weth, 0);
    MockPoolHelpers.expectMintToTreasury(pool, _two(weth, usdc));

    vm.prank(anyone);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function test_onReport_includesRevertingOracleReserve() public {
    _setupHappyPath();
    _setThreshold(1_000e8);
    MockPoolHelpers.setPriceReverts(oracle, weth);
    MockPoolHelpers.expectMintToTreasury(pool, _two(weth, usdc));

    vm.prank(anyone);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function test_onReport_excludesInactiveReserve() public {
    _setupHappyPath();
    _setThreshold(1_000e8);
    MockPoolHelpers.setReserve(pool, MockPoolHelpers.Reserve(weth, 1e18, 18, false, 1.1e27));
    MockPoolHelpers.expectMintToTreasury(pool, _one(usdc));

    vm.prank(anyone);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function test_onReport_mintsAcrossPools_andSkipsUnmintable() public {
    _setupHappyPath();
    address otherPool = makeAddr('otherPool');
    address belowPool = makeAddr('belowPool');
    _setupPool(otherPool);
    _setupPool(belowPool);

    vm.startPrank(admin);
    robot.updateUsdThreshold(otherPool, THRESHOLD);
    robot.updateUsdThreshold(belowPool, ACCRUED_USD + 1);
    vm.stopPrank();

    address[] memory pools = new address[](3);
    pools[0] = pool;
    pools[1] = belowPool;
    pools[2] = otherPool;

    MockPoolHelpers.expectMintToTreasury(pool, _two(weth, usdc));
    MockPoolHelpers.expectMintToTreasury(otherPool, _two(weth, usdc));
    vm.expectCall(belowPool, abi.encodeWithSelector(IPool.mintToTreasury.selector), 0);

    vm.prank(anyone);
    robot.onReport('', abi.encode(pools));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenBelowThreshold() public {
    _setupHappyPath();
    _setThreshold(ACCRUED_USD + 1);

    vm.prank(anyone);
    vm.expectRevert(IMintToTreasuryReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenDisabled() public {
    _setupHappyPath();

    vm.prank(guardian);
    robot.disableMinting(pool);

    vm.prank(anyone);
    vm.expectRevert(IMintToTreasuryReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenUnconfigured() public {
    vm.prank(anyone);
    vm.expectRevert(IMintToTreasuryReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function test_onReport_revertsWith_ConditionsNotMet_whenInputEmpty() public {
    vm.prank(anyone);
    vm.expectRevert(IMintToTreasuryReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(new address[](0)));
  }

  function test_onReport_revertsWith_AutomationIsDisabled() public {
    _setupHappyPath();
    vm.prank(guardian);
    robot.disableAutomation();

    vm.prank(anyone);
    vm.expectRevert(IWorkflowsBase.AutomationIsDisabled.selector);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function test_enableAutomation_resumesUpkeepAndReports() public {
    _setupHappyPath();
    vm.prank(guardian);
    robot.disableAutomation();
    vm.prank(admin);
    robot.enableAutomation();

    (bool upkeepNeeded, ) = robot.checkUpkeep(abi.encode(_one(pool)));
    assertTrue(upkeepNeeded, 'upkeep should resume');

    MockPoolHelpers.expectMintToTreasury(pool, _two(weth, usdc));
    vm.prank(anyone);
    robot.onReport('', abi.encode(_one(pool)));
  }

  function _setupHappyPath() internal {
    _setupPool(pool);
    _setThreshold(THRESHOLD);
  }

  /// @dev WETH: 1e18 scaled at a 1.1 income, $2,000. USDC: 1,000e6 scaled at a 1.0 income, $1.
  /// DAI: nothing accrued.
  function _setupPool(address target) internal {
    address[] memory reserves = new address[](3);
    reserves[0] = weth;
    reserves[1] = dai;
    reserves[2] = usdc;

    MockPoolHelpers.setOracle(target, provider, oracle);
    MockPoolHelpers.setReservesList(target, reserves);
    MockPoolHelpers.setReserve(target, MockPoolHelpers.Reserve(weth, 1e18, 18, true, 1.1e27));
    MockPoolHelpers.setReserve(target, MockPoolHelpers.Reserve(dai, 0, 18, true, 1e27));
    MockPoolHelpers.setReserve(target, MockPoolHelpers.Reserve(usdc, 1_000e6, 6, true, 1e27));
    MockPoolHelpers.setPrice(oracle, weth, 2_000e8);
    MockPoolHelpers.setPrice(oracle, dai, 1e8);
    MockPoolHelpers.setPrice(oracle, usdc, 1e8);
  }

  function _setThreshold(uint256 usdThreshold) internal {
    vm.prank(admin);
    robot.updateUsdThreshold(pool, usdThreshold);
  }

  function _one(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }

  function _two(address a, address b) internal pure returns (address[] memory arr) {
    arr = new address[](2);
    arr[0] = a;
    arr[1] = b;
  }
}
