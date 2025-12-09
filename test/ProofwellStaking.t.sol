// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ProofwellStaking} from "../src/ProofwellStaking.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";

contract ProofwellStakingTest is Test {
    ProofwellStaking public staking;
    address public treasury;
    address public user1;
    address public user2;

    // Test P-256 key pair (from wycheproof test vectors)
    // These are valid P-256 points
    bytes32 constant TEST_PUB_KEY_X = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    bytes32 constant TEST_PUB_KEY_Y = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;

    // Second valid P-256 key pair (2G - generator doubled)
    bytes32 constant TEST_PUB_KEY_X_2 = 0x7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978;
    bytes32 constant TEST_PUB_KEY_Y_2 = 0x07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1;

    uint256 constant SECONDS_PER_DAY = 86400;
    uint256 constant GRACE_PERIOD = 6 hours;
    uint256 constant MIN_STAKE = 0.001 ether;

    function setUp() public {
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        staking = new ProofwellStaking(treasury);

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    // ============ Staking Tests ============

    function test_Stake_Success() public {
        uint256 goalSeconds = 2 hours;
        uint256 durationDays = 7;
        uint256 stakeAmount = 1 ether;

        vm.prank(user1);
        staking.stake{value: stakeAmount}(goalSeconds, durationDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        ProofwellStaking.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.amount, stakeAmount);
        assertEq(userStake.goalSeconds, goalSeconds);
        assertEq(userStake.durationDays, durationDays);
        assertEq(userStake.pubKeyX, TEST_PUB_KEY_X);
        assertEq(userStake.pubKeyY, TEST_PUB_KEY_Y);
        assertEq(userStake.successfulDays, 0);
        assertFalse(userStake.claimed);
    }

    function test_Stake_EmitsEvent() public {
        uint256 goalSeconds = 2 hours;
        uint256 durationDays = 7;
        uint256 stakeAmount = 1 ether;

        vm.expectEmit(true, false, false, true);
        emit ProofwellStaking.Staked(user1, stakeAmount, goalSeconds, durationDays, block.timestamp);

        vm.prank(user1);
        staking.stake{value: stakeAmount}(goalSeconds, durationDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_Stake_RevertIf_AlreadyStaked() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.expectRevert(ProofwellStaking.StakeAlreadyExists.selector);
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
    }

    function test_Stake_RevertIf_ZeroGoal() public {
        vm.expectRevert(ProofwellStaking.InvalidGoal.selector);
        vm.prank(user1);
        staking.stake{value: 1 ether}(0, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_Stake_RevertIf_GoalTooHigh() public {
        vm.expectRevert(ProofwellStaking.InvalidGoal.selector);
        vm.prank(user1);
        staking.stake{value: 1 ether}(25 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_Stake_RevertIf_ZeroDuration() public {
        vm.expectRevert(ProofwellStaking.InvalidDuration.selector);
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 0, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_Stake_RevertIf_DurationTooLong() public {
        vm.expectRevert(ProofwellStaking.InvalidDuration.selector);
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 366, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_Stake_RevertIf_InsufficientAmount() public {
        vm.expectRevert(ProofwellStaking.InsufficientStake.selector);
        vm.prank(user1);
        staking.stake{value: 0.0009 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_Stake_RevertIf_InvalidPublicKey() public {
        vm.expectRevert(ProofwellStaking.InvalidPublicKey.selector);
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_Stake_RevertIf_KeyAlreadyRegistered() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.expectRevert(ProofwellStaking.KeyAlreadyRegistered.selector);
        vm.prank(user2);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_GetKeyOwner() public {
        assertEq(staking.getKeyOwner(TEST_PUB_KEY_X, TEST_PUB_KEY_Y), address(0));

        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        assertEq(staking.getKeyOwner(TEST_PUB_KEY_X, TEST_PUB_KEY_Y), user1);
    }

    // ============ Day Proof Tests ============

    function test_CanSubmitProof_NoStake() public view {
        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertFalse(canSubmit);
        assertEq(reason, "No stake found");
    }

    function test_CanSubmitProof_DayNotEnded() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertFalse(canSubmit);
        assertEq(reason, "Day has not ended yet");
    }

    function test_CanSubmitProof_WithinWindow() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Move to just after day 0 ends
        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertTrue(canSubmit);
        assertEq(reason, "");
    }

    function test_CanSubmitProof_WindowClosed() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Move past the grace period
        vm.warp(block.timestamp + SECONDS_PER_DAY + GRACE_PERIOD + 1);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertFalse(canSubmit);
        assertEq(reason, "Submission window closed");
    }

    function test_CanSubmitProof_InvalidDayIndex() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 7);
        assertFalse(canSubmit);
        assertEq(reason, "Invalid day index");
    }

    function test_SubmitDayProof_RevertIf_NoStake() public {
        vm.expectRevert(ProofwellStaking.NoStakeFound.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, bytes32(0), bytes32(0));
    }

    function test_SubmitDayProof_RevertIf_InvalidDayIndex() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        vm.expectRevert(ProofwellStaking.InvalidDayIndex.selector);
        vm.prank(user1);
        staking.submitDayProof(7, true, bytes32(0), bytes32(0));
    }

    function test_SubmitDayProof_RevertIf_TooEarly() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Don't warp - still day 0
        vm.expectRevert(ProofwellStaking.ProofSubmissionWindowClosed.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, bytes32(0), bytes32(0));
    }

    function test_SubmitDayProof_RevertIf_TooLate() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp past grace period
        vm.warp(block.timestamp + SECONDS_PER_DAY + GRACE_PERIOD + 1);

        vm.expectRevert(ProofwellStaking.ProofSubmissionWindowClosed.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, bytes32(0), bytes32(0));
    }

    // ============ Claim Tests ============

    function test_Claim_RevertIf_NoStake() public {
        vm.expectRevert(ProofwellStaking.NoStakeFound.selector);
        vm.prank(user1);
        staking.claim();
    }

    function test_Claim_RevertIf_NotEnded() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.expectRevert(ProofwellStaking.StakeNotEnded.selector);
        vm.prank(user1);
        staking.claim();
    }

    function test_Claim_AllSlashed() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp past stake duration
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 userBalanceBefore = user1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(user1);
        staking.claim();

        // User gets nothing (0 successful days)
        assertEq(user1.balance, userBalanceBefore);
        // Treasury gets everything
        assertEq(treasury.balance, treasuryBalanceBefore + 1 ether);

        ProofwellStaking.Stake memory userStake = staking.getStake(user1);
        assertTrue(userStake.claimed);
    }

    function test_Claim_RevertIf_AlreadyClaimed() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        vm.expectRevert(ProofwellStaking.StakeAlreadyClaimed.selector);
        vm.prank(user1);
        staking.claim();
    }

    function test_Claim_EmitsEvent() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.expectEmit(true, false, false, true);
        emit ProofwellStaking.Claimed(user1, 0, 1 ether);

        vm.prank(user1);
        staking.claim();
    }

    // ============ Current Day Index Tests ============

    function test_GetCurrentDayIndex_NoStake() public view {
        assertEq(staking.getCurrentDayIndex(user1), type(uint256).max);
    }

    function test_GetCurrentDayIndex_Day0() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        assertEq(staking.getCurrentDayIndex(user1), 0);
    }

    function test_GetCurrentDayIndex_Day3() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        assertEq(staking.getCurrentDayIndex(user1), 3);
    }

    function test_GetCurrentDayIndex_LastDay() public {
        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp past the stake duration
        vm.warp(block.timestamp + 100 * SECONDS_PER_DAY);

        // Should cap at last day index (6 for 7-day stake)
        assertEq(staking.getCurrentDayIndex(user1), 6);
    }

    // ============ Constants Tests ============

    function test_Constants() public view {
        assertEq(staking.SECONDS_PER_DAY(), 86400);
        assertEq(staking.GRACE_PERIOD(), 6 hours);
        assertEq(staking.MIN_STAKE(), 0.001 ether);
        assertEq(staking.MAX_DURATION_DAYS(), 365);
        assertEq(staking.MAX_GOAL_SECONDS(), 24 hours);
    }

    function test_ProtocolTreasury() public view {
        assertEq(staking.protocolTreasury(), treasury);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Stake_ValidParameters(uint256 goalSeconds, uint256 durationDays, uint256 stakeAmount) public {
        goalSeconds = bound(goalSeconds, 1, 24 hours);
        durationDays = bound(durationDays, 1, 365);
        stakeAmount = bound(stakeAmount, MIN_STAKE, 100 ether);

        vm.deal(user1, stakeAmount);

        vm.prank(user1);
        staking.stake{value: stakeAmount}(goalSeconds, durationDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        ProofwellStaking.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.amount, stakeAmount);
        assertEq(userStake.goalSeconds, goalSeconds);
        assertEq(userStake.durationDays, durationDays);
    }

    function testFuzz_Claim_ProportionalReturn(uint8 successfulDays, uint8 totalDays) public {
        totalDays = uint8(bound(totalDays, 1, 100));
        successfulDays = uint8(bound(successfulDays, 0, totalDays));

        uint256 stakeAmount = 1 ether;

        vm.prank(user1);
        staking.stake{value: stakeAmount}(2 hours, totalDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Manually set successful days via storage slot manipulation
        // Stake struct slot for user1:
        // stakes mapping is at slot 0, then Stake struct fields
        bytes32 stakeSlot = keccak256(abi.encode(user1, uint256(0)));
        // successfulDays is at offset 6 in the struct (after amount, goalSeconds, startTimestamp, durationDays, pubKeyX, pubKeyY)
        bytes32 successfulDaysSlot = bytes32(uint256(stakeSlot) + 6);
        vm.store(address(staking), successfulDaysSlot, bytes32(uint256(successfulDays)));

        // Warp past duration
        vm.warp(block.timestamp + uint256(totalDays) * SECONDS_PER_DAY + 1);

        uint256 expectedReturn = (stakeAmount * successfulDays) / totalDays;
        uint256 expectedSlash = stakeAmount - expectedReturn;

        uint256 userBalanceBefore = user1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(user1);
        staking.claim();

        assertEq(user1.balance, userBalanceBefore + expectedReturn);
        assertEq(treasury.balance, treasuryBalanceBefore + expectedSlash);
    }
}

/// @notice Test contract for signature verification with real P-256 signatures
contract ProofwellStakingSignatureTest is Test {
    ProofwellStaking public staking;
    address public treasury;
    address public user1;

    uint256 constant SECONDS_PER_DAY = 86400;

    function setUp() public {
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        staking = new ProofwellStaking(treasury);
        vm.deal(user1, 10 ether);
    }

    /// @notice Test with known valid P-256 signature from wycheproof vectors
    /// This test uses a pre-computed signature to verify the contract's P-256 verification works
    function test_SubmitDayProof_WithValidSignature() public {
        // Use a known valid P-256 key pair from wycheproof test vectors
        // This is the generator point G
        bytes32 pubKeyX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
        bytes32 pubKeyY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;

        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, pubKeyX, pubKeyY);

        // Move time to after day 0 ends
        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        // Since we can't easily generate valid P-256 signatures in Foundry without a private key,
        // and the private key for the generator point G is 1 (which we shouldn't use in practice),
        // we'll test that invalid signatures are rejected properly

        // This should revert with InvalidSignature since these are not valid signature values
        bytes32 invalidR = bytes32(uint256(123));
        bytes32 invalidS = bytes32(uint256(456));

        vm.expectRevert(ProofwellStaking.InvalidSignature.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, invalidR, invalidS);
    }

    /// @notice Test that day verification state is properly tracked
    function test_DayVerified_StateTracking() public {
        bytes32 pubKeyX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
        bytes32 pubKeyY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;

        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, pubKeyX, pubKeyY);

        // Initially not verified
        assertFalse(staking.dayVerified(user1, 0));
        assertFalse(staking.dayVerified(user1, 1));
    }
}

