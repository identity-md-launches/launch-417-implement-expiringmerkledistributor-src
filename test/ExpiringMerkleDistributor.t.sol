// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ExpiringMerkleDistributor, IERC20} from "../src/ExpiringMerkleDistributor.sol";

/*//////////////////////////////////////////////////////////////////////////
                         SELF-CONTAINED TEST SCAFFOLDING
    The repository ships no forge-std, so the cheatcode interface and the
    assertion helpers are inlined here. A failing assertion reverts, which
    forge reports as a test failure.
//////////////////////////////////////////////////////////////////////////*/

interface Vm {
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
    function assume(bool condition) external pure;
    function label(address account, string calldata newLabel) external;
}

/*//////////////////////////////////////////////////////////////////////////
                                 MOCK TOKENS
//////////////////////////////////////////////////////////////////////////*/

/// @dev Well-behaved ERC-20: returns true, reverts on insufficient balance.
contract StandardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev USDT-style ERC-20: transfer returns no data at all.
contract NoBoolToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev ERC-20 that signals failure by returning false without reverting.
contract FalseReturningToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev ERC-20 whose transfer returns return data that is not a 32-byte bool.
contract MalformedReturnToken {
    mapping(address => uint256) public balanceOf;
    uint256 public returnSize;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setReturnSize(uint256 size) external {
        returnSize = size;
    }

    function transfer(address, uint256) external view {
        uint256 size = returnSize;
        assembly {
            mstore(0, 1)
            mstore(32, 1)
            return(0, size)
        }
    }
}

