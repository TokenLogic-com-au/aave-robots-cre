// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';

import {ChainIds} from 'solidity-utils/contracts/utils/ChainHelpers.sol';

import {GovernanceOwners} from '../scripts/GovernanceOwners.sol';

contract GovernanceOwnersTest is Test {
  function test_get_returnsOwnerAndGuardian() public view {
    uint256[19] memory chainIds = [
      ChainIds.MAINNET,
      ChainIds.AVALANCHE,
      ChainIds.POLYGON,
      ChainIds.OPTIMISM,
      ChainIds.ARBITRUM,
      ChainIds.BASE,
      ChainIds.BNB,
      ChainIds.PLASMA,
      ChainIds.MONAD,
      ChainIds.CELO,
      ChainIds.GNOSIS,
      ChainIds.INK,
      ChainIds.LINEA,
      ChainIds.MANTLE,
      ChainIds.MEGAETH,
      ChainIds.SCROLL,
      ChainIds.SONIC,
      ChainIds.XLAYER,
      ChainIds.ZKSYNC
    ];
    for (uint256 i = 0; i < chainIds.length; i++) {
      (address owner, address guardian) = this.get(chainIds[i]);
      assertNotEq(owner, address(0), 'owner unset');
      assertNotEq(guardian, address(0), 'guardian unset');
      assertNotEq(owner, guardian, 'owner and guardian must differ');
    }
  }

  function test_get_revertsOnUnsupportedChain() public {
    vm.expectRevert(bytes('unsupported chain'));
    this.get(ChainIds.ANVIL);
  }

  function get(uint256 chainId) external pure returns (address, address) {
    return GovernanceOwners.get(chainId);
  }
}
