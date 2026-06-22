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
| MockERC20 (mUSD) | [`0x89e421920daF3D723Ab0B797B13b12D71e1CaF99`](https://explorer.teiza-devnet.gateway.fm/address/0x89e421920daF3D723Ab0B797B13b12D71e1CaF99) | Shared test collateral (`mint` is public — **test only**) |
| MultiOutcomeMarket | [`0x575532C577F89e3b3d5d0bBABe6947D4d91570D6`](https://explorer.teiza-devnet.gateway.fm/address/0x575532C577F89e3b3d5d0bBABe6947D4d91570D6) | 2 outcome slots, 2% fee; resolver `0x3445…ef75` |
| MarketFactory | [`0x0DC33490e6B9c3D3FeD00D964E895cd402D74899`](https://explorer.teiza-devnet.gateway.fm/address/0x0DC33490e6B9c3D3FeD00D964E895cd402D74899) | Deploys binary `PredictionMarket`s |

All three contracts are source-verified on the explorer. These are **devnet/testing** deployments — not production.

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
