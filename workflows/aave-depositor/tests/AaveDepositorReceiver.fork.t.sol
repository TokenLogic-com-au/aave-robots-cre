// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';

import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {MiscEthereum} from 'aave-address-book/MiscEthereum.sol';

import {AaveDepositorReceiver} from '../src/AaveDepositorReceiver.sol';
import {IAaveDepositorReceiver, IPoolExposureSteward} from '../src/IAaveDepositorReceiver.sol';
import {AaveDepositorEthereum} from '../scripts/AaveDepositorEthereum.sol';

interface IModuleManager {
  function enableModule(address module) external;
  function isModuleEnabled(address module) external view returns (bool);
}

interface IRolesAdmin is IModuleManager {
  function assignRoles(
    address module,
    bytes32[] calldata roleKeys,
    bool[] calldata memberOf
  ) external;
}

contract AaveDepositorReceiverForkTest is Test {
  address internal constant FORWARDER = AaveDepositorEthereum.FORWARDER;
  address internal constant ROLES = AaveDepositorEthereum.ROLES;
  bytes32 internal constant ROLE_KEY = AaveDepositorEthereum.ROLE_KEY;
  uint256 internal constant AMOUNT = 1_000_000e6;

  AaveDepositorReceiver internal robot;
  address internal anyone = makeAddr('anyone');

  function setUp() public {
    vm.createSelectFork(vm.envString('RPC_MAINNET'));
    robot = new AaveDepositorReceiver(
      FORWARDER,
      ROLES,
      AaveV3Ethereum.POOL_EXPOSURE_STEWARD,
      ROLE_KEY,
      GovernanceV3Ethereum.EXECUTOR_LVL_1,
      GovernanceV3Ethereum.GOVERNANCE_GUARDIAN
    );
  }

  function test_fork_onReport_revertsWithoutRole() public {
    bytes memory report = _depositReport(AMOUNT);
    (bool needed, ) = robot.checkUpkeep(report);
    assertTrue(needed, 'checkUpkeep should accept an allowed deposit');

    vm.prank(FORWARDER);
    vm.expectRevert();
    robot.onReport('', report);
  }

  // The AFC Safe wires the Roles Modifier as its module (not yet done on mainnet),
  // enables the robot on Roles and grants it the role; then a forwarder-delivered
  // report supplies Collector USDC into the real V3 pool.
  function test_fork_onReport_depositsCollectorFunds_onceGranted() public {
    _grantRole();
    deal(AaveV3EthereumAssets.USDC_UNDERLYING, address(AaveV3Ethereum.COLLECTOR), AMOUNT);
    IERC20 usdc = IERC20(AaveV3EthereumAssets.USDC_UNDERLYING);
    IERC20 aUsdc = IERC20(AaveV3EthereumAssets.USDC_A_TOKEN);
    uint256 usdcBefore = usdc.balanceOf(address(AaveV3Ethereum.COLLECTOR));
    uint256 aUsdcBefore = aUsdc.balanceOf(address(AaveV3Ethereum.COLLECTOR));

    vm.prank(FORWARDER);
    robot.onReport('', _depositReport(AMOUNT));

    assertEq(
      usdcBefore - usdc.balanceOf(address(AaveV3Ethereum.COLLECTOR)),
      AMOUNT,
      'collector usdc not deposited'
    );
    assertApproxEqAbs(
      aUsdc.balanceOf(address(AaveV3Ethereum.COLLECTOR)) - aUsdcBefore,
      AMOUNT,
      1,
      'collector did not receive aUSDC'
    );
  }

  function test_fork_onReport_revertsWith_InvalidSender_forNonForwarder() public {
    _grantRole();
    vm.prank(anyone);
    vm.expectRevert(abi.encodeWithSelector(IAaveDepositorReceiver.InvalidSender.selector, anyone));
    robot.onReport('', _depositReport(AMOUNT));
  }

  // multicall is not allowed by the role, so the robot rejects it before touching Roles.
  function test_fork_multicallRejected() public view {
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeWithSignature('multicall(bytes[])', new bytes[](0));
    (bool needed, ) = robot.checkUpkeep(abi.encode(calls));
    assertFalse(needed, 'checkUpkeep should reject multicall');
  }

  function _grantRole() internal {
    bytes32[] memory keys = new bytes32[](1);
    keys[0] = ROLE_KEY;
    bool[] memory member = new bool[](1);
    member[0] = true;
    vm.startPrank(MiscEthereum.AFC_SAFE);
    if (!IModuleManager(MiscEthereum.AFC_SAFE).isModuleEnabled(ROLES)) {
      IModuleManager(MiscEthereum.AFC_SAFE).enableModule(ROLES);
    }
    IRolesAdmin(ROLES).enableModule(address(robot));
    IRolesAdmin(ROLES).assignRoles(address(robot), keys, member);
    vm.stopPrank();
    assertTrue(
      IModuleManager(MiscEthereum.AFC_SAFE).isModuleEnabled(ROLES),
      'roles not enabled on safe'
    );
    assertTrue(IRolesAdmin(ROLES).isModuleEnabled(address(robot)), 'robot not enabled on roles');
  }

  function _depositReport(uint256 amount) internal pure returns (bytes memory) {
    bytes[] memory calls = new bytes[](1);
    calls[0] = abi.encodeCall(
      IPoolExposureSteward.depositV3,
      (address(AaveV3Ethereum.POOL), AaveV3EthereumAssets.USDC_UNDERLYING, amount)
    );
    return abi.encode(calls);
  }
}