/// @dev ERC-20 whose transfer re-enters the distributor before doing the transfer itself.
contract ReentrantToken {
    mapping(address => uint256) public balanceOf;

    ExpiringMerkleDistributor public target;
    uint256 public reIndex;
    address public reAccount;
    uint256 public reAmount;
    bytes32[] public reProof;

    bool public reentered;
    bool public innerSucceeded;
    bytes public innerRevert;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(
        ExpiringMerkleDistributor target_,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] memory proof
    ) external {
        target = target_;
        reIndex = index;
        reAccount = account;
        reAmount = amount;
        delete reProof;
        for (uint256 i = 0; i < proof.length; ++i) {
            reProof.push(proof[i]);
        }
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (!reentered && address(target) != address(0)) {
            reentered = true;
            try target.claim(reIndex, reAccount, reAmount, reProof) {
                innerSucceeded = true;
            } catch (bytes memory reason) {
                innerRevert = reason;
            }
        }
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                                    TESTS
//////////////////////////////////////////////////////////////////////////*/

contract ExpiringMerkleDistributorTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Re-declared so expectEmit can match against them.
    event Claimed(uint256 indexed index, address indexed account, uint256 amount);
    event Swept(uint256 amount);

    /*//////////////////////////////////////////////////////////////////////
        REFERENCE VECTOR
        Generated with @openzeppelin/merkle-tree StandardMerkleTree.of(values,
        ["uint256","address","uint256"]). Using an externally generated tree
        checks the contract's leaf encoding and sorted-pair hashing against
        the real StandardMerkleTree rather than against this file's own
        tree builder.
    //////////////////////////////////////////////////////////////////////*/

    bytes32 internal constant OZ_ROOT = 0x74b7522369a8f40d0ed56e435bb3c39d8dbf2e62221fe88b62d594d84462e85f;
    uint256 internal constant N = 6;

    uint256[N] internal IDX = [uint256(0), 1, 2, 255, 256, type(uint256).max];
    address[N] internal ACCT =
        [address(0xA11), address(0xB0B), address(0xC0C), address(0xD0D), address(0xE0E), address(0xF0F)];
    uint256[N] internal AMT = [uint256(1e18), 2.5e18, 0, 7, 300e18, type(uint256).max];

    // Sum of the five finite allocations; the max-uint leaf is funded separately.
    uint256 internal constant FINITE_TOTAL = 1e18 + 2.5e18 + 0 + 7 + 300e18;

    function _ozProof(uint256 i) internal pure returns (bytes32[] memory p) {
        if (i == 0) {
            p = new bytes32[](2);
            p[0] = 0xf860fba692b8f7472cb8a8ab90a36fbdefac432d5d33be1e4ba98a9b14443ca7;
            p[1] = 0x58efafe6840b8149454a5ed173201a0c51689f60c4f2d96b0068308dec3f478c;
        } else if (i == 1) {
            p = new bytes32[](3);
            p[0] = 0x0c276e3cda4b19891e317a0c97e7d79751443c8b198346461086cb0cc8000922;
            p[1] = 0x3d14ec041927067c5d02ac4cd29485f55f3e1612a537c212f758fecd912df9a6;
            p[2] = 0xec4f737a2e6be277fe5f9072bf37955c1f99241e69b35e99e46f6a207a05da1e;
        } else if (i == 2) {
            p = new bytes32[](3);
            p[0] = 0x82d8bb3be3493a27aa3edbf8be8248a7dab9975857f1fd761a16f7e7018c9bc6;
            p[1] = 0x8b40654a557942f84fa79cb3675a24854514730bf72c9c7808a17b133477dbf4;
            p[2] = 0xec4f737a2e6be277fe5f9072bf37955c1f99241e69b35e99e46f6a207a05da1e;
        } else if (i == 3) {
            p = new bytes32[](2);
            p[0] = 0xb5533d7eacf808171a3817354c05c91051f95d05223a496f9421f605f1ab9e74;
            p[1] = 0x58efafe6840b8149454a5ed173201a0c51689f60c4f2d96b0068308dec3f478c;
        } else if (i == 4) {
            p = new bytes32[](3);
            p[0] = 0x6607dd6ecd89b847c7bcb399d8e049210de5381fdbe59d240f91787fd51afaa8;
            p[1] = 0x8b40654a557942f84fa79cb3675a24854514730bf72c9c7808a17b133477dbf4;
            p[2] = 0xec4f737a2e6be277fe5f9072bf37955c1f99241e69b35e99e46f6a207a05da1e;
        } else {
            p = new bytes32[](3);
            p[0] = 0x04851e41453364f2d4ac4616c172ce2c379ab6b3fb81fb31bdd58fe3d1394245;
            p[1] = 0x3d14ec041927067c5d02ac4cd29485f55f3e1612a537c212f758fecd912df9a6;
            p[2] = 0xec4f737a2e6be277fe5f9072bf37955c1f99241e69b35e99e46f6a207a05da1e;
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                                   FIXTURE
    //////////////////////////////////////////////////////////////////////*/

    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant EXPIRY = START + 30 days;
    address internal constant SWEEP_TO = address(0x5EE9);
    address internal constant STRANGER = address(0x5712A);

    StandardToken internal token;
    ExpiringMerkleDistributor internal dist;

    function setUp() public {
        vm.warp(START);
        token = new StandardToken();
        dist = new ExpiringMerkleDistributor(address(token), OZ_ROOT, EXPIRY, SWEEP_TO);
        token.mint(address(dist), FINITE_TOTAL);
        vm.label(address(dist), "distributor");
        vm.label(SWEEP_TO, "sweepTo");
    }

    /*//////////////////////////////////////////////////////////////////////
                              ASSERTION HELPERS
    //////////////////////////////////////////////////////////////////////*/

    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, string.concat("assertEq(uint) failed: ", what));
    }

    function assertEq(address a, address b, string memory what) internal pure {
        require(a == b, string.concat("assertEq(address) failed: ", what));
    }

    function assertEq(bytes32 a, bytes32 b, string memory what) internal pure {
        require(a == b, string.concat("assertEq(bytes32) failed: ", what));
    }

    function assertTrue(bool c, string memory what) internal pure {
        require(c, string.concat("assertTrue failed: ", what));
    }

    function assertFalse(bool c, string memory what) internal pure {
        require(!c, string.concat("assertFalse failed: ", what));
    }

    /*//////////////////////////////////////////////////////////////////////
        IN-SOLIDITY TREE BUILDER
        Sorted-pair hashing, odd trailing node promoted. The layout differs
        from StandardMerkleTree but the verifier only depends on sorted pair
        hashing, so any layout with the same leaf format verifies. Used for
        fuzzing and for deliberately mis-encoded trees.
    //////////////////////////////////////////////////////////////////////*/

    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _singleHashLeaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(index, account, amount));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    function _nextLevel(bytes32[] memory level) internal pure returns (bytes32[] memory next) {
        uint256 n = level.length;
        next = new bytes32[]((n + 1) / 2);
        for (uint256 i = 0; i < n; i += 2) {
            next[i / 2] = i + 1 < n ? _hashPair(level[i], level[i + 1]) : level[i];
        }
    }

    function _root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _nextLevel(level);
        }
        return level[0];
    }

    function _proof(bytes32[] memory leaves, uint256 pos) internal pure returns (bytes32[] memory proof) {
        // First pass: count siblings.
        uint256 count;
        {
            bytes32[] memory level = leaves;
            uint256 p = pos;
            while (level.length > 1) {
                if ((p ^ 1) < level.length) ++count;
                level = _nextLevel(level);
                p /= 2;
            }
        }
        proof = new bytes32[](count);
        bytes32[] memory lvl = leaves;
        uint256 k;
        while (lvl.length > 1) {
            if ((pos ^ 1) < lvl.length) proof[k++] = lvl[pos ^ 1];
            lvl = _nextLevel(lvl);
            pos /= 2;
        }
    }

    /// @dev Deploys a fresh distributor over a root, backed by a fresh standard token funded with `fund`.
    function _deploy(bytes32 root, uint256 fund) internal returns (ExpiringMerkleDistributor d, StandardToken t) {
        t = new StandardToken();
        d = new ExpiringMerkleDistributor(address(t), root, EXPIRY, SWEEP_TO);
        t.mint(address(d), fund);
    }

    /*//////////////////////////////////////////////////////////////////////
                             TREE BUILDER SELF-CHECK
    //////////////////////////////////////////////////////////////////////*/

    function test_treeBuilder_matchesContractVerifier() public {
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i = 0; i < 5; ++i) {
            leaves[i] = _leaf(i, address(uint160(i + 1)), i * 10);
        }
        (ExpiringMerkleDistributor d,) = _deploy(_root(leaves), 100);
        for (uint256 i = 0; i < 5; ++i) {
            d.claim(i, address(uint160(i + 1)), i * 10, _proof(leaves, i));
            assertTrue(d.isClaimed(i), "claimed via builder proof");
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////*/

    function test_constructor_setsImmutables() public view {
        assertEq(dist.token(), address(token), "token");
        assertEq(dist.merkleRoot(), OZ_ROOT, "merkleRoot");
        assertEq(dist.expiry(), EXPIRY, "expiry");
        assertEq(dist.sweepTo(), SWEEP_TO, "sweepTo");
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert(ExpiringMerkleDistributor.ZeroAddress.selector);
        new ExpiringMerkleDistributor(address(0), OZ_ROOT, EXPIRY, SWEEP_TO);
    }

    function test_constructor_revertsOnZeroSweepTo() public {
        vm.expectRevert(ExpiringMerkleDistributor.ZeroAddress.selector);
        new ExpiringMerkleDistributor(address(token), OZ_ROOT, EXPIRY, address(0));
    }

    function test_constructor_revertsWhenExpiryEqualsNow() public {
        vm.expectRevert(ExpiringMerkleDistributor.InvalidExpiry.selector);
        new ExpiringMerkleDistributor(address(token), OZ_ROOT, block.timestamp, SWEEP_TO);
    }

    function test_constructor_revertsWhenExpiryInPast() public {
        vm.expectRevert(ExpiringMerkleDistributor.InvalidExpiry.selector);
        new ExpiringMerkleDistributor(address(token), OZ_ROOT, block.timestamp - 1, SWEEP_TO);
    }

    function test_constructor_revertsWhenExpiryIsZero() public {
        vm.expectRevert(ExpiringMerkleDistributor.InvalidExpiry.selector);
        new ExpiringMerkleDistributor(address(token), OZ_ROOT, 0, SWEEP_TO);
    }

    function test_constructor_acceptsExpiryOneSecondAhead() public {
        ExpiringMerkleDistributor d =
            new ExpiringMerkleDistributor(address(token), OZ_ROOT, block.timestamp + 1, SWEEP_TO);
        assertEq(d.expiry(), block.timestamp + 1, "expiry");
    }

    function test_constructor_acceptsZeroRoot() public {
        // A zero root is a valid (if useless) commitment; nothing can be claimed against it.
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(token), bytes32(0), EXPIRY, SWEEP_TO);
        assertEq(d.merkleRoot(), bytes32(0), "root");
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        d.claim(0, address(0xA11), 1, new bytes32[](0));
    }

    function testFuzz_constructor_expiryBoundary(uint256 expiry) public {
        if (expiry <= block.timestamp) {
            vm.expectRevert(ExpiringMerkleDistributor.InvalidExpiry.selector);
            new ExpiringMerkleDistributor(address(token), OZ_ROOT, expiry, SWEEP_TO);
        } else {
            ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(token), OZ_ROOT, expiry, SWEEP_TO);
            assertEq(d.expiry(), expiry, "expiry");
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                              CLAIM: HAPPY PATHS
    //////////////////////////////////////////////////////////////////////*/

    function test_claim_everyFiniteLeafAgainstOZTree() public {
        for (uint256 i = 0; i < N - 1; ++i) {
            assertFalse(dist.isClaimed(IDX[i]), "not claimed before");
            uint256 before = token.balanceOf(ACCT[i]);

            vm.expectEmit(true, true, true, true, address(dist));
            emit Claimed(IDX[i], ACCT[i], AMT[i]);
            dist.claim(IDX[i], ACCT[i], AMT[i], _ozProof(i));

            assertTrue(dist.isClaimed(IDX[i]), "claimed after");
            assertEq(token.balanceOf(ACCT[i]) - before, AMT[i], "account received amount");
        }
        assertEq(token.balanceOf(address(dist)), 0, "distributor drained exactly");
    }

    function test_claim_anyoneMaySubmitButTokensGoToAccount() public {
        vm.prank(STRANGER);
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));

        assertEq(token.balanceOf(ACCT[0]), AMT[0], "account got tokens");
        assertEq(token.balanceOf(STRANGER), 0, "submitter got nothing");
    }

    function test_claim_zeroAmountLeafIsClaimableOnce() public {
        assertEq(AMT[2], 0, "fixture: leaf 2 is zero");
        vm.expectEmit(true, true, true, true, address(dist));
        emit Claimed(IDX[2], ACCT[2], 0);
        dist.claim(IDX[2], ACCT[2], 0, _ozProof(2));
        assertTrue(dist.isClaimed(IDX[2]), "zero leaf marked claimed");
        assertEq(token.balanceOf(ACCT[2]), 0, "no tokens");

        vm.expectRevert(ExpiringMerkleDistributor.AlreadyClaimed.selector);
        dist.claim(IDX[2], ACCT[2], 0, _ozProof(2));
    }

    function test_claim_maxIndexAndMaxAmount() public {
        (ExpiringMerkleDistributor d, StandardToken t) = _deploy(OZ_ROOT, type(uint256).max);
        d.claim(IDX[5], ACCT[5], AMT[5], _ozProof(5));
        assertTrue(d.isClaimed(type(uint256).max), "max index claimed");
        assertEq(t.balanceOf(ACCT[5]), type(uint256).max, "max amount received");
        assertEq(t.balanceOf(address(d)), 0, "drained");
        // Neighbouring bit in the last word is untouched.
        assertFalse(d.isClaimed(type(uint256).max - 1), "neighbour bit clean");
    }

    function test_claim_atExactExpirySucceeds() public {
        vm.warp(EXPIRY);
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertTrue(dist.isClaimed(IDX[0]), "claimed at expiry");
    }

    function test_claim_singleLeafTreeWithEmptyProof() public {
        bytes32 leaf = _leaf(42, address(0xABCD), 99);
        (ExpiringMerkleDistributor d, StandardToken t) = _deploy(leaf, 99);
        d.claim(42, address(0xABCD), 99, new bytes32[](0));
        assertEq(t.balanceOf(address(0xABCD)), 99, "single leaf claim");
    }

    function test_claim_orderOfClaimsDoesNotMatter() public {
        // Claim in reverse order relative to the tree.
        dist.claim(IDX[4], ACCT[4], AMT[4], _ozProof(4));
        dist.claim(IDX[1], ACCT[1], AMT[1], _ozProof(1));
        dist.claim(IDX[3], ACCT[3], AMT[3], _ozProof(3));
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        dist.claim(IDX[2], ACCT[2], AMT[2], _ozProof(2));
        assertEq(token.balanceOf(address(dist)), 0, "drained");
    }

    /*//////////////////////////////////////////////////////////////////////
                              CLAIM: BITMAP
    //////////////////////////////////////////////////////////////////////*/

    function test_bitmap_indices255And256LiveInDifferentWords() public {
        dist.claim(IDX[3], ACCT[3], AMT[3], _ozProof(3)); // index 255, last bit of word 0
        assertTrue(dist.isClaimed(255), "255 claimed");
        assertFalse(dist.isClaimed(256), "256 untouched");
        assertFalse(dist.isClaimed(254), "254 untouched");
        assertFalse(dist.isClaimed(0), "0 untouched");

        dist.claim(IDX[4], ACCT[4], AMT[4], _ozProof(4)); // index 256, first bit of word 1
        assertTrue(dist.isClaimed(256), "256 claimed");
        assertTrue(dist.isClaimed(255), "255 still claimed");
        assertFalse(dist.isClaimed(257), "257 untouched");
        assertFalse(dist.isClaimed(511), "511 untouched");
        assertFalse(dist.isClaimed(512), "512 untouched");
    }

    function test_bitmap_isClaimedFalseForUnknownIndices() public view {
        assertFalse(dist.isClaimed(0), "0");
        assertFalse(dist.isClaimed(1), "1");
        assertFalse(dist.isClaimed(255), "255");
        assertFalse(dist.isClaimed(256), "256");
        assertFalse(dist.isClaimed(type(uint256).max), "max");
    }

    function testFuzz_bitmap_onlyTheClaimedBitIsSet(uint256 index, uint256 other) public {
        vm.assume(index != other);
        bytes32 leaf = _leaf(index, address(0xABCD), 1);
        (ExpiringMerkleDistributor d,) = _deploy(leaf, 1);

        d.claim(index, address(0xABCD), 1, new bytes32[](0));
        assertTrue(d.isClaimed(index), "index set");
        assertFalse(d.isClaimed(other), "other clear");
        // Same word, adjacent bits.
        if (index % 256 != 0) assertFalse(d.isClaimed(index - 1), "index-1 clear");
        if (index % 256 != 255) assertFalse(d.isClaimed(index + 1), "index+1 clear");
    }

    /*//////////////////////////////////////////////////////////////////////
                              CLAIM: FAILURE PATHS
    //////////////////////////////////////////////////////////////////////*/

    function test_claim_revertsOnSecondClaimOfSameIndex() public {
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        vm.expectRevert(ExpiringMerkleDistributor.AlreadyClaimed.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertEq(token.balanceOf(ACCT[0]), AMT[0], "paid exactly once");
    }

    function test_claim_revertsOnSecondClaimFromDifferentCaller() public {
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        vm.prank(STRANGER);
        vm.expectRevert(ExpiringMerkleDistributor.AlreadyClaimed.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
    }

    function test_claim_alreadyClaimedCheckedBeforeProof() public {
        // Once an index is claimed, even a garbage proof reports AlreadyClaimed, not InvalidProof.
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        vm.expectRevert(ExpiringMerkleDistributor.AlreadyClaimed.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0] + 1, new bytes32[](0));
    }

    function test_claim_revertsOneSecondAfterExpiry() public {
        vm.warp(EXPIRY + 1);
        vm.expectRevert(ExpiringMerkleDistributor.ClaimExpired.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertFalse(dist.isClaimed(IDX[0]), "not marked claimed");
    }

    function test_claim_expiryCheckedBeforeAnythingElse() public {
        vm.warp(EXPIRY + 1);
        // Garbage inputs still yield ClaimExpired, so a late claimer learns the real reason.
        vm.expectRevert(ExpiringMerkleDistributor.ClaimExpired.selector);
        dist.claim(999, address(1), 1, new bytes32[](0));
    }

    function test_claim_revertsOnWrongAmount() public {
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0] + 1, _ozProof(0));
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0] - 1, _ozProof(0));
        assertFalse(dist.isClaimed(IDX[0]), "not claimed");
    }

    function test_claim_revertsOnWrongAccount() public {
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[0], STRANGER, AMT[0], _ozProof(0));
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[0], address(0), AMT[0], _ozProof(0));
    }

    function test_claim_revertsOnWrongIndex() public {
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[0] + 1, ACCT[0], AMT[0], _ozProof(0));
        // Index of a different real leaf, with this leaf's account and amount.
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[1], ACCT[0], AMT[0], _ozProof(0));
    }

    function test_claim_revertsOnProofForAnotherLeaf() public {
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(1));
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(3));
    }

    function test_claim_revertsOnEmptyProofForMultiLeafTree() public {
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0], new bytes32[](0));
    }

    function test_claim_revertsOnTruncatedProof() public {
        bytes32[] memory full = _ozProof(1);
        bytes32[] memory short = new bytes32[](full.length - 1);
        for (uint256 i = 0; i < short.length; ++i) {
            short[i] = full[i];
        }
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[1], ACCT[1], AMT[1], short);
    }

    function test_claim_revertsOnExtendedProof() public {
        bytes32[] memory full = _ozProof(1);
        bytes32[] memory longer = new bytes32[](full.length + 1);
        for (uint256 i = 0; i < full.length; ++i) {
            longer[i] = full[i];
        }
        longer[full.length] = bytes32(0);
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[1], ACCT[1], AMT[1], longer);
    }

    function test_claim_revertsOnReorderedProof() public {
        bytes32[] memory p = _ozProof(1);
        (p[0], p[1]) = (p[1], p[0]);
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[1], ACCT[1], AMT[1], p);
    }

    function test_claim_revertsOnFlippedProofElement() public {
        for (uint256 j = 0; j < 3; ++j) {
            bytes32[] memory p = _ozProof(1);
            p[j] = p[j] ^ bytes32(uint256(1));
            vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
            dist.claim(IDX[1], ACCT[1], AMT[1], p);
        }
    }

    function testFuzz_claim_revertsOnFlippedProofElement(uint8 leafSel, uint8 elemSel, uint256 flip) public {
        vm.assume(flip != 0);
        uint256 li = uint256(leafSel) % (N - 1);
        bytes32[] memory p = _ozProof(li);
        uint256 ei = uint256(elemSel) % p.length;
        p[ei] = p[ei] ^ bytes32(flip);
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(IDX[li], ACCT[li], AMT[li], p);
    }

    /// @dev A tree built from single-hashed leaves (no StandardMerkleTree double hash) must be rejected.
    function test_claim_rejectsSingleHashedLeafTree() public {
        bytes32[] memory leaves = new bytes32[](4);
        for (uint256 i = 0; i < 4; ++i) {
            leaves[i] = _singleHashLeaf(i, address(uint160(i + 1)), 1);
        }
        (ExpiringMerkleDistributor d,) = _deploy(_root(leaves), 4);
        for (uint256 i = 0; i < 4; ++i) {
            vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
            d.claim(i, address(uint160(i + 1)), 1, _proof(leaves, i));
        }
    }

    /// @dev Second-preimage check: a tree whose "leaves" are the internal nodes of the real tree.
    ///      The internal node is keccak256 over 64 bytes; no (index, account, amount) triple can
    ///      double-hash to it, so presenting a proof against the parent level cannot succeed.
    function test_claim_innerNodeCannotPassAsLeaf() public {
        bytes32[] memory leaves = new bytes32[](4);
        for (uint256 i = 0; i < 4; ++i) {
            leaves[i] = _leaf(i, address(uint160(i + 1)), 1);
        }
        bytes32 root = _root(leaves);
        (ExpiringMerkleDistributor d,) = _deploy(root, 4);

        // Proof that would verify if the verifier accepted an inner node as the leaf.
        bytes32[] memory inner = _nextLevel(leaves); // [H(l0,l1), H(l2,l3)]
        bytes32[] memory shortProof = new bytes32[](1);
        shortProof[0] = inner[1];

        // Whatever triple the attacker submits, its double-hashed leaf is not inner[0].
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        d.claim(0, address(1), 1, shortProof);
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        d.claim(uint256(inner[0]), address(uint160(uint256(inner[0]))), uint256(inner[0]), shortProof);

        // Sanity: the honest proof for leaf 0 does verify against the same root.
        d.claim(0, address(1), 1, _proof(leaves, 0));
    }

    function test_claim_revertsWhenUnderfundedAndLeavesIndexUnclaimed() public {
        (ExpiringMerkleDistributor d, StandardToken t) = _deploy(OZ_ROOT, AMT[0] - 1);
        vm.expectRevert(ExpiringMerkleDistributor.TokenTransferFailed.selector);
        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertFalse(d.isClaimed(IDX[0]), "bit rolled back");
        assertEq(t.balanceOf(ACCT[0]), 0, "nothing paid");

        // Top up and the same claim goes through.
        t.mint(address(d), 1);
        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertTrue(d.isClaimed(IDX[0]), "claimed after top up");
    }

    function test_claim_revertsWhenTokenReturnsFalse() public {
        FalseReturningToken bad = new FalseReturningToken();
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(bad), OZ_ROOT, EXPIRY, SWEEP_TO);
        bad.mint(address(d), FINITE_TOTAL);
        vm.expectRevert(ExpiringMerkleDistributor.TokenTransferFailed.selector);
        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertFalse(d.isClaimed(IDX[0]), "bit rolled back");
    }

    function test_claim_revertsWhenTokenHasNoCode() public {
        // The constructor only checks for a nonzero address, so a codeless token deploys fine...
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(0xDEAD), OZ_ROOT, EXPIRY, SWEEP_TO);
        // ...but claims must not silently succeed against it.
        vm.expectRevert(ExpiringMerkleDistributor.TokenTransferFailed.selector);
        d.claim(IDX[2], ACCT[2], 0, _ozProof(2));
        assertFalse(d.isClaimed(IDX[2]), "bit rolled back");
    }

    function test_claim_revertsWhenTokenReturnsMalformedData() public {
        MalformedReturnToken bad = new MalformedReturnToken();
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(bad), OZ_ROOT, EXPIRY, SWEEP_TO);

        // 1 byte: too short to decode a bool.
        bad.setReturnSize(1);
        vm.expectRevert();
        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));

        // 31 bytes: still too short.
        bad.setReturnSize(31);
        vm.expectRevert();
        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));

        assertFalse(d.isClaimed(IDX[0]), "not claimed");

        // 32 bytes of 0x...01 is a valid `true`, and 64 bytes with a leading true also decode.
        bad.setReturnSize(32);
        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertTrue(d.isClaimed(IDX[0]), "claimed with well-formed true");
    }

    function test_claim_toleratesTokenReturningNoBool() public {
        NoBoolToken usdt = new NoBoolToken();
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(usdt), OZ_ROOT, EXPIRY, SWEEP_TO);
        usdt.mint(address(d), FINITE_TOTAL);

        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertEq(usdt.balanceOf(ACCT[0]), AMT[0], "paid via no-bool token");
        assertTrue(d.isClaimed(IDX[0]), "claimed");
    }

    function test_claim_noBoolTokenRevertPropagatesAsTokenTransferFailed() public {
        NoBoolToken usdt = new NoBoolToken();
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(usdt), OZ_ROOT, EXPIRY, SWEEP_TO);
        usdt.mint(address(d), AMT[0] - 1);
        vm.expectRevert(ExpiringMerkleDistributor.TokenTransferFailed.selector);
        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        assertFalse(d.isClaimed(IDX[0]), "bit rolled back");
    }

    function test_claim_reentrantTokenCannotDoubleClaim() public {
        ReentrantToken evil = new ReentrantToken();
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(evil), OZ_ROOT, EXPIRY, SWEEP_TO);
        evil.mint(address(d), FINITE_TOTAL);
        evil.arm(d, IDX[0], ACCT[0], AMT[0], _ozProof(0));

        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));

        assertTrue(evil.reentered(), "token re-entered");
        assertFalse(evil.innerSucceeded(), "inner claim must fail");
        assertEq(
            bytes32(evil.innerRevert()),
            bytes32(ExpiringMerkleDistributor.AlreadyClaimed.selector),
            "inner claim reverted with AlreadyClaimed"
        );
        assertEq(evil.balanceOf(ACCT[0]), AMT[0], "paid exactly once");
        assertEq(evil.balanceOf(address(d)), FINITE_TOTAL - AMT[0], "distributor debited once");
    }

    function test_claim_reentrantTokenMayClaimADifferentLeaf() public {
        // Reentrancy for a *different* index is legitimate; state must stay consistent.
        ReentrantToken evil = new ReentrantToken();
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(evil), OZ_ROOT, EXPIRY, SWEEP_TO);
        evil.mint(address(d), FINITE_TOTAL);
        evil.arm(d, IDX[1], ACCT[1], AMT[1], _ozProof(1));

        d.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));

        assertTrue(evil.innerSucceeded(), "inner claim for another leaf ok");
        assertTrue(d.isClaimed(IDX[0]), "outer claimed");
        assertTrue(d.isClaimed(IDX[1]), "inner claimed");
        assertEq(evil.balanceOf(ACCT[0]), AMT[0], "outer paid");
        assertEq(evil.balanceOf(ACCT[1]), AMT[1], "inner paid");
    }

    /*//////////////////////////////////////////////////////////////////////
                                CLAIM: FUZZ
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_claim_singleLeafRoundTrip(uint256 index, address account, uint256 amount) public {
        vm.assume(account != address(0));
        vm.assume(account != SWEEP_TO && account != STRANGER);
        vm.assume(account.code.length == 0);
        bytes32 leaf = _leaf(index, account, amount);
        (ExpiringMerkleDistributor d, StandardToken t) = _deploy(leaf, amount);

        vm.prank(STRANGER);
        d.claim(index, account, amount, new bytes32[](0));
        assertEq(t.balanceOf(account), amount, "paid");
        assertTrue(d.isClaimed(index), "claimed");

        vm.expectRevert(ExpiringMerkleDistributor.AlreadyClaimed.selector);
        d.claim(index, account, amount, new bytes32[](0));
    }

    function testFuzz_claim_randomTreeAllLeavesClaimOnce(uint8 rawSize, uint256 seed) public {
        uint256 size = 1 + (uint256(rawSize) % 17); // 1..17 leaves, including odd sizes
        bytes32[] memory leaves = new bytes32[](size);
        uint256 total;
        for (uint256 i = 0; i < size; ++i) {
            uint256 amt = uint256(keccak256(abi.encode(seed, i))) % 1e24;
            leaves[i] = _leaf(i, address(uint160(0x1000 + i)), amt);
            total += amt;
        }
        (ExpiringMerkleDistributor d, StandardToken t) = _deploy(_root(leaves), total);

        for (uint256 i = 0; i < size; ++i) {
            uint256 amt = uint256(keccak256(abi.encode(seed, i))) % 1e24;
            d.claim(i, address(uint160(0x1000 + i)), amt, _proof(leaves, i));
            assertEq(t.balanceOf(address(uint160(0x1000 + i))), amt, "leaf paid");
            vm.expectRevert(ExpiringMerkleDistributor.AlreadyClaimed.selector);
            d.claim(i, address(uint160(0x1000 + i)), amt, _proof(leaves, i));
        }
        assertEq(t.balanceOf(address(d)), 0, "fully distributed");
    }

    function testFuzz_claim_wrongTripleAlwaysRejected(uint256 dIndex, uint160 dAccount, uint256 dAmount) public {
        vm.assume(dIndex != 0 || dAccount != 0 || dAmount != 0);
        uint256 index = IDX[0] ^ dIndex;
        address account = address(uint160(ACCT[0]) ^ dAccount);
        uint256 amount = AMT[0] ^ dAmount;
        vm.expectRevert(ExpiringMerkleDistributor.InvalidProof.selector);
        dist.claim(index, account, amount, _ozProof(0));
    }

    function testFuzz_claim_timeWindow(uint256 t) public {
        t = START + (t % (60 days));
        vm.warp(t);
        if (t <= EXPIRY) {
            dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
            assertTrue(dist.isClaimed(IDX[0]), "claimed in window");
        } else {
            vm.expectRevert(ExpiringMerkleDistributor.ClaimExpired.selector);
            dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        }
    }

    /*//////////////////////////////////////////////////////////////////////
                                    SWEEP
    //////////////////////////////////////////////////////////////////////*/

    function test_sweep_revertsBeforeExpiry() public {
        vm.expectRevert(ExpiringMerkleDistributor.NotExpired.selector);
        dist.sweep();
        assertEq(token.balanceOf(SWEEP_TO), 0, "nothing swept");
    }

    function test_sweep_revertsAtExactExpiry() public {
        vm.warp(EXPIRY);
        vm.expectRevert(ExpiringMerkleDistributor.NotExpired.selector);
        dist.sweep();
    }

    function test_sweep_revertsBeforeExpiryEvenFromSweepTo() public {
        vm.prank(SWEEP_TO);
        vm.expectRevert(ExpiringMerkleDistributor.NotExpired.selector);
        dist.sweep();
    }

    function test_sweep_oneSecondAfterExpirySendsEverythingToSweepTo() public {
        vm.warp(EXPIRY + 1);
        vm.expectEmit(true, true, true, true, address(dist));
        emit Swept(FINITE_TOTAL);
        vm.prank(STRANGER);
        dist.sweep();

        assertEq(token.balanceOf(SWEEP_TO), FINITE_TOTAL, "sweepTo received all");
        assertEq(token.balanceOf(address(dist)), 0, "distributor empty");
        assertEq(token.balanceOf(STRANGER), 0, "caller got nothing");
    }

    function test_sweep_sendsOnlyUnclaimedRemainder() public {
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        dist.claim(IDX[4], ACCT[4], AMT[4], _ozProof(4));
        uint256 remainder = FINITE_TOTAL - AMT[0] - AMT[4];

        vm.warp(EXPIRY + 1);
        vm.expectEmit(true, true, true, true, address(dist));
        emit Swept(remainder);
        dist.sweep();

        assertEq(token.balanceOf(SWEEP_TO), remainder, "remainder swept");
        assertEq(token.balanceOf(ACCT[0]), AMT[0], "claimant 0 keeps tokens");
        assertEq(token.balanceOf(ACCT[4]), AMT[4], "claimant 4 keeps tokens");
    }

    function test_sweep_canBeRepeatedForLateDeposits() public {
        vm.warp(EXPIRY + 1);
        dist.sweep();
        assertEq(token.balanceOf(SWEEP_TO), FINITE_TOTAL, "first sweep");

        // Second sweep with nothing left: emits Swept(0), transfers nothing, does not revert.
        vm.expectEmit(true, true, true, true, address(dist));
        emit Swept(0);
        dist.sweep();
        assertEq(token.balanceOf(SWEEP_TO), FINITE_TOTAL, "unchanged");

        // Late deposit, sweep again.
        token.mint(address(dist), 1234);
        vm.expectEmit(true, true, true, true, address(dist));
        emit Swept(1234);
        dist.sweep();
        assertEq(token.balanceOf(SWEEP_TO), FINITE_TOTAL + 1234, "late deposit swept");
        assertEq(token.balanceOf(address(dist)), 0, "empty again");
    }

    function test_sweep_thenClaimStillRevertsExpired() public {
        vm.warp(EXPIRY + 1);
        dist.sweep();
        vm.expectRevert(ExpiringMerkleDistributor.ClaimExpired.selector);
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
    }

    function test_sweep_doesNotTouchClaimBitmap() public {
        dist.claim(IDX[0], ACCT[0], AMT[0], _ozProof(0));
        vm.warp(EXPIRY + 1);
        dist.sweep();
        assertTrue(dist.isClaimed(IDX[0]), "claimed bit persists");
        assertFalse(dist.isClaimed(IDX[1]), "unclaimed bit persists");
    }

    function test_sweep_toleratesTokenReturningNoBool() public {
        NoBoolToken usdt = new NoBoolToken();
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(usdt), OZ_ROOT, EXPIRY, SWEEP_TO);
        usdt.mint(address(d), 555);
        vm.warp(EXPIRY + 1);
        d.sweep();
        assertEq(usdt.balanceOf(SWEEP_TO), 555, "swept via no-bool token");
    }

    function test_sweep_revertsWhenTokenReturnsFalse() public {
        FalseReturningToken bad = new FalseReturningToken();
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(bad), OZ_ROOT, EXPIRY, SWEEP_TO);
        bad.mint(address(d), 1);
        vm.warp(EXPIRY + 1);
        vm.expectRevert(ExpiringMerkleDistributor.TokenTransferFailed.selector);
        d.sweep();
    }

    function test_sweep_revertsWhenTokenHasNoCode() public {
        ExpiringMerkleDistributor d = new ExpiringMerkleDistributor(address(0xDEAD), OZ_ROOT, EXPIRY, SWEEP_TO);
        vm.warp(EXPIRY + 1);
        // balanceOf on a codeless address reverts inside the high-level call before _safeTransfer.
        vm.expectRevert();
        d.sweep();
    }

    function testFuzz_sweep_timeWindow(uint256 t) public {
        t = START + (t % (60 days));
        vm.warp(t);
        if (t > EXPIRY) {
            dist.sweep();
            assertEq(token.balanceOf(SWEEP_TO), FINITE_TOTAL, "swept");
        } else {
            vm.expectRevert(ExpiringMerkleDistributor.NotExpired.selector);
            dist.sweep();
        }
    }

    function testFuzz_sweep_anyCallerSameOutcome(address caller, uint256 extra) public {
        vm.assume(caller != SWEEP_TO);
        extra = extra % 1e30;
        token.mint(address(dist), extra);
        vm.warp(EXPIRY + 1);
        vm.prank(caller);
        dist.sweep();
        assertEq(token.balanceOf(SWEEP_TO), FINITE_TOTAL + extra, "all to sweepTo");
        assertEq(token.balanceOf(caller), 0, "caller unpaid");
    }

    /*//////////////////////////////////////////////////////////////////////
                         CLAIM / SWEEP WINDOWS ARE DISJOINT
    //////////////////////////////////////////////////////////////////////*/

    function testFuzz_exactlyOneOfClaimOrSweepIsOpen(uint256 t) public {
        t = START + (t % (60 days));
        vm.warp(t);

        bool claimOpen;
        try dist.claim(IDX[2], ACCT[2], AMT[2], _ozProof(2)) {
            claimOpen = true;
        } catch (bytes memory reason) {
            assertEq(bytes32(reason), bytes32(ExpiringMerkleDistributor.ClaimExpired.selector), "claim reason");
        }

        bool sweepOpen;
        try dist.sweep() {
            sweepOpen = true;
        } catch (bytes memory reason) {
            assertEq(bytes32(reason), bytes32(ExpiringMerkleDistributor.NotExpired.selector), "sweep reason");
        }

        assertTrue(claimOpen != sweepOpen, "exactly one window open");
        assertTrue(claimOpen == (t <= EXPIRY), "claim window is [.., expiry]");
    }
}
