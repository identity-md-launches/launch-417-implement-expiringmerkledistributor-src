// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Minimal ERC-20 interface; transfers are called through the optional-return helper below.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title ExpiringMerkleDistributor
/// @notice Distributes a funded ERC-20 allocation until expiry, then sends remaining tokens to sweepTo.
/// @dev Fund this contract separately. Build the tree with unique indices and StandardMerkleTree
///      types ["uint256", "address", "uint256"]. Leaves are double-hashed ABI encodings and nodes
///      hash sorted pairs. Each index can be claimed once, including allocations of zero tokens.
contract ExpiringMerkleDistributor {
    address public immutable token;
    bytes32 public immutable merkleRoot;
    uint256 public immutable expiry;
    address public immutable sweepTo;

    // Word index = allocation index / 256; bit index = allocation index % 256.
    mapping(uint256 => uint256) private claimedBitMap;

    error ZeroAddress();
    error InvalidExpiry();
    error ClaimExpired();
    error AlreadyClaimed();
    error InvalidProof();
    error NotExpired();
    error TokenTransferFailed();

    event Claimed(uint256 indexed index, address indexed account, uint256 amount);
    event Swept(uint256 amount);

    /// @param token_ ERC-20 token to distribute; must be nonzero.
    /// @param merkleRoot_ Root committing to the claim allocations.
    /// @param expiry_ Last timestamp at which claims are allowed; must be in the future.
    /// @param sweepTo_ Nonzero recipient of all post-expiry sweeps.
    constructor(address token_, bytes32 merkleRoot_, uint256 expiry_, address sweepTo_) {
        if (token_ == address(0) || sweepTo_ == address(0)) revert ZeroAddress();
        if (expiry_ <= block.timestamp) revert InvalidExpiry();

        token = token_;
        merkleRoot = merkleRoot_;
        expiry = expiry_;
        sweepTo = sweepTo_;
    }

    /// @notice Whether the allocation at index has already been successfully claimed.
    function isClaimed(uint256 index) public view returns (bool) {
        uint256 mask = uint256(1) << (index % 256);
        return (claimedBitMap[index / 256] & mask) != 0;
    }

    /// @notice Anyone may submit a claim, but tokens always go to the account in the leaf.
    /// @dev Claims are valid through expiry (inclusive). State is updated before transferring
    ///      tokens to prevent reentrant claims for the same index; transfer failure rolls it back.
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        if (block.timestamp > expiry) revert ClaimExpired();
        if (isClaimed(index)) revert AlreadyClaimed();

        // Double hashing separates the leaf encoding from the 64-byte internal node encoding.
        bytes32 node = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            node = node < sibling ? keccak256(bytes.concat(node, sibling)) : keccak256(bytes.concat(sibling, node));
        }
        if (node != merkleRoot) revert InvalidProof();

        claimedBitMap[index / 256] |= uint256(1) << (index % 256);
        emit Claimed(index, account, amount);
        _safeTransfer(account, amount);
    }

    /// @notice Anyone may send the entire current token balance to sweepTo after expiry.
    /// @dev Strictly after expiry, so sweeping and claiming never overlap. Repeatable for late deposits.
    function sweep() external {
        if (block.timestamp <= expiry) revert NotExpired();

        uint256 amount = IERC20(token).balanceOf(address(this));
        emit Swept(amount);
        _safeTransfer(sweepTo, amount);
    }

    /// @dev Accepts successful ERC-20 transfers returning either true or no data.
    ///      Rejects addresses without code, failed calls, false returns and malformed return data.
    function _safeTransfer(address to, uint256 amount) private {
        if (token.code.length == 0) revert TokenTransferFailed();
        (bool success, bytes memory result) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!success || (result.length != 0 && !abi.decode(result, (bool)))) revert TokenTransferFailed();
    }
}
