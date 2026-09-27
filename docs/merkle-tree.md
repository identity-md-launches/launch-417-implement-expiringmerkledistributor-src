# Building the Merkle tree

The repository has no off-chain tooling. Neither the tree generator nor a proof server is
included. Build the tree with OpenZeppelin's
[`@openzeppelin/merkle-tree`](https://github.com/OpenZeppelin/merkle-tree) (`StandardMerkleTree`).
This is an external dependency and is not part of the repository.

## Leaf format

Each row is `[index, account, amount]` with types `["uint256", "address", "uint256"]`. The
contract recomputes the leaf as:

```solidity
keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))
```

Internal nodes are `keccak256` of the two children's 64 bytes, with the smaller child first.
Because the leaf is double-hashed, an internal node cannot be passed off as a leaf. The test
`test_claim_innerNodeCannotPassAsLeaf` checks this.

Rules for the input:

- `index` must be unique per row. The contract tracks claims by index only.
- `index` does not have to be dense or start at 0. Sparse indices work, but each block of 256
  indices uses its own storage word.
- `amount` is in the token's smallest unit (wei for an 18-decimal token).

## Example

This script reproduces the tree used by the test suite. It prints the root and the proof hard-coded
in `test/ExpiringMerkleDistributor.t.sol` (`OZ_ROOT` and `_ozProof(0)`). It was checked with
`@openzeppelin/merkle-tree@1` on Node:

```sh
npm i @openzeppelin/merkle-tree@1
```

```js
// gen.mjs — run with: node gen.mjs
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

const values = [
  ["0",   "0x0000000000000000000000000000000000000A11", "1000000000000000000"],
  ["1",   "0x0000000000000000000000000000000000000B0B", "2500000000000000000"],
  ["2",   "0x0000000000000000000000000000000000000C0C", "0"],
  ["255", "0x0000000000000000000000000000000000000D0D", "7"],
  ["256", "0x0000000000000000000000000000000000000E0E", "300000000000000000000"],
  [(2n ** 256n - 1n).toString(), "0x0000000000000000000000000000000000000F0F", (2n ** 256n - 1n).toString()],
];

const tree = StandardMerkleTree.of(values, ["uint256", "address", "uint256"]);
console.log(tree.root);
// 0x74b7522369a8f40d0ed56e435bb3c39d8dbf2e62221fe88b62d594d84462e85f

for (const [i, v] of tree.entries()) {
  if (v[0] === "0") console.log(JSON.stringify(tree.getProof(i)));
}
// ["0xf860fba6…3ca7","0x58efafe6…478c"]
```

Pass `tree.root` to the constructor as `merkleRoot`. Give each claimant their row and
`tree.getProof(...)` so they can call `claim`. `tree.dump()` produces JSON you can store and
serve.

## Funding

Add up `amount` over all rows and transfer at least that much `token` to the deployed
contract. The contract never checks this. See [security.md](security.md).
