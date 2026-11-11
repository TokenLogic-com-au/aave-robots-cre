// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm} from 'forge-std/Vm.sol';
import {IPool} from 'aave-v3-origin/contracts/interfaces/IPool.sol';
import {IPoolAddressesProvider} from 'aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPriceOracleGetter} from 'aave-v3-origin/contracts/interfaces/IPriceOracleGetter.sol';
import {DataTypes} from 'aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from 'aave-v3-origin/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';

library MockPoolHelpers {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  bool public constant IS_TEST = true;
  Vm internal constant VM = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  struct Reserve {
    address asset;
    uint128 accruedToTreasury;
    uint256 decimals;
    bool active;
    uint256 normalizedIncome;
  }

  function setOracle(address pool, address provider, address oracle) internal {
    VM.mockCall(
      pool,
      abi.encodeWithSelector(IPool.ADDRESSES_PROVIDER.selector),
      abi.encode(provider)
    );
    VM.mockCall(
      provider,
      abi.encodeWithSelector(IPoolAddressesProvider.getPriceOracle.selector),
      abi.encode(oracle)
    );
  }

  function setReservesList(address pool, address[] memory reserves) internal {
    VM.mockCall(pool, abi.encodeWithSelector(IPool.getReservesList.selector), abi.encode(reserves));
  }

  function setReserve(address pool, Reserve memory reserve) internal {
    DataTypes.ReserveDataLegacy memory data;
    data.configuration.setDecimals(reserve.decimals);
    data.configuration.setActive(reserve.active);
    data.accruedToTreasury = reserve.accruedToTreasury;

    VM.mockCall(
      pool,
      abi.encodeWithSelector(IPool.getReserveData.selector, reserve.asset),
      abi.encode(data)
    );
    VM.mockCall(
      pool,
      abi.encodeWithSelector(IPool.getReserveNormalizedIncome.selector, reserve.asset),
      abi.encode(reserve.normalizedIncome)
    );
  }

  function setPrice(address oracle, address asset, uint256 price) internal {
    VM.mockCall(
      oracle,
      abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, asset),
      abi.encode(price)
    );
  }

  function setPriceReverts(address oracle, address asset) internal {
    VM.mockCallRevert(
      oracle,
      abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, asset),
      bytes('price unavailable')
    );
  }

  function expectMintToTreasury(address pool, address[] memory assets) internal {
    // `mintToTreasury` returns nothing, so the caller checks the pool has code.
    if (pool.code.length == 0) VM.etch(pool, hex'00');
    bytes memory data = abi.encodeWithSelector(IPool.mintToTreasury.selector, assets);
    VM.mockCall(pool, data, '');
    VM.expectCall(pool, data);
  }
}
