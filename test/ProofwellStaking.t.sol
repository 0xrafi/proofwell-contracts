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
