// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {IStataTokenFactory} from 'aave-v3-origin/contracts/extensions/stata-token/interfaces/IStataTokenFactory.sol';
import {IRewardsDistributor} from 'aave-v3-origin/contracts/rewards/interfaces/IRewardsDistributor.sol';

import {IRefreshRewardsReceiver, IStataToken} from '../src/IRefreshRewardsReceiver.sol';
import {RefreshRewardsReceiverHarness} from './helpers/RefreshRewardsReceiverHarness.sol';
import {DeployRefreshRewardsReceiver} from '../scripts/DeployRefreshRewardsReceiver.s.sol';

contract RefreshRewardsReceiverForkTest is Test {
  RefreshRewardsReceiverHarness internal robot;
  address internal owner = makeAddr('fork-owner');
  address internal guardian = makeAddr('fork-guardian');
  address internal anyone = makeAddr('fork-anyone');

  IStataTokenFactory internal factory = IStataTokenFactory(AaveV3Ethereum.STATA_FACTORY);

  function setUp() public {
    vm.createSelectFork('mainnet');

    address[] memory factories = new address[](1);
    factories[0] = address(factory);
    robot = new RefreshRewardsReceiverHarness(owner, guardian, factories);
  }

  /// Checks the upstream interfaces match the deployed stataTokens.
  function test_fork_readPath_interfacesMatch() public view {
    address[] memory stataTokens = factory.getStataTokens();
    for (uint256 i = 0; i < stataTokens.length; i++) {
      IStataToken stata = IStataToken(stataTokens[i]);
      assertTrue(stata.aToken() != address(0), 'aToken is zero');
      assertTrue(address(stata.INCENTIVES_CONTROLLER()) != address(0), 'controller is zero');
      assertTrue(
        robot.isFactoryStataToken(address(factory), stataTokens[i]),
        'stataToken not recognized as factory stataToken'
      );
      robot.needsRefresh(stataTokens[i]);
    }
  }

  function test_fork_checkUpkeep_picksTokensFlaggedByNeedsRefresh() public view {
    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(factory));
    if (!needed) return;

    (, address[] memory tokens) = abi.decode(performData, (address, address[]));
    assertGt(tokens.length, 0, 'upkeep needed without stataTokens');
    assertLe(tokens.length, robot.MAX_ACTIONS(), 'more stataTokens than MAX_ACTIONS');
    for (uint256 i = 0; i < tokens.length; i++) {
      assertTrue(robot.needsRefresh(tokens[i]), 'picked a stataToken that needs no refresh');
    }
  }

  /// Every factory the deploy script enables, on every supported chain. Samples the
  /// first and last stataToken to keep the RPC load (and CI time) low.
  function test_fork_allChains_readPath() public {
    string[5] memory chains = ['mainnet', 'avalanche', 'optimism', 'arbitrum', 'base'];
    DeployRefreshRewardsReceiver script = new DeployRefreshRewardsReceiver();
    vm.makePersistent(address(script));

    for (uint256 c = 0; c < chains.length; c++) {
      vm.createSelectFork(chains[c]);
      DeployRefreshRewardsReceiver.DeployConfig memory config = script.getDeployConfig(
        block.chainid
      );
      RefreshRewardsReceiverHarness harness = new RefreshRewardsReceiverHarness(
        owner,
        guardian,
        config.factories
      );

      for (uint256 f = 0; f < config.factories.length; f++) {
        address[] memory stataTokens = IStataTokenFactory(config.factories[f]).getStataTokens();
        assertGt(stataTokens.length, 0, string.concat(chains[c], ': factory has no stataTokens'));
        address[2] memory sample = [stataTokens[0], stataTokens[stataTokens.length - 1]];
        for (uint256 i = 0; i < sample.length; i++) {
          assertTrue(
            harness.isFactoryStataToken(config.factories[f], sample[i]),
            string.concat(chains[c], ': stataToken not recognized as factory stataToken')
          );
          harness.needsRefresh(sample[i]);
        }
      }
    }
  }

  function test_fork_onReport_revertsConditionsNotMet_whenFullyRegistered() public {
    address stata = _findFullyRegisteredToken();
    require(stata != address(0), 'no fully registered stataToken on the fork');

    vm.prank(anyone);
    vm.expectRevert(IRefreshRewardsReceiver.ConditionsNotMet.selector);
    robot.onReport('', abi.encode(factory, _one(stata)));
  }

  /// Simulates a reward added to the aToken after the stataToken was created by
  /// appending one to the controller's reward list, then refreshes for real.
  function test_fork_onReport_refreshes_whenRewardUnregistered() public {
    IStataToken stata = IStataToken(factory.getStataTokens()[0]);
    IRewardsDistributor controller = stata.INCENTIVES_CONTROLLER();
    address newReward = makeAddr('newReward');

    address[] memory current = controller.getRewardsByAsset(stata.aToken());
    address[] memory rewards = new address[](current.length + 1);
    for (uint256 i = 0; i < current.length; i++) rewards[i] = current[i];
    rewards[current.length] = newReward;
    vm.mockCall(
      address(controller),
      abi.encodeWithSelector(IRewardsDistributor.getRewardsByAsset.selector, stata.aToken()),
      abi.encode(rewards)
    );

    assertTrue(robot.needsRefresh(address(stata)), 'stataToken should need a refresh');
    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(factory));
    assertTrue(needed, 'checkUpkeep should flag the stataToken');

    vm.expectEmit(address(robot));
    emit IRefreshRewardsReceiver.RefreshSucceeded(address(stata));

    vm.prank(anyone);
    robot.onReport('', performData);

    assertTrue(stata.isRegisteredRewardToken(newReward), 'reward not registered');
    assertFalse(robot.needsRefresh(address(stata)), 'stataToken still needs a refresh');
  }

  function _findFullyRegisteredToken() internal view returns (address) {
    address[] memory stataTokens = factory.getStataTokens();
    for (uint256 i = 0; i < stataTokens.length; i++) {
      if (!robot.needsRefresh(stataTokens[i])) return stataTokens[i];
    }
    return address(0);
  }

  function _one(address a) internal pure returns (address[] memory arr) {
    arr = new address[](1);
    arr[0] = a;
  }
}
