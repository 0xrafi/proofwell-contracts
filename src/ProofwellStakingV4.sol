// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProofwellStakingV3} from "./ProofwellStakingV3.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ProofwellStakingV4
/// @notice Pool-based staking — friends can create private pools and bet against each other
/// @dev Inherits V3 storage layout and consumes 4 gap slots from __gapV3 for new state
contract ProofwellStakingV4 is ProofwellStakingV3 {
    using SafeERC20 for IERC20;

    // ============ New Errors ============
    error PoolNotFound();
    error PoolNotOpen();
    error PoolEntryDeadlinePassed();
    error PoolGoalMismatch();
    error PoolDurationMismatch();
    error PoolNotStartable();
    error PoolAlreadyResolved();
    error InvalidEntryDeadline();

    // ============ New Events ============
    event PoolCreated(
        uint256 indexed poolId,
        address indexed creator,
        uint256 goalSeconds,
        uint256 durationDays,
        uint256 entryDeadline
    );
    event PoolStarted(uint256 indexed poolId);
    event PoolResolved(uint256 indexed poolId);
    event StakedETHV4(
        address indexed user,
        uint256 indexed stakeId,
        uint256 indexed poolId,
        uint256 amount,
        uint256 goalSeconds,
        uint256 durationDays,
        uint256 startTimestamp
    );
    event StakedUSDCV4(
        address indexed user,
        uint256 indexed stakeId,
        uint256 indexed poolId,
        uint256 amount,
        uint256 goalSeconds,
        uint256 durationDays,
        uint256 startTimestamp
    );
    event ClaimedV4(
        address indexed user,
        uint256 indexed stakeId,
        uint256 indexed poolId,
        uint256 amountReturned,
        uint256 amountSlashed,
        uint256 winnerBonus,
        bool isUSDC
    );
    event ResolvedExpiredV4(
        address indexed user,
        uint256 indexed stakeId,
        uint256 indexed poolId,
        address resolver,
        uint256 amountReturned,
        uint256 amountSlashed,
        uint256 winnerBonus,
        bool isUSDC
    );

    // ============ New Enums ============
    enum PoolStatus {
        OPEN,
        RUNNING,
        RESOLVED
    }

    // ============ New Structs ============
    struct Pool {
        uint256 poolId;
        address creator;
        uint256 goalSeconds;
        uint256 durationDays;
        uint256 entryDeadline;
        PoolStatus status;
        uint256 totalStakersETH;
        uint256 totalStakersUSDC;
        uint256 remainingWinnersETH;
        uint256 remainingWinnersUSDC;
        uint256 poolETH;
        uint256 poolUSDC;
    }

    // ============ New Storage (consuming __gapV3 slots 0-3) ============
    // These overlay the first 4 slots of V3's `uint256[42] private __gapV3`

    /// @dev Monotonic counter for pool IDs (starts at 1; 0 = weekly cohort)
    uint256 public nextPoolId; // gapV3[0]

    /// @dev Pool storage: poolId => Pool
    mapping(uint256 => Pool) public pools; // gapV3[1]

    /// @dev Maps user stakes to pools: user => stakeId => poolId (0 = weekly cohort)
    mapping(address => mapping(uint256 => uint256)) public stakePool; // gapV3[2]

    /// @dev Tracks total stakers ever added to a pool (for determining if pool is empty)
    mapping(uint256 => uint256) public poolTotalStakers; // gapV3[3]

    /// @dev Remaining gap slots: 42 - 4 = 38
    uint256[38] private __gapV4;

    // ============ V4 Initializer ============

    /// @notice Initialize V4 — bumps reinitializer version
    function initializeV4() public reinitializer(3) {
        nextPoolId = 1; // Pool IDs start at 1; 0 means "no pool" (weekly cohort)
    }

    // ============ Pool Management ============

    /// @notice Create a new pool for friends to bet against each other
    /// @param goalSeconds Screen time goal all participants must match
    /// @param durationDays Challenge duration all participants must match
    /// @param entryDeadlineDuration Seconds from now until entry closes
    /// @return poolId The created pool ID (shareable as invite)
    function createPool(uint256 goalSeconds, uint256 durationDays, uint256 entryDeadlineDuration)
        external
        whenNotPaused
        returns (uint256 poolId)
    {
        if (goalSeconds == 0 || goalSeconds > MAX_GOAL_SECONDS) revert InvalidGoal();
        if (durationDays < MIN_DURATION_DAYS || durationDays > MAX_DURATION_DAYS) revert InvalidDuration();
        if (entryDeadlineDuration == 0) revert InvalidEntryDeadline();

        poolId = nextPoolId++;

        pools[poolId] = Pool({
            poolId: poolId,
            creator: msg.sender,
            goalSeconds: goalSeconds,
            durationDays: durationDays,
            entryDeadline: block.timestamp + entryDeadlineDuration,
            status: PoolStatus.OPEN,
            totalStakersETH: 0,
            totalStakersUSDC: 0,
            remainingWinnersETH: 0,
            remainingWinnersUSDC: 0,
            poolETH: 0,
            poolUSDC: 0
        });

        emit PoolCreated(poolId, msg.sender, goalSeconds, durationDays, block.timestamp + entryDeadlineDuration);
    }

    /// @notice Start a pool after its entry deadline has passed
    /// @param poolId The pool to start
    function startPool(uint256 poolId) external whenNotPaused {
        Pool storage pool = pools[poolId];
        if (pool.poolId == 0) revert PoolNotFound();
        if (pool.status != PoolStatus.OPEN) revert PoolNotStartable();
        if (block.timestamp < pool.entryDeadline) revert PoolNotStartable();

        pool.status = PoolStatus.RUNNING;
        emit PoolStarted(poolId);
    }

    // ============ V4 Stake Functions ============

    /// @notice Stake ETH with optional pool membership
    /// @param goalSeconds Screen time goal in seconds
    /// @param durationDays Number of days for the challenge
    /// @param pubKeyX P-256 public key X coordinate
    /// @param pubKeyY P-256 public key Y coordinate
    /// @param poolId Pool to join (0 = weekly cohort fallback)
    /// @return stakeId The assigned stake ID
    function stakeETHV4(uint256 goalSeconds, uint256 durationDays, bytes32 pubKeyX, bytes32 pubKeyY, uint256 poolId)
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

        if (poolId > 0) {
            _validatePoolEntry(poolId, goalSeconds, durationDays);
        }

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

        if (poolId > 0) {
            stakePool[msg.sender][stakeId] = poolId;

            // Pool-level accounting
            pools[poolId].totalStakersETH++;
            pools[poolId].remainingWinnersETH++;
            poolTotalStakers[poolId]++;

            // Auto-start pool if entry deadline has passed
            if (pools[poolId].status == PoolStatus.OPEN && block.timestamp >= pools[poolId].entryDeadline) {
                pools[poolId].status = PoolStatus.RUNNING;
                emit PoolStarted(poolId);
            }

            emit StakedETHV4(msg.sender, stakeId, poolId, msg.value, goalSeconds, durationDays, block.timestamp);
        } else {
            // Cohort-level accounting (same as V3)
            cohortTotalStakersETH[cohortWeek]++;
            cohortRemainingWinnersETH[cohortWeek]++;

            emit StakedETHV4(msg.sender, stakeId, 0, msg.value, goalSeconds, durationDays, block.timestamp);
        }
    }

    /// @notice Stake USDC with optional pool membership
    /// @param amount Amount of USDC to stake (6 decimals)
    /// @param goalSeconds Screen time goal in seconds
    /// @param durationDays Number of days for the challenge
    /// @param pubKeyX P-256 public key X coordinate
    /// @param pubKeyY P-256 public key Y coordinate
    /// @param poolId Pool to join (0 = weekly cohort fallback)
    /// @return stakeId The assigned stake ID
    function stakeUSDCV4(
        uint256 amount,
        uint256 goalSeconds,
        uint256 durationDays,
        bytes32 pubKeyX,
        bytes32 pubKeyY,
        uint256 poolId
    ) external nonReentrant whenNotPaused returns (uint256 stakeId) {
        if (activeStakeCount[msg.sender] >= MAX_ACTIVE_STAKES) revert TooManyActiveStakes();
        if (goalSeconds == 0 || goalSeconds > MAX_GOAL_SECONDS) revert InvalidGoal();
        if (durationDays < MIN_DURATION_DAYS || durationDays > MAX_DURATION_DAYS) revert InvalidDuration();
        if (amount < MIN_STAKE_USDC) revert InsufficientStake();

        if (poolId > 0) {
            _validatePoolEntry(poolId, goalSeconds, durationDays);
        }

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

        if (poolId > 0) {
            stakePool[msg.sender][stakeId] = poolId;

            // Pool-level accounting
            pools[poolId].totalStakersUSDC++;
            pools[poolId].remainingWinnersUSDC++;
            poolTotalStakers[poolId]++;

            // Auto-start pool if entry deadline has passed
            if (pools[poolId].status == PoolStatus.OPEN && block.timestamp >= pools[poolId].entryDeadline) {
                pools[poolId].status = PoolStatus.RUNNING;
                emit PoolStarted(poolId);
            }

            emit StakedUSDCV4(msg.sender, stakeId, poolId, amount, goalSeconds, durationDays, block.timestamp);
        } else {
            // Cohort-level accounting (same as V3)
            cohortTotalStakersUSDC[cohortWeek]++;
            cohortRemainingWinnersUSDC[cohortWeek]++;

            emit StakedUSDCV4(msg.sender, stakeId, 0, amount, goalSeconds, durationDays, block.timestamp);
        }
    }

    // ============ V4 Claim ============

    /// @notice Claim a specific stake after its duration ends (pool-aware)
    /// @param stakeId The stake ID to claim
    function claimV4(uint256 stakeId) external nonReentrant whenNotPaused {
        Stake storage userStake = stakesV3[msg.sender][stakeId];
        if (userStake.amount == 0) revert StakeNotFound();

        uint256 stakeEndTimestamp = userStake.startTimestamp + (userStake.durationDays * SECONDS_PER_DAY);
        if (block.timestamp < stakeEndTimestamp) revert StakeNotEnded();

        uint256 poolId = stakePool[msg.sender][stakeId];

        if (poolId == 0) {
            // Cohort-based: delegate to V3 logic
            (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC_) =
                _processClaimV3(msg.sender, stakeId);

            if (amountReturned > 0) {
                _transferFunds(msg.sender, amountReturned, isUSDC_);
            }

            emit ClaimedV4(msg.sender, stakeId, 0, amountReturned, amountSlashed, winnerBonus, isUSDC_);
        } else {
            // Pool-based
            (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC_) =
                _processClaimV4Pool(msg.sender, stakeId, poolId);

            if (amountReturned > 0) {
                _transferFunds(msg.sender, amountReturned, isUSDC_);
            }

            emit ClaimedV4(msg.sender, stakeId, poolId, amountReturned, amountSlashed, winnerBonus, isUSDC_);
        }
    }

    /// @notice Resolve an expired stake for a user who hasn't claimed (pool-aware)
    /// @param user Address of the staker to resolve
    /// @param stakeId The stake ID to resolve
    function resolveExpiredV4(address user, uint256 stakeId) external nonReentrant whenNotPaused {
        Stake storage userStake = stakesV3[user][stakeId];
        if (userStake.amount == 0) revert StakeNotFound();

        uint256 stakeEndTimestamp = userStake.startTimestamp + (userStake.durationDays * SECONDS_PER_DAY);
        if (block.timestamp < stakeEndTimestamp + RESOLUTION_BUFFER) revert ResolutionBufferNotElapsed();

        uint256 poolId = stakePool[user][stakeId];

        if (poolId == 0) {
            // Cohort-based: delegate to V3 logic
            (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC_) =
                _processClaimV3(user, stakeId);

            if (amountReturned > 0) {
                if (!_tryTransferFunds(user, amountReturned, isUSDC_)) {
                    _transferFunds(treasury, amountReturned, isUSDC_);
                }
            }

            emit ResolvedExpiredV4(user, stakeId, 0, msg.sender, amountReturned, amountSlashed, winnerBonus, isUSDC_);
        } else {
            // Pool-based
            (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC_) =
                _processClaimV4Pool(user, stakeId, poolId);

            if (amountReturned > 0) {
                if (!_tryTransferFunds(user, amountReturned, isUSDC_)) {
                    _transferFunds(treasury, amountReturned, isUSDC_);
                }
            }

            emit ResolvedExpiredV4(
                user, stakeId, poolId, msg.sender, amountReturned, amountSlashed, winnerBonus, isUSDC_
            );
        }
    }

    // ============ V4 Internal Functions ============

    /// @dev Validates that a pool exists, is open, deadline hasn't passed, and goal/duration match
    function _validatePoolEntry(uint256 poolId, uint256 goalSeconds, uint256 durationDays) internal view {
        Pool storage pool = pools[poolId];
        if (pool.poolId == 0) revert PoolNotFound();
        if (pool.status != PoolStatus.OPEN) revert PoolNotOpen();
        if (block.timestamp >= pool.entryDeadline) revert PoolEntryDeadlinePassed();
        if (goalSeconds != pool.goalSeconds) revert PoolGoalMismatch();
        if (durationDays != pool.durationDays) revert PoolDurationMismatch();
    }

    /// @dev Pool-level claim processing. Slashed funds go to pool instead of cohort.
    function _processClaimV4Pool(address user, uint256 stakeId, uint256 poolId)
        internal
        returns (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC_)
    {
        Stake storage userStake = stakesV3[user][stakeId];
        Pool storage pool = pools[poolId];

        // Cache values
        uint256 totalAmount = userStake.amount;
        uint256 successfulDays = userStake.successfulDays;
        uint256 durationDays_ = userStake.durationDays;
        isUSDC_ = userStake.isUSDC;

        // Effects: clear stake state
        for (uint256 i = 0; i < durationDays_; i++) {
            delete dayVerifiedV3[user][stakeId][i];
        }
        delete stakesV3[user][stakeId];
        delete stakePool[user][stakeId];
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

            // Winner share goes to pool instead of cohort
            if (isUSDC_) {
                pool.poolUSDC += toWinnersPool;
            } else {
                pool.poolETH += toWinnersPool;
            }

            _transferFunds(treasury, toTreasury, isUSDC_);
            _transferFunds(charity, toCharity, isUSDC_);

            if (toCharity > 0) {
                emit CharityDonation(toCharity, poolId, isUSDC_);
            }
        }

        // Interactions: pool-level accounting
        if (isUSDC_) {
            if (!isWinner && pool.remainingWinnersUSDC > 0) {
                pool.remainingWinnersUSDC--;
            }
            if (isWinner) {
                uint256 remainingWinners = pool.remainingWinnersUSDC;
                if (remainingWinners > 0) {
                    uint256 poolFunds = pool.poolUSDC;
                    if (poolFunds > 0) {
                        winnerBonus = poolFunds / remainingWinners;
                        pool.poolUSDC -= winnerBonus;
                        amountReturned += winnerBonus;
                        emit WinnerBonusPaid(user, winnerBonus, poolId, true);
                    }
                    pool.remainingWinnersUSDC--;
                }
            }
            pool.totalStakersUSDC--;
        } else {
            if (!isWinner && pool.remainingWinnersETH > 0) {
                pool.remainingWinnersETH--;
            }
            if (isWinner) {
                uint256 remainingWinners = pool.remainingWinnersETH;
                if (remainingWinners > 0) {
                    uint256 poolFunds = pool.poolETH;
                    if (poolFunds > 0) {
                        winnerBonus = poolFunds / remainingWinners;
                        pool.poolETH -= winnerBonus;
                        amountReturned += winnerBonus;
                        emit WinnerBonusPaid(user, winnerBonus, poolId, false);
                    }
                    pool.remainingWinnersETH--;
                }
            }
            pool.totalStakersETH--;
        }

        // Check if pool is fully resolved
        if (pool.totalStakersETH == 0 && pool.totalStakersUSDC == 0) {
            // Sweep any leftover pool funds to treasury/charity
            _finalizePoolLeftover(poolId);
            pool.status = PoolStatus.RESOLVED;
            emit PoolResolved(poolId);
        }
    }

    /// @dev Sweep leftover pool funds when all stakers have resolved
    function _finalizePoolLeftover(uint256 poolId) internal {
        Pool storage pool = pools[poolId];

        // Sweep leftover ETH
        if (pool.poolETH > 0) {
            uint256 leftoverETH = pool.poolETH;
            pool.poolETH = 0;
            uint256 toTreasury = (leftoverETH * 67) / 100;
            uint256 toCharity = leftoverETH - toTreasury;
            _transferFunds(treasury, toTreasury, false);
            _transferFunds(charity, toCharity, false);
            if (toCharity > 0) {
                emit CharityDonation(toCharity, poolId, false);
            }
        }

        // Sweep leftover USDC
        if (pool.poolUSDC > 0) {
            uint256 leftoverUSDC = pool.poolUSDC;
            pool.poolUSDC = 0;
            uint256 toTreasury = (leftoverUSDC * 67) / 100;
            uint256 toCharity = leftoverUSDC - toTreasury;
            _transferFunds(treasury, toTreasury, true);
            _transferFunds(charity, toCharity, true);
            if (toCharity > 0) {
                emit CharityDonation(toCharity, poolId, true);
            }
        }
    }

    // ============ V4 View Functions ============

    /// @notice Get pool details
    /// @param poolId The pool ID to query
    /// @return pool The pool struct
    function getPool(uint256 poolId) external view returns (Pool memory pool) {
        return pools[poolId];
    }

    /// @notice Get the pool ID for a user's stake
    /// @param user The user address
    /// @param stakeId The stake ID
    /// @return poolId The pool ID (0 = weekly cohort)
    function getStakePool(address user, uint256 stakeId) external view returns (uint256 poolId) {
        return stakePool[user][stakeId];
    }

    // ============ Version Override ============

    /// @notice Get contract version
    function version() external pure override returns (string memory) {
        return "4.0.0";
    }
}
