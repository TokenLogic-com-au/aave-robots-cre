// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {GsmFreezerReceiver} from '../src/GsmFreezerReceiver.sol';
import {IGsmFreezerReceiver, IGsm, IPoolAddressesProvider, IPriceOracle} from '../src/IGsmFreezerReceiver.sol';

contract GsmFreezerReceiverTest is Test {
  uint256 internal constant FREEZE_LOWER = 0.99e8;
  uint256 internal constant FREEZE_UPPER = 1.01e8;
  uint256 internal constant UNFREEZE_LOWER = 0.995e8;
  uint256 internal constant UNFREEZE_UPPER = 1.005e8;
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

    robot = new GsmFreezerReceiver(
      gsm,
      underlying,
      provider,
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: FREEZE_LOWER,
        freezeUpperBound: FREEZE_UPPER,
        unfreezeLowerBound: UNFREEZE_LOWER,
        unfreezeUpperBound: UNFREEZE_UPPER
      }),
      true,
      owner,
      guardian
    );
  }

  function test_constructor_setsImmutables() public view {
    assertEq(robot.owner(), owner);
    assertEq(robot.guardian(), guardian);
    assertEq(address(robot.GSM()), gsm);
    assertEq(robot.UNDERLYING_ASSET(), underlying);
    assertEq(address(robot.ADDRESS_PROVIDER()), provider);
    assertEq(robot.FREEZE_LOWER_BOUND(), FREEZE_LOWER);
    assertEq(robot.FREEZE_UPPER_BOUND(), FREEZE_UPPER);
    assertEq(robot.UNFREEZE_LOWER_BOUND(), UNFREEZE_LOWER);
    assertEq(robot.UNFREEZE_UPPER_BOUND(), UNFREEZE_UPPER);
    assertTrue(robot.ALLOW_UNFREEZE());
  }

  function test_constructor_revertsWith_InvalidBounds_whenNotNested() public {
    vm.expectRevert(IGsmFreezerReceiver.InvalidBounds.selector);
    new GsmFreezerReceiver(
      gsm,
      underlying,
      provider,
      // unfreeze band not nested inside freeze band
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: 0.99e8,
        freezeUpperBound: 1.01e8,
        unfreezeLowerBound: 0.98e8,
        unfreezeUpperBound: 1.005e8
      }),
      true,
      owner,
      guardian
    );
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId));
    assertTrue(robot.supportsInterface(type(IAaveCREReceiver).interfaceId));
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId));
    assertFalse(robot.supportsInterface(0xffffffff));
  }

  function test_checkUpkeep_returnsFalse_whenRoleMissing() public {
    _mockState({price: 0.90e8, frozen: false, seized: false, robotHasRole: false});
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsFalse_whenSeized() public {
    _mockState({price: 0.90e8, frozen: false, seized: true, robotHasRole: true});
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsFalse_whenPriceZero() public {
    _mockState({price: 0, frozen: false, seized: false, robotHasRole: true});
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsFalse_whenPriceInBand() public {
    _mockState({price: 1e8, frozen: false, seized: false, robotHasRole: true});
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_freezes_whenPriceAtOrBelowLowerBound() public {
    _mockState({price: FREEZE_LOWER, frozen: false, seized: false, robotHasRole: true});
    _assertAction(IGsmFreezerReceiver.Action.FREEZE);
  }

  function test_checkUpkeep_freezes_whenPriceAtOrAboveUpperBound() public {
    _mockState({price: FREEZE_UPPER, frozen: false, seized: false, robotHasRole: true});
    _assertAction(IGsmFreezerReceiver.Action.FREEZE);
  }

  function test_checkUpkeep_returnsFalse_whenFrozenAndPriceStillOutOfBand() public {
    _mockState({price: 0.90e8, frozen: true, seized: false, robotHasRole: true});
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_unfreezes_whenFrozenAndPriceBackInInnerBand() public {
    _mockState({price: 1e8, frozen: true, seized: false, robotHasRole: true});
    _assertAction(IGsmFreezerReceiver.Action.UNFREEZE);
  }

  function test_checkUpkeep_doesNotUnfreeze_whenAllowUnfreezeFalse() public {
    GsmFreezerReceiver noUnfreeze = new GsmFreezerReceiver(
      gsm,
      underlying,
      provider,
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: FREEZE_LOWER,
        freezeUpperBound: FREEZE_UPPER,
        unfreezeLowerBound: UNFREEZE_LOWER,
        unfreezeUpperBound: UNFREEZE_UPPER
      }),
      false,
      owner,
      guardian
    );
    _mockStateFor(address(noUnfreeze), 1e8, true, false, true);
    (bool needed, ) = noUnfreeze.checkUpkeep('');
    assertFalse(needed);
  }

  function test_checkUpkeep_returnsFalse_whenDisabled() public {
    _mockState({price: 0.90e8, frozen: false, seized: false, robotHasRole: true});
    vm.prank(guardian);
    robot.setDisabled(true);
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed);
  }

  function test_onReport_freezes_whenPriceOutOfBand() public {
    _mockState({price: 0.90e8, frozen: false, seized: false, robotHasRole: true});
    vm.expectCall(gsm, abi.encodeCall(IGsm.setSwapFreeze, (true)));
    vm.expectEmit(address(robot));
    emit IGsmFreezerReceiver.SwapFreezeSet(true);
    vm.prank(anyone);
    robot.onReport('', '');
  }

  function test_onReport_unfreezes_whenPriceBackInBand() public {
    _mockState({price: 1e8, frozen: true, seized: false, robotHasRole: true});
    vm.expectCall(gsm, abi.encodeCall(IGsm.setSwapFreeze, (false)));
    vm.expectEmit(address(robot));
    emit IGsmFreezerReceiver.SwapFreezeSet(false);
    vm.prank(anyone);
    robot.onReport('', '');
  }

  function test_onReport_revertsWith_NoActionPossible_whenPriceInBand() public {
    _mockState({price: 1e8, frozen: false, seized: false, robotHasRole: true});
    vm.expectRevert(IGsmFreezerReceiver.NoActionPossible.selector);
    robot.onReport('', '');
  }

  // A report signed while the price was out of band must NOT force a freeze once
  // the price has recovered: onReport re-derives the action from live state.
  function test_onReport_revalidates_whenPriceRecoveredBeforeExecution() public {
    _mockState({price: 0.90e8, frozen: false, seized: false, robotHasRole: true});
    (bool needed, ) = robot.checkUpkeep('');
    assertTrue(needed);

    _mockState({price: 1e8, frozen: false, seized: false, robotHasRole: true});
    vm.expectRevert(IGsmFreezerReceiver.NoActionPossible.selector);
    robot.onReport('', '');
  }

  function test_onReport_revertsWith_NoActionPossible_whenSeized() public {
    _mockState({price: 0.90e8, frozen: false, seized: true, robotHasRole: true});
    vm.expectRevert(IGsmFreezerReceiver.NoActionPossible.selector);
    robot.onReport('', '');
  }

  function test_constructor_revertsWith_InvalidBounds_onEqualAdjacentBound() public {
    // freezeLowerBound == unfreezeLowerBound
    vm.expectRevert(IGsmFreezerReceiver.InvalidBounds.selector);
    new GsmFreezerReceiver(
      gsm,
      underlying,
      provider,
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: 0.99e8,
        freezeUpperBound: 1.01e8,
        unfreezeLowerBound: 0.99e8,
        unfreezeUpperBound: 1.005e8
      }),
      true,
      owner,
      guardian
    );

    // unfreezeLowerBound == unfreezeUpperBound
    vm.expectRevert(IGsmFreezerReceiver.InvalidBounds.selector);
    new GsmFreezerReceiver(
      gsm,
      underlying,
      provider,
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: 0.99e8,
        freezeUpperBound: 1.01e8,
        unfreezeLowerBound: 1e8,
        unfreezeUpperBound: 1e8
      }),
      true,
      owner,
      guardian
    );

    // unfreezeUpperBound == freezeUpperBound
    vm.expectRevert(IGsmFreezerReceiver.InvalidBounds.selector);
    new GsmFreezerReceiver(
      gsm,
      underlying,
      provider,
      IGsmFreezerReceiver.Bounds({
        freezeLowerBound: 0.99e8,
        freezeUpperBound: 1.01e8,
        unfreezeLowerBound: 0.995e8,
        unfreezeUpperBound: 1.01e8
      }),
      true,
      owner,
      guardian
    );
  }

  function test_setDisabled_togglesAndEmits() public {
    assertFalse(robot.isDisabled());
    vm.expectEmit(address(robot));
    emit IGsmFreezerReceiver.AutomationDisabled(true);
    vm.prank(owner);
    robot.setDisabled(true);
    assertTrue(robot.isDisabled());
  }

  function test_setDisabled_revertsWith_NotOwnerOrGuardian() public {
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, anyone)
    );
    vm.prank(anyone);
    robot.setDisabled(true);
  }

  function _assertAction(IGsmFreezerReceiver.Action expected) internal view {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed);
    assertEq(uint256(abi.decode(performData, (IGsmFreezerReceiver.Action))), uint256(expected));
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
      abi.encodeCall(IPriceOracle.getAssetPrice, (underlying)),
      abi.encode(price)
    );
    vm.mockCall(gsm, abi.encodeWithSelector(IGsm.setSwapFreeze.selector), '');
  }
}
