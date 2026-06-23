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

| Contract | Address | Notes |
| --- | --- | --- |
| MockERC20 (mUSDT) | [`0x4921C68f4A34C4087aED3F9AF5c7A72c56dAdC07`](https://explorer.teiza-devnet.gateway.fm/address/0x4921C68f4A34C4087aED3F9AF5c7A72c56dAdC07) | **Current** standard collateral (`Mock USDT`); `mint` is public — **test only** |
| MarketFactory | [`0x173b640805d98999FB8c238dC01E290a66A30ae3`](https://explorer.teiza-devnet.gateway.fm/address/0x173b640805d98999FB8c238dC01E290a66A30ae3) | **Current** factory; deploys binary `PredictionMarket`s |
| MultiOutcomeMarket | [`0x575532C577F89e3b3d5d0bBABe6947D4d91570D6`](https://explorer.teiza-devnet.gateway.fm/address/0x575532C577F89e3b3d5d0bBABe6947D4d91570D6) | 2 outcome slots, 2% fee; resolver `0x3445…ef75`. Bound to the **legacy** mUSD collateral `0x89e4…AF99`, not mUSDT |

All contracts are source-verified on the explorer. These are **devnet/testing** deployments — not production.

<sub>Superseded by the latest deploy (block 894459): earlier mUSD collateral `0x89e421920daF3D723Ab0B797B13b12D71e1CaF99` and MarketFactory `0x0DC33490e6B9c3D3FeD00D964E895cd402D74899`.</sub>

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

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
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
