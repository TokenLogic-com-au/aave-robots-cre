// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {GovernanceV3Ethereum} from 'aave-address-book/GovernanceV3Ethereum.sol';
import {GovernanceV3Avalanche} from 'aave-address-book/GovernanceV3Avalanche.sol';
import {GovernanceV3Polygon} from 'aave-address-book/GovernanceV3Polygon.sol';
import {AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3AvalancheAssets} from 'aave-address-book/AaveV3Avalanche.sol';
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
/// action against the live voting machine, data warehouse and RootsConsumer, comparing
/// `checkUpkeep` with the live BGD keeper's.
contract VotingChainRobotReceiverForkTest is Test {
  struct ChainSetup {
    string rpcAlias;
    address liveKeeper;
    address crossChainController;
    address l1VotingPortal;
    address dataWarehouse;
    address votingStrategy;
    address link;
  }

  address internal constant LIVE_KEEPER_ETHEREUM = 0xbC3210bfff692a5bbDBB068D42Ab4eAF28b01Ee0;
  address internal constant LIVE_KEEPER_AVALANCHE = 0x2cf0fA5b36F0f89a5EA18F835d1375974a7720B8;
  address internal constant LIVE_KEEPER_POLYGON = 0x1180eE41eC15Dd0accC13a1e646B3152bECFf8F6;

  // ERC677 LINK the Polygon RootsConsumer pays its operator with (not the PoS-bridged reserve).
  address internal constant LINK_POLYGON = 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;

  // Block on Avalanche where proposal 531 is being voted on (ends at 1792355163).
  uint256 internal constant AVALANCHE_BLOCK_PROPOSAL_531_ACTIVE = 97735679;
  uint256 internal constant AVALANCHE_PROPOSAL_531 = 531;

  // Short, so warping past its end leaves other live votes untouched.
  uint24 internal constant VOTING_DURATION = 1 hours;

  // Offset from the latest bridged proposal id, to stay clear of the next real ones.
  uint256 internal constant PROPOSAL_ID_OFFSET = 1000;

  bytes32 internal constant OPERATOR_REQUEST_SENT =
    keccak256('OperatorRequestSent(bytes32,string,uint256)');

  address internal anyone = makeAddr('anyone');

  function test_fork_ethereum_runsProposalLifecycle() public {
    _runLifecycle(
      ChainSetup({
        rpcAlias: 'mainnet',
        liveKeeper: LIVE_KEEPER_ETHEREUM,
        crossChainController: GovernanceV3Ethereum.CROSS_CHAIN_CONTROLLER,
        l1VotingPortal: GovernanceV3Ethereum.VOTING_PORTAL_ETH_ETH,
        dataWarehouse: address(GovernanceV3Ethereum.DATA_WAREHOUSE),
        votingStrategy: address(GovernanceV3Ethereum.VOTING_STRATEGY),
        link: AaveV3EthereumAssets.LINK_UNDERLYING
      })
    );
  }

  function test_fork_avalanche_runsProposalLifecycle() public {
    _runLifecycle(
      ChainSetup({
        rpcAlias: 'avalanche',
        liveKeeper: LIVE_KEEPER_AVALANCHE,
        crossChainController: GovernanceV3Avalanche.CROSS_CHAIN_CONTROLLER,
        l1VotingPortal: GovernanceV3Ethereum.VOTING_PORTAL_ETH_AVAX,
        dataWarehouse: address(GovernanceV3Avalanche.DATA_WAREHOUSE),
        votingStrategy: address(GovernanceV3Avalanche.VOTING_STRATEGY),
        link: AaveV3AvalancheAssets.LINKe_UNDERLYING
      })
    );
  }

  function test_fork_polygon_runsProposalLifecycle() public {
    _runLifecycle(
      ChainSetup({
        rpcAlias: 'polygon',
        liveKeeper: LIVE_KEEPER_POLYGON,
        crossChainController: GovernanceV3Polygon.CROSS_CHAIN_CONTROLLER,
        l1VotingPortal: GovernanceV3Ethereum.VOTING_PORTAL_ETH_POL,
        dataWarehouse: address(GovernanceV3Polygon.DATA_WAREHOUSE),
        votingStrategy: address(GovernanceV3Polygon.VOTING_STRATEGY),
        link: LINK_POLYGON
      })
    );
  }

  /// Closes a real vote: proposal 531 on Avalanche, once its voting period is over.
  function test_fork_avalanche_closesLiveProposal() public {
    vm.createSelectFork('avalanche', AVALANCHE_BLOCK_PROPOSAL_531_ACTIVE);
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
    vm.createSelectFork('mainnet');
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

    vm.startPrank(config.owner);
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

  /// Deploys with the script, then takes a freshly bridged proposal through roots request,
  /// vote start and close.
  function _runLifecycle(ChainSetup memory chain) internal {
    vm.createSelectFork(chain.rpcAlias);
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

    // Only the RootsConsumer's robot keeper may request roots.
    (bool due, ) = _findAction(robot, id);
    assertFalse(due, 'roots requested before becoming the robot keeper');
    _becomeRobotKeeper(robot, config.owner, chain.link);

    bytes memory performData = _checkUpkeepMatchesLiveKeeper(robot, chain.liveKeeper);
    _assertHasAction(performData, id, IVotingChainRobotReceiver.ProposalAction.PerformSubmitRoots);

    vm.recordLogs();
    vm.prank(anyone);
    robot.onReport('', performData);
    assertTrue(
      _requestSent(vm.getRecordedLogs(), address(robot.ROOTS_CONSUMER()), blockHash),
      'RootsConsumer did not send the operator request'
    );
    assertTrue(robot.isRootsRequested(blockHash), 'roots request not recorded');
    (due, ) = _findAction(robot, id);
    assertFalse(due, 'roots requested twice');

    // The operator's callback registers the proofs; stand in for it.
    _registerRoots(robot, blockHash);
    performData = _checkUpkeepMatchesLiveKeeper(robot, chain.liveKeeper);
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
      address(robot.ROOTS_CONSUMER()),
      address(liveKeeper.ROOTS_CONSUMER()),
      'roots consumer differs from the live keeper'
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

  /// Governance (the RootsConsumer owner) sets the robot as its robot keeper; LINK covers
  /// one request.
  function _becomeRobotKeeper(
    VotingChainRobotReceiver robot,
    address governanceExecutor,
    address link
  ) internal {
    address consumer = address(robot.ROOTS_CONSUMER());
    assertEq(
      Ownable(consumer).owner(),
      governanceExecutor,
      'RootsConsumer not owned by governance'
    );

    vm.prank(governanceExecutor);
    (bool ok, ) = consumer.call(abi.encodeWithSignature('setRobotKeeper(address)', robot));
    assertTrue(ok, 'setRobotKeeper failed');
    assertEq(robot.ROOTS_CONSUMER().getRobotKeeper(), address(robot), 'robot keeper not set');

    (, bytes memory fee) = consumer.staticcall(abi.encodeWithSignature('getFee()'));
    deal(link, consumer, IERC20(link).balanceOf(consumer) + abi.decode(fee, (uint256)));
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

  function _checkUpkeepMatchesLiveKeeper(
    VotingChainRobotReceiver robot,
    address liveKeeper
  ) internal view returns (bytes memory performData) {
    performData = _checkUpkeep(robot);
    (bool liveNeeded, bytes memory livePerformData) = IAaveCREReceiver(liveKeeper).checkUpkeep('');
    assertTrue(liveNeeded, 'live keeper sees no upkeep');
    assertEq(performData, livePerformData, 'performData differs from the live keeper');
  }

  function _checkUpkeep(VotingChainRobotReceiver robot) internal view returns (bytes memory) {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');
    return performData;
  }

  function _findAction(
    VotingChainRobotReceiver robot,
    uint256 id
  ) internal view returns (bool, IVotingChainRobotReceiver.ProposalAction) {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    if (needed) {
      IVotingChainRobotReceiver.ActionWithId[] memory actions = abi.decode(
        performData,
        (IVotingChainRobotReceiver.ActionWithId[])
      );
      for (uint256 i = 0; i < actions.length; i++) {
        if (actions[i].id == id) return (true, actions[i].action);
      }
    }
    return (false, IVotingChainRobotReceiver.ProposalAction.PerformSubmitRoots);
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

  function _requestSent(
    Vm.Log[] memory logs,
    address consumer,
    bytes32 blockHash
  ) internal pure returns (bool) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (
        logs[i].emitter == consumer &&
        logs[i].topics[0] == OPERATOR_REQUEST_SENT &&
        logs[i].topics[1] == blockHash
      ) return true;
    }
    return false;
  }

  function _blockHash() internal view returns (bytes32) {
    return keccak256(abi.encode('voting-chain-robot fork test', block.chainid));
  }
}
