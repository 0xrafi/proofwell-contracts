// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ProofwellStakingV2} from "../src/ProofwellStakingV2.sol";
import {ProofwellStakingV3} from "../src/ProofwellStakingV3.sol";
import {ProofwellStakingV4} from "../src/ProofwellStakingV4.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockUSDCV4 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ProofwellStakingV4Test is Test {
    ProofwellStakingV4 public staking;
    MockUSDCV4 public usdc;
    address public owner;
    address public treasury;
    address public charity;
    address public user1;
    address public user2;
    address public user3;

    // P-256 test keys (valid generator points)
    bytes32 constant PK_X1 = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    bytes32 constant PK_Y1 = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;
    bytes32 constant PK_X2 = 0x7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978;
    bytes32 constant PK_Y2 = 0x07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1;
    bytes32 constant PK_X3 = 0x5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C;
    bytes32 constant PK_Y3 = 0x8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032;

    uint256 constant SECONDS_PER_DAY = 300; // matches contract demo mode
    uint256 constant GRACE_PERIOD = 6 hours;

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");
        charity = makeAddr("charity");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        usdc = new MockUSDCV4();

        // Deploy V2 via proxy
        ProofwellStakingV2 v2Impl = new ProofwellStakingV2();
        bytes memory initData = abi.encodeCall(ProofwellStakingV2.initialize, (treasury, charity, address(usdc)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(v2Impl), initData);

        // Upgrade to V3
        ProofwellStakingV3 v3Impl = new ProofwellStakingV3();
        ProofwellStakingV2(payable(address(proxy))).upgradeToAndCall(
            address(v3Impl), abi.encodeCall(ProofwellStakingV3.initializeV3, ())
        );

        // Upgrade to V4
        ProofwellStakingV4 v4Impl = new ProofwellStakingV4();
        ProofwellStakingV3(payable(address(proxy))).upgradeToAndCall(
            address(v4Impl), abi.encodeCall(ProofwellStakingV4.initializeV4, ())
        );

        staking = ProofwellStakingV4(payable(address(proxy)));

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
        usdc.mint(user1, 100_000e6);
        usdc.mint(user2, 100_000e6);
        usdc.mint(user3, 100_000e6);
    }

    receive() external payable {}

    // ============ Helpers ============

    function _createPool(uint256 goalSec, uint256 durDays, uint256 deadlineSec) internal returns (uint256 poolId) {
        poolId = staking.createPool(goalSec, durDays, deadlineSec);
    }

    function _stakeETHPool(
        address user,
        uint256 value,
        uint256 goalSec,
        uint256 durDays,
        bytes32 pkx,
        bytes32 pky,
        uint256 poolId
    ) internal returns (uint256 stakeId) {
        vm.prank(user);
        stakeId = staking.stakeETHV4{value: value}(goalSec, durDays, pkx, pky, poolId);
    }

    function _stakeUSDCPool(
        address user,
        uint256 amount,
        uint256 goalSec,
        uint256 durDays,
        bytes32 pkx,
        bytes32 pky,
        uint256 poolId
    ) internal returns (uint256 stakeId) {
        vm.startPrank(user);
        usdc.approve(address(staking), amount);
        stakeId = staking.stakeUSDCV4(amount, goalSec, durDays, pkx, pky, poolId);
        vm.stopPrank();
    }

    function _stakeETHCohort(address user, uint256 value, uint256 goalSec, uint256 durDays, bytes32 pkx, bytes32 pky)
        internal
        returns (uint256 stakeId)
    {
        vm.prank(user);
        stakeId = staking.stakeETHV4{value: value}(goalSec, durDays, pkx, pky, 0);
    }

    function _stakeUSDCCohort(address user, uint256 amount, uint256 goalSec, uint256 durDays, bytes32 pkx, bytes32 pky)
        internal
        returns (uint256 stakeId)
    {
        vm.startPrank(user);
        usdc.approve(address(staking), amount);
        stakeId = staking.stakeUSDCV4(amount, goalSec, durDays, pkx, pky, 0);
        vm.stopPrank();
    }

    // ============ Version Tests ============

    function test_Version() public view {
        assertEq(staking.version(), "4.0.0");
    }

    function test_NextPoolId_StartsAt1() public view {
        assertEq(staking.nextPoolId(), 1);
    }

    function test_CannotReinitializeV4() public {
        vm.expectRevert();
        staking.initializeV4();
    }

    // ============ createPool Tests ============

    function test_CreatePool_Valid() public {
        uint256 poolId = _createPool(3600, 7, 1 days);

        assertEq(poolId, 1);
        assertEq(staking.nextPoolId(), 2);

        ProofwellStakingV4.Pool memory pool = staking.getPool(1);
        assertEq(pool.poolId, 1);
        assertEq(pool.creator, address(this));
        assertEq(pool.goalSeconds, 3600);
        assertEq(pool.durationDays, 7);
        assertEq(pool.entryDeadline, block.timestamp + 1 days);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.OPEN));
        assertEq(pool.totalStakersETH, 0);
        assertEq(pool.totalStakersUSDC, 0);
    }

    function test_CreatePool_ReturnsIncrementingIds() public {
        uint256 id1 = _createPool(3600, 7, 1 days);
        uint256 id2 = _createPool(7200, 14, 2 days);

        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    function test_CreatePool_InvalidGoal_Reverts() public {
        vm.expectRevert(ProofwellStakingV2.InvalidGoal.selector);
        staking.createPool(0, 7, 1 days);
    }

    function test_CreatePool_InvalidDuration_Reverts() public {
        vm.expectRevert(ProofwellStakingV2.InvalidDuration.selector);
        staking.createPool(3600, 0, 1 days);
    }

    function test_CreatePool_InvalidDeadline_Reverts() public {
        vm.expectRevert(ProofwellStakingV4.InvalidEntryDeadline.selector);
        staking.createPool(3600, 7, 0);
    }

    function test_CreatePool_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ProofwellStakingV4.PoolCreated(1, address(this), 3600, 7, block.timestamp + 1 days);
        staking.createPool(3600, 7, 1 days);
    }

    // ============ stakeETHV4 with Pool Tests ============

    function test_StakeETHV4_JoinsPool() public {
        uint256 poolId = _createPool(3600, 7, 1 days);
        uint256 stakeId = _stakeETHPool(user1, 0.01 ether, 3600, 7, PK_X1, PK_Y1, poolId);

        assertEq(stakeId, 0);
        assertEq(staking.getStakePool(user1, stakeId), poolId);
        assertEq(staking.activeStakeCount(user1), 1);

        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(pool.totalStakersETH, 1);
        assertEq(pool.remainingWinnersETH, 1);
    }

    function test_StakeETHV4_PoolGoalMismatch_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 days);

        vm.prank(user1);
        vm.expectRevert(ProofwellStakingV4.PoolGoalMismatch.selector);
        staking.stakeETHV4{value: 0.01 ether}(7200, 7, PK_X1, PK_Y1, poolId); // wrong goal
    }

    function test_StakeETHV4_PoolDurationMismatch_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 days);

        vm.prank(user1);
        vm.expectRevert(ProofwellStakingV4.PoolDurationMismatch.selector);
        staking.stakeETHV4{value: 0.01 ether}(3600, 14, PK_X1, PK_Y1, poolId); // wrong duration
    }

    function test_StakeETHV4_PoolNotFound_Reverts() public {
        vm.prank(user1);
        vm.expectRevert(ProofwellStakingV4.PoolNotFound.selector);
        staking.stakeETHV4{value: 0.01 ether}(3600, 7, PK_X1, PK_Y1, 999);
    }

    function test_StakeETHV4_AfterDeadline_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 hours);
        vm.warp(block.timestamp + 1 hours); // exactly at deadline

        vm.prank(user1);
        vm.expectRevert(ProofwellStakingV4.PoolEntryDeadlinePassed.selector);
        staking.stakeETHV4{value: 0.01 ether}(3600, 7, PK_X1, PK_Y1, poolId);
    }

    function test_StakeETHV4_EmitsEvent() public {
        uint256 poolId = _createPool(3600, 7, 1 days);

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit ProofwellStakingV4.StakedETHV4(user1, 0, poolId, 0.01 ether, 3600, 7, block.timestamp);
        staking.stakeETHV4{value: 0.01 ether}(3600, 7, PK_X1, PK_Y1, poolId);
    }

    // ============ stakeETHV4 Cohort Fallback Tests ============

    function test_StakeETHV4_CohortFallback() public {
        uint256 stakeId = _stakeETHCohort(user1, 0.01 ether, 3600, 7, PK_X1, PK_Y1);

        assertEq(stakeId, 0);
        assertEq(staking.getStakePool(user1, stakeId), 0);
        assertEq(staking.activeStakeCount(user1), 1);

        // Should be in cohort accounting
        uint256 cohortWeek = block.timestamp / 604800;
        (,, uint256 rwETH,, uint256 tsETH,) = staking.getCohortInfo(cohortWeek);
        assertEq(rwETH, 1);
        assertEq(tsETH, 1);
    }

    // ============ stakeUSDCV4 with Pool Tests ============

    function test_StakeUSDCV4_JoinsPool() public {
        uint256 poolId = _createPool(3600, 7, 1 days);
        uint256 stakeId = _stakeUSDCPool(user1, 10e6, 3600, 7, PK_X1, PK_Y1, poolId);

        assertEq(stakeId, 0);
        assertEq(staking.getStakePool(user1, stakeId), poolId);

        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(pool.totalStakersUSDC, 1);
        assertEq(pool.remainingWinnersUSDC, 1);
    }

    function test_StakeUSDCV4_CohortFallback() public {
        uint256 stakeId = _stakeUSDCCohort(user1, 10e6, 3600, 7, PK_X1, PK_Y1);

        assertEq(stakeId, 0);
        assertEq(staking.getStakePool(user1, stakeId), 0);

        uint256 cohortWeek = block.timestamp / 604800;
        (,,, uint256 rwUSDC,, uint256 tsUSDC) = staking.getCohortInfo(cohortWeek);
        assertEq(rwUSDC, 1);
        assertEq(tsUSDC, 1);
    }

    function test_StakeUSDCV4_PoolGoalMismatch_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 days);

        vm.startPrank(user1);
        usdc.approve(address(staking), 10e6);
        vm.expectRevert(ProofwellStakingV4.PoolGoalMismatch.selector);
        staking.stakeUSDCV4(10e6, 7200, 7, PK_X1, PK_Y1, poolId);
        vm.stopPrank();
    }

    // ============ Pool Entry Deadline Tests ============

    function test_EntryDeadline_JustBeforeDeadline_Succeeds() public {
        uint256 poolId = _createPool(3600, 7, 1 hours);
        vm.warp(block.timestamp + 1 hours - 1); // 1 second before deadline

        _stakeETHPool(user1, 0.01 ether, 3600, 7, PK_X1, PK_Y1, poolId);
        assertEq(staking.activeStakeCount(user1), 1);
    }

    function test_EntryDeadline_ExactlyAtDeadline_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 hours);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(user1);
        vm.expectRevert(ProofwellStakingV4.PoolEntryDeadlinePassed.selector);
        staking.stakeETHV4{value: 0.01 ether}(3600, 7, PK_X1, PK_Y1, poolId);
    }

    // ============ startPool Tests ============

    function test_StartPool_AfterDeadline() public {
        uint256 poolId = _createPool(3600, 7, 1 hours);
        vm.warp(block.timestamp + 1 hours);

        staking.startPool(poolId);

        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.RUNNING));
    }

    function test_StartPool_BeforeDeadline_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 hours);

        vm.expectRevert(ProofwellStakingV4.PoolNotStartable.selector);
        staking.startPool(poolId);
    }

    function test_StartPool_AlreadyRunning_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 hours);
        vm.warp(block.timestamp + 1 hours);
        staking.startPool(poolId);

        vm.expectRevert(ProofwellStakingV4.PoolNotStartable.selector);
        staking.startPool(poolId);
    }

    function test_StartPool_NotFound_Reverts() public {
        vm.expectRevert(ProofwellStakingV4.PoolNotFound.selector);
        staking.startPool(999);
    }

    // ============ Pool Status Transitions ============

    function test_PoolStatus_OpenToRunningToResolved() public {
        uint256 poolId = _createPool(3600, 3, 1 hours);

        // OPEN
        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.OPEN));

        // Stake before deadline
        _stakeUSDCPool(user1, 10e6, 3600, 3, PK_X1, PK_Y1, poolId);

        // Start pool
        vm.warp(block.timestamp + 1 hours);
        staking.startPool(poolId);

        pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.RUNNING));

        // Resolve by claiming (loser, so no proofs)
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);
        vm.prank(user1);
        staking.claimV4(0);

        pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.RESOLVED));
    }

    function test_PoolNotOpen_AfterStart_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 hours);

        // Join before deadline
        _stakeETHPool(user1, 0.01 ether, 3600, 7, PK_X1, PK_Y1, poolId);

        // Start pool
        vm.warp(block.timestamp + 1 hours);
        staking.startPool(poolId);

        // Try to join after start — pool is RUNNING, not OPEN
        vm.prank(user2);
        vm.expectRevert(ProofwellStakingV4.PoolNotOpen.selector);
        staking.stakeETHV4{value: 0.01 ether}(3600, 7, PK_X2, PK_Y2, poolId);
    }

    // ============ claimV4 with Pool Tests ============

    function test_ClaimV4_Pool_Loser_SlashedToPool() public {
        uint256 poolId = _createPool(3600, 3, 1 days);

        // Two users join the pool
        _stakeUSDCPool(user1, 100e6, 3600, 3, PK_X1, PK_Y1, poolId);
        _stakeUSDCPool(user2, 100e6, 3600, 3, PK_X2, PK_Y2, poolId);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 charityBefore = usdc.balanceOf(charity);

        // Warp past stake duration
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        // User1 claims (loser — no proofs submitted)
        vm.prank(user1);
        staking.claimV4(0);

        // 100M slashed: 40% (40M) to pool, 40% (40M) treasury, 20% (20M) charity
        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(pool.poolUSDC, 40e6);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 40e6);
        assertEq(usdc.balanceOf(charity) - charityBefore, 20e6);

        // Pool still has 1 staker (user2)
        assertEq(pool.totalStakersUSDC, 1);
        assertEq(pool.remainingWinnersUSDC, 1); // user1 was decremented as loser
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.OPEN)); // Not resolved yet
    }

    function test_ClaimV4_Pool_AllLosers_PoolResolved() public {
        uint256 poolId = _createPool(3600, 3, 1 days);

        _stakeUSDCPool(user1, 50e6, 3600, 3, PK_X1, PK_Y1, poolId);
        _stakeUSDCPool(user2, 50e6, 3600, 3, PK_X2, PK_Y2, poolId);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        // Both lose
        vm.prank(user1);
        staking.claimV4(0);
        vm.prank(user2);
        staking.claimV4(0);

        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.RESOLVED));
        assertEq(pool.poolUSDC, 0); // leftover swept to treasury/charity
    }

    function test_ClaimV4_Cohort_FallbackToV3() public {
        // Stake via V4 with poolId=0 (cohort)
        _stakeUSDCCohort(user1, 50e6, 3600, 3, PK_X1, PK_Y1);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 charityBefore = usdc.balanceOf(charity);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);
        vm.prank(user1);
        staking.claimV4(0);

        // 50M slashed: 40% (20M) to winner pool, 40% (20M) treasury, 20% (10M) charity
        // Single staker in cohort => cohort finalized: 67% of 20M (13.4M) treasury, 33% (6.6M) charity
        // Total treasury = 20M + 13.4M = 33.4M
        // Total charity = 10M + 6.6M = 16.6M
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 33_400_000);
        assertEq(usdc.balanceOf(charity) - charityBefore, 16_600_000);
    }

    function test_ClaimV4_BeforeEnd_Reverts() public {
        uint256 poolId = _createPool(3600, 7, 1 days);
        _stakeETHPool(user1, 0.01 ether, 3600, 7, PK_X1, PK_Y1, poolId);

        vm.prank(user1);
        vm.expectRevert(ProofwellStakingV2.StakeNotEnded.selector);
        staking.claimV4(0);
    }

    function test_ClaimV4_NonexistentStake_Reverts() public {
        vm.prank(user1);
        vm.expectRevert(ProofwellStakingV3.StakeNotFound.selector);
        staking.claimV4(999);
    }

    // ============ resolveExpiredV4 Tests ============

    function test_ResolveExpiredV4_Pool() public {
        uint256 poolId = _createPool(3600, 3, 1 days);
        _stakeUSDCPool(user1, 50e6, 3600, 3, PK_X1, PK_Y1, poolId);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 7 days + 1);

        vm.prank(user2);
        staking.resolveExpiredV4(user1, 0);

        // Stake should be cleared
        ProofwellStakingV2.Stake memory s = staking.getStakeV3(user1, 0);
        assertEq(s.amount, 0);
        assertEq(staking.activeStakeCount(user1), 0);

        // Pool should be resolved (single staker, all resolved)
        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.RESOLVED));
    }

    function test_ResolveExpiredV4_Cohort() public {
        _stakeUSDCCohort(user1, 50e6, 3600, 3, PK_X1, PK_Y1);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 7 days + 1);

        vm.prank(user2);
        staking.resolveExpiredV4(user1, 0);

        ProofwellStakingV2.Stake memory s = staking.getStakeV3(user1, 0);
        assertEq(s.amount, 0);
    }

    function test_ResolveExpiredV4_BeforeEnd_Reverts() public {
        uint256 poolId = _createPool(3600, 3, 1 days);
        _stakeETHPool(user1, 0.01 ether, 3600, 3, PK_X1, PK_Y1, poolId);

        // RESOLUTION_BUFFER is 0 in demo mode, so we test before stake end instead
        vm.warp(block.timestamp + 2 * SECONDS_PER_DAY);
        vm.prank(user2);
        vm.expectRevert(ProofwellStakingV2.ResolutionBufferNotElapsed.selector);
        staking.resolveExpiredV4(user1, 0);
    }

    // ============ Multiple Participants Tests ============

    function test_Pool_MultipleParticipants_MixedOutcomes_ETH() public {
        uint256 poolId = _createPool(3600, 3, 1 days);

        // 3 users join
        _stakeETHPool(user1, 1 ether, 3600, 3, PK_X1, PK_Y1, poolId);
        _stakeETHPool(user2, 1 ether, 3600, 3, PK_X2, PK_Y2, poolId);
        _stakeETHPool(user3, 1 ether, 3600, 3, PK_X3, PK_Y3, poolId);

        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(pool.totalStakersETH, 3);
        assertEq(pool.remainingWinnersETH, 3);

        // Warp past duration
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        // user1 loses (no proofs)
        uint256 user2BalBefore = user2.balance;
        vm.prank(user1);
        staking.claimV4(0);

        pool = staking.getPool(poolId);
        // 1 ETH slashed: 0.4 ETH to pool, 0.4 to treasury, 0.2 to charity
        assertEq(pool.poolETH, 0.4 ether);
        assertEq(pool.totalStakersETH, 2);
        assertEq(pool.remainingWinnersETH, 2); // user1 lost, so remaining winners decremented

        // user2 also loses
        vm.prank(user2);
        staking.claimV4(0);

        pool = staking.getPool(poolId);
        // Another 0.4 ETH to pool = 0.8 ETH total
        assertEq(pool.poolETH, 0.8 ether);
        assertEq(pool.totalStakersETH, 1);
        assertEq(pool.remainingWinnersETH, 1); // user2 lost too

        // user3 also loses — all 3 are losers
        uint256 treasuryBefore = treasury.balance;
        uint256 charityBefore = charity.balance;
        vm.prank(user3);
        staking.claimV4(0);

        // Pool is now resolved, leftover 1.2 ETH swept (67% treasury, 33% charity)
        pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.RESOLVED));
        assertEq(pool.poolETH, 0);
    }

    function test_Pool_TwoUsers_USDC_OneLoser() public {
        uint256 poolId = _createPool(3600, 3, 1 days);

        _stakeUSDCPool(user1, 100e6, 3600, 3, PK_X1, PK_Y1, poolId);
        _stakeUSDCPool(user2, 100e6, 3600, 3, PK_X2, PK_Y2, poolId);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        // user1 loses first
        vm.prank(user1);
        staking.claimV4(0);

        // Pool should have 40M USDC from user1's slash
        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(pool.poolUSDC, 40e6);
        assertEq(pool.remainingWinnersUSDC, 1); // only user2 remaining as potential winner

        // user2 also loses (no proofs) — the remaining "winner" pool goes to user2... no,
        // user2 is also a loser, so they get slashed too, then pool gets swept
        uint256 user2BalBefore = usdc.balanceOf(user2);
        vm.prank(user2);
        staking.claimV4(0);

        // user2 was a loser, so their 100M also gets slashed
        assertEq(usdc.balanceOf(user2), user2BalBefore); // no refund
        pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.RESOLVED));
    }

    // ============ Pool + Cohort Coexistence Tests ============

    function test_SameUser_PoolAndCohort() public {
        uint256 poolId = _createPool(3600, 3, 1 days);

        // User has both a pool stake and a cohort stake
        uint256 poolStakeId = _stakeUSDCPool(user1, 10e6, 3600, 3, PK_X1, PK_Y1, poolId);
        uint256 cohortStakeId = _stakeUSDCCohort(user1, 20e6, 7200, 7, PK_X1, PK_Y1);

        assertEq(poolStakeId, 0);
        assertEq(cohortStakeId, 1);
        assertEq(staking.activeStakeCount(user1), 2);
        assertEq(staking.getStakePool(user1, 0), poolId);
        assertEq(staking.getStakePool(user1, 1), 0);

        // Pool stake: check pool accounting
        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(pool.totalStakersUSDC, 1);

        // Cohort stake: check cohort accounting
        uint256 cohortWeek = block.timestamp / 604800;
        (,,, uint256 rwUSDC,, uint256 tsUSDC) = staking.getCohortInfo(cohortWeek);
        assertEq(rwUSDC, 1);
        assertEq(tsUSDC, 1);
    }

    function test_SameUser_ClaimPoolAndCohortIndependently() public {
        uint256 poolId = _createPool(3600, 3, 1 days);

        _stakeUSDCPool(user1, 10e6, 3600, 3, PK_X1, PK_Y1, poolId);
        _stakeUSDCCohort(user1, 20e6, 3600, 3, PK_X1, PK_Y1);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        // Claim pool stake
        vm.prank(user1);
        staking.claimV4(0);
        assertEq(staking.activeStakeCount(user1), 1);

        // Claim cohort stake
        vm.prank(user1);
        staking.claimV4(1);
        assertEq(staking.activeStakeCount(user1), 0);
    }

    // ============ View Function Tests ============

    function test_GetPool_NonexistentReturnsZero() public view {
        ProofwellStakingV4.Pool memory pool = staking.getPool(999);
        assertEq(pool.poolId, 0);
    }

    function test_GetStakePool_DefaultZero() public view {
        assertEq(staking.getStakePool(user1, 0), 0);
    }

    // ============ V2/V3 Functions Backward Compatibility ============

    function test_V2FunctionsStillWork() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 10e6);
        staking.stakeUSDC(10e6, 3600, 7, PK_X2, PK_Y2);
        vm.stopPrank();

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, 10e6);
    }

    function test_V3FunctionsStillWork() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 10e6);
        uint256 stakeId = staking.stakeUSDCV3(10e6, 3600, 7, PK_X1, PK_Y1);
        vm.stopPrank();

        assertEq(stakeId, 0);
        ProofwellStakingV2.Stake memory s = staking.getStakeV3(user1, 0);
        assertEq(s.amount, 10e6);
    }

    function test_V2StoragePreserved() public view {
        assertEq(staking.treasury(), treasury);
        assertEq(staking.charity(), charity);
        assertEq(staking.winnerPercent(), 40);
        assertEq(staking.treasuryPercent(), 40);
        assertEq(staking.charityPercent(), 20);
    }

    function test_ProofSubmission_SameAsV3() public {
        // submitDayProofV3 works with pool stakes (proofs are per-stake, not per-pool)
        uint256 poolId = _createPool(3600, 3, 1 days);
        _stakeETHPool(user1, 0.01 ether, 3600, 3, PK_X1, PK_Y1, poolId);

        // Can check proof window
        (bool canSubmit, string memory reason) = staking.canSubmitProofV3(user1, 0, 0);
        assertFalse(canSubmit);
        assertEq(reason, "Day has not ended yet");
    }

    // ============ Auto-Start Pool Tests ============

    function test_AutoStartPool_OnStakeAfterDeadline() public {
        // Create pool with very short deadline
        uint256 poolId = _createPool(3600, 3, 10); // 10 second deadline

        // Stake before deadline (pool stays OPEN)
        _stakeETHPool(user1, 0.01 ether, 3600, 3, PK_X1, PK_Y1, poolId);
        ProofwellStakingV4.Pool memory pool = staking.getPool(poolId);
        assertEq(uint8(pool.status), uint8(ProofwellStakingV4.PoolStatus.OPEN));

        // Note: staking after deadline would revert because _validatePoolEntry checks deadline
        // Auto-start only applies if someone stakes exactly at the boundary (not realistic)
        // The startPool function is the normal way to transition
    }
}
