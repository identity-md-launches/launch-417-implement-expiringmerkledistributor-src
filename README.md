# ExpiringMerkleDistributor

A single Solidity contract that pays out a fixed list of ERC-20 allocations, committed to by a
Merkle root, until an expiry timestamp. After expiry, anyone can sweep whatever is left to a fixed
address.

> **Status: not deployed, not audited. Do not use with real funds as-is.**
>
> - The contract has never been deployed to any network, and the repository has no deploy script.
> - Nobody outside this repository has reviewed it. The only checks are the Foundry test suite in
>   `test/` and the review notes in [`docs/security.md`](docs/security.md).
> - It is not safe for every token. Fee-on-transfer, rebasing and blocklisting tokens, and
>   tokens that revert on zero-value transfers, can leave claims or sweeps stuck. See
>   [Known limitations](#known-limitations).
> - There is no admin. Once deployed, the root, expiry, token and sweep recipient can never be
>   changed, and no tokens can be pulled out before expiry. If you get any of them wrong, you have
>   to deploy a new contract.
> - Nothing is mocked in `src/`. The mock tokens in the test file exist only in the tests.

## What is in the repository

| Path | What it is |
| --- | --- |
| `src/ExpiringMerkleDistributor.sol` | The contract. It has no imports: the Merkle proof check and the ERC-20 transfer helper are written inline. |
| `test/ExpiringMerkleDistributor.t.sol` | 63 Foundry tests, including fuzz tests. forge-std is not installed, so the test file declares its own cheatcode interface, assertions and mock tokens. |
| `docs/reference.md` | The full reference: every function, event and error, and exactly when each one reverts. |
| `docs/merkle-tree.md` | How to build the tree and proofs off-chain. |
| `docs/security.md` | Review notes, the trust model, and known limitations. |

There is no `foundry.toml`, `remappings.txt` or `lib/`. Foundry's defaults (`src/`, `test/`,
`out/`) are enough to build it.

## Build and test

