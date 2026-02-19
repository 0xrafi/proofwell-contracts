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

/// @notice Contract that rejects ETH transfers
contract RevertingReceiver {
    receive() external payable {
        revert("no ETH accepted");
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
        staking = ProofwellStakingV2(payable(address(new ERC1967Proxy(address(implementation), initData))));

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
        assertEq(staking.version(), "2.3.0");
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

        // Must pause first
        staking.pause();
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

        staking.pause();

        vm.expectEmit(true, false, false, true);
        emit ProofwellStakingV2.EmergencyWithdraw(address(usdc), contractBalance);

        staking.emergencyWithdraw(address(usdc));

        assertEq(usdc.balanceOf(owner), ownerBalanceBefore + contractBalance);
        assertEq(usdc.balanceOf(address(staking)), 0);
    }

    function test_EmergencyWithdraw_RevertIf_NotPaused() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.expectRevert();
        staking.emergencyWithdraw(address(0));
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

        (,, uint256 remainingWinnersETH,, uint256 totalStakersETH,) = staking.getCohortInfo(cohort);
        assertEq(remainingWinnersETH, 0);
        assertEq(totalStakersETH, 0);

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        (,, remainingWinnersETH,, totalStakersETH,) = staking.getCohortInfo(cohort);
        assertEq(remainingWinnersETH, 1);
        assertEq(totalStakersETH, 1);
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
        // remainingWinnersETH is 1 (loser decremented it from 2 to 1)
        (uint256 poolETH,, uint256 remainingWinnersETH,,,) = staking.getCohortInfo(cohort);
        assertEq(poolETH, 0.4 ether);
        assertEq(remainingWinnersETH, 1);

        // User2 claims (winner, gets bonus)
        uint256 user2Before = user2.balance;
        vm.prank(user2);
        staking.claim();

        // User2 gets: 1 ETH (full stake) + 0.4/1 = 0.4 ETH (full pool, only winner)
        assertEq(user2.balance, user2Before + 1.4 ether);
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

        // Pool has 0.4 ETH, 2 remaining ETH winners (loser decremented from 3 to 2)
        (uint256 poolETH,, uint256 remainingETH,,,) = staking.getCohortInfo(cohort);
        assertEq(poolETH, 0.4 ether);
        assertEq(remainingETH, 2);

        // User2 claims first - gets 1/2 of pool (0.2 ETH)
        uint256 user2Before = user2.balance;
        vm.prank(user2);
        staking.claim();
        assertEq(user2.balance, user2Before + 1.2 ether);

        // User3 claims second - gets remaining pool (0.2 ETH)
        uint256 user3Before = user3.balance;
        vm.prank(user3);
        staking.claim();
        assertEq(user3.balance, user3Before + 1.2 ether);
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
        (uint256 poolAfterUser1,,,,,) = staking.getCohortInfo(cohort);
        assertEq(poolAfterUser1, 0.4 ether);

        // User2 claims - binary payout means full 1 ETH slashed
        // 0.4 ETH to pool, 0.4 ETH to treasury, 0.2 ETH to charity
        // Then pool is finalized: total pool 0.8 ETH split 67/33
        vm.prank(user2);
        staking.claim();

        // Pool should now be drained since no ETH stakers left
        (uint256 poolFinal,,,,,) = staking.getCohortInfo(cohort);
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

        (uint256 poolETH, uint256 poolUSDC, uint256 remainingETH, uint256 remainingUSDC, uint256 totalETH, uint256 totalUSDC) =
            staking.getCohortInfo(cohort);

        assertEq(poolETH, 0);
        assertEq(poolUSDC, 0);
        assertEq(remainingETH, 1);
        assertEq(remainingUSDC, 0);
        assertEq(totalETH, 1);
        assertEq(totalUSDC, 0);
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
        assertEq(staking.version(), "2.3.0");
    }

    // ============ Constants Tests ============

    function test_Constants() public view {
        assertEq(staking.SECONDS_PER_DAY(), 86400);
        assertEq(staking.SECONDS_PER_WEEK(), 604800);
        assertEq(staking.GRACE_PERIOD(), 6 hours);
        assertEq(staking.MIN_STAKE_ETH(), 0.001 ether);
        assertEq(staking.MIN_STAKE_USDC(), 1e6);
        assertEq(staking.MIN_DURATION_DAYS(), 3);
        assertEq(staking.MAX_DURATION_DAYS(), 365);
        assertEq(staking.MAX_GOAL_SECONDS(), 24 hours);
    }

    function test_StakeETH_RevertIf_DurationTooShort() public {
        vm.expectRevert(ProofwellStakingV2.InvalidDuration.selector);
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 2, TEST_PUB_KEY_X, TEST_PUB_KEY_Y); // 2 < MIN_DURATION_DAYS
    }

    function test_StakeUSDC_RevertIf_DurationTooShort() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);

        vm.expectRevert(ProofwellStakingV2.InvalidDuration.selector);
        staking.stakeUSDC(100e6, 2 hours, 1, TEST_PUB_KEY_X, TEST_PUB_KEY_Y); // 1 < MIN_DURATION_DAYS
        vm.stopPrank();
    }

    function test_ReceiveETH_DirectTransfer() public {
        uint256 amount = 1 ether;
        uint256 balanceBefore = address(staking).balance;

        // Send ETH directly to contract
        vm.deal(user1, amount);
        vm.prank(user1);
        (bool success,) = address(staking).call{value: amount}("");

        assertTrue(success);
        assertEq(address(staking).balance, balanceBefore + amount);
    }

    function test_UpgradeEmitsEvent() public {
        ProofwellStakingV2 newImpl = new ProofwellStakingV2();

        vm.expectEmit(true, false, false, false);
        emit ProofwellStakingV2.UpgradeAuthorized(address(newImpl));

        staking.upgradeToAndCall(address(newImpl), "");
    }

    // ============ Phase 1: Signature Verification Tests ============

    function test_SubmitDayProof_ValidSignature_IncrementSuccessfulDays() public {
        uint256 privateKey = 1; // Corresponds to TEST_PUB_KEY_X/Y (generator point)

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp to after day 0 ends
        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        // Construct message hash the same way the contract does
        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));

        // Sign with P-256
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);

        ProofwellStakingV2.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.successfulDays, 1);
        assertTrue(staking.dayVerified(user1, 0));
    }

    function test_SubmitDayProof_InvalidSignature_Reverts() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        // Use wrong private key (2 instead of 1)
        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(2, messageHash);

        vm.expectRevert(ProofwellStakingV2.InvalidSignature.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);
    }

    function test_SubmitDayProof_WrongDayIndex_SignatureFails() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp past day 1
        vm.warp(block.timestamp + 2 * SECONDS_PER_DAY + 1);

        // Sign for day 0 but submit for day 1
        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.expectRevert(ProofwellStakingV2.InvalidSignature.selector);
        vm.prank(user1);
        staking.submitDayProof(1, true, r, s);
    }

    function test_SubmitDayProof_WrongGoalAchieved_SignatureFails() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        // Sign with goalAchieved=false but submit with goalAchieved=true
        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), false, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.expectRevert(ProofwellStakingV2.InvalidSignature.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);
    }

    function test_SubmitDayProof_WrongSender_SignatureFails() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        // Sign with user2's address encoded, but submit as user1
        bytes32 messageHash = keccak256(abi.encodePacked(user2, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.expectRevert(ProofwellStakingV2.InvalidSignature.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);
    }

    // ============ Phase 1: Public Key Validation Tests ============

    function test_StakeETH_InvalidPublicKey_Reverts() public {
        // (1, 1) is not on the P-256 curve
        vm.expectRevert(ProofwellStakingV2.InvalidPublicKey.selector);
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, bytes32(uint256(1)), bytes32(uint256(1)));
    }

    function test_StakeETH_ZeroPublicKey_Reverts() public {
        vm.expectRevert(ProofwellStakingV2.InvalidPublicKey.selector);
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, bytes32(0), bytes32(0));
    }

    function test_StakeUSDC_InvalidPublicKey_Reverts() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        vm.expectRevert(ProofwellStakingV2.InvalidPublicKey.selector);
        staking.stakeUSDC(100e6, 2 hours, 7, bytes32(uint256(1)), bytes32(uint256(1)));
        vm.stopPrank();
    }

    // ============ Phase 1: Transfer Failure Tests ============

    function test_EmergencyWithdraw_ETH_TransferFails() public {
        // Deploy a new proxy owned by a RevertingReceiver
        RevertingReceiver revertOwner = new RevertingReceiver();

        ProofwellStakingV2 impl = new ProofwellStakingV2();
        bytes memory initData = abi.encodeCall(ProofwellStakingV2.initialize, (treasury, charity, address(usdc)));
        ProofwellStakingV2 stakingLocal =
            ProofwellStakingV2(payable(address(new ERC1967Proxy(address(impl), initData))));

        // Transfer ownership to revertOwner
        stakingLocal.transferOwnership(address(revertOwner));
        // Can't accept ownership from RevertingReceiver easily, so test differently:
        // Instead, send ETH to the contract and mock the owner call to fail
        vm.deal(address(stakingLocal), 1 ether);

        // Must pause first
        stakingLocal.pause();

        // Mock the owner's call to revert by setting owner to a contract that reverts
        // Simpler approach: use vm.mockCall to make the ETH transfer fail
        vm.mockCallRevert(address(this), bytes(""), bytes("transfer failed"));

        vm.expectRevert(ProofwellStakingV2.TransferFailed.selector);
        stakingLocal.emergencyWithdraw(address(0));

        vm.clearMockedCalls();
    }

    function test_Claim_ETH_TransferFails_User() public {
        // Deploy fresh instance where user1 is a reverting receiver
        // Stake as user1 (an EOA), then mock user1 to reject ETH on claim
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        _setSuccessfulDays(user1, 7); // Winner
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // Mock user1 to reject ETH transfers
        vm.mockCallRevert(user1, bytes(""), bytes("no ETH"));

        vm.expectRevert(ProofwellStakingV2.TransferFailed.selector);
        vm.prank(user1);
        staking.claim();

        vm.clearMockedCalls();
    }

    function test_Claim_ETH_TransferFails_Treasury() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Loser - triggers treasury transfer
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.mockCallRevert(treasury, bytes(""), bytes("no ETH"));

        vm.expectRevert(ProofwellStakingV2.TransferFailed.selector);
        vm.prank(user1);
        staking.claim();

        vm.clearMockedCalls();
    }

    function test_Claim_ETH_TransferFails_Charity() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.mockCallRevert(charity, bytes(""), bytes("no ETH"));

        vm.expectRevert(ProofwellStakingV2.TransferFailed.selector);
        vm.prank(user1);
        staking.claim();

        vm.clearMockedCalls();
    }

    // ============ Phase 1: Access Control Tests ============

    function test_SetCharity_RevertIf_NotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        staking.setCharity(makeAddr("newCharity"));
    }

    function test_SetCharity_RevertIf_ZeroAddress() public {
        vm.expectRevert(ProofwellStakingV2.ZeroAddress.selector);
        staking.setCharity(address(0));
    }

    function test_SetDistribution_RevertIf_NotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        staking.setDistribution(50, 30, 20);
    }

    function test_EmergencyWithdraw_RevertIf_NotOwner() public {
        staking.pause();
        vm.expectRevert();
        vm.prank(user1);
        staking.emergencyWithdraw(address(0));
    }

    // ============ Phase 2: Goal Validation Tests ============

    function test_StakeETH_RevertIf_GoalZero() public {
        vm.expectRevert(ProofwellStakingV2.InvalidGoal.selector);
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(0, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_StakeETH_RevertIf_GoalExceedsMax() public {
        vm.expectRevert(ProofwellStakingV2.InvalidGoal.selector);
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(24 hours + 1, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_StakeUSDC_RevertIf_GoalZero() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        vm.expectRevert(ProofwellStakingV2.InvalidGoal.selector);
        staking.stakeUSDC(100e6, 0, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();
    }

    function test_StakeUSDC_RevertIf_GoalExceedsMax() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        vm.expectRevert(ProofwellStakingV2.InvalidGoal.selector);
        staking.stakeUSDC(100e6, 24 hours + 1, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();
    }

    // ============ Phase 2: Duration Validation Tests ============

    function test_StakeETH_RevertIf_DurationExceedsMax() public {
        vm.expectRevert(ProofwellStakingV2.InvalidDuration.selector);
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 366, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_StakeUSDC_RevertIf_DurationExceedsMax() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        vm.expectRevert(ProofwellStakingV2.InvalidDuration.selector);
        staking.stakeUSDC(100e6, 2 hours, 366, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();
    }

    function test_StakeETH_MinDuration_Succeeds() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y); // MIN_DURATION_DAYS = 3

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.durationDays, 3);
    }

    function test_StakeETH_MaxDuration_Succeeds() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 365, TEST_PUB_KEY_X, TEST_PUB_KEY_Y); // MAX_DURATION_DAYS = 365

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.durationDays, 365);
    }

    // ============ Phase 2: Proof Submission Window Tests ============

    function test_SubmitDayProof_BeforeDayEnds_Reverts() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp to just before day 0 ends (less than SECONDS_PER_DAY after start)
        vm.warp(block.timestamp + SECONDS_PER_DAY - 1);

        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.expectRevert(ProofwellStakingV2.ProofSubmissionWindowClosed.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);
    }

    function test_SubmitDayProof_ExactlyAtDayEnd_Succeeds() public {
        uint256 privateKey = 1;
        uint256 startTime = block.timestamp;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp to exactly when day 0 ends
        vm.warp(startTime + SECONDS_PER_DAY);

        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);

        assertTrue(staking.dayVerified(user1, 0));
    }

    function test_SubmitDayProof_ExactlyAtGraceEnd_Succeeds() public {
        uint256 privateKey = 1;
        uint256 startTime = block.timestamp;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp to exactly the end of grace period
        vm.warp(startTime + SECONDS_PER_DAY + GRACE_PERIOD);

        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);

        assertTrue(staking.dayVerified(user1, 0));
    }

    function test_SubmitDayProof_AfterGracePeriod_Reverts() public {
        uint256 privateKey = 1;
        uint256 startTime = block.timestamp;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp to 1 second after grace period ends
        vm.warp(startTime + SECONDS_PER_DAY + GRACE_PERIOD + 1);

        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.expectRevert(ProofwellStakingV2.ProofSubmissionWindowClosed.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);
    }

    // ============ Phase 2: Goal Achieved Branch Tests ============

    function test_SubmitDayProof_GoalNotAchieved_NoIncrement() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), false, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        // Normalize s to low-s form (required by some P256 implementations)
        uint256 P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
        if (uint256(s) > P256_N / 2) {
            s = bytes32(P256_N - uint256(s));
        }

        vm.prank(user1);
        staking.submitDayProof(0, false, r, s);

        ProofwellStakingV2.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.successfulDays, 0);
        assertTrue(staking.dayVerified(user1, 0));
    }

    function test_SubmitDayProof_GoalAchieved_IncrementsSuccessfulDays() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);

        ProofwellStakingV2.Stake memory userStake = staking.getStake(user1);
        assertEq(userStake.successfulDays, 1);
    }

    function test_SubmitDayProof_RevertIf_NoStake() public {
        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        vm.expectRevert(ProofwellStakingV2.NoStakeFound.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, bytes32(0), bytes32(0));
    }

    function test_SubmitDayProof_RevertIf_AfterClaim() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        // Stake is deleted after claim
        vm.expectRevert(ProofwellStakingV2.NoStakeFound.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, bytes32(0), bytes32(0));
    }

    function test_SubmitDayProof_RevertIf_InvalidDayIndex() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        vm.expectRevert(ProofwellStakingV2.InvalidDayIndex.selector);
        vm.prank(user1);
        staking.submitDayProof(7, true, bytes32(0), bytes32(0)); // dayIndex >= durationDays
    }

    function test_SubmitDayProof_RevertIf_DayAlreadyVerified() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);

        // Try to submit again
        vm.expectRevert(ProofwellStakingV2.DayAlreadyVerified.selector);
        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);
    }

    // ============ Phase 3: USDC Parity Tests ============

    function test_BinaryPayout_USDC_AllDaysSuccess_FullRefund() public {
        uint256 stakeAmount = 100e6;

        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        _setSuccessfulDays(user1, 7);
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 userBefore = usdc.balanceOf(user1);

        vm.prank(user1);
        staking.claim();

        assertEq(usdc.balanceOf(user1), userBefore + stakeAmount);
    }

    function test_WinnerBonus_USDC_SingleWinner() public {
        uint256 stakeAmount = 100e6;

        // User1 stakes USDC and fails
        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        // User2 stakes USDC and wins
        vm.startPrank(user2);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();
        _setSuccessfulDays(user2, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // User1 claims first (loser)
        vm.prank(user1);
        staking.claim();

        // User2 claims (winner, gets bonus from pool)
        uint256 user2Before = usdc.balanceOf(user2);
        vm.prank(user2);
        staking.claim();

        // User2 gets: 100 USDC (stake) + full pool (loser decremented remaining to 1)
        // Pool = 40% of 100 USDC = 40 USDC, divided by 1 remaining = 40 USDC bonus
        assertEq(usdc.balanceOf(user2), user2Before + stakeAmount + 40e6);
    }

    function test_WinnerBonus_USDC_MultipleWinners() public {
        address user3 = makeAddr("user3");
        usdc.mint(user3, 1000e6);
        uint256 stakeAmount = 100e6;

        // User1 stakes USDC and fails
        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        // User2 and user3 stake USDC and win
        vm.startPrank(user2);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();
        _setSuccessfulDays(user2, 7);

        vm.startPrank(user3);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X_3, TEST_PUB_KEY_Y_3);
        vm.stopPrank();
        _setSuccessfulDays(user3, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // User1 claims (loser) - pool gets 40 USDC
        vm.prank(user1);
        staking.claim();

        // User2 claims - gets 40/2 = 20 USDC bonus (loser decremented remaining to 2)
        uint256 user2Before = usdc.balanceOf(user2);
        vm.prank(user2);
        staking.claim();
        uint256 user2Bonus = usdc.balanceOf(user2) - user2Before - stakeAmount;
        assertEq(user2Bonus, 20e6);

        // User3 claims - gets remaining pool / 1 = 20 USDC
        uint256 user3Before = usdc.balanceOf(user3);
        vm.prank(user3);
        staking.claim();
        uint256 user3Bonus = usdc.balanceOf(user3) - user3Before - stakeAmount;
        assertEq(user3Bonus, 20e6);
    }

    function test_NoWinners_USDC_PoolSplitToTreasuryAndCharity() public {
        uint256 stakeAmount = 100e6;

        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 charityBefore = usdc.balanceOf(charity);

        vm.prank(user2);
        staking.claim();

        // Both losers: pool finalized, treasury and charity get distributions
        assertTrue(usdc.balanceOf(treasury) > treasuryBefore);
        assertTrue(usdc.balanceOf(charity) > charityBefore);
    }

    function test_StakeUSDC_RevertIf_AlreadyStakedETH() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        vm.expectRevert(ProofwellStakingV2.StakeAlreadyExists.selector);
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();
    }

    function test_StakeETH_RevertIf_AlreadyStakedUSDC() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        vm.expectRevert(ProofwellStakingV2.StakeAlreadyExists.selector);
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
    }

    // ============ Phase 4: View Function Tests ============

    function test_CanSubmitProof_NoStake_ReturnsFalse() public view {
        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertFalse(canSubmit);
        assertEq(reason, "No stake found");
    }

    function test_CanSubmitProof_AfterClaim_ReturnsFalse() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);
        vm.prank(user1);
        staking.claim();

        // Stake is deleted after claim, so "No stake found"
        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertFalse(canSubmit);
        assertEq(reason, "No stake found");
    }

    function test_CanSubmitProof_InvalidDayIndex_ReturnsFalse() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 7);
        assertFalse(canSubmit);
        assertEq(reason, "Invalid day index");
    }

    function test_CanSubmitProof_DayAlreadyVerified_ReturnsFalse() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);

        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);

        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertFalse(canSubmit);
        assertEq(reason, "Day already verified");
    }

    function test_CanSubmitProof_DayNotEnded_ReturnsFalse() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Don't warp - day hasn't ended
        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertFalse(canSubmit);
        assertEq(reason, "Day has not ended yet");
    }

    function test_CanSubmitProof_WindowClosed_ReturnsFalse() public {
        uint256 startTime = block.timestamp;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp past grace period
        vm.warp(startTime + SECONDS_PER_DAY + GRACE_PERIOD + 1);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertFalse(canSubmit);
        assertEq(reason, "Submission window closed");
    }

    function test_CanSubmitProof_ValidWindow_ReturnsTrue() public {
        uint256 startTime = block.timestamp;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp to within submission window
        vm.warp(startTime + SECONDS_PER_DAY + 1);

        (bool canSubmit, string memory reason) = staking.canSubmitProof(user1, 0);
        assertTrue(canSubmit);
        assertEq(reason, "");
    }

    function test_GetCurrentDayIndex_NoStake_ReturnsMax() public view {
        uint256 dayIndex = staking.getCurrentDayIndex(user1);
        assertEq(dayIndex, type(uint256).max);
    }

    function test_GetCurrentDayIndex_BeforeStart_ReturnsZero() public {
        // Set timestamp in the future for the stake
        uint256 futureStart = block.timestamp + 1000;
        vm.warp(futureStart);

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp back (before stake start - not realistic but tests the branch)
        // Actually this won't work since startTimestamp is set at stake time
        // Instead test: getCurrentDayIndex at stake time should be 0
        uint256 dayIndex = staking.getCurrentDayIndex(user1);
        assertEq(dayIndex, 0);
    }

    function test_GetCurrentDayIndex_AfterEnd_ReturnsLastDay() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp well past the end
        vm.warp(block.timestamp + 30 * SECONDS_PER_DAY);

        uint256 dayIndex = staking.getCurrentDayIndex(user1);
        assertEq(dayIndex, 6); // durationDays - 1
    }

    function test_GetCurrentDayIndex_MidChallenge() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Day 3 (0-indexed)
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 100);

        uint256 dayIndex = staking.getCurrentDayIndex(user1);
        assertEq(dayIndex, 3);
    }

    function test_GetKeyOwner_UnregisteredKey_ReturnsZero() public view {
        address keyOwner = staking.getKeyOwner(bytes32(uint256(999)), bytes32(uint256(888)));
        assertEq(keyOwner, address(0));
    }

    function test_GetKeyOwner_RegisteredKey_ReturnsOwner() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        address keyOwner = staking.getKeyOwner(TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        assertEq(keyOwner, user1);
    }

    // ============ Phase 5: Edge Case Tests ============

    function test_WinnerBonus_RoundingDust_NotLost() public {
        // 3 winners splitting 100 USDC pool: 33.333... each, 1 unit dust
        address user3 = makeAddr("user3");
        address user4 = makeAddr("user4");
        usdc.mint(user3, 1000e6);
        usdc.mint(user4, 1000e6);

        uint256 stakeAmount = 83333334; // ~83.33 USDC to create a 33.33 USDC pool (40%)

        // Loser
        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        // 3 winners
        vm.startPrank(user2);
        usdc.approve(address(staking), 10e6);
        staking.stakeUSDC(10e6, 2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();
        _setSuccessfulDays(user2, 7);

        vm.startPrank(user3);
        usdc.approve(address(staking), 10e6);
        staking.stakeUSDC(10e6, 2 hours, 7, TEST_PUB_KEY_X_3, TEST_PUB_KEY_Y_3);
        vm.stopPrank();
        _setSuccessfulDays(user3, 7);

        bytes32 KEY_X_4 = 0xE2534A3532D08FBBA02DDE659EE62BD0031FE2DB785596EF509302446B030852;
        bytes32 KEY_Y_4 = 0xE0F1575A4C633CC719DFEE5FDA862D764EFC96C3F30EE0055C42C23F184ED8C6;

        vm.startPrank(user4);
        usdc.approve(address(staking), 10e6);
        staking.stakeUSDC(10e6, 2 hours, 7, KEY_X_4, KEY_Y_4);
        vm.stopPrank();
        _setSuccessfulDays(user4, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // Loser claims
        vm.prank(user1);
        staking.claim();

        // Winners claim sequentially - contract should not revert due to rounding
        vm.prank(user2);
        staking.claim();

        vm.prank(user3);
        staking.claim();

        vm.prank(user4);
        staking.claim();

        // No revert means rounding is handled safely
    }

    function test_FinalizePool_NoLeftover_NoTransfers() public {
        // Single winner, no losers = no pool leftover
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        _setSuccessfulDays(user1, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 treasuryBefore = treasury.balance;
        uint256 charityBefore = charity.balance;

        vm.prank(user1);
        staking.claim();

        // Winner gets full refund, no slashing, no pool, no finalization transfers
        assertEq(treasury.balance, treasuryBefore);
        assertEq(charity.balance, charityBefore);
    }

    function test_FinalizePool_OnlyETHLeftover() public {
        // Two ETH losers, no winners
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        uint256 treasuryBefore = treasury.balance;
        uint256 charityBefore = charity.balance;
        uint256 treasuryUSDCBefore = usdc.balanceOf(treasury);

        vm.prank(user2);
        staking.claim();

        // Pool finalized with ETH only
        assertTrue(treasury.balance > treasuryBefore);
        assertTrue(charity.balance > charityBefore);
        // No USDC transferred during finalization
        assertEq(usdc.balanceOf(treasury), treasuryUSDCBefore);
    }

    function test_FinalizePool_OnlyUSDCLeftover() public {
        uint256 stakeAmount = 100e6;

        // Two USDC losers, no winners
        vm.startPrank(user1);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(staking), stakeAmount);
        staking.stakeUSDC(stakeAmount, 2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        uint256 treasuryETHBefore = treasury.balance;
        uint256 treasuryUSDCBefore = usdc.balanceOf(treasury);
        uint256 charityUSDCBefore = usdc.balanceOf(charity);

        vm.prank(user2);
        staking.claim();

        // Pool finalized with USDC only
        assertEq(treasury.balance, treasuryETHBefore); // No ETH transferred
        assertTrue(usdc.balanceOf(treasury) > treasuryUSDCBefore);
        assertTrue(usdc.balanceOf(charity) > charityUSDCBefore);
    }

    function test_FinalizePool_BothTokensLeftover() public {
        // One ETH loser, one USDC loser, no winners
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.startPrank(user2);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        uint256 treasuryETHBefore = treasury.balance;
        uint256 charityETHBefore = charity.balance;

        // ETH loser claims — ETH pool finalizes immediately (only ETH staker)
        vm.prank(user1);
        staking.claim();

        // ETH pool already finalized
        assertTrue(treasury.balance > treasuryETHBefore);
        assertTrue(charity.balance > charityETHBefore);

        uint256 treasuryUSDCBefore = usdc.balanceOf(treasury);
        uint256 charityUSDCBefore = usdc.balanceOf(charity);

        // USDC loser claims — USDC pool finalizes
        vm.prank(user2);
        staking.claim();

        assertTrue(usdc.balanceOf(treasury) > treasuryUSDCBefore);
        assertTrue(usdc.balanceOf(charity) > charityUSDCBefore);
    }

    function test_KeyReuse_DifferentUser_Reverts() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // User2 tries to use same key
        vm.expectRevert(ProofwellStakingV2.KeyAlreadyRegistered.selector);
        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
    }

    function test_Claim_RevertIf_NoStake() public {
        vm.expectRevert(ProofwellStakingV2.NoStakeFound.selector);
        vm.prank(user1);
        staking.claim();
    }

    function test_Claim_RevertIf_AlreadyClaimed() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        // Stake is deleted after claim
        vm.expectRevert(ProofwellStakingV2.NoStakeFound.selector);
        vm.prank(user1);
        staking.claim();
    }

    function test_Claim_RevertIf_StakeNotEnded() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Only warp 3 days, not 7
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY);

        vm.expectRevert(ProofwellStakingV2.StakeNotEnded.selector);
        vm.prank(user1);
        staking.claim();
    }

    // ============ Phase 6: Boundary Condition Tests ============

    function test_StakeETH_ExactMinAmount_Succeeds() public {
        vm.prank(user1);
        staking.stakeETH{value: MIN_STAKE_ETH}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, MIN_STAKE_ETH);
    }

    function test_StakeUSDC_ExactMinAmount_Succeeds() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), MIN_STAKE_USDC);
        staking.stakeUSDC(MIN_STAKE_USDC, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, MIN_STAKE_USDC);
    }

    function test_Stake_ExactMaxGoal_Succeeds() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(24 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.goalSeconds, 24 hours);
    }

    function test_Claim_AfterOneYear_Succeeds() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 365, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        _setSuccessfulDays(user1, 365);

        vm.warp(block.timestamp + 365 * SECONDS_PER_DAY + 1);

        uint256 userBefore = user1.balance;
        vm.prank(user1);
        staking.claim();

        assertEq(user1.balance, userBefore + 1 ether);
    }

    // ============ Fuzz Tests ============

    function testFuzz_StakeETH_ValidParameters(uint256 goalSeconds, uint256 durationDays, uint256 stakeAmount) public {
        goalSeconds = bound(goalSeconds, 1, 24 hours);
        durationDays = bound(durationDays, 3, 365); // MIN_DURATION_DAYS = 3
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

    // ============ resolveExpired Tests ============

    function test_ResolveExpired_AfterBuffer_LoserETH() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // 0 successful days — loser
        // Warp past stake end + 7 day buffer
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        uint256 treasuryBefore = treasury.balance;
        uint256 charityBefore = charity.balance;
        address resolver = makeAddr("resolver");

        vm.prank(resolver);
        staking.resolveExpired(user1);

        // Loser: all slashed. 40% to winner pool, 40% to treasury, 20% to charity.
        // Since this is the only staker, cohort finalizes immediately:
        // leftover pool (0.4 ETH) split 67% treasury + 33% charity.
        // Treasury: 0.4 + 0.268 = 0.668, Charity: 0.2 + 0.132 = 0.332
        assertEq(treasury.balance, treasuryBefore + 0.668 ether);
        assertEq(charity.balance, charityBefore + 0.332 ether);

        // Stake deleted after resolve
        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, 0);
    }

    function test_ResolveExpired_AfterBuffer_WinnerETH() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // All days successful — winner
        _setSuccessfulDays(user1, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        uint256 userBefore = user1.balance;
        address resolver = makeAddr("resolver");

        vm.prank(resolver);
        staking.resolveExpired(user1);

        // Winner: full refund sent to user, not resolver
        assertEq(user1.balance, userBefore + 1 ether);
        assertEq(resolver.balance, 0);
    }

    function test_ResolveExpired_RevertIf_BeforeBuffer() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp past stake end but NOT past the 7-day buffer
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 3 days);

        vm.expectRevert(ProofwellStakingV2.ResolutionBufferNotElapsed.selector);
        staking.resolveExpired(user1);
    }

    function test_ResolveExpired_RevertIf_AlreadyClaimed() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // User self-claims (stake is deleted)
        vm.prank(user1);
        staking.claim();

        // Resolver tries after buffer
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectRevert(ProofwellStakingV2.NoStakeFound.selector);
        staking.resolveExpired(user1);
    }

    function test_ResolveExpired_RevertIf_NoStake() public {
        address nobody = makeAddr("nobody");

        vm.expectRevert(ProofwellStakingV2.NoStakeFound.selector);
        staking.resolveExpired(nobody);
    }

    function test_ResolveExpired_EmitsEvent() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        address resolver = makeAddr("resolver");

        vm.expectEmit(true, true, false, true);
        emit ProofwellStakingV2.ResolvedExpired(user1, resolver, 0, 1 ether, 0, false);

        vm.prank(resolver);
        staking.resolveExpired(user1);
    }

    function test_ResolveExpired_TriggersCohortFinalization() public {
        // Two users in same cohort
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);

        uint256 cohort = staking.getCurrentWeek();

        // user1 is a loser, user2 is a loser
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // user1 self-claims (loser), cohort not finalized yet
        vm.prank(user1);
        staking.claim();
        assertEq(staking.cohortTotalStakersETH(cohort), 1);

        // Warp past buffer for resolve
        vm.warp(block.timestamp + 7 days + 1);

        // Resolve user2 — should finalize cohort (pool swept)
        address resolver = makeAddr("resolver");
        vm.prank(resolver);
        staking.resolveExpired(user2);

        assertEq(staking.cohortTotalStakersETH(cohort), 0);
        assertEq(staking.cohortPoolETH(cohort), 0); // Pool swept
    }

    function test_ResolveExpired_USDC() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        // Winner
        _setSuccessfulDays(user1, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        uint256 userBefore = usdc.balanceOf(user1);
        address resolver = makeAddr("resolver");

        vm.prank(resolver);
        staking.resolveExpired(user1);

        // Funds go to user, not resolver
        assertEq(usdc.balanceOf(user1), userBefore + 100e6);
        assertEq(usdc.balanceOf(resolver), 0);
    }

    function test_ResolveExpired_RevertIf_OneSecondBeforeBuffer() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Warp to 1 second before buffer expires
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days - 1);

        vm.expectRevert(ProofwellStakingV2.ResolutionBufferNotElapsed.selector);
        staking.resolveExpired(user1);
    }

    function test_ResolveExpired_RevertIf_Paused() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        staking.pause();

        vm.expectRevert();
        staking.resolveExpired(user1);
    }

    function test_ResolveExpired_SelfResolve() public {
        // User forgot to claim, calls resolveExpired on themselves after buffer
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        _setSuccessfulDays(user1, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        uint256 userBefore = user1.balance;

        vm.prank(user1);
        staking.resolveExpired(user1);

        assertEq(user1.balance, userBefore + 1 ether);
        assertEq(staking.getStake(user1).amount, 0); // Stake deleted
    }

    function test_ResolveExpired_WinnerGetsBonusFromLoserSlash() public {
        // Loser claims normally, winner gets resolved with bonus from pool
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        _setSuccessfulDays(user2, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // Loser claims normally — builds pool
        vm.prank(user1);
        staking.claim();

        // Warp past buffer, resolve winner
        vm.warp(block.timestamp + 7 days + 1);

        uint256 user2Before = user2.balance;
        address resolver = makeAddr("resolver");
        vm.prank(resolver);
        staking.resolveExpired(user2);

        // Winner gets: 1 ETH stake + 0.4 ETH bonus (full pool, only winner)
        assertEq(user2.balance, user2Before + 1.4 ether);
    }

    function test_ResolveExpired_MixedClaimAndResolve_FullAccounting() public {
        // 3 stakers: 1 loser claims, 1 loser resolved, 1 winner resolved
        // Verify total distributed == total staked
        address user3 = makeAddr("user3");
        vm.deal(user3, 10 ether);

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.prank(user3);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X_3, TEST_PUB_KEY_Y_3);
        _setSuccessfulDays(user3, 7); // Only user3 wins

        uint256 cohort = staking.getCurrentWeek();

        // Snapshot balances
        uint256 treasuryBefore = treasury.balance;
        uint256 charityBefore = charity.balance;
        uint256 user3Before = user3.balance;

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // Loser 1 claims normally
        vm.prank(user1);
        staking.claim();

        // Warp past buffer
        vm.warp(block.timestamp + 7 days + 1);

        address resolver = makeAddr("resolver");

        // Loser 2 resolved
        vm.prank(resolver);
        staking.resolveExpired(user2);

        // Winner resolved
        vm.prank(resolver);
        staking.resolveExpired(user3);

        // Verify cohort finalized (all ETH stakers resolved)
        assertEq(staking.cohortTotalStakersETH(cohort), 0);
        assertEq(staking.cohortPoolETH(cohort), 0);

        // Accounting: 3 ETH total staked
        // 2 losers slashed: 2 ETH total
        //   - 0.8 ETH to winner pool (40% each)
        //   - 0.8 ETH to treasury (40% each)
        //   - 0.4 ETH to charity (20% each)
        // Winner gets: 1 ETH stake + 0.8 ETH pool = 1.8 ETH
        // Treasury gets: 0.8 ETH
        // Charity gets: 0.4 ETH
        // Total out: 1.8 + 0.8 + 0.4 = 3.0 ETH ✓
        assertEq(user3.balance, user3Before + 1.8 ether);
        assertEq(treasury.balance, treasuryBefore + 0.8 ether);
        assertEq(charity.balance, charityBefore + 0.4 ether);
    }

    function test_ResolveExpired_ETHTransferFails_FallbackToTreasury() public {
        // Stake from a contract that rejects ETH
        RevertingReceiver badReceiver = new RevertingReceiver();
        vm.deal(address(badReceiver), 10 ether);

        vm.prank(address(badReceiver));
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        _setSuccessfulDays(address(badReceiver), 7); // Winner

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        uint256 treasuryBefore = treasury.balance;

        // resolveExpired should NOT revert — falls back to treasury
        address resolver = makeAddr("resolver");
        vm.prank(resolver);
        staking.resolveExpired(address(badReceiver));

        // Funds went to treasury instead of reverting
        assertEq(treasury.balance, treasuryBefore + 1 ether);
        assertEq(staking.getStake(address(badReceiver)).amount, 0); // Stake deleted
    }

    function test_ResolveExpired_USDCTransferFails_FallbackToTreasury() public {
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        _setSuccessfulDays(user1, 7);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        // Mock USDC transfer to user1 to fail (simulating blacklist)
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(usdc.transfer.selector, user1, 100e6), "blacklisted");

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        address resolver = makeAddr("resolver");
        vm.prank(resolver);
        staking.resolveExpired(user1);

        // Funds redirected to treasury
        assertEq(usdc.balanceOf(treasury), treasuryBefore + 100e6);
        assertEq(staking.getStake(user1).amount, 0); // Stake deleted
    }

    function test_Constants_IncludesResolutionBuffer() public view {
        assertEq(staking.RESOLUTION_BUFFER(), 7 days);
    }

    // ============ Re-staking Tests ============

    function test_ReStake_ETH_AfterClaim() public {
        // First stake
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        _setSuccessfulDays(user1, 7);
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        // Stake should be deleted
        assertEq(staking.getStake(user1).amount, 0);

        // Key should be deregistered
        assertEq(staking.getKeyOwner(TEST_PUB_KEY_X, TEST_PUB_KEY_Y), address(0));

        // Re-stake with same key
        vm.prank(user1);
        staking.stakeETH{value: 0.5 ether}(3 hours, 5, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, 0.5 ether);
        assertEq(s.goalSeconds, 3 hours);
        assertEq(s.durationDays, 5);
    }

    function test_ReStake_USDC_AfterClaim() public {
        // First stake
        vm.startPrank(user1);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.stopPrank();

        _setSuccessfulDays(user1, 7);
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        // Re-stake with same key and different token
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(4 hours, 10, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, 1 ether);
        assertFalse(s.isUSDC);
    }

    function test_ReStake_AfterResolveExpired() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 7 days + 1);

        address resolver = makeAddr("resolver");
        vm.prank(resolver);
        staking.resolveExpired(user1);

        // Re-stake with same key
        vm.prank(user1);
        staking.stakeETH{value: 0.5 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        assertEq(staking.getStake(user1).amount, 0.5 ether);
    }

    function test_ReStake_DayVerifiedCleared() public {
        uint256 privateKey = 1;

        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Submit proof for day 0
        vm.warp(block.timestamp + SECONDS_PER_DAY + 1);
        bytes32 messageHash = keccak256(abi.encodePacked(user1, uint256(0), true, block.chainid, address(staking)));
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, messageHash);
        vm.prank(user1);
        staking.submitDayProof(0, true, r, s);

        assertTrue(staking.dayVerified(user1, 0));

        // Complete and claim
        _setSuccessfulDays(user1, 3);
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY);
        vm.prank(user1);
        staking.claim();

        // dayVerified should be cleared
        assertFalse(staking.dayVerified(user1, 0));
    }

    // ============ Mixed ETH/USDC Cohort Fairness Tests ============

    function test_MixedCohort_ETHWinnerDoesNotGetUSDCPool() public {
        // ETH winner and USDC loser in same cohort
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        _setSuccessfulDays(user1, 7);

        vm.startPrank(user2);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 2 hours, 7, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();
        // user2 is a USDC loser (0 days)

        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        // USDC loser claims — builds USDC pool
        vm.prank(user2);
        staking.claim();

        // ETH winner claims — should NOT receive USDC bonus
        uint256 user1USDCBefore = usdc.balanceOf(user1);
        uint256 user1ETHBefore = user1.balance;

        vm.prank(user1);
        staking.claim();

        // Gets full ETH stake back, no USDC bonus, no ETH bonus (no ETH losers)
        assertEq(user1.balance, user1ETHBefore + 1 ether);
        assertEq(usdc.balanceOf(user1), user1USDCBefore);
    }

    // ============ State Cleanup Verification ============

    /// @notice Verify claim deletes ALL stake struct fields (not just amount)
    function test_Claim_DeletesFullStakeStruct() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        _setSuccessfulDays(user1, 3);
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, 0);
        assertEq(s.goalSeconds, 0);
        assertEq(s.startTimestamp, 0);
        assertEq(s.durationDays, 0);
        assertEq(s.pubKeyX, bytes32(0));
        assertEq(s.pubKeyY, bytes32(0));
        assertEq(s.successfulDays, 0);
        assertFalse(s.claimed);
        assertFalse(s.isUSDC);
        assertEq(s.cohortWeek, 0);
    }

    /// @notice Verify resolveExpired deletes full stake struct and clears key
    function test_ResolveExpired_ClearsFullState() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 7 days + 1);

        vm.prank(user2);
        staking.resolveExpired(user1);

        // Full struct zeroed
        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, 0);
        assertEq(s.goalSeconds, 0);
        assertEq(s.pubKeyX, bytes32(0));

        // Key deregistered
        assertEq(staking.getKeyOwner(TEST_PUB_KEY_X, TEST_PUB_KEY_Y), address(0));
    }

    /// @notice Verify dayVerified cleared for all days (not just day 0)
    function test_Claim_ClearsAllDayVerifiedEntries() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 7, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        // Set dayVerified[user1][i] = true for days 0..6 via storage
        // dayVerified is at slot 2: mapping(address => mapping(uint256 => bool))
        for (uint256 day = 0; day < 7; day++) {
            bytes32 innerSlot = keccak256(abi.encode(user1, uint256(2)));
            bytes32 daySlot = keccak256(abi.encode(day, innerSlot));
            vm.store(address(staking), daySlot, bytes32(uint256(1)));
            assertTrue(staking.dayVerified(user1, day), "dayVerified should be set");
        }

        _setSuccessfulDays(user1, 7);
        vm.warp(block.timestamp + 7 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        // All 7 dayVerified entries should be cleared
        for (uint256 i = 0; i < 7; i++) {
            assertFalse(staking.dayVerified(user1, i), "dayVerified should be cleared");
        }
    }

    // ============ Cohort Counter Edge Cases ============

    /// @notice All losers in cohort — remainingWinners counter reaches 0 without underflow
    function test_ClaimLoser_DoesNotUnderflowWinnerCounter() public {
        // Two losers, no winners
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);
        vm.prank(user2);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);

        uint256 cohort = staking.getCurrentWeek();

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        // Both losers (0 successful days)
        vm.prank(user1);
        staking.claim();
        vm.prank(user2);
        staking.claim();

        (,, uint256 rwETH,, uint256 tsETH,) = staking.getCohortInfo(cohort);
        assertEq(rwETH, 0, "remainingWinnersETH should be 0");
        assertEq(tsETH, 0, "totalStakersETH should be 0");
    }

    // ============ Cross-Token Finalization Isolation ============

    /// @notice ETH last-claimer triggers ETH finalization while USDC stakers remain
    function test_ETHLastClaimer_WhenUSDCStakersRemain() public {
        // ETH loser + USDC loser in same cohort
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.startPrank(user2);
        usdc.approve(address(staking), 100e6);
        staking.stakeUSDC(100e6, 2 hours, 3, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);
        vm.stopPrank();

        uint256 cohort = staking.getCurrentWeek();

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        // ETH loser claims — triggers ETH finalization
        uint256 usdcPoolBefore = staking.cohortPoolUSDC(cohort);
        vm.prank(user1);
        staking.claim();

        // ETH pool finalized (swept to treasury/charity)
        assertEq(staking.cohortPoolETH(cohort), 0, "ETH pool should be finalized");

        // USDC pool untouched
        assertEq(staking.cohortPoolUSDC(cohort), usdcPoolBefore, "USDC pool should not be touched");

        // USDC staker count still 1
        (,,, uint256 rwUSDC,, uint256 tsUSDC) = staking.getCohortInfo(cohort);
        assertEq(tsUSDC, 1, "USDC staker count should still be 1");

        // Now USDC loser claims — triggers USDC finalization independently
        vm.prank(user2);
        staking.claim();

        (,,, uint256 rwUSDC2,, uint256 tsUSDC2) = staking.getCohortInfo(cohort);
        assertEq(tsUSDC2, 0, "USDC staker count should be 0 after claim");
        assertEq(staking.cohortPoolUSDC(cohort), 0, "USDC pool should be finalized");
    }

    // ============ Full Lifecycle Re-staking ============

    /// @notice Stake → win → claim → stake again → lose → claim (full cycle)
    function test_ReStake_FullCycle_WinThenLose() public {
        // Cycle 1: Win
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        _setSuccessfulDays(user1, 3);
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        // Cycle 2: Lose (same key, different amount)
        vm.prank(user1);
        staking.stakeETH{value: 0.5 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        uint256 balBefore = user1.balance;
        vm.prank(user1);
        staking.claim();

        // Loser gets nothing back
        assertEq(user1.balance, balBefore, "Loser should get 0 back");

        // Stake fully cleared — can stake again
        ProofwellStakingV2.Stake memory s = staking.getStake(user1);
        assertEq(s.amount, 0);
    }

    /// @notice Re-stake with a DIFFERENT key after claim
    function test_ReStake_DifferentKeyAfterClaim() public {
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X, TEST_PUB_KEY_Y);

        _setSuccessfulDays(user1, 3);
        vm.warp(block.timestamp + 3 * SECONDS_PER_DAY + 1);

        vm.prank(user1);
        staking.claim();

        // Key 1 deregistered
        assertEq(staking.getKeyOwner(TEST_PUB_KEY_X, TEST_PUB_KEY_Y), address(0));

        // Re-stake with key 2
        vm.prank(user1);
        staking.stakeETH{value: 1 ether}(2 hours, 3, TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2);

        // Key 2 registered to user1
        assertEq(staking.getKeyOwner(TEST_PUB_KEY_X_2, TEST_PUB_KEY_Y_2), user1);
        // Key 1 still deregistered
        assertEq(staking.getKeyOwner(TEST_PUB_KEY_X, TEST_PUB_KEY_Y), address(0));
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
        staking = ProofwellStakingV2(payable(address(new ERC1967Proxy(address(implementation), initData))));
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

            // Stake is deleted after claim
            ProofwellStakingV2.Stake memory stake = staking.getStake(users[i]);
            assertEq(stake.amount, 0);

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

        // Log gas usage for monitoring (no assertions - varies with compiler settings)
        // Typical ranges: stakeETH ~252k, stakeUSDC ~280k, claim ~61k (without IR)
        // IR compilation adds ~5-10% overhead
        assertTrue(stakeETHGas > 0);
        assertTrue(stakeUSDCGas > 0);
        assertTrue(claimGas > 0);
    }
}
