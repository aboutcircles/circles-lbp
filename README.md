## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Group Algorithm

1. Deploy Safe.

2. Deploy UpgradeableRenounceableProxy with LBPMintPolicy as an implementation.

2.1. Get txHash to sign

```Solidity
uint256 nonce = safe.nonce();
bytes32 txHash = safe.getTransactionHash(
    address(0x777f78921890Df5Db755e77CbA84CBAdA5DB56D2), // to
    0, // value
    data, // 0xca4e46bb
    Enum.Operation.DelegateCall, // 1
    0, // safeTxGas
    0, // baseGas
    0, // gasPrice
    address(0), // gasToken
    address(0), // refundReceiver
    nonce // safe nonce
);
```
2.2. Sign or approve txHash by safe owners and compile signatures.

```Solidity
uint256 threshold = safe.getThreshold();
address[] memory owners = safe.getOwners();
bytes memory signatures;
for (uint256 i; i < threshold; i++) {
    // use owner to send tx
    vm.prank(owners[i]);
    safe.approveHash(txHash);
    // craft signatures
    //                                                                      r               s           v
    bytes memory approvedHashSignature = abi.encodePacked(uint256(uint160(owners[i])), bytes32(0), bytes1(0x01));
    // need to sort owners first
    signatures = bytes.concat(signatures, approvedHashSignature);
}
```
2.3. Execute safe tx
```Solidity
bool success = safe.execTransaction(
    address(0x777f78921890Df5Db755e77CbA84CBAdA5DB56D2), // to
    0, // value
    data, // 0xca4e46bb
    Enum.Operation.DelegateCall, // 1
    0, // safeTxGas
    0, // baseGas
    0, // gasPrice
    address(0), // gasToken
    payable(address(0)), // refundReceiver
    signatures // signatures (65 bytes/owner * threshold)
);
```

3. Approve deployed proxy (find address in event ProxyCreation from previous step) in TrustModule by Safe. It is Enum.Operation.Call, so can be done via Safe UI -> New transaction -> Transaction Builder -> Enter Address 0x56652E53649F20C6a360Ea5F25379F9987cECE82 pick `approveMintPolicy` and paste proxy address.

4. Enable Module by Safe - TrustModule. It is Enum.Operation.Call. Can be done via Safe UI, but the call from Safe to itself, so: Transaction Builder -> Enter Address `Safe Address` pick `enableModule` and paste 0x56652E53649F20C6a360Ea5F25379F9987cECE82.

5. Register Group in Hub with proxy as a mint policy. It is Enum.Operation.Call, can be done via Safe UI.

## User Algorithm

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