You need [Foundry](https://getfoundry.sh). These commands were run with forge 1.8.3:

```sh
curl -L https://foundry.paradigm.xyz | bash && foundryup   # skip if forge is installed
git clone <this-repo> && cd <this-repo>
forge build
forge test
```

`forge test` should print `63 tests passed, 0 failed`. The pragma is `^0.8.20`. With no
`foundry.toml`, forge auto-selects a compiler; it picked solc 0.8.37 here. The first build
downloads that compiler, so it needs network access. After that, builds work offline.

Other useful commands:

```sh
forge test -vvv --match-test test_claim_   # only the claim tests, with traces
forge build --sizes                        # runtime size is about 3.2 KB
```

`out/` and `cache/` are not in a `.gitignore` in this repository. In a fresh clone they show up as
untracked after a build.

## How it works

1. **Off-chain:** build a tree of `(uint256 index, address account, uint256 amount)` rows with
   OpenZeppelin `StandardMerkleTree`, using types `["uint256", "address", "uint256"]`. Every row
   must have a unique `index`. See [`docs/merkle-tree.md`](docs/merkle-tree.md).
2. **Deploy** `ExpiringMerkleDistributor(token, merkleRoot, expiry, sweepTo)`. The constructor
   does not pull tokens in.
3. **Fund it** by transferring the tokens to the contract address with a plain ERC-20 `transfer`.
   The contract does not check that it holds enough. If it is underfunded, claims are paid first
   come, first served, and later claims revert (see below).
4. **Claims:** until `block.timestamp <= expiry`, anyone can call
   `claim(index, account, amount, proof)`. The tokens always go to `account`, never to the
   caller. Each index can be claimed once.
5. **After expiry** (`block.timestamp > expiry`), claims stop and anyone can call `sweep()`. It
   sends the contract's entire token balance to `sweepTo`. You can call it again later to sweep
   tokens that arrive afterwards.

Claiming and sweeping never overlap. At `block.timestamp == expiry` claims still work and
`sweep()` reverts.

### Example (Foundry `cast`)

These are illustrative only; nothing has been deployed. `$DIST` is the address of a distributor
you deployed yourself.

```sh
# Read state
cast call $DIST "isClaimed(uint256)(bool)" 0 --rpc-url $RPC
cast call $DIST "expiry()(uint256)" --rpc-url $RPC

# Claim index 0 for its account (any key can send this; tokens go to the account in the leaf)
cast send $DIST "claim(uint256,address,uint256,bytes32[])" \
  0 0x0000000000000000000000000000000000000A11 1000000000000000000 \
  "[0xf860fba692b8f7472cb8a8ab90a36fbdefac432d5d33be1e4ba98a9b14443ca7,0x58efafe6840b8149454a5ed173201a0c51689f60c4f2d96b0068308dec3f478c]" \
  --rpc-url $RPC --private-key $KEY

# After expiry: sweep the remainder to sweepTo
cast send $DIST "sweep()" --rpc-url $RPC --private-key $KEY
```

The proof above is the real proof for leaf 0 of the tree used in the tests (root
`0x74b7…e85f`). [`docs/merkle-tree.md`](docs/merkle-tree.md) shows how it was generated.

## Entry points

Full detail is in [`docs/reference.md`](docs/reference.md). Summary:

| Function | Who may call | Reverts when |
| --- | --- | --- |
| `constructor(address token_, bytes32 merkleRoot_, uint256 expiry_, address sweepTo_)` | Deployer | `ZeroAddress()` if `token_` or `sweepTo_` is `address(0)`; `InvalidExpiry()` if `expiry_ <= block.timestamp`. |
| `claim(uint256 index, address account, uint256 amount, bytes32[] proof)` | Anyone. Tokens go to `account`. | Checked in this order: `ClaimExpired()` if `block.timestamp > expiry`; `AlreadyClaimed()` if `index` was already claimed; `InvalidProof()` if the leaf and proof don't hash to `merkleRoot`; `TokenTransferFailed()` if the token has no code, the transfer reverts (for example, not enough balance) or it returns `false`. A plain revert with no error data if the token returns 1 to 31 bytes. |
| `sweep()` | Anyone. Tokens go to `sweepTo`. | `NotExpired()` if `block.timestamp <= expiry`; `TokenTransferFailed()` if the transfer fails or returns `false`. A plain revert if `token` has no code, because `balanceOf` is called before the transfer helper. |
| `isClaimed(uint256 index)` | Anyone (view) | Never. |
| `token()`, `merkleRoot()`, `expiry()`, `sweepTo()` | Anyone (view) | Never. These are immutable getters. |

Events: `Claimed(uint256 indexed index, address indexed account, uint256 amount)` and
`Swept(uint256 amount)`.

## Where the code differs from the original brief

The contract matches the brief it was built from, with these additions and details a reader
should know about:

- **Error types.** The brief only said "reverts". The code uses custom errors: `ZeroAddress`,
  `InvalidExpiry`, `ClaimExpired`, `AlreadyClaimed`, `InvalidProof`, `NotExpired` and
  `TokenTransferFailed`.
- **Codeless token check.** The transfer helper also rejects a `token` address that has no code.
  The constructor does **not** check this, so a distributor pointed at an EOA or a wrong address
  deploys fine, and then every claim reverts with `TokenTransferFailed`.
- **Zero-amount leaves.** These are claimable and still mark the index as claimed. They still
  call `transfer(account, 0)`.
- **Empty sweeps.** `sweep()` with a zero balance does not revert. It emits `Swept(0)` and calls
  `transfer(sweepTo, 0)`.
- **Unchecked accounts.** Nothing checks that `account` is nonzero. A leaf for `address(0)` pays
  `address(0)` if the token allows that.
- **Event order.** `Claimed` and `Swept` are emitted before the token transfer. If the transfer
  fails, the whole call reverts and the event is not kept.
- **Constructor argument names** have a trailing underscore (`token_`, …). The ABI is the same.

## Known limitations

See [`docs/security.md`](docs/security.md) for the reasoning. In short:

- **No funding check or accounting.** The contract never compares the sum of the tree to its
  balance.
- **Fee-on-transfer and rebasing tokens.** If less arrives than the tree expects, the last
  claimants cannot be paid.
- **Tokens that revert on zero-value transfers.** Zero-amount leaves can never be claimed, and
  `sweep()` reverts when the balance is zero. That is harmless in itself, but it is not the
  "`Swept(0)`" behaviour the tests show for standard tokens.
- **Blocklisting tokens (for example USDC or USDT).** If `sweepTo` is blocklisted, every sweep
  reverts and the leftover tokens are stuck forever. If a claimant is blocklisted, their
  allocation cannot be claimed and goes to `sweepTo` after expiry.
- **Mistaken deposits.** Tokens sent to the contract, including other ERC-20s and ETH, cannot be
  recovered before expiry. After expiry only `token` can be swept. Other tokens are stuck, and the
  contract cannot receive ETH at all.
- **Duplicate indices.** The contract relies on every tree row having a unique `index`. Two rows
  with the same index means only one of them can ever be claimed.
