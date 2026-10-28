// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';
import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';
import {IVotingStrategy} from 'aave-address-book/governance-v3/IVotingStrategy.sol';
import {IDataWarehouse} from 'aave-address-book/governance-v3/IDataWarehouse.sol';
import {IVotingPortal} from 'aave-address-book/governance-v3/IVotingPortal.sol';
import {IBaseReceiverPortal} from 'aave-address-book/governance-v3/IBaseReceiverPortal.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';

import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {VotingChainRobotReceiver} from '../src/VotingChainRobotReceiver.sol';
import {IVotingChainRobotReceiver} from '../src/IVotingChainRobotReceiver.sol';
import {DeployVotingChainRobotReceiver} from '../scripts/DeployVotingChainRobotReceiver.s.sol';

/// Runs the deploy script on each voting chain and drives a bridged proposal through every
/// action against the live voting machine and data warehouse, comparing `checkUpkeep` with the
/// live BGD keeper's.
contract VotingChainRobotReceiverForkTest is Test {
  struct ChainSetup {
    string rpcAlias;
    uint256 forkBlock;
    address liveKeeper;
    address crossChainController;
    address l1VotingPortal;
    address dataWarehouse;
    address votingStrategy;
  }

  /// `performData` entry of BGD's keeper, whose actions are SubmitRoots (0), CreateVote (1)
  /// and CloseAndSendVote (2).
  struct LiveKeeperAction {
    uint256 id;
    uint8 action;
  }

  address internal constant LIVE_KEEPER_ETHEREUM = 0xbC3210bfff692a5bbDBB068D42Ab4eAF28b01Ee0;
  address internal constant LIVE_KEEPER_AVALANCHE = 0x2cf0fA5b36F0f89a5EA18F835d1375974a7720B8;
  address internal constant LIVE_KEEPER_POLYGON = 0x1180eE41eC15Dd0accC13a1e646B3152bECFf8F6;

  // Pinned so the live keeper's state and the Fast Gas answer (~0.16 gwei) don't change under
  // the tests. On Avalanche, proposal 531 is being voted on (ends at 1792355163).
  uint256 internal constant ETHEREUM_BLOCK = 26207320;
  uint256 internal constant AVALANCHE_BLOCK = 97735679;
  uint256 internal constant POLYGON_BLOCK = 95650092;
  uint256 internal constant AVALANCHE_PROPOSAL_531 = 531;

  // Short, so warping past its end leaves other live votes untouched.
  uint24 internal constant VOTING_DURATION = 1 hours;

  // Offset from the latest bridged proposal id, to stay clear of the next real ones.
  uint256 internal constant PROPOSAL_ID_OFFSET = 1000;

  uint8 internal constant LIVE_KEEPER_SUBMIT_ROOTS = 0;

  address internal anyone = makeAddr('anyone');

  function test_fork_ethereum_runsProposalLifecycle() public {
    _runLifecycle(
      ChainSetup({
        rpcAlias: 'mainnet',
        forkBlock: ETHEREUM_BLOCK,
        liveKeeper: LIVE_KEEPER_ETHEREUM,
        crossChainController: GovernanceV3Ethereum.CROSS_CHAIN_CONTROLLER,
        l1VotingPortal: GovernanceV3Ethereum.VOTING_PORTAL_ETH_ETH,
        dataWarehouse: address(GovernanceV3Ethereum.DATA_WAREHOUSE),
        votingStrategy: address(GovernanceV3Ethereum.VOTING_STRATEGY)
      })
    );
  }

  function test_fork_avalanche_runsProposalLifecycle() public {
    _runLifecycle(
      ChainSetup({
        rpcAlias: 'avalanche',
        forkBlock: AVALANCHE_BLOCK,
        liveKeeper: LIVE_KEEPER_AVALANCHE,
        crossChainController: GovernanceV3Avalanche.CROSS_CHAIN_CONTROLLER,
        l1VotingPortal: GovernanceV3Ethereum.VOTING_PORTAL_ETH_AVAX,
        dataWarehouse: address(GovernanceV3Avalanche.DATA_WAREHOUSE),
        votingStrategy: address(GovernanceV3Avalanche.VOTING_STRATEGY)
      })
    );
  }

  function test_fork_polygon_runsProposalLifecycle() public {
    _runLifecycle(
      ChainSetup({
        rpcAlias: 'polygon',
        forkBlock: POLYGON_BLOCK,
        liveKeeper: LIVE_KEEPER_POLYGON,
        crossChainController: GovernanceV3Polygon.CROSS_CHAIN_CONTROLLER,
        l1VotingPortal: GovernanceV3Ethereum.VOTING_PORTAL_ETH_POL,
        dataWarehouse: address(GovernanceV3Polygon.DATA_WAREHOUSE),
        votingStrategy: address(GovernanceV3Polygon.VOTING_STRATEGY)
      })
    );
  }

  /// Closes a real vote: proposal 531 on Avalanche, once its voting period is over.
  function test_fork_avalanche_closesLiveProposal() public {
    vm.createSelectFork('avalanche', AVALANCHE_BLOCK);
    VotingChainRobotReceiver robot = VotingChainRobotReceiver(
      new DeployVotingChainRobotReceiver().run()
    );
    IVotingMachineWithProofs votingMachine = robot.VOTING_MACHINE();
    IVotingMachineWithProofs.ProposalWithoutVotes memory proposal = votingMachine.getProposalById(
      AVALANCHE_PROPOSAL_531
    );
    _assertState(
      votingMachine,
      AVALANCHE_PROPOSAL_531,
      IVotingMachineWithProofs.ProposalState.Active
    );

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed while the vote is active');

    vm.warp(proposal.endTime + 1);
    bytes memory performData = _checkUpkeepMatchesLiveKeeper(robot, LIVE_KEEPER_AVALANCHE);
    _assertHasAction(
      performData,
      AVALANCHE_PROPOSAL_531,
      IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote
    );

    vm.prank(anyone);
    robot.onReport('', performData);
    _assertState(
      votingMachine,
      AVALANCHE_PROPOSAL_531,
      IVotingMachineWithProofs.ProposalState.SentToGovernance
    );
  }

  /// At the cap the due action is reported; above it nothing is, as the live keeper does.
  function test_fork_ethereum_respectsGasPriceCap() public {
    vm.createSelectFork('mainnet', ETHEREUM_BLOCK);
    DeployVotingChainRobotReceiver script = new DeployVotingChainRobotReceiver();
    DeployVotingChainRobotReceiver.DeployConfig memory config = script.getDeployConfig(
      block.chainid
    );
    VotingChainRobotReceiver robot = VotingChainRobotReceiver(script.run());
    (uint256 id, ) = _bridgeProposal(
      robot.VOTING_MACHINE(),
      GovernanceV3Ethereum.CROSS_CHAIN_CONTROLLER,
      GovernanceV3Ethereum.VOTING_PORTAL_ETH_ETH
    );
    _registerRoots(robot, _blockHash());

    uint256 gasPrice = uint256(AggregatorInterface(config.gasPriceOracle).latestAnswer());
    require(gasPrice > 0, 'gas price feed answered 0');

    vm.startPrank(config.guardian);
    if (robot.getMaxGasPrice() != gasPrice) robot.setMaxGasPrice(gasPrice);
    _assertHasAction(
      _checkUpkeep(robot),
      id,
      IVotingChainRobotReceiver.ProposalAction.PerformCreateVote
    );

    robot.setMaxGasPrice(gasPrice - 1);
    vm.stopPrank();
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed above the gas price cap');
  }

  /// Deploys with the script, then takes a freshly bridged proposal through vote start (once
  /// its roots are registered) and close.
  function _runLifecycle(ChainSetup memory chain) internal {
    vm.createSelectFork(chain.rpcAlias, chain.forkBlock);
    DeployVotingChainRobotReceiver script = new DeployVotingChainRobotReceiver();
    DeployVotingChainRobotReceiver.DeployConfig memory config = script.getDeployConfig(
      block.chainid
    );
    VotingChainRobotReceiver robot = VotingChainRobotReceiver(script.run());
    _assertDeployment(robot, config, chain);

    IVotingMachineWithProofs votingMachine = robot.VOTING_MACHINE();
    (uint256 id, bytes32 blockHash) = _bridgeProposal(
      votingMachine,
      chain.crossChainController,
      chain.l1VotingPortal
    );
    _assertState(votingMachine, id, IVotingMachineWithProofs.ProposalState.NotCreated);

    assertFalse(_hasAction(robot, id), 'action due before the roots are registered');

    // The governance storage roots workflow registers the proofs; stand in for it.
    _registerRoots(robot, blockHash);
    bytes memory performData = _checkUpkeepMatchesLiveKeeper(robot, chain.liveKeeper);
    _assertHasAction(performData, id, IVotingChainRobotReceiver.ProposalAction.PerformCreateVote);

    vm.prank(anyone);
    robot.onReport('', performData);
    _assertState(votingMachine, id, IVotingMachineWithProofs.ProposalState.Active);

    vm.warp(votingMachine.getProposalById(id).endTime + 1);
    performData = _checkUpkeepMatchesLiveKeeper(robot, chain.liveKeeper);
    _assertHasAction(
      performData,
      id,
      IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote
    );

    vm.prank(anyone);
    robot.onReport('', performData);
    _assertState(votingMachine, id, IVotingMachineWithProofs.ProposalState.SentToGovernance);
  }

  function _assertDeployment(
    VotingChainRobotReceiver robot,
    DeployVotingChainRobotReceiver.DeployConfig memory config,
    ChainSetup memory chain
  ) internal view {
    IVotingChainRobotReceiver liveKeeper = IVotingChainRobotReceiver(chain.liveKeeper);
    assertEq(address(robot.VOTING_MACHINE()), config.votingMachine, 'voting machine mismatch');
    assertEq(address(robot.DATA_WAREHOUSE()), chain.dataWarehouse, 'data warehouse mismatch');
    assertEq(address(robot.VOTING_STRATEGY()), chain.votingStrategy, 'voting strategy mismatch');
    assertEq(robot.GOVERNANCE(), address(GovernanceV3Ethereum.GOVERNANCE), 'governance mismatch');
    assertEq(robot.owner(), config.owner, 'owner mismatch');
    assertEq(robot.guardian(), config.guardian, 'guardian mismatch');
    assertEq(
      address(robot.VOTING_MACHINE()),
      address(liveKeeper.VOTING_MACHINE()),
      'voting machine differs from the live keeper'
    );
    assertEq(
      address(robot.DATA_WAREHOUSE()),
      address(liveKeeper.DATA_WAREHOUSE()),
      'data warehouse differs from the live keeper'
    );
  }

  /// Bridges a vote configuration for a new proposal, as the L1 voting portal would, with a
  /// block hash that has no roots registered.
  function _bridgeProposal(
    IVotingMachineWithProofs votingMachine,
    address crossChainController,
    address l1VotingPortal
  ) internal returns (uint256 id, bytes32 blockHash) {
    uint256[] memory latest = votingMachine.getProposalsVoteConfigurationIds(0, 1);
    require(latest.length == 1, 'voting machine has no proposal');
    id = latest[0] + PROPOSAL_ID_OFFSET;
    blockHash = _blockHash();

    vm.prank(crossChainController);
    IBaseReceiverPortal(address(votingMachine)).receiveCrossChainMessage(
      l1VotingPortal,
      1,
      abi.encode(IVotingPortal.MessageType.Proposal, abi.encode(id, blockHash, VOTING_DURATION))
    );
    assertEq(
      votingMachine.getProposalVoteConfiguration(id).l1ProposalBlockHash,
      blockHash,
      'vote configuration not bridged'
    );
  }

  function _registerRoots(VotingChainRobotReceiver robot, bytes32 blockHash) internal {
    vm.mockCall(
      address(robot.VOTING_STRATEGY()),
      abi.encodeCall(IVotingStrategy.hasRequiredRoots, (blockHash)),
      ''
    );
    vm.mockCall(
      address(robot.DATA_WAREHOUSE()),
      abi.encodeCall(IDataWarehouse.getStorageRoots, (robot.GOVERNANCE(), blockHash)),
      abi.encode(keccak256('representatives root'))
    );
  }

  /// The robot must pick the same start / close actions as the live keeper. The keeper's roots
  /// requests are left out, and its action values are one higher (SubmitRoots comes first).
  function _checkUpkeepMatchesLiveKeeper(
    VotingChainRobotReceiver robot,
    address liveKeeper
  ) internal view returns (bytes memory performData) {
    performData = _checkUpkeep(robot);
    IVotingChainRobotReceiver.ActionWithId[] memory actions = abi.decode(
      performData,
      (IVotingChainRobotReceiver.ActionWithId[])
    );

    (bool liveNeeded, bytes memory livePerformData) = IAaveCREReceiver(liveKeeper).checkUpkeep('');
    assertTrue(liveNeeded, 'live keeper sees no upkeep');
    LiveKeeperAction[] memory liveActions = abi.decode(livePerformData, (LiveKeeperAction[]));

    uint256 matched = 0;
    for (uint256 i = 0; i < liveActions.length; i++) {
      if (liveActions[i].action == LIVE_KEEPER_SUBMIT_ROOTS) continue;
      assertLt(matched, actions.length, 'live keeper has more actions');
      assertEq(actions[matched].id, liveActions[i].id, 'proposal differs from the live keeper');
      assertEq(
        uint256(actions[matched].action) + 1,
        liveActions[i].action,
        'action differs from the live keeper'
      );
      matched++;
    }
    assertEq(matched, actions.length, 'robot has more actions than the live keeper');
  }

  function _checkUpkeep(VotingChainRobotReceiver robot) internal view returns (bytes memory) {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    return performData;
  }

  function _hasAction(VotingChainRobotReceiver robot, uint256 id) internal view returns (bool) {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    if (!needed) return false;
    IVotingChainRobotReceiver.ActionWithId[] memory actions = abi.decode(
      performData,
      (IVotingChainRobotReceiver.ActionWithId[])
    );
    for (uint256 i = 0; i < actions.length; i++) {
      if (actions[i].id == id) return true;
    }
    return false;
  }

  function _assertHasAction(
    bytes memory performData,
    uint256 id,
    IVotingChainRobotReceiver.ProposalAction action
  ) internal pure {
    IVotingChainRobotReceiver.ActionWithId[] memory actions = abi.decode(
      performData,
      (IVotingChainRobotReceiver.ActionWithId[])
    );
    for (uint256 i = 0; i < actions.length; i++) {
      if (actions[i].id == id) {
        assertEq(uint256(actions[i].action), uint256(action), 'unexpected action');
        return;
      }
    }
    revert('proposal missing from performData');
  }

  function _assertState(
    IVotingMachineWithProofs votingMachine,
    uint256 id,
    IVotingMachineWithProofs.ProposalState expected
  ) internal view {
    assertEq(
      uint256(votingMachine.getProposalState(id)),
      uint256(expected),
      'unexpected proposal state'
    );
  }

  function _blockHash() internal view returns (bytes32) {
    return keccak256(abi.encode('voting-chain-robot fork test', block.chainid));
  }
}
