## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Deployments

### TEIZA devnet (chain id `36854461`)

- RPC: `https://rpc.teiza-devnet.gateway.fm`
- Explorer (Blockscout): https://explorer.teiza-devnet.gateway.fm

Latest deploy (blocks 952106–952107), deployer & Vault admin `0xa480087F9083A9427b8723f177a16761a5aF9fC4`:

| Contract | Address | Notes |
| --- | --- | --- |
| MockERC20 (mUSDT) | [`0x81A737852aC8dEBA2312BF336f71cE5af6cEe4e8`](https://explorer.teiza-devnet.gateway.fm/address/0x81A737852aC8dEBA2312BF336f71cE5af6cEe4e8) | **Current** standard collateral (`Mock USDT`); `mint` is public — **test only** |
| MarketFactory | [`0xf5A69Ff33C11554C8bD8cCc708FA3ECcf93832e5`](https://explorer.teiza-devnet.gateway.fm/address/0xf5A69Ff33C11554C8bD8cCc708FA3ECcf93832e5) | **Current** factory; deploys binary `PredictionMarket`s (`createMarket` now takes a `feeVault` argument) |
| Vault | [`0x0e3128ED498cBC04FDD278d0EfC396E3Ea555ac6`](https://explorer.teiza-devnet.gateway.fm/address/0x0e3128ED498cBC04FDD278d0EfC396E3Ea555ac6) | ERC20 payout vault holding mUSDT; admin/owner `0xa480…9fC4`. Open deposits, owner-only single & batch distribution |

All three are source-verified on the explorer. These are **devnet/testing** deployments — not production.

<sub>Supersedes all earlier deploys, including MockERC20 `0x4921…dC07`, MarketFactory `0x173b…0ae3`, and MultiOutcomeMarket `0x5755…70D6` (not redeployed this round — deploy it separately if needed).</sub>

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

Deploy the core stack (mUSDT + MarketFactory + Vault, sharing one mUSDT, deployer as Vault admin)
with a keystore account:

```shell
$ forge script script/DeployCore.s.sol:DeployCore \
    --rpc-url https://rpc.teiza-devnet.gateway.fm \
    --account <keystore-name> --sender <deployer-address> \
    --broadcast
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