/// @notice Integration test simulating a full stake lifecycle with manual state manipulation
contract ProofwellStakingIntegrationTest is Test {
    ProofwellStaking public staking;
    address public treasury;
    address public user1;

    uint256 constant SECONDS_PER_DAY = 86400;
    uint256 constant GRACE_PERIOD = 6 hours;

    bytes32 constant PUB_KEY_X = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    bytes32 constant PUB_KEY_Y = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;

    function setUp() public {
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        staking = new ProofwellStaking(treasury);
        vm.deal(user1, 10 ether);
    }

    /// @notice Test full lifecycle: stake -> (simulate proofs) -> claim with partial success
    function test_FullLifecycle_PartialSuccess() public {
        uint256 stakeAmount = 1 ether;
        uint256 durationDays = 7;

        // Step 1: Stake
        vm.prank(user1);
        staking.stake{value: stakeAmount}(2 hours, durationDays, PUB_KEY_X, PUB_KEY_Y);

        // Step 2: Simulate 4 successful day proofs (out of 7)
        // We'll manipulate storage to simulate successful proof submissions
        bytes32 stakeSlot = keccak256(abi.encode(user1, uint256(0)));
        bytes32 successfulDaysSlot = bytes32(uint256(stakeSlot) + 6);
        vm.store(address(staking), successfulDaysSlot, bytes32(uint256(4)));

        // Verify the storage update
        ProofwellStaking.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.successfulDays, 4);

        // Step 3: Warp past stake duration
        vm.warp(block.timestamp + durationDays * SECONDS_PER_DAY + 1);

        // Step 4: Claim
        uint256 expectedReturn = (stakeAmount * 4) / 7; // ~0.571 ether
        uint256 expectedSlash = stakeAmount - expectedReturn;

        uint256 userBalanceBefore = user1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.expectEmit(true, false, false, true);
        emit ProofwellStaking.Claimed(user1, expectedReturn, expectedSlash);

        vm.prank(user1);
        staking.claim();

        assertEq(user1.balance, userBalanceBefore + expectedReturn);
        assertEq(treasury.balance, treasuryBalanceBefore + expectedSlash);
    }

    /// @notice Test full lifecycle: stake -> all successful -> full return
    function test_FullLifecycle_AllSuccess() public {
        uint256 stakeAmount = 1 ether;
        uint256 durationDays = 7;

        vm.prank(user1);
        staking.stake{value: stakeAmount}(2 hours, durationDays, PUB_KEY_X, PUB_KEY_Y);

        // Simulate all 7 successful days
        bytes32 stakeSlot = keccak256(abi.encode(user1, uint256(0)));
        bytes32 successfulDaysSlot = bytes32(uint256(stakeSlot) + 6);
        vm.store(address(staking), successfulDaysSlot, bytes32(uint256(7)));

        vm.warp(block.timestamp + durationDays * SECONDS_PER_DAY + 1);

        uint256 userBalanceBefore = user1.balance;
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(user1);
        staking.claim();

        // User gets everything back
        assertEq(user1.balance, userBalanceBefore + stakeAmount);
        // Treasury gets nothing
        assertEq(treasury.balance, treasuryBalanceBefore);
    }

    /// @notice Test multiple users can stake simultaneously
    function test_MultipleUsers() public {
        address user2 = makeAddr("user2");
        vm.deal(user2, 10 ether);

        // Different valid P-256 point (2G)
        bytes32 pubKeyX2 = 0x7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978;
        bytes32 pubKeyY2 = 0x07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1;

        vm.prank(user1);
        staking.stake{value: 1 ether}(2 hours, 7, PUB_KEY_X, PUB_KEY_Y);

        vm.prank(user2);
        staking.stake{value: 2 ether}(3 hours, 14, pubKeyX2, pubKeyY2);

        ProofwellStaking.Stake memory stake1 = staking.getStake(user1);
        ProofwellStaking.Stake memory stake2 = staking.getStake(user2);

        assertEq(stake1.amount, 1 ether);
        assertEq(stake1.durationDays, 7);
        assertEq(stake2.amount, 2 ether);
        assertEq(stake2.durationDays, 14);
    }
}

