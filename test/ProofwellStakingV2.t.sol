// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ProofwellStakingV2} from "../src/ProofwellStakingV2.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Mock USDC token for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ProofwellStakingV2Test is Test {
    ProofwellStakingV2 public staking;
    MockUSDC public usdc;
    address public owner;
    address public treasury;
    address public charity;
    address public user1;
    address public user2;

    // Test P-256 key pairs (valid generator points)
    bytes32 constant TEST_PUB_KEY_X = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    bytes32 constant TEST_PUB_KEY_Y = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;
    bytes32 constant TEST_PUB_KEY_X_2 = 0x7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978;
    bytes32 constant TEST_PUB_KEY_Y_2 = 0x07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1;
    bytes32 constant TEST_PUB_KEY_X_3 = 0x5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C;
    bytes32 constant TEST_PUB_KEY_Y_3 = 0x8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032;

    uint256 constant SECONDS_PER_DAY = 86400;
    uint256 constant GRACE_PERIOD = 6 hours;
    uint256 constant MIN_STAKE_ETH = 0.001 ether;
    uint256 constant MIN_STAKE_USDC = 1e6; // 1 USDC

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");
        charity = makeAddr("charity");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        usdc = new MockUSDC();

        // Deploy via proxy
        ProofwellStakingV2 implementation = new ProofwellStakingV2();
        bytes memory initData = abi.encodeCall(ProofwellStakingV2.initialize, (treasury, charity, address(usdc)));
        staking = ProofwellStakingV2(address(new ERC1967Proxy(address(implementation), initData)));

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        usdc.mint(user1, 1000e6); // 1000 USDC
        usdc.mint(user2, 1000e6);
    }

    // Allow test contract to receive ETH (for emergencyWithdraw test)
    receive() external payable {}

    // ============ Initialization Tests ============

    function test_Initialize_Success() public view {
        assertEq(staking.treasury(), treasury);
        assertEq(staking.charity(), charity);
        assertEq(address(staking.usdc()), address(usdc));
        assertEq(staking.winnerPercent(), 40);
        assertEq(staking.treasuryPercent(), 40);
        assertEq(staking.charityPercent(), 20);
        assertEq(staking.owner(), owner);
        assertEq(staking.version(), "2.0.0");
    }

    function test_Initialize_RevertIf_ZeroTreasury() public {
        ProofwellStakingV2 impl = new ProofwellStakingV2();
        bytes memory initData = abi.encodeCall(ProofwellStakingV2.initialize, (address(0), charity, address(usdc)));
        vm.expectRevert(ProofwellStakingV2.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertIf_ZeroCharity() public {
        ProofwellStakingV2 impl = new ProofwellStakingV2();
        bytes memory initData = abi.encodeCall(ProofwellStakingV2.initialize, (treasury, address(0), address(usdc)));
        vm.expectRevert(ProofwellStakingV2.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_Initialize_RevertIf_ZeroUSDC() public {
        ProofwellStakingV2 impl = new ProofwellStakingV2();
        bytes memory initData = abi.encodeCall(ProofwellStakingV2.initialize, (treasury, charity, address(0)));
        vm.expectRevert(ProofwellStakingV2.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        staking.initialize(treasury, charity, address(usdc));
    }

    function test_ImplementationCannotBeInitialized() public {
        ProofwellStakingV2 impl = new ProofwellStakingV2();
        vm.expectRevert();
        impl.initialize(treasury, charity, address(usdc));
    }

    // ============ ETH Staking Tests ============

    function test_StakeETH_Success() public {
        uint256 goalSeconds = 2 hours;
        uint256 durationDays = 7;
        uint256 stakeAmount = 1 ether;

        vm.prank(user1);
        staking.stakeETH{value: stakeAmount}(goalSeconds, durationDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        ProofwellStakingV2.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.amount, stakeAmount);
        assertEq(userStake.goalSeconds, goalSeconds);
        assertEq(userStake.durationDays, durationDays);
        assertFalse(userStake.isUSDC);
        assertEq(userStake.cohortWeek, block.timestamp / 604800);
    }

    function test_StakeETH_EmitsEvent() public {
        uint256 goalSeconds = 2 hours;
        uint256 durationDays = 7;
        uint256 stakeAmount = 1 ether;
        uint256 expectedCohort = block.timestamp / 604800;

        vm.expectEmit(true, false, false, true);
        emit ProofwellStakingV2.StakedETH(
            user1, stakeAmount, goalSeconds, durationDays, block.timestamp, expectedCohort
        );

        vm.prank(user1);
        staking.stakeETH{value: stakeAmount}(goalSeconds, durationDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_StakeETH_RevertIf_AlreadyStaked() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.expectRevert(ProofwellStakingV2.StakeAlreadyExists.selector);
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
    }

    function test_StakeETH_RevertIf_InsufficientAmount() public {
        vm.expectRevert(ProofwellStakingV2.InsufficientStake.selector);
        vm.prank(user1);
        staking.stakeETH{value: 0.0009 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    // ============ USDC Staking Tests ============

    function test_StakeUSDC_Success() public {
        uint256 goalSeconds = 2 hours;
        uint256 durationDays = 7;
        uint256 stakeAmount = 100e6; // 100 USDC

        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, goalSeconds, durationDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        ProofwellStakingV2.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.amount, stakeAmount);
        assertTrue(userStake.isUSDC);
        assertEq(usdc.balanceOf(address(staking)), stakeAmount);
    }

    function test_StakeUSDC_EmitsEvent() public {
        uint256 goalSeconds = 2 hours;
        uint256 durationDays = 7;
        uint256 stakeAmount = 100e6;
        uint256 expectedCohort = block.timestamp / 604800;

        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);

        vm.expectEmit(true, false, false, true);
        emit ProofwellStakingV2.StakedUSDC(
            user1, stakeAmount, goalSeconds, durationDays, block.timestamp, expectedCohort
        );

        staking.stakeUSDC(stakeAmount, goalSeconds, durationDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();
    }

    function test_StakeUSDC_RevertIf_InsufficientAmount() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 0.5e6);

        vm.expectRevert(ProofwellStakingV2.InsufficientStake.selector);
        staking.stakeUSDC(0.5e6, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y); // 0.5 USDC < 1 USDC min
        vm.stopPrank();
    }

    // ============ Admin Function Tests ============

    function test_Pause_Success() public {
        staking.pause();
        assertTrue(staking.paused());
    }

    function test_Pause_RevertIf_NotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        staking.pause();
    }

    function test_Unpause_Success() public {
        staking.pause();
        staking.unpause();
        assertFalse(staking.paused());
    }

    function test_StakeETH_RevertIf_Paused() public {
        staking.pause();

        vm.expectRevert();
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_StakeUSDC_RevertIf_Paused() public {
        staking.pause();

        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);

        vm.expectRevert();
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();
    }

    function test_SetTreasury_Success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit ProofwellStakingV2.TreasuryUpdated(treasury, newTreasury);

        staking.setTreasury(newTreasury);
        assertEq(staking.treasury(), newTreasury);
    }

    function test_SetTreasury_RevertIf_ZeroAddress() public {
        vm.expectRevert(ProofwellStakingV2.ZeroAddress.selector);
        staking.setTreasury(address(0));
    }

    function test_SetTreasury_RevertIf_NotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        staking.setTreasury(makeAddr("newTreasury"));
    }

    function test_SetCharity_Success() public {
        address newCharity = makeAddr("newCharity");

        vm.expectEmit(true, true, false, false);
        emit ProofwellStakingV2.CharityUpdated(charity, newCharity);

        staking.setCharity(newCharity);
        assertEq(staking.charity(), newCharity);
    }

    function test_SetDistribution_Success() public {
        vm.expectEmit(false, false, false, true);
        emit ProofwellStakingV2.DistributionUpdated(50, 30, 20);

        staking.setDistribution(50, 30, 20);
        assertEq(staking.winnerPercent(), 50);
        assertEq(staking.treasuryPercent(), 30);
        assertEq(staking.charityPercent(), 20);
    }

    function test_SetDistribution_RevertIf_InvalidSum() public {
        vm.expectRevert(ProofwellStakingV2.InvalidDistribution.selector);
        staking.setDistribution(50, 30, 30); // Sum = 110
    }

    function test_EmergencyWithdraw_ETH() public {
        // First, stake some ETH
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        uint256 ownerBalanceBefore = owner.balance;
        uint256 contractBalance = address(staking).balance;

        staking.emergencyWithdraw(address(0));

        assertEq(owner.balance, ownerBalanceBefore + contractBalance);
        assertEq(address(staking).balance, 0);
    }

    function test_EmergencyWithdraw_USDC() public {
        // First, stake some USDC
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        uint256 ownerBalanceBefore = usdc.balanceOf(owner);
        uint256 contractBalance = usdc.balanceOf(address(staking));

        vm.expectEmit(true, false, false, true);
        emit ProofwellStakingV2.EmergencyWithdraw(address(usdc), contractBalance);

        staking.emergencyWithdraw(address(usdc));

        assertEq(usdc.balanceOf(owner), ownerBalanceBefore + contractBalance);
        assertEq(usdc.balanceOf(address(staking)), 0);
    }

    // ============ Claim with Distribution Tests ============

    /// @dev Helper to set successful days via storage
    /// @notice With UUPS pattern using ERC-7201 namespaced storage, stakes mapping is at slot 0
    function _setSuccessfulDays(address user, uint256 days_) internal {
        // Slot 0: stakes mapping (ERC-7201 namespaced storage puts our state first)
        bytes32 stakeSlot = keccak256(abi.encode(user, uint256(0)));
        // Stake struct: amount(0), goalSeconds(1), startTimestamp(2), durationDays(3),
        //               pubKeyX(4), pubKeyY(5), successfulDays(6), claimed+isUSDC(7), cohortWeek(8)
        bytes32 successfulDaysSlot = bytes32(uint256(stakeSlot) + 6);
        vm.store(address(staking), successfulDaysSlot, bytes32(days_));
    }

    function test_Claim_ETH_AllSlashed_Distribution() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 treasuryBefore = treasury.balance;
        uint256 charityBefore = charity.balance;

        vm.prank(user1);
        staking.claim();

        // When last staker claims with no winners, pool is finalized
        // Slashed 1 ETH: 40% to pool, 40% to treasury, 20% to charity
        // Then leftover pool (0.4 ETH) split: 67% treasury, 33% charity
        // Treasury: 0.4 + 0.268 = 0.668 ETH
        // Charity: 0.2 + 0.132 = 0.332 ETH
        assertEq(treasury.balance, treasuryBefore + 0.668 ether);
        assertEq(charity.balance, charityBefore + 0.332 ether);
    }

    function test_Claim_ETH_PartialSuccess_Distribution() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 10, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // 5/10 days successful (not a winner - binary payout means $0 returned)
        _setSuccessfulDays(user1, 5);

        vm.warp(block.timestamp + 10 * SECONDS_PER_DAY + 1);

        uint256 userBefore = user1.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 charityBefore = charity.balance;

        vm.prank(user1);
        staking.claim();

        // Binary payout: User gets $0 (not 100% success)
        // Full 1 ETH slashed and distributed:
        //   40% (0.4 ETH) to winner pool
        //   40% (0.4 ETH) to treasury
        //   20% (0.2 ETH) to charity
        // Since this is the last staker and no winners, pool is finalized:
        //   Pool (0.4 ETH) split: 67% to treasury (0.268), 33% to charity (0.132)
        // Total treasury: 0.4 + 0.268 = 0.668 ETH
        // Total charity: 0.2 + 0.132 = 0.332 ETH
        assertEq(user1.balance, userBefore); // No refund
        assertEq(treasury.balance, treasuryBefore + 0.668 ether);
        assertEq(charity.balance, charityBefore + 0.332 ether);
    }

    function test_Claim_USDC_PartialSuccess_Distribution() public {
        uint256 stakeAmount = 100e6; // 100 USDC

        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 10, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        // 5/10 days successful (not a winner - binary payout means $0 returned)
        _setSuccessfulDays(user1, 5);

        vm.warp(block.timestamp + 10 * SECONDS_PER_DAY + 1);

        uint256 userBefore = usdc.balanceOf(user1);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 charityBefore = usdc.balanceOf(charity);

        vm.prank(user1);
        staking.claim();

        // Binary payout: User gets $0 (not 100% success)
        // Full 100 USDC slashed and distributed:
        //   40% (40 USDC) to winner pool
        //   40% (40 USDC) to treasury
        //   20% (20 USDC) to charity
        // Since last staker and no winners, pool finalized:
        //   Pool (40 USDC) split: 67% treasury (26.8), 33% charity (13.2)
        // Total treasury: 40 + 26.8 = 66.8 USDC
        // Total charity: 20 + 13.2 = 33.2 USDC
        assertEq(usdc.balanceOf(user1), userBefore); // No refund
        assertEq(usdc.balanceOf(treasury), treasuryBefore + 66800000);
        assertEq(usdc.balanceOf(charity), charityBefore + 33200000);
    }

    // ============ Binary Payout Tests ============

    function test_BinaryPayout_AllDaysSuccess_FullRefund() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // 7/7 days successful = winner
        _setSuccessfulDays(user1, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 userBefore = user1.balance;

        vm.prank(user1);
        staking.claim();

        // Winner gets full stake back (no slashing)
        assertEq(user1.balance, userBefore + 1 ether);
    }

    function test_BinaryPayout_OneDayMissed_NoRefund() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // 6/7 days successful = NOT a winner (binary: miss one = lose all)
        _setSuccessfulDays(user1, 6);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 userBefore = user1.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 charityBefore = charity.balance;

        vm.prank(user1);
        staking.claim();

        // User gets $0 - entire stake slashed
        assertEq(user1.balance, userBefore);
        // Distribution: 40% pool, 40% treasury, 20% charity
        // Pool finalized: 67% treasury, 33% charity
        assertEq(treasury.balance, treasuryBefore + 0.668 ether);
        assertEq(charity.balance, charityBefore + 0.332 ether);
    }

    function test_BinaryPayout_MinimalSuccess_NoRefund() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // 1/7 days successful = NOT a winner
        _setSuccessfulDays(user1, 1);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 userBefore = user1.balance;

        vm.prank(user1);
        staking.claim();

        // User gets $0 - entire stake slashed
        assertEq(user1.balance, userBefore);
    }

    function test_BinaryPayout_ZeroSuccess_NoRefund() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // 0/7 days successful = NOT a winner
        // successfulDays defaults to 0, no need to set

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 userBefore = user1.balance;

        vm.prank(user1);
        staking.claim();

        // User gets $0 - entire stake slashed
        assertEq(user1.balance, userBefore);
    }

    function test_BinaryPayout_USDC_OneDayMissed_NoRefund() public {
        uint256 stakeAmount = 100e6; // 100 USDC

        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        // 6/7 days successful = NOT a winner
        _setSuccessfulDays(user1, 6);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 userBefore = usdc.balanceOf(user1);

        vm.prank(user1);
        staking.claim();

        // User gets $0 - entire stake slashed
        assertEq(usdc.balanceOf(user1), userBefore);
    }

    // ============ Cohort Winner Distribution Tests ============

    function test_CohortTracking_IncrementOnStake() public {
        uint256 cohort = block.timestamp / 604800;

        (,, uint256 remainingWinners, uint256 totalStakers,) = staking.getCohortInfo(cohort);
        assertEq(remainingWinners, 0);
        assertEq(totalStakers, 0);

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        (,, remainingWinners, totalStakers,) = staking.getCohortInfo(cohort);
        assertEq(remainingWinners, 1);
        assertEq(totalStakers, 1);
    }

    function test_WinnerBonus_SingleWinner() public {
        // User1 stakes and fails completely
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Get cohort from the stake
        uint256 cohort = staking.getStake(user1).cohortWeek;

        // User2 stakes and succeeds completely
        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        _setSuccessfulDays(user2, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // User1 claims first (fails, contributes to pool)
        vm.prank(user1);
        staking.claim();

        // Pool should have 0.4 ETH (40% of 1 ETH slashed)
        // remainingWinners is 2 (both started as potential winners)
        // but user1 didn't decrement it since they weren't a winner
        (uint256 poolETH,, uint256 remainingWinners,, bool finalized) = staking.getCohortInfo(cohort);
        assertEq(poolETH, 0.4 ether);
        assertEq(remainingWinners, 2); // Still 2 since non-winner doesn't decrement
        assertFalse(finalized);

        // User2 claims (winner, gets bonus)
        uint256 user2Before = user2.balance;
        vm.prank(user2);
        staking.claim();

        // User2 gets: 1 ETH (full stake) + 0.4/2 = 0.2 ETH (share of pool with 2 remaining)
        // Since remainingWinners was 2 when user2 claimed
        assertEq(user2.balance, user2Before + 1.2 ether);
    }

    function test_WinnerBonus_MultipleWinners() public {
        address user3 = makeAddr("user3");
        vm.deal(user3, 10 ether);

        // User1 stakes and fails completely
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Get cohort from the stake
        uint256 cohort = staking.getStake(user1).cohortWeek;

        // User2 stakes and succeeds
        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        _setSuccessfulDays(user2, 7);

        // User3 stakes and succeeds
        vm.prank(user3);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_3, TEST_PUB_KEY_Y_3);
        _setSuccessfulDays(user3, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // User1 claims (fails)
        vm.prank(user1);
        staking.claim();

        // Pool has 0.4 ETH, 3 remaining "potential winners" (non-winners don't decrement)
        (uint256 poolETH,, uint256 remaining,,) = staking.getCohortInfo(cohort);
        assertEq(poolETH, 0.4 ether);
        assertEq(remaining, 3); // All 3 stakers counted as potential winners

        // User2 claims first - gets 1/3 of pool (0.133 ETH)
        uint256 user2Before = user2.balance;
        vm.prank(user2);
        staking.claim();
        assertEq(user2.balance, user2Before + 1 ether + 0.133333333333333333 ether);

        // User3 claims second - gets 1/2 of remaining pool (0.133 ETH)
        uint256 user3Before = user3.balance;
        vm.prank(user3);
        staking.claim();
        // Pool was 0.266... ETH, divided by 2 = 0.133 ETH
        assertEq(user3.balance, user3Before + 1 ether + 0.133333333333333333 ether);
    }

    function test_NoWinners_PoolSplitToTreasuryAndCharity() public {
        uint256 cohort = block.timestamp / 604800;

        // User1 stakes and fails completely
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // User2 stakes and fails partially (binary payout: still loses everything)
        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        _setSuccessfulDays(user2, 3); // Not a winner

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // User1 claims - slashes 1 ETH
        // 0.4 ETH to pool, 0.4 ETH to treasury, 0.2 ETH to charity
        vm.prank(user1);
        staking.claim();

        // Pool has 0.4 ETH from user1's slash
        (uint256 poolAfterUser1,,,,) = staking.getCohortInfo(cohort);
        assertEq(poolAfterUser1, 0.4 ether);

        // User2 claims - binary payout means full 1 ETH slashed
        // 0.4 ETH to pool, 0.4 ETH to treasury, 0.2 ETH to charity
        // Then pool is finalized: total pool 0.8 ETH split 67/33
        vm.prank(user2);
        staking.claim();

        // Pool should now be finalized since no stakers left
        (uint256 poolFinal,,,, bool finalized) = staking.getCohortInfo(cohort);
        assertTrue(finalized);
        assertEq(poolFinal, 0); // Pool drained to treasury/charity
    }

    // ============ Proof Submission Tests ============

    function test_SubmitDayProof_RevertIf_Paused() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        staking.pause();

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        vm.expectRevert();
        vm.prank(user1);
        staking.submitDayProof(0, true, bytes32(0), bytes32(0));
    }

    function test_Claim_RevertIf_Paused() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        staking.pause();

        vm.expectRevert();
        vm.prank(user1);
        staking.claim();
    }

    // ============ View Function Tests ============

    function test_GetCurrentWeek() public view {
        assertEq(staking.getCurrentWeek(), block.timestamp / 604800);
    }

    function test_GetCohortInfo() public {
        uint256 cohort = block.timestamp / 604800;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        (uint256 poolETH, uint256 poolUSDC, uint256 remaining, uint256 total, bool finalized) =
            staking.getCohortInfo(cohort);

        assertEq(poolETH, 0);
        assertEq(poolUSDC, 0);
        assertEq(remaining, 1);
        assertEq(total, 1);
        assertFalse(finalized);
    }

    // ============ Ownership Tests ============

    function test_TransferOwnership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        staking.transferOwnership(newOwner);

        // Still old owner until accepted
        assertEq(staking.owner(), owner);
        assertEq(staking.pendingOwner(), newOwner);

        // Accept ownership
        vm.prank(newOwner);
        staking.acceptOwnership();

        assertEq(staking.owner(), newOwner);
    }

    // ============ UUPS Upgrade Tests ============

    function test_UpgradeToNewImplementation() public {
        // Create a stake first to test state preservation
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Deploy new implementation
        ProofwellStakingV2 newImpl = new ProofwellStakingV2();

        // Upgrade (only owner can)
        staking.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertEq(staking.treasury(), treasury);
        assertEq(staking.charity(), charity);
        assertEq(staking.owner(), owner);

        // Verify stake still exists
        ProofwellStakingV2.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.amount, 1 ether);
    }

    function test_UpgradeRevertIf_NotOwner() public {
        ProofwellStakingV2 newImpl = new ProofwellStakingV2();

        vm.prank(user1);
        vm.expectRevert();
        staking.upgradeToAndCall(address(newImpl), "");
    }

    function test_Version() public view {
        assertEq(staking.version(), "2.0.0");
    }

    // ============ Constants Tests ============

    function test_Constants() public view {
        assertEq(staking.SECONDS_PER_DAY(), 86400);
        assertEq(staking.SECONDS_PER_WEEK(), 604800);
        assertEq(staking.GRACE_PERIOD(), 6 hours);
        assertEq(staking.MIN_STAKE_ETH(), 0.001 ether);
        assertEq(staking.MIN_STAKE_USDC(), 1e6);
        assertEq(staking.MAX_DURATION_DAYS(), 365);
        assertEq(staking.MAX_GOAL_SECONDS(), 24 hours);
    }

    // ============ Fuzz Tests ============

    function testFuzz_StakeETH_ValidParameters(uint256 goalSeconds, uint256 durationDays, uint256 stakeAmount) public {
        goalSeconds = bound(goalSeconds, 1, 24 hours);
        durationDays = bound(durationDays, 1, 365);
        stakeAmount = bound(stakeAmount, MIN_STAKE_ETH, 100 ether);

        vm.deal(user1, stakeAmount);

        vm.prank(user1);
        staking.stakeETH{value: stakeAmount}(goalSeconds, durationDays, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        ProofwellStakingV2.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.amount, stakeAmount);
        assertEq(userStake.goalSeconds, goalSeconds);
        assertEq(userStake.durationDays, durationDays);
    }

    function testFuzz_Distribution_ValidPercentages(uint8 winner, uint8 treasury_) public {
        // Bound winner to 0-100, then calculate charity as remainder
        winner = uint8(bound(winner, 0, 100));
        treasury_ = uint8(bound(treasury_, 0, 100 - winner));
        uint8 charity_ = uint8(100 - winner - treasury_);

        staking.setDistribution(winner, treasury_, charity_);

        assertEq(staking.winnerPercent(), winner);
        assertEq(staking.treasuryPercent(), treasury_);
        assertEq(staking.charityPercent(), charity_);
    }
}

