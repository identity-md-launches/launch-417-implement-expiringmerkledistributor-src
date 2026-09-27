# Contract reference: `ExpiringMerkleDistributor`

Source: `src/ExpiringMerkleDistributor.sol` (pragma `^0.8.20`, no imports).

The contract has no owner, no roles, no pause switch and no upgrade path. Every state-changing
function can be called by anyone. The only state that ever changes is the claimed bitmap and the
contract's token balance.

## Storage

| Name | Type | Visibility | Notes |
| --- | --- | --- | --- |
| `token` | `address` | public immutable | The ERC-20 being distributed. |
| `merkleRoot` | `bytes32` | public immutable | Root of the allocation tree. |
| `expiry` | `uint256` | public immutable | The last timestamp at which a claim works (inclusive). |
| `sweepTo` | `address` | public immutable | The only address that ever receives swept tokens. |
| `claimedBitMap` | `mapping(uint256 => uint256)` | private | Bit `index % 256` of word `index / 256`. Read it with `isClaimed`. |

## Constructor

```solidity
constructor(address token_, bytes32 merkleRoot_, uint256 expiry_, address sweepTo_)
```

- **Caller:** the deployer. It takes no ETH (not payable) and pulls no tokens in.
- **Reverts:**
  - `ZeroAddress()` if `token_ == address(0)` or `sweepTo_ == address(0)`. `token_` is checked
    first, but both give the same error.
  - `InvalidExpiry()` if `expiry_ <= block.timestamp`. `expiry_` must be at least
    `block.timestamp + 1`.
- **Not checked:**
  - Whether `token_` has code or is an ERC-20.
  - Whether `merkleRoot_` is nonzero. A zero root deploys, but nothing can ever be claimed
    against it.
  - How far in the future `expiry_` is.

## `claim`

```solidity
function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external
```

This pays `amount` of `token` to `account` if `(index, account, amount)` is a leaf of
`merkleRoot` and `index` has not been claimed.

- **Caller:** anyone. `msg.sender` is never used, and the tokens always go to `account`. That
  means a third party (a relayer, a bot or a front-runner) can claim on someone's behalf. They
  gain nothing from it, and the account still gets exactly its allocation.
- **Time window:** it works while `block.timestamp <= expiry`, including at exactly `expiry`.
- **Leaf:** `keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))`. This is
  OpenZeppelin `StandardMerkleTree`'s double hash.
- **Proof:** the leaf is hashed with each element of `proof` in turn. The smaller of the two
  values goes first (`a < b ? keccak256(a‖b) : keccak256(b‖a)`). The result must equal
  `merkleRoot`. An empty proof is valid only for a one-leaf tree, where the root is the leaf.
- **Checks, in this order:**
  1. `ClaimExpired()` if `block.timestamp > expiry`. Any input gets this error after expiry.
  2. `AlreadyClaimed()` if `isClaimed(index)`. Any proof gets this error once the index is
     claimed.
  3. `InvalidProof()` if the computed root is not `merkleRoot`. That covers a wrong
     index, account or amount, and a truncated, extended, reordered or altered proof.
  4. The index is marked claimed and `Claimed(index, account, amount)` is emitted.
  5. `token.transfer(account, amount)` is called. `TokenTransferFailed()` if:
     - `token` has no code
     - the call reverts (for example, the contract does not hold enough)
     - it returns data that decodes to `false`

     If it returns 1 to 31 bytes, the call reverts with **no** error data, because
     `abi.decode` fails.

  If step 5 fails, the whole call reverts, including the bitmap update and the event. The same
  claim can succeed later, for example after the contract is topped up.
- **Reentrancy:** the bit is set before the external call, so if the token re-enters `claim` for
  the same index, that inner call gets `AlreadyClaimed()`. Re-entering for a different, valid
  index succeeds and is accounted for correctly. The tests cover both cases.
- **Zero amounts:** a leaf with `amount == 0` can be claimed once. It still calls
  `transfer(account, 0)`.

## `sweep`

```solidity
function sweep() external
```

This sends the contract's whole `token` balance to `sweepTo`.

- **Caller:** anyone. The caller gets nothing.
- **Time window:** only while `block.timestamp > expiry`. It reverts at exactly `expiry`.
- **Repeatable:** yes. Each call sends whatever the balance is at that moment. With a zero
  balance and a standard token, it emits `Swept(0)` and does not revert.
- **Reverts:**
  - `NotExpired()` if `block.timestamp <= expiry`. `sweepTo` itself gets the same error.
  - `TokenTransferFailed()` if the transfer reverts or returns `false`. For example, `sweepTo`
    is blocklisted, or the token rejects zero-value transfers and the balance is 0.
  - A plain revert (no custom error) if `token` has no code. `IERC20(token).balanceOf` is a
    high-level call, and it fails before the transfer helper runs.
- **Does not change** the claimed bitmap.
- **Emits** `Swept(amount)` before the transfer. If the transfer fails, the event is rolled back
  with the rest of the call.

## `isClaimed`

```solidity
function isClaimed(uint256 index) public view returns (bool)
```

- **Caller:** anyone. It never reverts.
- Returns `true` only if `claim` succeeded for `index`. Indices that aren't in the tree return
  `false`. Any `uint256` works, including `type(uint256).max`.

## Events

| Event | Emitted by | Notes |
| --- | --- | --- |
| `Claimed(uint256 indexed index, address indexed account, uint256 amount)` | `claim` | `account` is the recipient, not `msg.sender`. |
| `Swept(uint256 amount)` | `sweep` | `amount` is the balance at the time of the call, which may be 0. |

## Errors

| Error | Raised by | Meaning |
| --- | --- | --- |
| `ZeroAddress()` | constructor | `token_` or `sweepTo_` is zero. |
| `InvalidExpiry()` | constructor | `expiry_ <= block.timestamp`. |
| `ClaimExpired()` | `claim` | `block.timestamp > expiry`. |
| `AlreadyClaimed()` | `claim` | The index is already claimed. |
| `InvalidProof()` | `claim` | The leaf and proof don't hash to `merkleRoot`. |
| `NotExpired()` | `sweep` | `block.timestamp <= expiry`. |
| `TokenTransferFailed()` | `claim`, `sweep` | The token has no code (claim only), or the transfer reverted or returned `false`. |

## `IERC20` in the same file

The source file also declares a minimal `interface IERC20 { balanceOf; transfer; }`. It is used
only to encode calls. Importing the file brings this `IERC20` into scope. It is not the
OpenZeppelin interface, so watch for name clashes.
