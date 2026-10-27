// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';
import {AaveV2Avalanche} from 'aave-address-book/AaveV2Avalanche.sol';
import {AaveV3Avalanche} from 'aave-address-book/AaveV3Avalanche.sol';

import {GovernanceOwners} from '../../shared/scripts/GovernanceOwners.sol';
import {ProofOfReserveReceiver} from '../src/ProofOfReserveReceiver.sol';
import {DeployProofOfReserveReceiver} from '../scripts/DeployProofOfReserveReceiver.s.sol';

contract DeployProofOfReserveReceiverTest is Test {
  DeployProofOfReserveReceiver internal script;

  function setUp() public {
    script = new DeployProofOfReserveReceiver();
  }

  function test_run_deploysOnAvalanche() public {
    vm.chainId(ChainIds.AVALANCHE);
    (address owner, address guardian) = GovernanceOwners.get(ChainIds.AVALANCHE);

    ProofOfReserveReceiver receiver = ProofOfReserveReceiver(script.run());

    assertEq(receiver.owner(), owner, 'owner mismatch');
    assertEq(receiver.guardian(), guardian, 'guardian mismatch');
    assertTrue(receiver.isExecutorEnabled(AaveV2Avalanche.PROOF_OF_RESERVE), 'v2 not enabled');
    assertTrue(receiver.isExecutorEnabled(AaveV3Avalanche.PROOF_OF_RESERVE), 'v3 not enabled');
  }

  function test_run_revertsOnUnsupportedChain() public {
    vm.chainId(ChainIds.MAINNET);
    vm.expectRevert(bytes('unsupported chain'));
    script.run();
  }
}
