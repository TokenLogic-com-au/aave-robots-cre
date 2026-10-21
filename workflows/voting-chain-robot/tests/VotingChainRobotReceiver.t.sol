// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';
import {IWithGuardian} from 'solidity-utils/contracts/access-control/interfaces/IWithGuardian.sol';
import {IERC165} from 'openzeppelin-contracts/contracts/utils/introspection/IERC165.sol';
import {IRescuable} from 'aave-v4/interfaces/IRescuable.sol';
import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {IVotingMachineWithProofs} from 'aave-address-book/governance-v3/IVotingMachineWithProofs.sol';
import {IVotingStrategy} from 'aave-address-book/governance-v3/IVotingStrategy.sol';
import {IDataWarehouse} from 'aave-address-book/governance-v3/IDataWarehouse.sol';
import {AggregatorInterface} from 'aave-v3-origin/contracts/dependencies/chainlink/AggregatorInterface.sol';

import {IReceiver} from 'aave-cre/IReceiver.sol';
import {IAaveCREReceiver} from 'aave-cre/IAaveCREReceiver.sol';

import {VotingChainRobotReceiver} from '../src/VotingChainRobotReceiver.sol';
import {IVotingChainRobotReceiver} from '../src/IVotingChainRobotReceiver.sol';
import {DeployVotingChainRobotReceiver} from '../scripts/DeployVotingChainRobotReceiver.s.sol';
import {VotingChainRobotReceiverHarness} from './helpers/VotingChainRobotReceiverHarness.sol';

