// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IReceiver, IERC165} from 'aave-cre/IReceiver.sol';
import {Address} from 'openzeppelin-contracts/contracts/utils/Address.sol';

/// @title MailboxCRE
/// @notice Receiver contract that decodes and forwards CRE automation reports to their target contracts.
/// @dev No caller or forwarder checks are performed, as the target automation contracts (robots) are permissionless.
contract MailboxCRE is IReceiver {
  using Address for address;

  /// @inheritdoc IReceiver
  /// @dev The metadata parameter is ignored. The report must ABI-encode a target address and calldata.
  function onReport(bytes calldata, bytes calldata report) external {
    (address target, bytes memory encodedCalldata) = abi.decode(report, (address, bytes));
    target.functionCall(encodedCalldata);
  }

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
    return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
  }
}
