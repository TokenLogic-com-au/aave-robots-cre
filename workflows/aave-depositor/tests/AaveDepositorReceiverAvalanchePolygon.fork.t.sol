// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';

import {AaveV3Avalanche, AaveV3AvalancheAssets} from 'aave-address-book/AaveV3Avalanche.sol';
import {AaveV2Avalanche, AaveV2AvalancheAssets} from 'aave-address-book/AaveV2Avalanche.sol';
import {AaveV3Polygon, AaveV3PolygonAssets} from 'aave-address-book/AaveV3Polygon.sol';
import {AaveV2Polygon, AaveV2PolygonAssets} from 'aave-address-book/AaveV2Polygon.sol';
import {MiscAvalanche} from 'aave-address-book/MiscAvalanche.sol';
import {MiscPolygon} from 'aave-address-book/MiscPolygon.sol';

import {AaveDepositorReceiver} from '../src/AaveDepositorReceiver.sol';
import {IPoolExposureSteward} from '../src/IAaveDepositorReceiver.sol';
import {AaveDepositorNetworks} from '../scripts/AaveDepositorNetworks.sol';

/// @dev Zodiac Roles v2 admin functions, called by the Roles owner (the AFC Safe).
interface IRolesAdmin {
  function enableModule(address module) external;

  function assignRoles(
    address module,
    bytes32[] calldata roleKeys,
    bool[] calldata memberOf
  ) external;

  function scopeTarget(bytes32 roleKey, address targetAddress) external;

  function allowFunction(
    bytes32 roleKey,
    address targetAddress,
    bytes4 selector,
    uint8 options
  ) external;
}

