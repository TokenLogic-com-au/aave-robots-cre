// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from 'forge-std/Test.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';

import {GhoEthereum} from 'aave-address-book/GhoEthereum.sol';

import {GsmFeeClaimerReceiver} from '../src/GsmFeeClaimerReceiver.sol';
import {IGsmFeeClaimerReceiver, IGsmFees} from '../src/IGsmFeeClaimerReceiver.sol';

interface IGsmTreasury {
  function getGhoTreasury() external view returns (address);
}

contract GsmFeeClaimerReceiverForkTest is Test {
  bytes32 internal constant FEES_DISTRIBUTED_TO_TREASURY =
    keccak256('FeesDistributedToTreasury(address,address,uint256)');

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
    robot.checkUpkeep(abi.encode(gsms));
  }

  // End-to-end against the real GSMs: whatever checkUpkeep selects, an
  // unpermissioned onReport clears its accrued fees into the GHO treasury. A
  // Gsm4626 folds vault excess into the distribution, so the treasury is checked
  // against what the GSMs report in FeesDistributedToTreasury, not the fee sum.
  function test_fork_onReport_distributesRealFeesToTreasury() public {
    (bool needed, bytes memory performData) = robot.checkUpkeep(abi.encode(gsms));
    if (!needed) {
      vm.skip(true);
    }
    address[] memory withFees = abi.decode(performData, (address[]));
    address treasury = IGsmTreasury(withFees[0]).getGhoTreasury();
    IERC20 gho = IERC20(GhoEthereum.GHO_TOKEN);

    uint256 fees;
    uint256[] memory feesOf = new uint256[](withFees.length);
    uint256[] memory gsmBalances = new uint256[](withFees.length);
    for (uint256 i = 0; i < withFees.length; i++) {
      feesOf[i] = IGsmFees(withFees[i]).getAccruedFees();
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
      if (logs[i].topics[0] != FEES_DISTRIBUTED_TO_TREASURY) continue;
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

    vm.prank(anyone);
    vm.expectRevert(IGsmFeeClaimerReceiver.NothingToDistribute.selector);
    robot.onReport('', performData);
  }
}