contract VotingChainRobotReceiverTest is Test {
  uint256 internal constant MAX_GAS_PRICE = 150 gwei;

  VotingChainRobotReceiverHarness internal robot;

  address internal owner = makeAddr('owner');
  address internal guardian = makeAddr('guardian');
  address internal bob = makeAddr('bob');
  address internal anyone = makeAddr('anyone');

  address internal votingMachine = makeAddr('votingMachine');
  address internal votingStrategy = makeAddr('votingStrategy');
  address internal dataWarehouse = makeAddr('dataWarehouse');
  address internal governance = makeAddr('governance');
  address internal gasOracle = makeAddr('gasOracle');

  function setUp() public {
    // Calls to functions without return data check the target has code.
    vm.etch(votingMachine, hex'00');
    vm.etch(votingStrategy, hex'00');
    vm.etch(dataWarehouse, hex'00');
    vm.etch(gasOracle, hex'00');

    vm.mockCall(
      votingMachine,
      abi.encodeCall(IVotingMachineWithProofs.VOTING_STRATEGY, ()),
      abi.encode(votingStrategy)
    );
    vm.mockCall(
      votingMachine,
      abi.encodeCall(IVotingMachineWithProofs.DATA_WAREHOUSE, ()),
      abi.encode(dataWarehouse)
    );
    vm.mockCall(
      votingMachine,
      abi.encodeCall(IVotingMachineWithProofs.GOVERNANCE, ()),
      abi.encode(governance)
    );

    robot = _deploy(gasOracle, MAX_GAS_PRICE);
    _mockGasPrice(1 gwei);
    _mockProposalIds(0, new uint256[](0));
    _mockProposalIds(robot.PAGE_SIZE(), new uint256[](0));
  }

  function test_constructor_setsImmutablesAndRoles() public view {
    assertEq(address(robot.VOTING_MACHINE()), votingMachine, 'voting machine mismatch');
    assertEq(address(robot.VOTING_STRATEGY()), votingStrategy, 'voting strategy mismatch');
    assertEq(address(robot.DATA_WAREHOUSE()), dataWarehouse, 'data warehouse mismatch');
    assertEq(robot.GOVERNANCE(), governance, 'governance mismatch');
    assertEq(address(robot.GAS_PRICE_ORACLE()), gasOracle, 'gas price oracle mismatch');
    assertEq(robot.getMaxGasPrice(), MAX_GAS_PRICE, 'max gas price mismatch');
    assertEq(robot.owner(), owner, 'owner mismatch');
    assertEq(robot.guardian(), guardian, 'guardian mismatch');
  }

  function test_constructor_emitsMaxGasPriceSet() public {
    vm.expectEmit();
    emit IVotingChainRobotReceiver.MaxGasPriceSet(MAX_GAS_PRICE);
    _deploy(gasOracle, MAX_GAS_PRICE);
  }

  function test_constructor_withoutGasPriceOracle() public {
    VotingChainRobotReceiver deployed = _deploy(address(0), 0);
    assertEq(address(deployed.GAS_PRICE_ORACLE()), address(0), 'gas price oracle set');
    assertEq(deployed.getMaxGasPrice(), 0, 'max gas price set');
  }

  function test_constructor_revertsWith_InvalidAddress_whenVotingMachineIsZero() public {
    vm.expectRevert(IVotingChainRobotReceiver.InvalidAddress.selector);
    new VotingChainRobotReceiver(address(0), gasOracle, MAX_GAS_PRICE, owner, guardian);
  }

  function test_constructor_revertsWith_GasPriceCapNotSupported() public {
    vm.expectRevert(IVotingChainRobotReceiver.GasPriceCapNotSupported.selector);
    _deploy(address(0), 1);
  }

  function test_constructor_revertsWith_InvalidMaxGasPrice() public {
    vm.expectRevert(IVotingChainRobotReceiver.InvalidMaxGasPrice.selector);
    _deploy(gasOracle, 0);
  }

  function test_constants() public view {
    assertEq(robot.MAX_ACTIONS(), 5, 'unexpected MAX_ACTIONS');
    assertEq(robot.PAGE_SIZE(), 20, 'unexpected PAGE_SIZE');
  }

  function test_supportsInterface() public view {
    assertTrue(robot.supportsInterface(type(IReceiver).interfaceId), 'IReceiver not supported');
    assertTrue(
      robot.supportsInterface(type(IAaveCREReceiver).interfaceId),
      'IAaveCREReceiver not supported'
    );
    assertTrue(robot.supportsInterface(type(IERC165).interfaceId), 'IERC165 not supported');
    assertFalse(robot.supportsInterface(0xffffffff), 'invalid interface id supported');
  }

  /// Every combination of the inputs the decision depends on.
  function test_fuzz_getAction(
    uint8 stateSeed,
    bool strategyRoots,
    bool governanceRoot,
    bool disabled
  ) public {
    IVotingMachineWithProofs.ProposalState state = IVotingMachineWithProofs.ProposalState(
      bound(stateSeed, 0, 3)
    );
    _setupProposal(1, state, _hash(1));
    _mockRoots(_hash(1), strategyRoots, governanceRoot);
    if (disabled) {
      vm.prank(guardian);
      robot.disableAutomation(1);
    }

    (bool due, IVotingChainRobotReceiver.ProposalAction action) = robot.getAction(1);

    bool createVote = state == IVotingMachineWithProofs.ProposalState.NotCreated &&
      strategyRoots &&
      governanceRoot;
    bool closeVote = state == IVotingMachineWithProofs.ProposalState.Finished;

    assertEq(due, !disabled && (createVote || closeVote), 'unexpected due');
    assertEq(
      robot.canCreateVote(state, 1),
      createVote,
      'canCreateVote disagrees with the roots and state'
    );
    if (!due) return;
    _assertAction(
      action,
      createVote
        ? IVotingChainRobotReceiver.ProposalAction.PerformCreateVote
        : IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote
    );
  }

  function test_fuzz_isGasPriceInRange(uint256 gasPrice, uint256 maxGasPrice) public {
    gasPrice = bound(gasPrice, 0, uint256(type(int256).max));
    if (maxGasPrice != robot.getMaxGasPrice()) {
      vm.prank(owner);
      robot.setMaxGasPrice(maxGasPrice);
    }
    _mockGasPrice(gasPrice);

    assertEq(robot.isGasPriceInRange(), gasPrice <= maxGasPrice, 'unexpected isGasPriceInRange');
  }

  function test_isGasPriceInRange_withoutOracle() public {
    VotingChainRobotReceiver deployed = _deploy(address(0), 0);
    assertTrue(deployed.isGasPriceInRange(), 'no oracle should mean no cap');
  }

  function test_checkUpkeep_returnsFalse_whenNoProposals() public view {
    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed without proposals');
    assertEq(performData.length, 0, 'performData should be empty');
  }

  function test_checkUpkeep_returnsFalse_whenGasPriceAboveCap() public {
    _mockProposalIds(0, _ids(1, 1));
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));
    _mockGasPrice(MAX_GAS_PRICE + 1);

    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'upkeep needed above the gas price cap');
  }

  function test_checkUpkeep_ignoresGasPrice_withoutOracle() public {
    VotingChainRobotReceiver deployed = _deploy(address(0), 0);
    _mockProposalIds(0, _ids(1, 1));
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));
    _mockGasPrice(type(uint128).max);

    (bool needed, ) = deployed.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed without a gas price cap');
  }

  /// A vote whose roots are missing (4) waits for the storage roots workflow.
  function test_checkUpkeep_returnsActionsOfEachKind_latestFirst() public {
    _mockProposalIds(0, _ids(4, 4));
    _setupProposal(4, IVotingMachineWithProofs.ProposalState.NotCreated, _hash(4));
    _mockRoots(_hash(4), false, false);
    _setupProposal(3, IVotingMachineWithProofs.ProposalState.NotCreated, _hash(3));
    _mockRoots(_hash(3), true, true);
    _setupProposal(2, IVotingMachineWithProofs.ProposalState.Active, _hash(2));
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');

    IVotingChainRobotReceiver.ActionWithId[] memory actions = _decode(performData);
    assertEq(actions.length, 2, 'unexpected number of actions');
    _assertActionWithId(actions[0], 3, IVotingChainRobotReceiver.ProposalAction.PerformCreateVote);
    _assertActionWithId(
      actions[1],
      1,
      IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote
    );
  }

  /// BGD's keeper reverts out of bounds once more than `MAX_ACTIONS` actions are due.
  function test_checkUpkeep_capsAtMaxActions() public {
    uint256 maxActions = robot.MAX_ACTIONS();
    uint256 total = maxActions + 3;
    _mockProposalIds(0, _ids(total, total));
    for (uint256 id = 1; id <= total; id++) {
      _setupProposal(id, IVotingMachineWithProofs.ProposalState.Finished, _hash(id));
    }

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');

    IVotingChainRobotReceiver.ActionWithId[] memory actions = _decode(performData);
    assertEq(actions.length, maxActions, 'should return MAX_ACTIONS actions');
    for (uint256 i = 0; i < maxActions; i++) {
      assertEq(actions[i].id, total - i, 'should pick the latest proposals first');
    }
  }

  function test_checkUpkeep_readsNextPage_whenPageHadActions() public {
    uint256 pageSize = robot.PAGE_SIZE();
    _setupPage(0, pageSize * 2, pageSize, 1);
    _setupPage(pageSize, pageSize, pageSize, 1);
    _mockProposalIds(pageSize * 2, new uint256[](0));

    (bool needed, bytes memory performData) = robot.checkUpkeep('');
    assertTrue(needed, 'upkeep should be needed');

    IVotingChainRobotReceiver.ActionWithId[] memory actions = _decode(performData);
    assertEq(actions.length, 2, 'should collect one action per page');
    assertEq(actions[0].id, pageSize * 2, 'unexpected first page action');
    assertEq(actions[1].id, pageSize, 'unexpected second page action');
  }

  function test_checkUpkeep_stopsPaging_whenPageHadNoAction() public {
    uint256 pageSize = robot.PAGE_SIZE();
    _setupPage(0, pageSize * 2, pageSize, 0);
    _setupPage(pageSize, pageSize, pageSize, 1);

    vm.expectCall(
      votingMachine,
      abi.encodeCall(
        IVotingMachineWithProofs.getProposalsVoteConfigurationIds,
        (pageSize, pageSize)
      ),
      0
    );
    (bool needed, ) = robot.checkUpkeep('');
    assertFalse(needed, 'older pages are only read after a page with actions');
  }

  function test_checkUpkeep_skipsDisabledProposals() public {
    _mockProposalIds(0, _ids(2, 2));
    _setupProposal(2, IVotingMachineWithProofs.ProposalState.Finished, _hash(2));
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));
    vm.prank(guardian);
    robot.disableAutomation(2);

    (, bytes memory performData) = robot.checkUpkeep('');
    IVotingChainRobotReceiver.ActionWithId[] memory actions = _decode(performData);
    assertEq(actions.length, 1, 'disabled proposal not skipped');
    assertEq(actions[0].id, 1, 'unexpected proposal');
  }

  function test_onReport_startsVote() public {
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.NotCreated, _hash(1));
    _mockRoots(_hash(1), true, true);
    vm.mockCall(
      votingMachine,
      abi.encodeCall(IVotingMachineWithProofs.startProposalVote, (1)),
      abi.encode(uint256(1))
    );

    vm.expectCall(votingMachine, abi.encodeCall(IVotingMachineWithProofs.startProposalVote, (1)));
    vm.expectEmit(address(robot));
    emit IVotingChainRobotReceiver.ActionSucceeded(
      1,
      IVotingChainRobotReceiver.ProposalAction.PerformCreateVote
    );

    vm.prank(anyone);
    robot.onReport('', _report(1, IVotingChainRobotReceiver.ProposalAction.PerformCreateVote));
  }

  function test_onReport_closesAndSendsVote() public {
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));
    _mockCloseAndSendVote(1);

    vm.expectCall(votingMachine, abi.encodeCall(IVotingMachineWithProofs.closeAndSendVote, (1)));
    vm.expectEmit(address(robot));
    emit IVotingChainRobotReceiver.ActionSucceeded(
      1,
      IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote
    );

    vm.prank(anyone);
    robot.onReport(
      '',
      _report(1, IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote)
    );
  }

  function test_onReport_performsOldestProposalFirst() public {
    _setupProposal(2, IVotingMachineWithProofs.ProposalState.Finished, _hash(2));
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));
    _mockCloseAndSendVote(2);
    _mockCloseAndSendVote(1);

    IVotingChainRobotReceiver.ActionWithId[]
      memory actions = new IVotingChainRobotReceiver.ActionWithId[](2);
    actions[0] = _action(2, IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote);
    actions[1] = _action(1, IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote);

    vm.recordLogs();
    robot.onReport('', abi.encode(actions));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 2, 'expected two ActionSucceeded');
    assertEq(uint256(logs[0].topics[1]), 1, 'oldest proposal not performed first');
    assertEq(uint256(logs[1].topics[1]), 2, 'latest proposal not performed last');
  }

  function test_onReport_skipsRevertingAction_andPerformsRest() public {
    _setupProposal(2, IVotingMachineWithProofs.ProposalState.Finished, _hash(2));
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));
    vm.mockCallRevert(
      votingMachine,
      abi.encodeCall(IVotingMachineWithProofs.closeAndSendVote, (1)),
      'bridge failed'
    );
    _mockCloseAndSendVote(2);

    IVotingChainRobotReceiver.ActionWithId[]
      memory actions = new IVotingChainRobotReceiver.ActionWithId[](2);
    actions[0] = _action(2, IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote);
    actions[1] = _action(1, IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote);

    vm.recordLogs();
    robot.onReport('', abi.encode(actions));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 1, 'expected a single ActionSucceeded');
    assertEq(uint256(logs[0].topics[1]), 2, 'event for wrong proposal');
  }

  /// Roots missing and voting not finished: no action is due.
  function test_fuzz_onReport_revertsWith_NoActionCanBePerformed_whenNothingDue(
    uint8 stateSeed,
    uint8 actionSeed
  ) public {
    IVotingMachineWithProofs.ProposalState[3] memory states = [
      IVotingMachineWithProofs.ProposalState.NotCreated,
      IVotingMachineWithProofs.ProposalState.Active,
      IVotingMachineWithProofs.ProposalState.SentToGovernance
    ];
    IVotingChainRobotReceiver.ProposalAction action = IVotingChainRobotReceiver.ProposalAction(
      bound(actionSeed, 0, 1)
    );
    _setupProposal(1, states[bound(stateSeed, 0, 2)], _hash(1));
    _mockRoots(_hash(1), false, false);

    vm.expectRevert(IVotingChainRobotReceiver.NoActionCanBePerformed.selector);
    robot.onReport('', _report(1, action));
  }

  function test_onReport_revertsWith_NoActionCanBePerformed_whenActionDoesNotMatchState() public {
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));

    vm.expectRevert(IVotingChainRobotReceiver.NoActionCanBePerformed.selector);
    robot.onReport('', _report(1, IVotingChainRobotReceiver.ProposalAction.PerformCreateVote));
  }

  function test_onReport_revertsWith_NoActionCanBePerformed_whenProposalDisabled() public {
    _setupProposal(1, IVotingMachineWithProofs.ProposalState.Finished, _hash(1));
    _mockCloseAndSendVote(1);
    vm.prank(guardian);
    robot.disableAutomation(1);

    vm.expectCall(votingMachine, abi.encodeCall(IVotingMachineWithProofs.closeAndSendVote, (1)), 0);
    vm.expectRevert(IVotingChainRobotReceiver.NoActionCanBePerformed.selector);
    robot.onReport(
      '',
      _report(1, IVotingChainRobotReceiver.ProposalAction.PerformCloseAndSendVote)
    );
  }

  function test_onReport_revertsWith_NoActionCanBePerformed_whenEmptyBatch() public {
    vm.expectRevert(IVotingChainRobotReceiver.NoActionCanBePerformed.selector);
    robot.onReport('', abi.encode(new IVotingChainRobotReceiver.ActionWithId[](0)));
  }

  function test_disableAutomation_byOwnerOrGuardian() public {
    vm.expectEmit(address(robot));
    emit IVotingChainRobotReceiver.AutomationDisabled(1, true);
    vm.prank(owner);
    robot.disableAutomation(1);
    assertTrue(robot.isDisabled(1), 'proposal not disabled by owner');

    vm.prank(guardian);
    robot.disableAutomation(2);
    assertTrue(robot.isDisabled(2), 'proposal not disabled by guardian');
  }

  function test_disableAutomation_revertsWith_OnlyGuardianOrOwnerInvalidCaller() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.disableAutomation(1);
  }

  function test_disableAutomation_revertsWith_AutomationStatusUnchanged() public {
    vm.prank(guardian);
    robot.disableAutomation(1);

    vm.prank(guardian);
    vm.expectRevert(
      abi.encodeWithSelector(IVotingChainRobotReceiver.AutomationStatusUnchanged.selector, 1)
    );
    robot.disableAutomation(1);
  }

  function test_enableAutomation() public {
    vm.prank(guardian);
    robot.disableAutomation(1);

    vm.expectEmit(address(robot));
    emit IVotingChainRobotReceiver.AutomationDisabled(1, false);
    vm.prank(owner);
    robot.enableAutomation(1);
    assertFalse(robot.isDisabled(1), 'proposal still disabled');
  }

  function test_enableAutomation_revertsWhenCalledByGuardian() public {
    vm.prank(guardian);
    robot.disableAutomation(1);

    vm.prank(guardian);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
    robot.enableAutomation(1);
  }

  function test_enableAutomation_revertsWith_AutomationStatusUnchanged() public {
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(IVotingChainRobotReceiver.AutomationStatusUnchanged.selector, 1)
    );
    robot.enableAutomation(1);
  }

  function test_setMaxGasPrice_byOwnerOrGuardian() public {
    vm.expectEmit(address(robot));
    emit IVotingChainRobotReceiver.MaxGasPriceSet(1 gwei);
    vm.prank(owner);
    robot.setMaxGasPrice(1 gwei);
    assertEq(robot.getMaxGasPrice(), 1 gwei, 'max gas price not updated by owner');

    vm.prank(guardian);
    robot.setMaxGasPrice(2 gwei);
    assertEq(robot.getMaxGasPrice(), 2 gwei, 'max gas price not updated by guardian');
  }

  function test_setMaxGasPrice_revertsWith_OnlyGuardianOrOwnerInvalidCaller() public {
    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(IWithGuardian.OnlyGuardianOrOwnerInvalidCaller.selector, bob)
    );
    robot.setMaxGasPrice(1 gwei);
  }

  function test_setMaxGasPrice_revertsWith_MaxGasPriceUnchanged() public {
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(IVotingChainRobotReceiver.MaxGasPriceUnchanged.selector)
    );
    robot.setMaxGasPrice(MAX_GAS_PRICE);
  }

  function test_setMaxGasPrice_revertsWith_GasPriceCapNotSupported() public {
    VotingChainRobotReceiver deployed = _deploy(address(0), 0);
    vm.prank(guardian);
    vm.expectRevert(IVotingChainRobotReceiver.GasPriceCapNotSupported.selector);
    deployed.setMaxGasPrice(1 gwei);
  }

  function test_rescueGuardian_isOwner() public view {
    assertEq(robot.rescueGuardian(), owner, 'rescue guardian is not the owner');
  }

  function test_rescueToken_revertsWith_OnlyRescueGuardian() public {
    vm.prank(guardian);
    vm.expectRevert(IRescuable.OnlyRescueGuardian.selector);
    robot.rescueToken(makeAddr('token'), bob, 100);
  }

  function test_getDeployConfig_revertsOnUnsupportedChain() public {
    DeployVotingChainRobotReceiver script = new DeployVotingChainRobotReceiver();
    vm.expectRevert(bytes('unsupported chain'));
    script.getDeployConfig(ChainIds.ARBITRUM);
  }

  function test_getDeployConfig_capsGasPriceOnlyOnEthereum() public {
    DeployVotingChainRobotReceiver script = new DeployVotingChainRobotReceiver();
    uint256[3] memory chainIds = [ChainIds.MAINNET, ChainIds.AVALANCHE, ChainIds.POLYGON];
    for (uint256 i = 0; i < chainIds.length; i++) {
      DeployVotingChainRobotReceiver.DeployConfig memory config = script.getDeployConfig(
        chainIds[i]
      );
      bool isEthereum = chainIds[i] == ChainIds.MAINNET;
      assertEq(config.gasPriceOracle != address(0), isEthereum, 'unexpected gas price oracle');
      assertEq(config.maxGasPrice != 0, isEthereum, 'unexpected max gas price');
      assertTrue(config.votingMachine != address(0), 'voting machine is zero');
      assertTrue(config.owner != address(0), 'owner is zero');
      assertTrue(config.guardian != address(0), 'guardian is zero');
    }
  }

  function _deploy(
    address oracle,
    uint256 maxGasPrice
  ) internal returns (VotingChainRobotReceiverHarness) {
    return new VotingChainRobotReceiverHarness(votingMachine, oracle, maxGasPrice, owner, guardian);
  }

  /// Mocks one page of `size` ids counting down from `firstId`, with `withActions` Finished
  /// proposals first and the rest SentToGovernance.
  function _setupPage(uint256 skip, uint256 firstId, uint256 size, uint256 withActions) internal {
    uint256[] memory ids = _ids(firstId, size);
    _mockProposalIds(skip, ids);
    for (uint256 i = 0; i < size; i++) {
      _setupProposal(
        ids[i],
        i < withActions
          ? IVotingMachineWithProofs.ProposalState.Finished
          : IVotingMachineWithProofs.ProposalState.SentToGovernance,
        _hash(ids[i])
      );
    }
  }

  function _setupProposal(
    uint256 id,
    IVotingMachineWithProofs.ProposalState state,
    bytes32 blockHash
  ) internal {
    vm.mockCall(
      votingMachine,
      abi.encodeCall(IVotingMachineWithProofs.getProposalState, (id)),
      abi.encode(state)
    );
    vm.mockCall(
      votingMachine,
      abi.encodeCall(IVotingMachineWithProofs.getProposalVoteConfiguration, (id)),
      abi.encode(
        IVotingMachineWithProofs.ProposalVoteConfiguration({
          votingDuration: 3 days,
          l1ProposalBlockHash: blockHash
        })
      )
    );
  }

  function _mockProposalIds(uint256 skip, uint256[] memory ids) internal {
    vm.mockCall(
      votingMachine,
      abi.encodeCall(
        IVotingMachineWithProofs.getProposalsVoteConfigurationIds,
        (skip, robot.PAGE_SIZE())
      ),
      abi.encode(ids)
    );
  }

  function _mockRoots(bytes32 blockHash, bool strategyRoots, bool governanceRoot) internal {
    if (strategyRoots) {
      vm.mockCall(
        votingStrategy,
        abi.encodeCall(IVotingStrategy.hasRequiredRoots, (blockHash)),
        ''
      );
    } else {
      vm.mockCallRevert(
        votingStrategy,
        abi.encodeCall(IVotingStrategy.hasRequiredRoots, (blockHash)),
        'MISSING_ROOTS'
      );
    }
    vm.mockCall(
      dataWarehouse,
      abi.encodeCall(IDataWarehouse.getStorageRoots, (governance, blockHash)),
      abi.encode(governanceRoot ? keccak256('root') : bytes32(0))
    );
  }

  function _mockCloseAndSendVote(uint256 id) internal {
    vm.mockCall(votingMachine, abi.encodeCall(IVotingMachineWithProofs.closeAndSendVote, (id)), '');
  }

  function _mockGasPrice(uint256 gasPrice) internal {
    vm.mockCall(
      gasOracle,
      abi.encodeCall(AggregatorInterface.latestAnswer, ()),
      abi.encode(int256(gasPrice))
    );
  }

  function _assertAction(
    IVotingChainRobotReceiver.ProposalAction actual,
    IVotingChainRobotReceiver.ProposalAction expected
  ) internal pure {
    assertEq(uint256(actual), uint256(expected), 'unexpected action');
  }

  function _assertActionWithId(
    IVotingChainRobotReceiver.ActionWithId memory actual,
    uint256 id,
    IVotingChainRobotReceiver.ProposalAction action
  ) internal pure {
    assertEq(actual.id, id, 'unexpected proposal id');
    _assertAction(actual.action, action);
  }

  function _decode(
    bytes memory performData
  ) internal pure returns (IVotingChainRobotReceiver.ActionWithId[] memory) {
    return abi.decode(performData, (IVotingChainRobotReceiver.ActionWithId[]));
  }

  function _action(
    uint256 id,
    IVotingChainRobotReceiver.ProposalAction action
  ) internal pure returns (IVotingChainRobotReceiver.ActionWithId memory) {
    return IVotingChainRobotReceiver.ActionWithId({id: id, action: action});
  }

  function _report(
    uint256 id,
    IVotingChainRobotReceiver.ProposalAction action
  ) internal pure returns (bytes memory) {
    IVotingChainRobotReceiver.ActionWithId[]
      memory actions = new IVotingChainRobotReceiver.ActionWithId[](1);
    actions[0] = _action(id, action);
    return abi.encode(actions);
  }

  /// `size` ids counting down from `firstId`, as `getProposalsVoteConfigurationIds` returns them.
  function _ids(uint256 firstId, uint256 size) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](size);
    for (uint256 i = 0; i < size; i++) ids[i] = firstId - i;
  }

  function _hash(uint256 id) internal pure returns (bytes32) {
    return keccak256(abi.encode('blockHash', id));
  }
}