/// @notice Integration tests for V2 specific features
contract ProofwellStakingV2IntegrationTest is Test {
    ProofwellStakingV2 public staking;
    MockUSDC public usdc;
    address public owner;
    address public treasury;
    address public charity;

    bytes32 constant PUB_KEY_X_1 = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    bytes32 constant PUB_KEY_Y_1 = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;
    bytes32 constant PUB_KEY_X_2 = 0x7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978;
    bytes32 constant PUB_KEY_Y_2 = 0x07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1;
    bytes32 constant PUB_KEY_X_3 = 0x5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C;
    bytes32 constant PUB_KEY_Y_3 = 0x8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032;
    bytes32 constant PUB_KEY_X_4 = 0xE2534A3532D08FBBA02DDE659EE62BD0031FE2DB785596EF509302446B030852;
    bytes32 constant PUB_KEY_Y_4 = 0xE0F1575A4C633CC719DFEE5FDA862D764EFC96C3F30EE0055C42C23F184ED8C6;
    bytes32 constant PUB_KEY_X_5 = 0x51590B7A515140D2D784C85608668FDFEF8C82FD1F5BE52421554A0DC3D033ED;
    bytes32 constant PUB_KEY_Y_5 = 0xE0C17DA8904A727D8AE1BF36BF8A79260D012F00D4D80888D1D0BB44FDA16DA4;

    uint256 constant SECONDS_PER_DAY = 86400;

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");
        charity = makeAddr("charity");

        usdc = new MockUSDC();

        // Deploy via proxy
        ProofwellStakingV2 implementation = new ProofwellStakingV2();
        bytes memory initData = abi.encodeCall(ProofwellStakingV2.initialize, (treasury, charity, address(usdc)));
        staking = ProofwellStakingV2(address(new ERC1967Proxy(address(implementation), initData)));
    }

    /// @dev Helper to set successful days via storage
    /// @notice With UUPS pattern using ERC-7201 namespaced storage, stakes mapping is at slot 0
    function _setSuccessfulDays(address user, uint256 days_) internal {
        // Slot 0: stakes mapping (ERC-7201 namespaced storage puts our state first)
        bytes32 stakeSlot = keccak256(abi.encode(user, uint256(0)));
        // Stake struct: amount(0), goalSeconds(1), startTimestamp(2), durationDays(3),
        //               pubKeyX(4), pubKeyY(5), successfulDays(6), claimed+isUSDC(7), cohortWeek(8)
        bytes32 successfulDaysSlot = bytes32(uint256(stakeSlot) + 6);
        vm.store(address(staking), successfulDaysSlot, bytes32(days_));
    }

    /// @notice Full scenario: 5 users, mix of ETH and USDC, various success rates
    function test_FullScenario_MixedTokensAndOutcomes() public {
        address[] memory users = new address[](5);
        bytes32[5] memory pubKeysX = [PUB_KEY_X_1, PUB_KEY_X_2, PUB_KEY_X_3, PUB_KEY_X_4, PUB_KEY_X_5];
        bytes32[5] memory pubKeysY = [PUB_KEY_Y_1, PUB_KEY_Y_2, PUB_KEY_Y_3, PUB_KEY_Y_4, PUB_KEY_Y_5];

        // Setup users and stakes
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
            vm.deal(users[i], 10 ether);
            usdc.mint(users[i], 1000e6);
        }

        // User0: 1 ETH, winner (7/7)
        vm.prank(users[0]);
        staking.stakeETH{value: 1 ether}(4 hours, 7, pubKeysX[0], pubKeysY[0]);
        _setSuccessfulDays(users[0], 7);

        // User1: 100 USDC, winner (7/7)
        vm.startPrank(users[1]);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 4 hours, 7, pubKeysX[1], pubKeysY[1]);
        vm.stopPrank();
        _setSuccessfulDays(users[1], 7);

        // User2: 2 ETH, partial (5/7)
        vm.prank(users[2]);
        staking.stakeETH{value: 2 ether}(4 hours, 7, pubKeysX[2], pubKeysY[2]);
        _setSuccessfulDays(users[2], 5);

        // User3: 50 USDC, fail (0/7)
        vm.startPrank(users[3]);
        usdc.approve(address(staking), 50e6);
        staking.stakeUSDC(50e6, 4 hours, 7, pubKeysX[3], pubKeysY[3]);
        vm.stopPrank();
        // No success days set

        // User4: 0.5 ETH, fail (0/7)
        vm.prank(users[4]);
        staking.stakeETH{value: 0.5 ether}(4 hours, 7, pubKeysX[4], pubKeysY[4]);
        // No success days set

        // Warp past stake duration
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // Track balances before claims
        uint256 treasuryETHBefore = treasury.balance;
        uint256 treasuryUSDCBefore = usdc.balanceOf(treasury);
        uint256 charityETHBefore = charity.balance;
        uint256 charityUSDCBefore = usdc.balanceOf(charity);

        // All users claim
        for (uint256 i = 0; i < 5; i++) {
            uint256 balanceBefore = users[i].balance;
            uint256 usdcBefore = usdc.balanceOf(users[i]);

            vm.prank(users[i]);
            staking.claim();

            ProofwellStakingV2.Stake memory stake = staking.getStake(users[i]);
            assertTrue(stake.claimed);

            console.log("User", i, "ETH balance change:", users[i].balance - balanceBefore);
            console.log("User", i, "USDC balance change:", usdc.balanceOf(users[i]) - usdcBefore);
        }

        // Verify treasury and charity received funds
        assertTrue(treasury.balance > treasuryETHBefore, "Treasury should receive ETH");
        assertTrue(usdc.balanceOf(treasury) > treasuryUSDCBefore, "Treasury should receive USDC");
        assertTrue(charity.balance > charityETHBefore, "Charity should receive ETH");
        assertTrue(usdc.balanceOf(charity) > charityUSDCBefore, "Charity should receive USDC");
    }

    /// @notice Test early claimer advantage
    function test_EarlyClaimerAdvantage() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address winner1 = makeAddr("winner1");
        address winner2 = makeAddr("winner2");

        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(winner1, 10 ether);
        vm.deal(winner2, 10 ether);

        // Two losers stake first
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);

        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(4 hours, 7, PUB_KEY_X_2, PUB_KEY_Y_2);

        // Two winners stake
        vm.prank(winner1);
        staking.stakeETH{value: 1 ether}(4 hours, 7, PUB_KEY_X_3, PUB_KEY_Y_3);
        _setSuccessfulDays(winner1, 7);

        vm.prank(winner2);
        staking.stakeETH{value: 1 ether}(4 hours, 7, PUB_KEY_X_4, PUB_KEY_Y_4);
        _setSuccessfulDays(winner2, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // Losers claim first - this builds up the pool
        vm.prank(user1);
        staking.claim();

        // Pool now has 0.4 ETH

        // First winner claims - gets share of current pool
        uint256 winner1Before = winner1.balance;
        vm.prank(winner1);
        staking.claim();
        uint256 winner1Bonus = winner1.balance - winner1Before - 1 ether;
        console.log("Winner1 bonus:", winner1Bonus);

        // Second loser claims - adds more to pool
        vm.prank(user2);
        staking.claim();

        // Second winner claims - gets remaining pool (which grew)
        uint256 winner2Before = winner2.balance;
        vm.prank(winner2);
        staking.claim();
        uint256 winner2Bonus = winner2.balance - winner2Before - 1 ether;
        console.log("Winner2 bonus:", winner2Bonus);

        // Both winners should have gotten bonuses
        assertTrue(winner1Bonus > 0, "Winner1 should get bonus");
        assertTrue(winner2Bonus > 0, "Winner2 should get bonus");
    }

    /// @notice Gas comparison between V1 and V2 operations
    function test_GasCost_V2Operations() public {
        address user = makeAddr("gasUser");
        vm.deal(user, 10 ether);
        usdc.mint(user, 1000e6);

        // ETH Stake
        uint256 gasBefore = gasleft();
        vm.prank(user);
        staking.stakeETH{value: 1 ether}(4 hours, 7, PUB_KEY_X_1, PUB_KEY_Y_1);
        uint256 stakeETHGas = gasBefore - gasleft();
        console.log("Gas for stakeETH:", stakeETHGas);

        _setSuccessfulDays(user, 7);
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // Claim
        gasBefore = gasleft();
        vm.prank(user);
        staking.claim();
        uint256 claimGas = gasBefore - gasleft();
        console.log("Gas for claim:", claimGas);

        // USDC Stake (new user)
        address user2 = makeAddr("gasUser2");
        vm.deal(user2, 10 ether);
        usdc.mint(user2, 1000e6);

        vm.startPrank(user2);
        usdc.approve(address(staking), 100e6);
        gasBefore = gasleft();
        staking.stakeUSDC(100e6, 4 hours, 7, PUB_KEY_X_2, PUB_KEY_Y_2);
        uint256 stakeUSDCGas = gasBefore - gasleft();
        vm.stopPrank();
        console.log("Gas for stakeUSDC:", stakeUSDCGas);

        // Verify reasonable gas usage (V2 with UUPS proxy has ~2.5k overhead per call)
        assertLt(stakeETHGas, 260_000, "stakeETH gas too high");
        assertLt(stakeUSDCGas, 310_000, "stakeUSDC gas too high");
        assertLt(claimGas, 210_000, "claim gas too high"); // V2 claim is more complex
    }
}
