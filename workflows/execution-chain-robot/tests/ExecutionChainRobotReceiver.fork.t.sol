// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';
import {IPayloadsControllerCore} from 'aave-address-book/governance-v3/IPayloadsControllerCore.sol';
import {IBaseReceiverPortal} from 'aave-address-book/governance-v3/IBaseReceiverPortal.sol';
import {PayloadsControllerUtils} from 'aave-address-book/governance-v3/PayloadsControllerUtils.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';
import {GovernanceV3Optimism} from 'aave-address-book/GovernanceV3Optimism.sol';
import {GovernanceV3Arbitrum} from 'aave-address-book/GovernanceV3Arbitrum.sol';
import {GovernanceV3Base} from 'aave-address-book/GovernanceV3Base.sol';
import {GovernanceV3BNB} from 'aave-address-book/GovernanceV3BNB.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {ExecutionChainRobotReceiver} from '../src/ExecutionChainRobotReceiver.sol';
import {IExecutionChainRobotReceiver} from '../src/IExecutionChainRobotReceiver.sol';
import {DeployExecutionChainRobotReceiver} from '../scripts/DeployExecutionChainRobotReceiver.s.sol';

/// @dev Delegatecalled by the executor, so the event is emitted by the executor.
contract NoopPayload {
  event NoopPayloadExecuted();

  function execute() external {
    emit NoopPayloadExecuted();
  }
}