/// On Avalanche and Polygon the AFC already runs a Roles Modifier with an `aave_depositor`
/// role, but the role doesn't allow the Steward's `depositV3` / `migrateV2toV3` yet. These
/// tests check that, then apply the AFC Safe transaction that scopes them and run a real
/// deposit and V2 to V3 migration of Collector funds.
contract AaveDepositorReceiverAvalanchePolygonForkTest is Test {
  bytes32 internal constant ROLE_KEY = AaveDepositorNetworks.ROLE_KEY;

  struct Market {
    string fork;
    address afcSafe;
    address collector;
    address poolV3;
    address poolV2;
    address usdc;
    address aUsdcV3;
    address migrated;
    address migratedATokenV2;
    address migratedATokenV3;
  }

  function test_fork_avalanche_depositsAndMigrates_onceAfcScopesRole() public {
    _run(
      Market({
        fork: 'avalanche',
        afcSafe: MiscAvalanche.AFC_SAFE,
        collector: address(AaveV3Avalanche.COLLECTOR),
        poolV3: address(AaveV3Avalanche.POOL),
        poolV2: address(AaveV2Avalanche.POOL),
        usdc: AaveV3AvalancheAssets.USDC_UNDERLYING,
        aUsdcV3: AaveV3AvalancheAssets.USDC_A_TOKEN,
        migrated: AaveV2AvalancheAssets.DAIe_UNDERLYING,
        migratedATokenV2: AaveV2AvalancheAssets.DAIe_A_TOKEN,
        migratedATokenV3: AaveV3AvalancheAssets.DAIe_A_TOKEN
      })
    );
  }

  function test_fork_polygon_depositsAndMigrates_onceAfcScopesRole() public {
    _run(
      Market({
        fork: 'polygon',
        afcSafe: MiscPolygon.AFC_SAFE,
        collector: address(AaveV3Polygon.COLLECTOR),
        poolV3: address(AaveV3Polygon.POOL),
        poolV2: address(AaveV2Polygon.POOL),
        usdc: AaveV3PolygonAssets.USDCn_UNDERLYING,
        aUsdcV3: AaveV3PolygonAssets.USDCn_A_TOKEN,
        migrated: AaveV2PolygonAssets.DAI_UNDERLYING,
        migratedATokenV2: AaveV2PolygonAssets.DAI_A_TOKEN,
        migratedATokenV3: AaveV3PolygonAssets.DAI_A_TOKEN
      })
    );
  }

  function _run(Market memory m) internal {
    vm.createSelectFork(m.fork);
    AaveDepositorNetworks.Network memory net = AaveDepositorNetworks.get(block.chainid);
    AaveDepositorReceiver robot = new AaveDepositorReceiver(
      net.forwarder,
      net.roles,
      net.steward,
      net.roleKey,
      net.owner,
      net.guardian
    );

    uint256 depositAmount = 1_000 * 10 ** _decimals(m.usdc);
    deal(m.usdc, m.collector, IERC20(m.usdc).balanceOf(m.collector) + depositAmount);
    bytes memory deposit = _report(
      abi.encodeCall(IPoolExposureSteward.depositV3, (m.poolV3, m.usdc, depositAmount))
    );

    // Even with the role granted, the current role config rejects the Steward call.
    _grantRole(m.afcSafe, net.roles, address(robot));
    vm.prank(net.forwarder);
    vm.expectRevert();
    robot.onReport('', deposit);

    _scopeRole(m.afcSafe, net.roles, net.steward);

    uint256 aUsdcBefore = IERC20(m.aUsdcV3).balanceOf(m.collector);
    vm.prank(net.forwarder);
    robot.onReport('', deposit);
    assertApproxEqAbs(
      IERC20(m.aUsdcV3).balanceOf(m.collector) - aUsdcBefore,
      depositAmount,
      2,
      string.concat(m.fork, ': collector did not receive the V3 aToken')
    );

    uint256 migrateAmount = IERC20(m.migratedATokenV2).balanceOf(m.collector) / 10;
    assertGt(migrateAmount, 0, string.concat(m.fork, ': collector has no V2 aToken to migrate'));
    uint256 v3Before = IERC20(m.migratedATokenV3).balanceOf(m.collector);
    vm.prank(net.forwarder);
    robot.onReport(
      '',
      _report(
        abi.encodeCall(
          IPoolExposureSteward.migrateV2toV3,
          (m.poolV2, m.poolV3, m.migrated, migrateAmount)
        )
      )
    );
    assertApproxEqAbs(
      IERC20(m.migratedATokenV3).balanceOf(m.collector) - v3Before,
      migrateAmount,
      2,
      string.concat(m.fork, ': V2 aToken not migrated to V3')
    );
  }

  function _grantRole(address afcSafe, address roles, address robot) internal {
    bytes32[] memory keys = new bytes32[](1);
    keys[0] = ROLE_KEY;
    bool[] memory member = new bool[](1);
    member[0] = true;
    vm.startPrank(afcSafe);
    IRolesAdmin(roles).enableModule(robot);
    IRolesAdmin(roles).assignRoles(robot, keys, member);
    vm.stopPrank();
  }

  /// The AFC Safe transaction still missing on these chains.
  function _scopeRole(address afcSafe, address roles, address steward) internal {
    vm.startPrank(afcSafe);
    IRolesAdmin(roles).scopeTarget(ROLE_KEY, steward);
    IRolesAdmin(roles).allowFunction(ROLE_KEY, steward, IPoolExposureSteward.depositV3.selector, 0);
    IRolesAdmin(roles).allowFunction(
      ROLE_KEY,
      steward,
      IPoolExposureSteward.migrateV2toV3.selector,
      0
    );
    vm.stopPrank();
  }

  function _report(bytes memory call) internal pure returns (bytes memory) {
    bytes[] memory calls = new bytes[](1);
    calls[0] = call;
    return abi.encode(calls);
  }

  function _decimals(address token) internal view returns (uint256) {
    (, bytes memory data) = token.staticcall(abi.encodeWithSignature('decimals()'));
    return abi.decode(data, (uint8));
  }
}