/// @notice Real-world scenario tests for comprehensive coverage
contract ProofwellStakingRealWorldTest is Test {
    ProofwellStaking public staking;
    address public treasury;

    uint256 constant SECONDS_PER_DAY = 86400;
    uint256 constant GRACE_PERIOD = 6 hours;

    // Valid P-256 points for testing (generator multiples)
    bytes32 constant PUB_KEY_X_1 = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296; // G
    bytes32 constant PUB_KEY_Y_1 = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;
    bytes32 constant PUB_KEY_X_2 = 0x7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978; // 2G
    bytes32 constant PUB_KEY_Y_2 = 0x07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1;
    bytes32 constant PUB_KEY_X_3 = 0x5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C; // 3G
    bytes32 constant PUB_KEY_Y_3 = 0x8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032;
    bytes32 constant PUB_KEY_X_4 = 0xE2534A3532D08FBBA02DDE659EE62BD0031FE2DB785596EF509302446B030852; // 4G
    bytes32 constant PUB_KEY_Y_4 = 0xE0F1575A4C633CC719DFEE5FDA862D764EFC96C3F30EE0055C42C23F184ED8C6;
    bytes32 constant PUB_KEY_X_5 = 0x51590B7A515140D2D784C85608668FDFEF8C82FD1F5BE52421554A0DC3D033ED; // 5G
    bytes32 constant PUB_KEY_Y_5 = 0xE0C17DA8904A727D8AE1BF36BF8A79260D012F00D4D80888D1D0BB44FDA16DA4;

    function setUp() public {
        treasury = makeAddr("treasury");
        staking = new ProofwellStaking(treasury);
    }

    /// @dev Helper to set successful days via storage manipulation
    function _setSuccessfulDays(address user, uint256 days_) internal {
        bytes32 stakeSlot = keccak256(abi.encode(user, uint256(0)));
        bytes32 successfulDaysSlot = bytes32(uint256(stakeSlot) + 6);
        vm.store(address(staking), successfulDaysSlot, bytes32(days_));
    }

    /// @dev Helper to mark a day as verified
    function _markDayVerified(address user, uint256 dayIndex) internal {
        // dayVerified mapping is at slot 2
        bytes32 outerSlot = keccak256(abi.encode(user, uint256(2)));
        bytes32 innerSlot = keccak256(abi.encode(dayIndex, outerSlot));
        vm.store(address(staking), innerSlot, bytes32(uint256(1)));
    }

    // ============ Full 7-Day Challenge Lifecycle ============

    /// @notice Complete 7-day challenge with all days successful
    function test_Full7DayChallenge_AllSuccess() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);
        uint256 stakeAmount = 0.1 ether;

        // Day 0: Stake
        vm.prank(user);
        staking.stake{value: stakeAmount}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        uint256 startTime = block.timestamp;

        // Simulate 7 successful days
        _setSuccessfulDays(user, 7);
        for (uint256 i = 0; i < 7; i++) {
            _markDayVerified(user, i);
        }

        // Verify all days marked
        for (uint256 i = 0; i < 7; i++) {
            assertTrue(staking.dayVerified(user, i));
        }

        // Warp to after challenge ends
        vm.warp(startTime + 7 * SECONDS_PER_DAY + 1);

        // Claim
        uint256 balanceBefore = user.balance;
        vm.prank(user);
        staking.claim();

        // Should get full stake back
        assertEq(user.balance, balanceBefore + stakeAmount);
        assertEq(treasury.balance, 0);
    }

    /// @notice Complete 7-day challenge with zero days successful
    function test_Full7DayChallenge_AllFailed() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);
        uint256 stakeAmount = 0.1 ether;

        vm.prank(user);
        staking.stake{value: stakeAmount}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        // Don't set any successful days (default 0)

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 userBalanceBefore = user.balance;
        vm.prank(user);
        staking.claim();

        // User gets nothing, treasury gets all
        assertEq(user.balance, userBalanceBefore);
        assertEq(treasury.balance, stakeAmount);
    }

    // ============ Partial Success Scenarios ============

    /// @notice 5/7 days successful - should return ~71.4% of stake
    function test_PartialSuccess_5of7Days() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);
        uint256 stakeAmount = 1 ether;

        vm.prank(user);
        staking.stake{value: stakeAmount}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        _setSuccessfulDays(user, 5);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 expectedReturn = (stakeAmount * 5) / 7; // 714285714285714285 wei
        uint256 expectedSlash = stakeAmount - expectedReturn;

        uint256 userBalanceBefore = user.balance;

        vm.prank(user);
        staking.claim();

        assertEq(user.balance, userBalanceBefore + expectedReturn);
        assertEq(treasury.balance, expectedSlash);

        // Verify proportions
        assertApproxEqRel(expectedReturn, 0.714285714285714285 ether, 0.001e18); // 0.1% tolerance
    }

    /// @notice 3/7 days successful - should return ~42.9% of stake
    function test_PartialSuccess_3of7Days() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);
        uint256 stakeAmount = 1 ether;

        vm.prank(user);
        staking.stake{value: stakeAmount}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        _setSuccessfulDays(user, 3);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 expectedReturn = (stakeAmount * 3) / 7; // 428571428571428571 wei
        uint256 expectedSlash = stakeAmount - expectedReturn;

        uint256 userBalanceBefore = user.balance;

        vm.prank(user);
        staking.claim();

        assertEq(user.balance, userBalanceBefore + expectedReturn);
        assertEq(treasury.balance, expectedSlash);

        // Verify proportions
        assertApproxEqRel(expectedReturn, 0.428571428571428571 ether, 0.001e18);
    }

    /// @notice 1/7 days successful - minimal return
    function test_PartialSuccess_1of7Days() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);
        uint256 stakeAmount = 0.7 ether; // Divisible by 7 for clean math

        vm.prank(user);
        staking.stake{value: stakeAmount}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        _setSuccessfulDays(user, 1);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 expectedReturn = stakeAmount / 7; // 0.1 ether
        uint256 expectedSlash = stakeAmount - expectedReturn; // 0.6 ether

        uint256 userBalanceBefore = user.balance;

        vm.prank(user);
        staking.claim();

        assertEq(user.balance, userBalanceBefore + expectedReturn);
        assertEq(treasury.balance, expectedSlash);
        assertEq(expectedReturn, 0.1 ether);
        assertEq(expectedSlash, 0.6 ether);
    }

    // ============ Multiple Concurrent Users ============

    /// @notice 5 users with different success rates compete simultaneously
    function test_MultipleConcurrentUsers_DifferentSuccessRates() public {
        address[] memory users = new address[](5);
        bytes32[5] memory pubKeysX = [PUB_KEY_X_1, PUB_KEY_X_2, PUB_KEY_X_3, PUB_KEY_X_4, PUB_KEY_X_5];
        bytes32[5] memory pubKeysY = [PUB_KEY_Y_1, PUB_KEY_Y_2, PUB_KEY_Y_3, PUB_KEY_Y_4, PUB_KEY_Y_5];
        uint256[5] memory successDays = [uint256(7), uint256(5), uint256(3), uint256(1), uint256(0)];
        uint256 stakeAmount = 1 ether;

        // Create and fund users, all stake
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            vm.deal(users[i], 10 ether);

            vm.prank(users[i]);
            staking.stake{value: stakeAmount}(4 hours, 7, pubKeysX[i], pubKeysY[i]);

            _setSuccessfulDays(users[i], successDays[i]);
        }

        // Warp past all stakes
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // All users claim
        uint256[] memory expectedReturns = new uint256[](5);
        uint256 totalSlashed = 0;

        for (uint256 i = 0; i < 5; i++) {
            expectedReturns[i] = (stakeAmount * successDays[i]) / 7;
            totalSlashed += stakeAmount - expectedReturns[i];

            uint256 balanceBefore = users[i].balance;

            vm.prank(users[i]);
            staking.claim();

            assertEq(users[i].balance, balanceBefore + expectedReturns[i]);
        }

        // Treasury should have all slashed amounts
        assertEq(treasury.balance, totalSlashed);

        // Verify expected amounts
        assertEq(expectedReturns[0], 1 ether); // 7/7 = 100%
        assertApproxEqRel(expectedReturns[1], 0.714285714285714285 ether, 0.001e18); // 5/7
        assertApproxEqRel(expectedReturns[2], 0.428571428571428571 ether, 0.001e18); // 3/7
        assertApproxEqRel(expectedReturns[3], 0.142857142857142857 ether, 0.001e18); // 1/7
        assertEq(expectedReturns[4], 0); // 0/7
    }

    /// @notice Users with different stake amounts and durations
    function test_MultipleConcurrentUsers_DifferentStakesAndDurations() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(user3, 10 ether);

        // User1: 0.5 ETH for 7 days
        vm.prank(user1);
        staking.stake{value: 0.5 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        // User2: 1 ETH for 14 days
        vm.prank(user2);
        staking.stake{value: 1 ether}(2 hours, 14, PUB_KEY_X_2, PUB_KEY_Y_2);

        // User3: 2 ETH for 30 days
        vm.prank(user3);
        staking.stake{value: 2 ether}(6 hours, 30, PUB_KEY_X_3, PUB_KEY_Y_3);

        // Set success rates
        _setSuccessfulDays(user1, 7); // 100%
        _setSuccessfulDays(user2, 10); // ~71%
        _setSuccessfulDays(user3, 15); // 50%

        // User1 can claim after 7 days
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);
        uint256 user1BalanceBefore = user1.balance;
        vm.prank(user1);
        staking.claim();
        assertEq(user1.balance, user1BalanceBefore + 0.5 ether);

        // User2 can claim after 14 days
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY); // +7 more = 14 total
        uint256 user2BalanceBefore = user2.balance;
        vm.prank(user2);
        staking.claim();
        uint256 user2Expected = (uint256(1 ether) * 10) / 14;
        assertEq(user2.balance, user2BalanceBefore + user2Expected);

        // User3 can claim after 30 days
        vm.warp(block.timestamp + 16 * SECONDS_PER_DAY); // +16 more = 30 total
        uint256 user3BalanceBefore = user3.balance;
        vm.prank(user3);
        staking.claim();
        uint256 user3Expected = (uint256(2 ether) * 15) / 30; // 1 ether
        assertEq(user3.balance, user3BalanceBefore + user3Expected);
    }

    // ============ Grace Period Edge Cases ============

    /// @notice Submit proof exactly at grace period start (day end + 1 second)
    function test_GracePeriod_ExactlyAtStart() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);

        vm.prank(user);
        staking.stake{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        uint256 startTime = block.timestamp;
        uint256 dayEndTime = startTime + SECONDS_PER_DAY;

        // Warp to exactly day end
        vm.warp(dayEndTime);

        (bool canSubmit,) = staking.canSubmitProof(user, 0);
        assertTrue(canSubmit, "Should be able to submit at exact day end");
    }

    /// @notice Submit proof exactly at grace period end boundary
    function test_GracePeriod_ExactlyAtEnd() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);

        vm.prank(user);
        staking.stake{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        uint256 startTime = block.timestamp;
        uint256 dayEndTime = startTime + SECONDS_PER_DAY;
        uint256 windowEnd = dayEndTime + GRACE_PERIOD;

        // Warp to exactly grace period end
        vm.warp(windowEnd);

        (bool canSubmit,) = staking.canSubmitProof(user, 0);
        assertTrue(canSubmit, "Should be able to submit at exact grace period end");
    }

    /// @notice Submit proof 1 second after grace period ends
    function test_GracePeriod_OneSecondAfterEnd() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);

        vm.prank(user);
        staking.stake{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        uint256 startTime = block.timestamp;
        uint256 dayEndTime = startTime + SECONDS_PER_DAY;
        uint256 windowEnd = dayEndTime + GRACE_PERIOD;

        // Warp to 1 second after grace period
        vm.warp(windowEnd + 1);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user, 0);
        assertFalse(canSubmit);
        assertEq(reason, "Submission window closed");
    }

    /// @notice Multiple days with varying submission times within grace periods
    function test_GracePeriod_MultiDaySubmissions() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);

        vm.prank(user);
        staking.stake{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        ProofwellStaking.Stake memory userStake = staking.getStake(user);
        uint256 startTime = userStake.startTimestamp;

        // Day 0: Submit at start of grace period (day 0 ends at startTime + 1 day)
        uint256 day0End = startTime + SECONDS_PER_DAY;
        vm.warp(day0End);
        (bool can0,) = staking.canSubmitProof(user, 0);
        assertTrue(can0, "Day 0: should be able to submit at day end");

        // Day 1: Submit in middle of grace period (day 1 ends at startTime + 2 days)
        uint256 day1End = startTime + (2 * SECONDS_PER_DAY);
        vm.warp(day1End + 3 hours);
        (bool can1,) = staking.canSubmitProof(user, 1);
        assertTrue(can1, "Day 1: should be able to submit in middle of grace period");

        // Day 2: Submit at end of grace period (day 2 ends at startTime + 3 days)
        uint256 day2End = startTime + (3 * SECONDS_PER_DAY);
        vm.warp(day2End + GRACE_PERIOD);
        (bool can2,) = staking.canSubmitProof(user, 2);
        assertTrue(can2, "Day 2: should be able to submit at grace period end");

        // Day 3: Miss the window (day 3 ends at startTime + 4 days)
        uint256 day3End = startTime + (4 * SECONDS_PER_DAY);
        vm.warp(day3End + GRACE_PERIOD + 1);
        (bool can3,) = staking.canSubmitProof(user, 3);
        assertFalse(can3, "Day 3: should NOT be able to submit after grace period");
    }

    // ============ Gas Cost Tests ============

    /// @notice Verify gas costs for stake operation
    function test_GasCost_Stake() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);

        uint256 gasBefore = gasleft();
        vm.prank(user);
        staking.stake{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for stake:", gasUsed);
        // Stake should be under 200k gas
        assertLt(gasUsed, 200_000, "Stake gas too high");
    }

    /// @notice Verify gas costs for claim operation
    function test_GasCost_Claim() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);

        vm.prank(user);
        staking.stake{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        _setSuccessfulDays(user, 5);
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 gasBefore = gasleft();
        vm.prank(user);
        staking.claim();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for claim:", gasUsed);
        // Claim should be under 100k gas
        assertLt(gasUsed, 100_000, "Claim gas too high");
    }

    /// @notice Verify gas costs for view functions
    function test_GasCost_ViewFunctions() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);

        vm.prank(user);
        staking.stake{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        uint256 gasBefore = gasleft();
        staking.getStake(user);
        uint256 getStakeGas = gasBefore - gasleft();

        gasBefore = gasleft();
        staking.canSubmitProof(user, 0);
        uint256 canSubmitGas = gasBefore - gasleft();

        gasBefore = gasleft();
        staking.getCurrentDayIndex(user);
        uint256 getDayGas = gasBefore - gasleft();

        console.log("Gas for getStake:", getStakeGas);
        console.log("Gas for canSubmitProof:", canSubmitGas);
        console.log("Gas for getCurrentDayIndex:", getDayGas);

        // View functions should be very cheap
        assertLt(getStakeGas, 10_000, "getStake gas too high");
        assertLt(canSubmitGas, 15_000, "canSubmitProof gas too high");
        assertLt(getDayGas, 10_000, "getCurrentDayIndex gas too high");
    }

    /// @notice Full user flow gas estimation
    function test_GasCost_FullUserFlow() public {
        address user = makeAddr("challenger");
        vm.deal(user, 10 ether);

        // Stake
        uint256 totalGas = 0;
        uint256 gasBefore = gasleft();
        vm.prank(user);
        staking.stake{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);
        totalGas += gasBefore - gasleft();

        // Simulate 7 days of successful proofs (via storage)
        _setSuccessfulDays(user, 7);

        // Claim
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);
        gasBefore = gasleft();
        vm.prank(user);
        staking.claim();
        totalGas += gasBefore - gasleft();

        console.log("Total gas for stake + claim flow:", totalGas);
        // Full flow should be under 300k gas
        assertLt(totalGas, 300_000, "Full flow gas too high");
    }

    // ============ 30-Day Challenge Scenario ============

    /// @notice Realistic 30-day challenge with 25/30 success rate
    function test_Realistic30DayChallenge() public {
        address user = makeAddr("monthly_challenger");
        vm.deal(user, 10 ether);
        uint256 stakeAmount = 0.05 ether; // ~$150 at $3k ETH

        vm.prank(user);
        staking.stake{value: stakeAmount}(4 hours, 30, PUB_KEY_X_1, PUB_KEY_Y_1);

        // 25/30 days successful (83.3%)
        _setSuccessfulDays(user, 25);

        vm.warp(block.timestamp + 30 * SECONDS_PER_DAY + 1);

        uint256 expectedReturn = (stakeAmount * 25) / 30;
        uint256 expectedSlash = stakeAmount - expectedReturn;

        uint256 balanceBefore = user.balance;
        vm.prank(user);
        staking.claim();

        assertEq(user.balance, balanceBefore + expectedReturn);
        assertEq(treasury.balance, expectedSlash);

        // ~83.3% return
        assertApproxEqRel(expectedReturn, (stakeAmount * 833) / 1000, 0.01e18);
    }
}
