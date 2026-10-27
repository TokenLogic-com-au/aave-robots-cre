// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';

import {GhoEthereum} from 'aave-address-book/GhoEthereum.sol';
import {GhoPlasma} from 'aave-address-book/GhoPlasma.sol';

import {GsmFeeClaimerReceiver} from '../src/GsmFeeClaimerReceiver.sol';
import {IGsmFees} from '../src/IGsmFeeClaimerReceiver.sol';
import {DeployGsmFeeClaimerReceiver} from '../scripts/DeployGsmFeeClaimerReceiver.s.sol';
import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';

interface IGsmTreasury {
  function getGhoTreasury() external view returns (address);
}

contract GsmFeeClaimerReceiverForkTest is Test {
  bytes32 internal constant FEES_DISTRIBUTED_TO_TREASURY =
    keccak256('FeesDistributedToTreasury(address,address,uint256)');
  uint256 internal constant MIN_FEES = 1000e18;

  GsmFeeClaimerReceiver internal robot;
  address internal owner = makeAddr('owner');
  address internal guardian = makeAddr('guardian');
  address internal anyone = makeAddr('anyone');

  address[] internal gsms;

  function setUp() public {
    vm.createSelectFork(vm.envString('RPC_MAINNET'));
    robot = new GsmFeeClaimerReceiver(owner, guardian);
    gsms.push(GhoEthereum.GSM_USDC);
    gsms.push(GhoEthereum.GSM_USDT);
  }

  // Locks the minimal interface against the real deployed GSMs: both reads must
  // succeed, and checkUpkeep must return cleanly whatever the current fees are.
  function test_fork_readPath_matchesRealGsms() public view {
    IGsmFees(GhoEthereum.GSM_USDC).getAccruedFees();
    IGsmFees(GhoEthereum.GSM_USDT).getAccruedFees();
    robot.checkUpkeep(abi.encode(gsms, MIN_FEES));
  }

  // End-to-end against the real GSMs: whatever checkUpkeep selects, an
  // unpermissioned onReport clears its accrued fees into the GHO treasury. A
  // Gsm4626 folds vault excess into the distribution, so the treasury is checked
  // against what the GSMs report in FeesDistributedToTreasury, not the fee sum.
  function test_fork_onReport_distributesRealFeesToTreasury() public {
    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(gsms, MIN_FEES));
    if (!needed) {
      vm.skip(true);
    }
    address[] memory withFees = abi.decode(performData, (address[]));
    address treasury = IGsmTreasury(withFees[0]).getGhoTreasury();
    for (uint256 i = 1; i < withFees.length; i++) {
      assertEq(IGsmTreasury(withFees[i]).getGhoTreasury(), treasury, 'gsms differ in treasury');
    }
    IERC20 gho = IERC20(GhoEthereum.GHO_TOKEN);

    uint256 fees;
    uint256[] memory feesOf = new uint256[](withFees.length);
    uint256[] memory gsmBalances = new uint256[](withFees.length);
    for (uint256 i = 0; i < withFees.length; i++) {
      feesOf[i] = IGsmFees(withFees[i]).getAccruedFees();
      assertGe(feesOf[i], MIN_FEES, 'selected gsm below threshold');
      fees += feesOf[i];
      gsmBalances[i] = gho.balanceOf(withFees[i]);
    }
    uint256 treasuryBefore = gho.balanceOf(treasury);

    vm.recordLogs();
    vm.prank(anyone);
    robot.onReport('', performData);

    uint256 distributed;
    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics.length == 0 || logs[i].topics[0] != FEES_DISTRIBUTED_TO_TREASURY) continue;
      distributed += abi.decode(logs[i].data, (uint256));
    }
    uint256 received = gho.balanceOf(treasury) - treasuryBefore;
    assertEq(received, distributed, 'treasury did not receive what the gsms distributed');
    assertGe(received, fees, 'less than the accrued fees reached the treasury');
    for (uint256 i = 0; i < withFees.length; i++) {
      assertEq(IGsmFees(withFees[i]).getAccruedFees(), 0, 'gsm still has accrued fees');
      assertEq(
        gsmBalances[i] - gho.balanceOf(withFees[i]),
        feesOf[i],
        'gsm net outflow is not its accrued fees'
      );
    }

    // Replaying the report is a no-op: nothing left to distribute, nothing moves.
    uint256 treasuryAfter = gho.balanceOf(treasury);
    vm.prank(anyone);
    robot.onReport('', performData);
    assertEq(gho.balanceOf(treasury), treasuryAfter, 'replay moved funds');
    (needed, ) = robot.checkUpkeep(abi.encode(gsms, MIN_FEES));
    assertFalse(needed, 'upkeep still needed after distributing');
  }
}

/// Deploys through the script on every other supported chain and probes its live GSM.
contract GsmFeeClaimerDeployScriptForkTest is Test {
  // Not in the pinned address book yet; values from offchain/config.production.json.
  address internal constant ARBITRUM_GSM_USDT = 0x53E0cE250d06043414070100458546AaF4e284eD;
  address internal constant MONAD_GSM_USDC = 0x3Cf3779EEf770931543ACd2C7f6ECd1b37E35caB;

  function test_fork_arbitrum_deployScriptReadsGsm() public {
    vm.skip(!vm.envExists('RPC_ARBITRUM'), 'RPC_ARBITRUM not set');
    _deployAndCheck('arbitrum', ARBITRUM_GSM_USDT);
  }

  function test_fork_plasma_deployScriptReadsGsm() public {
    vm.skip(!vm.envExists('RPC_PLASMA'), 'RPC_PLASMA not set');
    _deployAndCheck('plasma', GhoPlasma.GSM_USDT);
  }

  /// Forking Monad needs forge's Monad EVM, which only `--network monad` selects.
  function test_fork_monad_deployScriptReadsGsm() public {
    vm.skip(!vm.envOr('FORK_MONAD', false), 'set FORK_MONAD=true and run with --network monad');
    _deployAndCheck('monad', MONAD_GSM_USDC);
  }

  function _deployAndCheck(string memory chain, address gsm) internal {
    vm.createSelectFork(chain);
    GsmFeeClaimerReceiver robot = GsmFeeClaimerReceiver(new DeployGsmFeeClaimerReceiver().run());
    (address owner, address guardian) = GovernanceOwners.get(block.chainid);
    assertEq(robot.owner(), owner, 'unexpected owner');
    assertEq(robot.guardian(), guardian, 'unexpected guardian');

    address[] memory gsms = new address[](1);
    gsms[0] = gsm;
    uint256 fees = IGsmFees(gsm).getAccruedFees();
    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(gsms, fees));
    assertEq(needed, fees > 0, 'upkeep decision does not match the live fees');
    if (needed) assertEq(performData, abi.encode(gsms), 'unexpected performData');
  }
}
