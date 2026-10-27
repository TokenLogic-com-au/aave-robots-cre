// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IPoolAddressesProvider} from 'aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from 'aave-v3-origin/contracts/interfaces/IPriceOracleGetter.sol';

import {IWorkflowsBase} from 'aave-cre/IWorkflowsBase.sol';

import {GsmFreezerReceiver} from '../src/GsmFreezerReceiver.sol';
import {IGsmFreezerReceiver, IGsm} from '../src/IGsmFreezerReceiver.sol';

contract GsmFreezerReceiverTest is Test {
  uint256 internal constant FREEZE_LOWER = 0.99e8;
  uint256 internal constant FREEZE_UPPER = 1.01e8;
  uint256 internal constant UNFREEZE_LOWER = 0.995e8;
  uint256 internal constant UNFREEZE_UPPER = 1.005e8;
  uint256 internal constant PEG_PRICE = 1e8;
  uint256 internal constant DEPEGGED_PRICE = 0.90e8;
  uint256 internal constant MAX_FUZZ_PRICE = 2e8;
  bytes32 internal constant ROLE = keccak256('SWAP_FREEZER_ROLE');

  GsmFreezerReceiver internal robot;

  address internal owner;
  address internal guardian;
  address internal anyone;

  address internal gsm;
  address internal underlying;
  address internal provider;
  address internal oracle;

  function setUp() public {
    owner = makeAddr('owner');
    guardian = makeAddr('guardian');
    anyone = makeAddr('anyone');

    gsm = makeAddr('gsm');
    underlying = makeAddr('underlying');
    provider = makeAddr('provider');
    oracle = makeAddr('oracle');

    robot = _deploy(_bounds(UNFREEZE_LOWER, UNFREEZE_UPPER), true);
  }

  function test_constructor_setsImmutables() public view {
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
    assertEq(address(robot.GSM()), gsm, 'gsm mismatch');
    assertEq(robot.UNDERLYING_ASSET(), underlying, 'underlying mismatch');
    assertEq(address(robot.ADDRESS_PROVIDER()), provider, 'provider mismatch');
    assertEq(robot.FREEZE_LOWER_BOUND(), FREEZE_LOWER, 'freeze lower mismatch');
    assertEq(robot.FREEZE_UPPER_BOUND(), FREEZE_UPPER, 'freeze upper mismatch');
    assertEq(robot.UNFREEZE_LOWER_BOUND(), UNFREEZE_LOWER, 'unfreeze lower mismatch');
    assertEq(robot.UNFREEZE_UPPER_BOUND(), UNFREEZE_UPPER, 'unfreeze upper mismatch');
    assertTrue(robot.ALLOW_UNFREEZE(), 'allowUnfreeze mismatch');
  }

  function test_constructor_revertsWith_InvalidAddress() public {
    IGsmFreezerReceiver.Bounds memory bounds = _bounds(UNFREEZE_LOWER, UNFREEZE_UPPER);
    address[3] memory gsms = [address(0), gsm, gsm];
    address[3] memory underlyings = [underlying, address(0), underlying];
    address[3] memory providers = [provider, provider, address(0)];
    for (uint256 i = 0; i < 3; i++) {
      vm.expectRevert(IGsmFreezerReceiver.InvalidAddress.selector);
      new GsmFreezerReceiver(gsms[i], underlyings[i], providers[i], bounds, true, owner, guardian);
    }
  }

  function test_constructor_revertsWith_InvalidBounds_whenFreezeBandInverted() public {
    IGsmFreezerReceiver.Bounds memory bounds = IGsmFreezerReceiver.Bounds({
      freezeLowerBound: FREEZE_UPPER,
      freezeUpperBound: FREEZE_LOWER,
      unfreezeLowerBound: 0,
      unfreezeUpperBound: 0
    });
    vm.expectRevert(IGsmFreezerReceiver.InvalidBounds.selector);
    _deploy(bounds, false);
  }

  function test_constructor_revertsWith_InvalidBounds_whenUnfreezeBandNotNested() public {
    uint256[2][4] memory unfreezeBands = [
      [uint256(0.98e8), UNFREEZE_UPPER], // below the freeze band
      [FREEZE_LOWER, UNFREEZE_UPPER], // touches freezeLowerBound
      [UNFREEZE_LOWER, FREEZE_UPPER], // touches freezeUpperBound
      [PEG_PRICE, PEG_PRICE] // empty unfreeze band
    ];
    for (uint256 i = 0; i < unfreezeBands.length; i++) {
      vm.expectRevert(IGsmFreezerReceiver.InvalidBounds.selector);
      _deploy(_bounds(unfreezeBands[i][0], unfreezeBands[i][1]), true);
    }
  }

  function test_constructor_freezeOnly_requiresZeroUnfreezeBounds() public {
    GsmFreezerReceiver freezeOnly = _deploy(_bounds(0, 0), false);
    assertFalse(freezeOnly.ALLOW_UNFREEZE(), 'allowUnfreeze should be false');

    uint256[2][3] memory nonZero = [
      [UNFREEZE_LOWER, UNFREEZE_UPPER],
      [UNFREEZE_LOWER, uint256(0)],
      [uint256(0), UNFREEZE_UPPER]
    ];
    for (uint256 i = 0; i < nonZero.length; i++) {
      vm.expectRevert(IGsmFreezerReceiver.InvalidBounds.selector);
      _deploy(_bounds(nonZero[i][0], nonZero[i][1]), false);
    }
  }

  function test_constructor_freezeOnly_revertsWith_InvalidBounds_whenFreezeBoundsEqual() public {
    IGsmFreezerReceiver.Bounds memory bounds = IGsmFreezerReceiver.Bounds({
      freezeLowerBound: PEG_PRICE,
      freezeUpperBound: PEG_PRICE,
      unfreezeLowerBound: 0,
      unfreezeUpperBound: 0
    });
    vm.expectRevert(IGsmFreezerReceiver.InvalidBounds.selector);
    _deploy(bounds, false);
  }

  function test_fuzz_checkUpkeep_followsPriceBands(uint256 price, bool frozen) public {
    price = bound(price, 1, MAX_FUZZ_PRICE);
    _mockState(price, frozen, false, true);

    IGsmFreezerReceiver.Action expected = IGsmFreezerReceiver.Action.NONE;
    if (!frozen && (price <= FREEZE_LOWER || price >= FREEZE_UPPER)) {
      expected = IGsmFreezerReceiver.Action.FREEZE;
    } else if (frozen && price >= UNFREEZE_LOWER && price <= UNFREEZE_UPPER) {
      expected = IGsmFreezerReceiver.Action.UNFREEZE;
    }
    _assertAction(robot, expected);
  }

  function test_checkUpkeep_freezes_atInclusiveFreezeBounds() public {
    _mockState(FREEZE_LOWER, false, false, true);
    _assertAction(robot, IGsmFreezerReceiver.Action.FREEZE);
    _mockState(FREEZE_UPPER, false, false, true);
    _assertAction(robot, IGsmFreezerReceiver.Action.FREEZE);
  }

  function test_checkUpkeep_unfreezes_atInclusiveUnfreezeBounds() public {
    _mockState(UNFREEZE_LOWER, true, false, true);
    _assertAction(robot, IGsmFreezerReceiver.Action.UNFREEZE);
    _mockState(UNFREEZE_UPPER, true, false, true);
    _assertAction(robot, IGsmFreezerReceiver.Action.UNFREEZE);
  }

  function test_checkUpkeep_returnsFalse_whenRoleMissing() public {
    _mockState(DEPEGGED_PRICE, false, false, false);
    _assertAction(robot, IGsmFreezerReceiver.Action.NONE);
  }

  function test_checkUpkeep_returnsFalse_whenSeized() public {
    _mockState(DEPEGGED_PRICE, false, true, true);
    _assertAction(robot, IGsmFreezerReceiver.Action.NONE);
  }

  function test_checkUpkeep_returnsFalse_whenPriceZero() public {
    _mockState(0, false, false, true);
    _assertAction(robot, IGsmFreezerReceiver.Action.NONE);
  }

  function test_checkUpkeep_returnsFalse_whenDisabled() public {
    _mockState(DEPEGGED_PRICE, false, false, true);
    vm.prank(guardian);
    robot.disableAutomation();

    _assertAction(robot, IGsmFreezerReceiver.Action.NONE);
  }

  /// Like `OracleSwapFreezer`, a frozen freeze-only robot has nothing to do and doesn't
  /// read the oracle, so a reverting oracle can't make `checkUpkeep` revert.
  function test_checkUpkeep_freezeOnly_skipsOracle_whenFrozen() public {
    GsmFreezerReceiver freezeOnly = _deploy(_bounds(0, 0), false);
    _mockStateFor(address(freezeOnly), PEG_PRICE, true, false, true);
    vm.mockCallRevert(
      oracle,
      abi.encodeCall(IPriceOracleGetter.getAssetPrice, (underlying)),
      'oracle down'
    );
    _assertAction(freezeOnly, IGsmFreezerReceiver.Action.NONE);
  }

  function test_onReport_freezes_whenAnyoneCalls() public {
    _mockState(DEPEGGED_PRICE, false, false, true);
    vm.expectCall(gsm, abi.encodeCall(IGsm.setSwapFreeze, (true)));
    vm.expectEmit(address(robot));
    emit IGsmFreezerReceiver.SwapFreezeSet(true);

    vm.prank(anyone);
    robot.onReport('', '');
  }

  function test_onReport_unfreezes_whenPriceBackInUnfreezeBand() public {
    _mockState(PEG_PRICE, true, false, true);
    vm.expectCall(gsm, abi.encodeCall(IGsm.setSwapFreeze, (false)));
    vm.expectEmit(address(robot));
    emit IGsmFreezerReceiver.SwapFreezeSet(false);

    vm.prank(anyone);
    robot.onReport('', '');
  }

  function test_onReport_revertsWith_NoActionPossible_whenPriceRecoveredBeforeExecution() public {
    _mockState(DEPEGGED_PRICE, false, false, true);
    _assertAction(robot, IGsmFreezerReceiver.Action.FREEZE);

    _mockState(PEG_PRICE, false, false, true);
    vm.expectCall(gsm, abi.encodeWithSelector(IGsm.setSwapFreeze.selector), 0);
    vm.prank(anyone);
    vm.expectRevert(IGsmFreezerReceiver.NoActionPossible.selector);
    robot.onReport('', abi.encode(IGsmFreezerReceiver.Action.FREEZE));
  }

  function test_onReport_revertsWith_AutomationIsDisabled_whenDepegged() public {
    _mockState(DEPEGGED_PRICE, false, false, true);
    vm.prank(guardian);
    robot.disableAutomation();

    vm.expectCall(gsm, abi.encodeWithSelector(IGsm.setSwapFreeze.selector), 0);
    vm.prank(anyone);
    vm.expectRevert(IWorkflowsBase.AutomationIsDisabled.selector);
    robot.onReport('', '');
  }

  function test_onReport_revertsWith_NoActionPossible_whenSeized() public {
    _mockState(DEPEGGED_PRICE, false, true, true);
    vm.expectCall(gsm, abi.encodeWithSelector(IGsm.setSwapFreeze.selector), 0);
    vm.prank(anyone);
    vm.expectRevert(IGsmFreezerReceiver.NoActionPossible.selector);
    robot.onReport('', '');
  }

  function _deploy(
    IGsmFreezerReceiver.Bounds memory bounds,
    bool allowUnfreeze
  ) internal returns (GsmFreezerReceiver) {
    return
      new GsmFreezerReceiver(gsm, underlying, provider, bounds, allowUnfreeze, owner, guardian);
  }

  function _bounds(
    uint256 unfreezeLower,
    uint256 unfreezeUpper
  ) internal pure returns (IGsmFreezerReceiver.Bounds memory) {
    return
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: FREEZE_LOWER,
        freezeUpperBound: FREEZE_UPPER,
        unfreezeLowerBound: unfreezeLower,
        unfreezeUpperBound: unfreezeUpper
      });
  }

  function _assertAction(
    GsmFreezerReceiver robot_,
    IGsmFreezerReceiver.Action expected
  ) internal view {
    (bool needed, bytes memory performData) = robot_.checkUpkeep('');
    assertEq(needed, expected != IGsmFreezerReceiver.Action.NONE, 'unexpected upkeepNeeded');
    if (needed) {
      assertEq(
        uint256(abi.decode(performData, (IGsmFreezerReceiver.Action))),
        uint256(expected),
        'unexpected action'
      );
    } else {
      assertEq(performData.length, 0, 'performData should be empty');
    }
  }

  function _mockState(uint256 price, bool frozen, bool seized, bool robotHasRole) internal {
    _mockStateFor(address(robot), price, frozen, seized, robotHasRole);
  }

  function _mockStateFor(
    address robot_,
    uint256 price,
    bool frozen,
    bool seized,
    bool robotHasRole
  ) internal {
    vm.mockCall(gsm, abi.encodeCall(IGsm.SWAP_FREEZER_ROLE, ()), abi.encode(ROLE));
    vm.mockCall(gsm, abi.encodeCall(IGsm.hasRole, (ROLE, robot_)), abi.encode(robotHasRole));
    vm.mockCall(gsm, abi.encodeCall(IGsm.getIsSeized, ()), abi.encode(seized));
    vm.mockCall(gsm, abi.encodeCall(IGsm.getIsFrozen, ()), abi.encode(frozen));
    vm.mockCall(
      provider,
      abi.encodeCall(IPoolAddressesProvider.getPriceOracle, ()),
      abi.encode(oracle)
    );
    vm.mockCall(
      oracle,
      abi.encodeCall(IPriceOracleGetter.getAssetPrice, (underlying)),
      abi.encode(price)
    );
    vm.mockCall(gsm, abi.encodeWithSelector(IGsm.setSwapFreeze.selector), '');
  }
}