/// @dev Runs the deploy script on each chain, creates a trivial payload on the live
/// PayloadsController, queues it as a bridged governance message would and checks the robot
/// executes it once its delay has passed, agreeing with BGD's live keeper along the way.
contract ExecutionChainRobotReceiverForkTest is Test {
  // BGD's keepers currently forwarded by CRE (Ethereum is the gas-capped variant).
  address internal constant BGD_KEEPER_ETHEREUM = 0xBa37F9eDC52f57caFA3a13ddfD655797Cc4FE257;
  address internal constant BGD_KEEPER_AVALANCHE = 0x7B74938583Eb03e06042fcB651046BaF0bf15644;
  address internal constant BGD_KEEPER_POLYGON = 0x249396a890F89D47F89326d7EE116b1d374Fb3A9;
  address internal constant BGD_KEEPER_OPTIMISM = 0xa0195539e21A6553243344A3BE6b874B5d3EC7b9;
  address internal constant BGD_KEEPER_ARBITRUM = 0x64093fe5f8Cf62aFb4377cf7EF4373537fe9155B;
  address internal constant BGD_KEEPER_BASE = 0xdb93e2712a8B36835078f8D28c70fCC95FD6d37c;
  address internal constant BGD_KEEPER_BNB = 0x870F5EBf5C13B73251283b2d883988066e2bb732;

  address internal anyone = makeAddr('anyone');

  function test_fork_ethereum_executesQueuedPayload() public {
    _executesQueuedPayload('mainnet', BGD_KEEPER_ETHEREUM);
  }

  function test_fork_avalanche_executesQueuedPayload() public {
    _executesQueuedPayload('avalanche', BGD_KEEPER_AVALANCHE);
  }

  function test_fork_polygon_executesQueuedPayload() public {
    _executesQueuedPayload('polygon', BGD_KEEPER_POLYGON);
  }

  function test_fork_optimism_executesQueuedPayload() public {
    _executesQueuedPayload('optimism', BGD_KEEPER_OPTIMISM);
  }

  function test_fork_arbitrum_executesQueuedPayload() public {
    _executesQueuedPayload('arbitrum', BGD_KEEPER_ARBITRUM);
  }

  function test_fork_base_executesQueuedPayload() public {
    _executesQueuedPayload('base', BGD_KEEPER_BASE);
  }

  function test_fork_bnb_executesQueuedPayload() public {
    _executesQueuedPayload('bnb', BGD_KEEPER_BNB);
  }

  function test_fork_ethereum_gasCapMatchesBgdKeeper() public {
    vm.createSelectFork('mainnet');
    ExecutionChainRobotReceiver receiver = _deploy();
    IExecutionChainRobotReceiver bgd = IExecutionChainRobotReceiver(BGD_KEEPER_ETHEREUM);

    assertEq(receiver.GAS_PRICE_ORACLE(), bgd.GAS_PRICE_ORACLE(), 'gas price oracle mismatch');
    assertEq(receiver.getMaxGasPrice(), bgd.getMaxGasPrice(), 'max gas price mismatch');

    uint40 payloadId = _createAndQueuePayload(receiver.PAYLOADS_CONTROLLER());
    vm.warp(block.timestamp + receiver.PAYLOADS_CONTROLLER().getPayloadById(payloadId).delay + 1);
    assertTrue(receiver.isGasPriceInRange(), 'live gas price above the cap');
    _assertPicked(receiver, payloadId, true);

    vm.mockCall(
      receiver.GAS_PRICE_ORACLE(),
      abi.encodeCall(AggregatorInterface.latestAnswer, ()),
      abi.encode(int256(receiver.getMaxGasPrice() + 1))
    );
    assertFalse(receiver.isGasPriceInRange(), 'gas price should be above the cap');
    (bool needed, ) = receiver.checkUpkeep('');
    assertFalse(needed, 'upkeep needed above the gas cap');
    (bool bgdNeeded, ) = IAaveCREReceiver(BGD_KEEPER_ETHEREUM).checkUpkeep('');
    assertFalse(bgdNeeded, 'BGD keeper upkeep needed above the gas cap');

    // The cap only gates checkUpkeep, as in BGD's keeper.
    vm.prank(anyone);
    receiver.onReport('', abi.encode(_ids(payloadId)));
    assertEq(
      uint8(receiver.PAYLOADS_CONTROLLER().getPayloadState(payloadId)),
      uint8(IPayloadsControllerCore.PayloadState.Executed),
      'payload not executed'
    );
  }

  function test_fork_ethereum_skipsExpiredPayload() public {
    vm.createSelectFork('mainnet');
    ExecutionChainRobotReceiver receiver = _deploy();
    IPayloadsControllerCore controller = receiver.PAYLOADS_CONTROLLER();
    uint40 payloadId = _createAndQueuePayload(controller);
    IPayloadsControllerCore.Payload memory payload = controller.getPayloadById(payloadId);

    vm.warp(uint256(payload.queuedAt) + payload.delay + payload.gracePeriod);
    assertEq(
      uint8(controller.getPayloadState(payloadId)),
      uint8(IPayloadsControllerCore.PayloadState.Expired),
      'payload should be expired'
    );
    _assertPicked(receiver, payloadId, false);

    vm.prank(anyone);
    vm.expectRevert(IExecutionChainRobotReceiver.NoActionCanBePerformed.selector);
    receiver.onReport('', abi.encode(_ids(payloadId)));
  }

  function _executesQueuedPayload(string memory chain, address bgdKeeper) internal {
    vm.createSelectFork(chain);
    ExecutionChainRobotReceiver receiver = _deploy();
    IPayloadsControllerCore controller = receiver.PAYLOADS_CONTROLLER();

    assertEq(
      address(controller),
      address(IExecutionChainRobotReceiver(bgdKeeper).PAYLOADS_CONTROLLER()),
      string.concat(chain, ': PayloadsController differs from the BGD keeper')
    );
    _assertAgreesWithBgdKeeper(receiver, bgdKeeper, chain);

    uint40 payloadId = _createAndQueuePayload(controller);
    _assertPicked(receiver, payloadId, false);

    vm.warp(block.timestamp + controller.getPayloadById(payloadId).delay + 1);
    _assertPicked(receiver, payloadId, true);
    _assertAgreesWithBgdKeeper(receiver, bgdKeeper, chain);

    vm.expectEmit(address(receiver));
    emit IExecutionChainRobotReceiver.ActionSucceeded(payloadId);
    vm.prank(anyone);
    receiver.onReport('', abi.encode(_ids(payloadId)));

    assertEq(
      uint8(controller.getPayloadState(payloadId)),
      uint8(IPayloadsControllerCore.PayloadState.Executed),
      string.concat(chain, ': payload not executed')
    );
    _assertPicked(receiver, payloadId, false);
  }

  /// Both robots see the same executable payloads: BGD's picks one of the (up to) MAX_ACTIONS
  /// newest at random, which must be among the ones the receiver returns.
  function _assertAgreesWithBgdKeeper(
    ExecutionChainRobotReceiver receiver,
    address bgdKeeper,
    string memory chain
  ) internal view {
    (bool needed, bytes memory performData) = receiver.checkUpkeep('');
    (bool bgdNeeded, bytes memory bgdPerformData) = IAaveCREReceiver(bgdKeeper).checkUpkeep('');
    assertEq(needed, bgdNeeded, string.concat(chain, ': upkeepNeeded differs from the BGD keeper'));
    if (!needed) return;

    uint40[] memory bgdIds = abi.decode(bgdPerformData, (uint40[]));
    assertEq(bgdIds.length, 1, string.concat(chain, ': BGD keeper should pick one payload'));
    assertTrue(
      _contains(abi.decode(performData, (uint40[])), bgdIds[0]),
      string.concat(chain, ': BGD keeper picked a payload the receiver did not')
    );
  }

  function _assertPicked(
    ExecutionChainRobotReceiver receiver,
    uint40 payloadId,
    bool expected
  ) internal view {
    (bool needed, bytes memory performData) = receiver.checkUpkeep('');
    bool picked = needed && _contains(abi.decode(performData, (uint40[])), payloadId);
    assertEq(picked, expected, 'unexpected checkUpkeep result for the test payload');
  }

  function _deploy() internal returns (ExecutionChainRobotReceiver receiver) {
    DeployExecutionChainRobotReceiver script = new DeployExecutionChainRobotReceiver();
    DeployExecutionChainRobotReceiver.DeployConfig memory config = script.getDeployConfig(
      block.chainid
    );
    receiver = ExecutionChainRobotReceiver(script.run());

    assertEq(address(receiver.PAYLOADS_CONTROLLER()), config.payloadsController, 'controller');
    assertEq(receiver.GAS_PRICE_ORACLE(), config.gasPriceOracle, 'gas price oracle');
    assertEq(receiver.getMaxGasPrice(), config.maxGasPrice, 'max gas price');
    assertEq(receiver.owner(), config.owner, 'owner');
    assertEq(receiver.guardian(), config.guardian, 'guardian');
  }

  /// Creates a payload delegatecalling `NoopPayload.execute()` and queues it the way the
  /// chain's CrossChainController delivers a passed proposal from Ethereum governance.
  function _createAndQueuePayload(IPayloadsControllerCore controller) internal returns (uint40) {
    IPayloadsControllerCore.ExecutionAction[]
      memory actions = new IPayloadsControllerCore.ExecutionAction[](1);
    actions[0] = IPayloadsControllerCore.ExecutionAction({
      target: address(new NoopPayload()),
      withDelegateCall: true,
      accessLevel: PayloadsControllerUtils.AccessControl.Level_1,
      value: 0,
      signature: 'execute()',
      callData: ''
    });
    uint40 payloadId = controller.createPayload(actions);

    vm.warp(block.timestamp + 1);
    vm.prank(_crossChainController(block.chainid));
    IBaseReceiverPortal(address(controller)).receiveCrossChainMessage(
      address(GovernanceV3Ethereum.GOVERNANCE),
      ChainIds.MAINNET,
      abi.encode(payloadId, PayloadsControllerUtils.AccessControl.Level_1, uint40(block.timestamp))
    );
    assertEq(
      uint8(controller.getPayloadState(payloadId)),
      uint8(IPayloadsControllerCore.PayloadState.Queued),
      'payload not queued'
    );
    return payloadId;
  }

  function _crossChainController(uint256 chainId) internal pure returns (address) {
    if (chainId == ChainIds.MAINNET) return GovernanceV3Ethereum.CROSS_CHAIN_CONTROLLER;
    if (chainId == ChainIds.AVALANCHE) return GovernanceV3Avalanche.CROSS_CHAIN_CONTROLLER;
    if (chainId == ChainIds.POLYGON) return GovernanceV3Polygon.CROSS_CHAIN_CONTROLLER;
    if (chainId == ChainIds.OPTIMISM) return GovernanceV3Optimism.CROSS_CHAIN_CONTROLLER;
    if (chainId == ChainIds.ARBITRUM) return GovernanceV3Arbitrum.CROSS_CHAIN_CONTROLLER;
    if (chainId == ChainIds.BASE) return GovernanceV3Base.CROSS_CHAIN_CONTROLLER;
    if (chainId == ChainIds.BNB) return GovernanceV3BNB.CROSS_CHAIN_CONTROLLER;
    revert('unsupported chain');
  }

  function _contains(uint40[] memory ids, uint40 id) internal pure returns (bool) {
    for (uint256 i = 0; i < ids.length; i++) if (ids[i] == id) return true;
    return false;
  }

  function _ids(uint40 a) internal pure returns (uint40[] memory arr) {
    arr = new uint40[](1);
    arr[0] = a;
  }
}
