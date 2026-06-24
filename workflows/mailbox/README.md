# MailboxCRE

Generic CRE **receiver** for the automation workflows. CRE can only `writeReport`
to a contract implementing `IReceiver.onReport`; the existing Aave robots only
expose `performUpkeep`. `MailboxCRE` is the adapter: on `onReport` it ABI-decodes
the report into `(address target, bytes calldata)` and forwards the call.

- **Source:** [`src/MailboxCRE.sol`](./src/MailboxCRE.sol) (interface: [`../shared/src/IReceiver.sol`](../shared/src/IReceiver.sol))
- **Deploy scripts:** [`scripts/MailboxCRE.s.sol`](./scripts/MailboxCRE.s.sol) - one `Deploy<Chain>` per network.
- **Permissionless by design:** no caller/forwarder check. The target robots are
  themselves permissionless (anyone may call `performUpkeep`), so guarding the
  Mailbox would add nothing. One generic Mailbox per chain serves every robot.

## Deployed addresses

These are the `mailboxAddress` values wired into each `workflows/automation/config.<chain>-agents.json`.

| Chain | CRE chain selector | MailboxCRE |
|-------|--------------------|-----------|
| Ethereum | `ethereum-mainnet` | `0x14fa87C3B5F1b95444D1b4Ed9A8fC8516D5d23bF` |
| Polygon | `polygon-mainnet` | `0x0FC9eB644dF453B53C7d9A6892c878f14382ddc3` |
| Optimism | `ethereum-mainnet-optimism-1` | `0x0875673647Df7ab4E38cb56a6812632ED48D71A0` |
| Arbitrum | `ethereum-mainnet-arbitrum-1` | `0x76132cf411aAd48fB3BDadD399cA79F6e0Af0446` |
| Base | `ethereum-mainnet-base-1` | `0x3Dd830C736f4160508BF3042CDB9768a16674248` |
| BNB | `binance_smart_chain-mainnet` | `0x3bb6Af80bA07EB16FA20EF12492199c0B8FC85E7` |
| Avalanche | `avalanche-mainnet` | `0xd44fdbf583e67adb84e530ae5cc784ad5315f022` |

## Deploying to a new chain

The deploy script carries `Deploy<Chain>` contracts for many more networks
(Gnosis, Ink, Linea, Sonic, Scroll, zkSync, Celo, Mantle, ...). To deploy:

```bash
# foundry submodules must be installed first (openzeppelin, forge-std):
forge install

# deploy + verify (uses foundry.toml [rpc_endpoints] + [etherscan])
forge script workflows/mailbox/scripts/MailboxCRE.s.sol:DeployBase \
  --rpc-url base --account <ledger-or-keystore> --broadcast --verify
```

After deploying, set the printed address as `mailboxAddress` in that chain's
`workflows/automation/config.<chain>-agents.json`.
