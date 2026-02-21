// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProofwellStakingV2} from "./ProofwellStakingV2.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";

/// @title ProofwellStakingV3
/// @notice Multi-stake upgrade — users can have multiple concurrent stakes
/// @dev Inherits V2 storage layout and consumes 4 gap slots for new state
contract ProofwellStakingV3 is ProofwellStakingV2 {
    using SafeERC20 for IERC20;

    // ============ New Errors ============
    error TooManyActiveStakes();
    error StakeNotFound();

    // ============ New Events ============
    event StakedETHV3(
        address indexed user,
        uint256 indexed stakeId,
        uint256 amount,
        uint256 goalSeconds,
        uint256 durationDays,
        uint256 startTimestamp,
        uint256 cohortWeek
    );
    event StakedUSDCV3(
        address indexed user,
        uint256 indexed stakeId,
        uint256 amount,
        uint256 goalSeconds,
        uint256 durationDays,
        uint256 startTimestamp,
        uint256 cohortWeek
    );
    event DayProofSubmittedV3(address indexed user, uint256 indexed stakeId, uint256 dayIndex, bool goalAchieved);
    event ClaimedV3(
        address indexed user,
        uint256 indexed stakeId,
        uint256 amountReturned,
        uint256 amountSlashed,
        uint256 winnerBonus,
        bool isUSDC
    );
    event ResolvedExpiredV3(
        address indexed user,
        uint256 indexed stakeId,
        address indexed resolver,
        uint256 amountReturned,
        uint256 amountSlashed,
        uint256 winnerBonus,
        bool isUSDC
    );

    // ============ New Constants ============
    uint256 public constant MAX_ACTIVE_STAKES = 10;

    // ============ New Storage (consuming __gap slots 0-3) ============
    // These overlay the first 4 slots of V2's `uint256[46] private __gap`

    /// @dev Per-user monotonic counter for stake IDs
    mapping(address => uint256) public nextStakeId; // gap[0]

    /// @dev Multi-stake storage: user => stakeId => Stake
    mapping(address => mapping(uint256 => Stake)) public stakesV3; // gap[1]

    /// @dev 3D day verification: user => stakeId => dayIndex => verified
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public dayVerifiedV3; // gap[2]

    /// @dev Active stake count per user (for MAX_ACTIVE_STAKES enforcement)
    mapping(address => uint256) public activeStakeCount; // gap[3]

    /// @dev Remaining gap slots: 46 - 4 = 42
    uint256[42] private __gapV3;

    // ============ V3 Initializer ============

    /// @notice Initialize V3 — bumps reinitializer version
    function initializeV3() public reinitializer(2) {
        // No new state to set — nextStakeId, activeStakeCount default to 0
    }

    // ============ V3 Stake Functions ============

    /// @notice Stake ETH with multi-stake support
    /// @return stakeId The assigned stake ID
    function stakeETHV3(uint256 goalSeconds, uint256 durationDays, bytes32 pubKeyX, bytes32 pubKeyY)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 stakeId)
    {
        if (activeStakeCount[msg.sender] >= MAX_ACTIVE_STAKES) revert TooManyActiveStakes();
        if (goalSeconds == 0 || goalSeconds > MAX_GOAL_SECONDS) revert InvalidGoal();
        if (durationDays < MIN_DURATION_DAYS || durationDays > MAX_DURATION_DAYS) revert InvalidDuration();
        if (msg.value < MIN_STAKE_ETH) revert InsufficientStake();

        _validateAndRegisterKeyV3(pubKeyX, pubKeyY);

        stakeId = nextStakeId[msg.sender]++;
        uint256 cohortWeek = block.timestamp / SECONDS_PER_WEEK;

        stakesV3[msg.sender][stakeId] = Stake({
            amount: msg.value,
            goalSeconds: goalSeconds,
            startTimestamp: block.timestamp,
            durationDays: durationDays,
            pubKeyX: pubKeyX,
            pubKeyY: pubKeyY,
            successfulDays: 0,
            claimed: false,
            isUSDC: false,
            cohortWeek: cohortWeek
        });

        activeStakeCount[msg.sender]++;
        cohortTotalStakersETH[cohortWeek]++;
        cohortRemainingWinnersETH[cohortWeek]++;

        emit StakedETHV3(msg.sender, stakeId, msg.value, goalSeconds, durationDays, block.timestamp, cohortWeek);
    }

    /// @notice Stake USDC with multi-stake support
    /// @return stakeId The assigned stake ID
    function stakeUSDCV3(uint256 amount, uint256 goalSeconds, uint256 durationDays, bytes32 pubKeyX, bytes32 pubKeyY)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 stakeId)
    {
        if (activeStakeCount[msg.sender] >= MAX_ACTIVE_STAKES) revert TooManyActiveStakes();
        if (goalSeconds == 0 || goalSeconds > MAX_GOAL_SECONDS) revert InvalidGoal();
        if (durationDays < MIN_DURATION_DAYS || durationDays > MAX_DURATION_DAYS) revert InvalidDuration();
        if (amount < MIN_STAKE_USDC) revert InsufficientStake();

        _validateAndRegisterKeyV3(pubKeyX, pubKeyY);

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        stakeId = nextStakeId[msg.sender]++;
        uint256 cohortWeek = block.timestamp / SECONDS_PER_WEEK;

        stakesV3[msg.sender][stakeId] = Stake({
            amount: amount,
            goalSeconds: goalSeconds,
            startTimestamp: block.timestamp,
            durationDays: durationDays,
            pubKeyX: pubKeyX,
            pubKeyY: pubKeyY,
            successfulDays: 0,
            claimed: false,
            isUSDC: true,
            cohortWeek: cohortWeek
        });

        activeStakeCount[msg.sender]++;
        cohortTotalStakersUSDC[cohortWeek]++;
        cohortRemainingWinnersUSDC[cohortWeek]++;

        emit StakedUSDCV3(msg.sender, stakeId, amount, goalSeconds, durationDays, block.timestamp, cohortWeek);
    }

    // ============ V3 Proof Submission ============

    /// @notice Submit proof for a specific day on a specific stake
    function submitDayProofV3(uint256 stakeId, uint256 dayIndex, bool goalAchieved, bytes32 r, bytes32 s)
        external
        nonReentrant
        whenNotPaused
    {
        Stake storage userStake = stakesV3[msg.sender][stakeId];
        if (userStake.amount == 0) revert StakeNotFound();
        if (dayIndex >= userStake.durationDays) revert InvalidDayIndex();
        if (dayVerifiedV3[msg.sender][stakeId][dayIndex]) revert DayAlreadyVerified();

        uint256 dayEndTimestamp = userStake.startTimestamp + ((dayIndex + 1) * SECONDS_PER_DAY);
        uint256 windowEnd = dayEndTimestamp + GRACE_PERIOD;

        if (block.timestamp < dayEndTimestamp) revert ProofSubmissionWindowClosed();
        if (block.timestamp > windowEnd) revert ProofSubmissionWindowClosed();

        // V3 message hash includes stakeId between msg.sender and dayIndex
        bytes32 messageHash =
            keccak256(abi.encodePacked(msg.sender, stakeId, dayIndex, goalAchieved, block.chainid, address(this)));

        bool valid = P256.verify(messageHash, r, s, userStake.pubKeyX, userStake.pubKeyY);
        if (!valid) revert InvalidSignature();

        dayVerifiedV3[msg.sender][stakeId][dayIndex] = true;

        if (goalAchieved) {
            userStake.successfulDays++;
        }

        emit DayProofSubmittedV3(msg.sender, stakeId, dayIndex, goalAchieved);
    }

    // ============ V3 Claim ============

    /// @notice Claim a specific stake after its duration ends
    function claimV3(uint256 stakeId) external nonReentrant whenNotPaused {
        Stake storage userStake = stakesV3[msg.sender][stakeId];
        if (userStake.amount == 0) revert StakeNotFound();

        uint256 stakeEndTimestamp = userStake.startTimestamp + (userStake.durationDays * SECONDS_PER_DAY);
        if (block.timestamp < stakeEndTimestamp) revert StakeNotEnded();

        (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC_) =
            _processClaimV3(msg.sender, stakeId);

        if (amountReturned > 0) {
            _transferFunds(msg.sender, amountReturned, isUSDC_);
        }

        emit ClaimedV3(msg.sender, stakeId, amountReturned, amountSlashed, winnerBonus, isUSDC_);
    }

    /// @notice Resolve an expired stake for a user who hasn't claimed
    function resolveExpiredV3(address user, uint256 stakeId) external nonReentrant whenNotPaused {
        Stake storage userStake = stakesV3[user][stakeId];
        if (userStake.amount == 0) revert StakeNotFound();

        uint256 stakeEndTimestamp = userStake.startTimestamp + (userStake.durationDays * SECONDS_PER_DAY);
        if (block.timestamp < stakeEndTimestamp + RESOLUTION_BUFFER) revert ResolutionBufferNotElapsed();

        (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC_) =
            _processClaimV3(user, stakeId);

        if (amountReturned > 0) {
            if (!_tryTransferFunds(user, amountReturned, isUSDC_)) {
                _transferFunds(treasury, amountReturned, isUSDC_);
            }
        }

        emit ResolvedExpiredV3(user, stakeId, msg.sender, amountReturned, amountSlashed, winnerBonus, isUSDC_);
    }

    // ============ V3 Internal Functions ============

    /// @dev V3 key validation: allows same user to reuse their key, blocks cross-user reuse
    function _validateAndRegisterKeyV3(bytes32 pubKeyX, bytes32 pubKeyY) internal {
        if (!P256.isValidPublicKey(pubKeyX, pubKeyY)) revert InvalidPublicKey();

        bytes32 keyHash = keccak256(abi.encodePacked(pubKeyX, pubKeyY));
        address existing = registeredKeys[keyHash];

        // Allow if unregistered or registered by the same user
        if (existing != address(0) && existing != msg.sender) revert KeyAlreadyRegistered();

        registeredKeys[keyHash] = msg.sender;
    }

    /// @dev Shared claim logic for V3 stakes
    function _processClaimV3(address user, uint256 stakeId)
        internal
        returns (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC_)
    {
        Stake storage userStake = stakesV3[user][stakeId];

        // Cache values
        uint256 totalAmount = userStake.amount;
        uint256 successfulDays = userStake.successfulDays;
        uint256 durationDays_ = userStake.durationDays;
        uint256 cohort = userStake.cohortWeek;
        isUSDC_ = userStake.isUSDC;

        // Effects: clear stake state (do NOT delete registeredKeys — key stays permanently registered)
        for (uint256 i = 0; i < durationDays_; i++) {
            delete dayVerifiedV3[user][stakeId][i];
        }
        delete stakesV3[user][stakeId];
        activeStakeCount[user]--;

        // Compute outcome (binary: all-or-nothing)
        bool isWinner = successfulDays == durationDays_;
        amountReturned = isWinner ? totalAmount : 0;
        amountSlashed = isWinner ? 0 : totalAmount;

        // Interactions: distribute slashed amount
        if (amountSlashed > 0) {
            uint256 toWinnersPool = (amountSlashed * winnerPercent) / 100;
            uint256 toTreasury = (amountSlashed * treasuryPercent) / 100;
            uint256 toCharity = amountSlashed - toWinnersPool - toTreasury;

            if (isUSDC_) {
                cohortPoolUSDC[cohort] += toWinnersPool;
            } else {
                cohortPoolETH[cohort] += toWinnersPool;
            }

            _transferFunds(treasury, toTreasury, isUSDC_);
            _transferFunds(charity, toCharity, isUSDC_);

            if (toCharity > 0) {
                emit CharityDonation(toCharity, cohort, isUSDC_);
            }
        }

        // Interactions: per-token cohort accounting
        if (isUSDC_) {
            if (!isWinner && cohortRemainingWinnersUSDC[cohort] > 0) {
                cohortRemainingWinnersUSDC[cohort]--;
            }
            if (isWinner) {
                uint256 remainingWinners = cohortRemainingWinnersUSDC[cohort];
                if (remainingWinners > 0) {
                    uint256 pool = cohortPoolUSDC[cohort];
                    if (pool > 0) {
                        winnerBonus = pool / remainingWinners;
                        cohortPoolUSDC[cohort] -= winnerBonus;
                        amountReturned += winnerBonus;
                        emit WinnerBonusPaid(user, winnerBonus, cohort, true);
                    }
                    cohortRemainingWinnersUSDC[cohort]--;
                }
            }
            cohortTotalStakersUSDC[cohort]--;
            if (cohortTotalStakersUSDC[cohort] == 0) {
                _finalizeLeftoverPool(cohort, true);
            }
        } else {
            if (!isWinner && cohortRemainingWinnersETH[cohort] > 0) {
                cohortRemainingWinnersETH[cohort]--;
            }
            if (isWinner) {
                uint256 remainingWinners = cohortRemainingWinnersETH[cohort];
                if (remainingWinners > 0) {
                    uint256 pool = cohortPoolETH[cohort];
                    if (pool > 0) {
                        winnerBonus = pool / remainingWinners;
                        cohortPoolETH[cohort] -= winnerBonus;
                        amountReturned += winnerBonus;
                        emit WinnerBonusPaid(user, winnerBonus, cohort, false);
                    }
                    cohortRemainingWinnersETH[cohort]--;
                }
            }
            cohortTotalStakersETH[cohort]--;
            if (cohortTotalStakersETH[cohort] == 0) {
                _finalizeLeftoverPool(cohort, false);
            }
        }
    }

    // ============ V3 View Functions ============

    /// @notice Get stake details for a user's specific stake
    function getStakeV3(address user, uint256 stakeId) external view returns (Stake memory) {
        return stakesV3[user][stakeId];
    }

    /// @notice Check if a user can submit a proof for a specific day on a specific stake
    function canSubmitProofV3(address user, uint256 stakeId, uint256 dayIndex)
        external
        view
        returns (bool canSubmit, string memory reason)
    {
        Stake storage userStake = stakesV3[user][stakeId];

        if (userStake.amount == 0) return (false, "No stake found");
        if (dayIndex >= userStake.durationDays) return (false, "Invalid day index");
        if (dayVerifiedV3[user][stakeId][dayIndex]) return (false, "Day already verified");

        uint256 dayEndTimestamp = userStake.startTimestamp + ((dayIndex + 1) * SECONDS_PER_DAY);
        uint256 windowEnd = dayEndTimestamp + GRACE_PERIOD;

        if (block.timestamp < dayEndTimestamp) return (false, "Day has not ended yet");
        if (block.timestamp > windowEnd) return (false, "Submission window closed");

        return (true, "");
    }

    /// @notice Get the current day index for a specific stake
    function getCurrentDayIndexV3(address user, uint256 stakeId) external view returns (uint256) {
        Stake storage userStake = stakesV3[user][stakeId];
        if (userStake.amount == 0) return type(uint256).max;

        if (block.timestamp < userStake.startTimestamp) return 0;

        uint256 elapsed = block.timestamp - userStake.startTimestamp;
        uint256 dayIndex = elapsed / SECONDS_PER_DAY;

        if (dayIndex >= userStake.durationDays) return userStake.durationDays - 1;

        return dayIndex;
    }

    // ============ Version Override ============

    /// @notice Get contract version
    function version() external pure override returns (string memory) {
        return "3.0.0";
    }
}
