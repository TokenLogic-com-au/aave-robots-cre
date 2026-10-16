// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {ChainlinkEthereum} from 'aave-address-book/ChainlinkEthereum.sol';
import {IGovernanceCore} from 'aave-address-book/governance-v3/IGovernanceCore.sol';
import {IGovernancePowerStrategy} from 'aave-address-book/governance-v3/IGovernancePowerStrategy.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {IGovernanceChainRobotReceiver} from '../src/IGovernanceChainRobotReceiver.sol';
import {GovernanceChainRobotReceiver} from '../src/GovernanceChainRobotReceiver.sol';
import {DeployGovernanceChainRobotReceiver} from '../scripts/DeployGovernanceChainRobotReceiver.s.sol';

/// Runs against the live Governance at a pinned block where proposal 531 is Active and 532 is
/// Created within its voting cooldown, and compares every `checkUpkeep` with BGD's live keeper.
contract GovernanceChainRobotReceiverForkTest is Test {
  uint256 internal constant FORK_BLOCK = 26_207_306;

  uint256 internal constant ACTIVE_PROPOSAL = 531;
  uint256 internal constant CREATED_PROPOSAL = 532;

  /// BGD's `GasCappedGovernanceChainRobotKeeper`. Its `checkUpkeep(bytes)` and
  /// `getMaxGasPrice()` share their selectors and return types with the receiver.
  address internal constant BGD_KEEPER = 0x1996c281235D99bB3c6B8d2afbEb8ac6c7A39C11;

  IGovernanceCore internal constant GOVERNANCE = GovernanceV3Ethereum.GOVERNANCE;

  GovernanceChainRobotReceiver internal robot;
  address internal anyone = makeAddr('fork-anyone');

  function setUp() public {
    vm.createSelectFork('mainnet', FORK_BLOCK);
    DeployGovernanceChainRobotReceiver.DeployConfig
      memory config = new DeployGovernanceChainRobotReceiver().getDeployConfig(block.chainid);
    robot = new GovernanceChainRobotReceiver(
      config.governance,
      config.gasPriceOracle,
      config.maxGasPrice,
      config.owner,
      config.guardian
    );

    require(
      GOVERNANCE.getProposalsCount() == CREATED_PROPOSAL + 1,
      'unexpected proposal count at the fork block'
    );
    require(
      GOVERNANCE.getProposal(ACTIVE_PROPOSAL).state == IGovernanceCore.State.Active,
      'proposal 531 not Active at the fork block'
    );
    require(
      GOVERNANCE.getProposal(CREATED_PROPOSAL).state == IGovernanceCore.State.Created,
      'proposal 532 not Created at the fork block'
    );
    require(robot.isGasPriceInRange(), 'gas price above the cap at the fork block');
  }

  function test_fork_deployScript_run() public {
    address deployed = new DeployGovernanceChainRobotReceiver().run();
    assertEq(deployed.code, address(robot).code, 'deployed bytecode differs from setUp');
  }

  function test_fork_deploy_wiring() public view {
    assertEq(address(robot.GOVERNANCE()), address(GOVERNANCE), 'governance mismatch');
    assertEq(robot.GAS_PRICE_ORACLE(), ChainlinkEthereum.Fast_Gas__Gwei, 'oracle mismatch');
    assertEq(robot.owner(), GovernanceV3Ethereum.EXECUTOR_LVL_1, 'owner mismatch');
    assertEq(robot.guardian(), GovernanceV3Ethereum.GOVERNANCE_GUARDIAN, 'guardian mismatch');
    assertEq(
      robot.getMaxGasPrice(),
      IGovernanceChainRobotReceiver(BGD_KEEPER).getMaxGasPrice(),
      'max gas price differs from the BGD keeper'
    );
    assertEq(
      robot.GAS_PRICE_ORACLE(),
      IGovernanceChainRobotReceiver(BGD_KEEPER).GAS_PRICE_ORACLE(),
      'oracle differs from the BGD keeper'
    );
  }

  function test_fork_checkUpkeep_noAction_atForkBlock() public view {
    (bool needed, ) = _checkUpkeepMatchingKeeper();
    assertFalse(needed, 'no action should be due at the fork block');
  }

  function test_fork_onReport_activatesVoting_afterCooldown() public {
    _warpPastVotingCooldown(CREATED_PROPOSAL);

    (bool needed, bytes memory performData) = _checkUpkeepMatchingKeeper();
    assertTrue(needed, 'activation should be due');
    _assertActions(
      performData,
      _one(CREATED_PROPOSAL, IGovernanceChainRobotReceiver.ProposalAction.PerformActivateVoting)
    );

    _onReport(performData);
    IGovernanceCore.Proposal memory p = GOVERNANCE.getProposal(CREATED_PROPOSAL);
    assertEq(uint8(p.state), uint8(IGovernanceCore.State.Active), 'voting not activated');
    assertEq(p.votingActivationTime, block.timestamp, 'wrong activation time');
  }

  function test_fork_onReport_executesQueuedProposal_andActivatesVoting() public {
    _queue(ACTIVE_PROPOSAL);
    require(
      block.timestamp - GOVERNANCE.getProposal(CREATED_PROPOSAL).creationTime >
        GOVERNANCE
          .getVotingConfig(GOVERNANCE.getProposal(CREATED_PROPOSAL).accessLevel)
          .coolDownBeforeVotingStart,
      'proposal 532 cooldown should have passed once 531 voting ended'
    );

    (bool needed, bytes memory performData) = _checkUpkeepMatchingKeeper();
    assertTrue(needed, 'execution should be due');
    IGovernanceChainRobotReceiver.ActionWithId[]
      memory expected = new IGovernanceChainRobotReceiver.ActionWithId[](2);
    expected[0] = IGovernanceChainRobotReceiver.ActionWithId(
      CREATED_PROPOSAL,
      IGovernanceChainRobotReceiver.ProposalAction.PerformActivateVoting
    );
    expected[1] = IGovernanceChainRobotReceiver.ActionWithId(
      ACTIVE_PROPOSAL,
      IGovernanceChainRobotReceiver.ProposalAction.PerformExecute
    );
    _assertActions(performData, expected);

    vm.recordLogs();
    _onReport(performData);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    assertEq(
      uint8(GOVERNANCE.getProposal(ACTIVE_PROPOSAL).state),
      uint8(IGovernanceCore.State.Executed),
      'proposal not executed'
    );
    assertEq(
      uint8(GOVERNANCE.getProposal(CREATED_PROPOSAL).state),
      uint8(IGovernanceCore.State.Active),
      'voting not activated'
    );
    assertEq(_countRobotActions(logs), 2, 'expected two ActionSucceeded');

    (needed, ) = _checkUpkeepMatchingKeeper();
    assertFalse(needed, 'no action should be left');
  }

  function test_fork_onReport_cancelsProposals_whenCreatorPowerDrops() public {
    _mockPropositionPower(GOVERNANCE.getProposal(ACTIVE_PROPOSAL).creator, 0);
    _mockPropositionPower(GOVERNANCE.getProposal(CREATED_PROPOSAL).creator, 0);

    (bool needed, bytes memory performData) = _checkUpkeepMatchingKeeper();
    assertTrue(needed, 'cancellation should be due');
    IGovernanceChainRobotReceiver.ActionWithId[]
      memory expected = new IGovernanceChainRobotReceiver.ActionWithId[](2);
    expected[0] = IGovernanceChainRobotReceiver.ActionWithId(
      CREATED_PROPOSAL,
      IGovernanceChainRobotReceiver.ProposalAction.PerformCancel
    );
    expected[1] = IGovernanceChainRobotReceiver.ActionWithId(
      ACTIVE_PROPOSAL,
      IGovernanceChainRobotReceiver.ProposalAction.PerformCancel
    );
    _assertActions(performData, expected);

    _onReport(performData);
    assertEq(
      uint8(GOVERNANCE.getProposal(ACTIVE_PROPOSAL).state),
      uint8(IGovernanceCore.State.Cancelled),
      'active proposal not cancelled'
    );
    assertEq(
      uint8(GOVERNANCE.getProposal(CREATED_PROPOSAL).state),
      uint8(IGovernanceCore.State.Cancelled),
      'created proposal not cancelled'
    );
  }

  function test_fork_checkUpkeep_returnsFalse_whenGasPriceAboveCap() public {
    _warpPastVotingCooldown(CREATED_PROPOSAL);
    vm.mockCall(
      ChainlinkEthereum.Fast_Gas__Gwei,
      abi.encodeWithSelector(AggregatorInterface.latestAnswer.selector),
      abi.encode(int256(robot.getMaxGasPrice() + 1))
    );

    (bool needed, ) = _checkUpkeepMatchingKeeper();
    assertFalse(needed, 'gas price cap not applied');
  }

  function test_fork_checkUpkeep_skipsDisabledProposal() public {
    _warpPastVotingCooldown(CREATED_PROPOSAL);
    vm.prank(GovernanceV3Ethereum.GOVERNANCE_GUARDIAN);
    robot.disableAutomation(CREATED_PROPOSAL);

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'disabled proposal returned');
  }

  function test_fork_onReport_revertsWith_NoActionCanBePerformed_whenNotDue() public {
    vm.expectRevert(IGovernanceChainRobotReceiver.NoActionCanBePerformed.selector);
    _onReport(
      abi.encode(
        _one(CREATED_PROPOSAL, IGovernanceChainRobotReceiver.ProposalAction.PerformActivateVoting)
      )
    );
  }

  /// Checks the robot and BGD's keeper agree, then returns the robot's result.
  function _checkUpkeepMatchingKeeper() internal view returns (bool, bytes memory) {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    (bool keeperNeeded, bytes memory keeperData) = IAaveCREReceiver(BGD_KEEPER).checkUpkeep('');
    assertEq(needed, keeperNeeded, 'upkeepNeeded differs from the BGD keeper');
    assertEq(performData, keeperData, 'performData differs from the BGD keeper');
    return (needed, performData);
  }

  function _onReport(bytes memory report) internal {
    vm.prank(anyone);
    robot.onReport('', report);
  }

  function _warpPastVotingCooldown(uint256 id) internal {
    IGovernanceCore.Proposal memory p = GOVERNANCE.getProposal(id);
    vm.warp(
      p.creationTime + GOVERNANCE.getVotingConfig(p.accessLevel).coolDownBeforeVotingStart + 1
    );
  }

  /// Ends the vote and queues the proposal as its voting portal would, with enough votes.
  function _queue(uint256 id) internal {
    IGovernanceCore.Proposal memory p = GOVERNANCE.getProposal(id);
    IGovernanceCore.VotingConfig memory config = GOVERNANCE.getVotingConfig(p.accessLevel);
    uint256 forVotes = (uint256(config.yesThreshold) + config.yesNoDifferential + 1) *
      GOVERNANCE.PRECISION_DIVIDER();

    vm.warp(uint256(p.votingActivationTime) + p.votingDuration + 1);
    vm.prank(p.votingPortal);
    GOVERNANCE.queueProposal(id, uint128(forVotes), 0);
    require(
      GOVERNANCE.getProposal(id).state == IGovernanceCore.State.Queued,
      'proposal not queued'
    );
  }

  function _mockPropositionPower(address user, uint256 power) internal {
    vm.mockCall(
      address(GOVERNANCE.getPowerStrategy()),
      abi.encodeWithSelector(IGovernancePowerStrategy.getFullPropositionPower.selector, user),
      abi.encode(power)
    );
  }

  function _assertActions(
    bytes memory performData,
    IGovernanceChainRobotReceiver.ActionWithId[] memory expected
  ) internal pure {
    IGovernanceChainRobotReceiver.ActionWithId[] memory actions = abi.decode(
      performData,
      (IGovernanceChainRobotReceiver.ActionWithId[])
    );
    assertEq(actions.length, expected.length, 'unexpected action count');
    for (uint256 i = 0; i < actions.length; i++) {
      assertEq(actions[i].id, expected[i].id, 'unexpected proposal');
      assertEq(uint8(actions[i].action), uint8(expected[i].action), 'unexpected action');
    }
  }

  function _countRobotActions(Vm.Log[] memory logs) internal view returns (uint256 count) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (
        logs[i].emitter == address(robot) &&
        logs[i].topics[0] == IGovernanceChainRobotReceiver.ActionSucceeded.selector
      ) count++;
    }
  }

  function _one(
    uint256 id,
    IGovernanceChainRobotReceiver.ProposalAction action
  ) internal pure returns (IGovernanceChainRobotReceiver.ActionWithId[] memory actions) {
    actions = new IGovernanceChainRobotReceiver.ActionWithId[](1);
    actions[0] = IGovernanceChainRobotReceiver.ActionWithId(id, action);
  }
}
