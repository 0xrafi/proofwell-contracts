// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title ProofwellStakingV2
/// @notice Stake ETH or USDC on screen time goals with tiered reward distribution
/// @dev V2 adds: USDC support, pause/admin functions, winner redistribution, charity donations
/// @custom:oz-upgrades
contract ProofwellStakingV2 is
    Initializable,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============ Errors ============
    error NoStakeFound();
    error StakeAlreadyExists();
    error StakeAlreadyClaimed();
    error InvalidGoal();
    error InvalidDuration();
    error InsufficientStake();
    error KeyAlreadyRegistered();
    error InvalidPublicKey();
    error StakeNotEnded();
    error ResolutionBufferNotElapsed();
    error DayAlreadyVerified();
    error InvalidDayIndex();
    error ProofSubmissionWindowClosed();
    error InvalidSignature();
    error InvalidDistribution();
    error ZeroAddress();
    error TransferFailed();

    // ============ Events ============
    event StakedETH(
        address indexed user,
        uint256 amount,
        uint256 goalSeconds,
        uint256 durationDays,
        uint256 startTimestamp,
        uint256 cohortWeek
    );
    event StakedUSDC(
        address indexed user,
        uint256 amount,
        uint256 goalSeconds,
        uint256 durationDays,
        uint256 startTimestamp,
        uint256 cohortWeek
    );
    event DayProofSubmitted(address indexed user, uint256 dayIndex, bool goalAchieved);
    event Claimed(
        address indexed user, uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC
    );
    event DistributionUpdated(uint8 winnerPercent, uint8 treasuryPercent, uint8 charityPercent);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event CharityUpdated(address indexed oldCharity, address indexed newCharity);
    event WinnerBonusPaid(address indexed user, uint256 amount, uint256 cohort, bool isUSDC);
    event CharityDonation(uint256 amount, uint256 cohort, bool isUSDC);
    event ResolvedExpired(address indexed user, address indexed resolver, uint256 amountReturned, uint256 amountSlashed);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event UpgradeAuthorized(address indexed newImplementation);

    // ============ Constants ============
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant SECONDS_PER_WEEK = 604800;
    uint256 public constant GRACE_PERIOD = 6 hours;
    uint256 public constant MIN_STAKE_ETH = 0.001 ether;
    uint256 public constant MIN_STAKE_USDC = 1e6; // 1 USDC (6 decimals)
    uint256 public constant MIN_DURATION_DAYS = 3;
    uint256 public constant MAX_DURATION_DAYS = 365;
    uint256 public constant MAX_GOAL_SECONDS = 24 hours;
    uint256 public constant RESOLUTION_BUFFER = 7 days;

    // ============ Structs ============
    struct Stake {
        uint256 amount;
        uint256 goalSeconds;
        uint256 startTimestamp;
        uint256 durationDays;
        bytes32 pubKeyX;
        bytes32 pubKeyY;
        uint256 successfulDays;
        bool claimed;
        bool isUSDC;
        uint256 cohortWeek;
    }

    // ============ State ============
    mapping(address => Stake) public stakes;
    mapping(bytes32 => address) public registeredKeys;
    mapping(address => mapping(uint256 => bool)) public dayVerified;

    // Distribution percentages (must sum to 100)
    uint8 public winnerPercent;
    uint8 public treasuryPercent;
    uint8 public charityPercent;

    // Addresses
    address public treasury;
    address public charity;
    IERC20 public usdc;

    // Cohort tracking for winner redistribution
    mapping(uint256 => uint256) public cohortPoolETH; // weekNum => accumulated winner pool
    mapping(uint256 => uint256) public cohortPoolUSDC;
    mapping(uint256 => uint256) public cohortRemainingWinners; // weekNum => winners who haven't claimed
    mapping(uint256 => uint256) public cohortTotalStakers; // weekNum => total stakers in cohort
    mapping(uint256 => bool) public cohortFinalized; // weekNum => all claims processed

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============
    /// @notice Initialize the contract (replaces constructor for proxy pattern)
    /// @param _treasury Address to receive treasury funds
    /// @param _charity Address to receive charity donations
    /// @param _usdc USDC token address
    function initialize(address _treasury, address _charity, address _usdc) public initializer {
        if (_treasury == address(0) || _charity == address(0) || _usdc == address(0)) {
            revert ZeroAddress();
        }

        __Ownable_init(msg.sender);
        __Pausable_init();

        treasury = _treasury;
        charity = _charity;
        usdc = IERC20(_usdc);

        // Set default distribution percentages
        winnerPercent = 40;
        treasuryPercent = 40;
        charityPercent = 20;
    }

    // ============ Admin Functions ============

    /// @notice Pause all stake/claim/proof operations
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause operations
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Update treasury address
    /// @param newTreasury New treasury address
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /// @notice Update charity address
    /// @param newCharity New charity address
    function setCharity(address newCharity) external onlyOwner {
        if (newCharity == address(0)) revert ZeroAddress();
        address oldCharity = charity;
        charity = newCharity;
        emit CharityUpdated(oldCharity, newCharity);
    }

    /// @notice Update distribution percentages
    /// @param _winnerPercent Percentage to winner pool (0-100)
    /// @param _treasuryPercent Percentage to treasury (0-100)
    /// @param _charityPercent Percentage to charity (0-100)
    function setDistribution(uint8 _winnerPercent, uint8 _treasuryPercent, uint8 _charityPercent) external onlyOwner {
        if (uint256(_winnerPercent) + uint256(_treasuryPercent) + uint256(_charityPercent) != 100) {
            revert InvalidDistribution();
        }
        winnerPercent = _winnerPercent;
        treasuryPercent = _treasuryPercent;
        charityPercent = _charityPercent;
        emit DistributionUpdated(_winnerPercent, _treasuryPercent, _charityPercent);
    }

    /// @notice Emergency withdraw stuck funds (owner only)
    /// @param token Address of token (address(0) for ETH)
    function emergencyWithdraw(address token) external onlyOwner {
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            (bool success,) = owner().call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            amount = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(owner(), amount);
        }
        emit EmergencyWithdraw(token, amount);
    }

    // ============ Stake Functions ============

    /// @notice Stake ETH with a screen time goal
    /// @param goalSeconds Maximum screen time goal in seconds
    /// @param durationDays Number of days for the challenge
    /// @param pubKeyX P-256 public key X coordinate (App Attest)
    /// @param pubKeyY P-256 public key Y coordinate (App Attest)
    function stakeETH(uint256 goalSeconds, uint256 durationDays, bytes32 pubKeyX, bytes32 pubKeyY)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (stakes[msg.sender].amount != 0) revert StakeAlreadyExists();
        if (goalSeconds == 0 || goalSeconds > MAX_GOAL_SECONDS) revert InvalidGoal();
        if (durationDays < MIN_DURATION_DAYS || durationDays > MAX_DURATION_DAYS) revert InvalidDuration();
        if (msg.value < MIN_STAKE_ETH) revert InsufficientStake();

        _validateAndRegisterKey(pubKeyX, pubKeyY);

        uint256 cohortWeek = block.timestamp / SECONDS_PER_WEEK;

        stakes[msg.sender] = Stake({
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

        cohortTotalStakers[cohortWeek]++;
        // Assume all stakers are potential winners initially
        cohortRemainingWinners[cohortWeek]++;

        emit StakedETH(msg.sender, msg.value, goalSeconds, durationDays, block.timestamp, cohortWeek);
    }

    /// @notice Stake USDC with a screen time goal (requires prior approval)
    /// @param amount Amount of USDC to stake (6 decimals)
    /// @param goalSeconds Maximum screen time goal in seconds
    /// @param durationDays Number of days for the challenge
    /// @param pubKeyX P-256 public key X coordinate (App Attest)
    /// @param pubKeyY P-256 public key Y coordinate (App Attest)
    function stakeUSDC(uint256 amount, uint256 goalSeconds, uint256 durationDays, bytes32 pubKeyX, bytes32 pubKeyY)
        external
        nonReentrant
        whenNotPaused
    {
        if (stakes[msg.sender].amount != 0) revert StakeAlreadyExists();
        if (goalSeconds == 0 || goalSeconds > MAX_GOAL_SECONDS) revert InvalidGoal();
        if (durationDays < MIN_DURATION_DAYS || durationDays > MAX_DURATION_DAYS) revert InvalidDuration();
        if (amount < MIN_STAKE_USDC) revert InsufficientStake();

        _validateAndRegisterKey(pubKeyX, pubKeyY);

        // Transfer USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 cohortWeek = block.timestamp / SECONDS_PER_WEEK;

        stakes[msg.sender] = Stake({
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

        cohortTotalStakers[cohortWeek]++;
        cohortRemainingWinners[cohortWeek]++;

        emit StakedUSDC(msg.sender, amount, goalSeconds, durationDays, block.timestamp, cohortWeek);
    }

    // ============ Proof Submission ============

    /// @notice Submit proof for a specific day
    /// @param dayIndex The day index (0-indexed from stake start)
    /// @param goalAchieved Whether the goal was achieved that day
    /// @param r Signature r value
    /// @param s Signature s value
    function submitDayProof(uint256 dayIndex, bool goalAchieved, bytes32 r, bytes32 s)
        external
        nonReentrant
        whenNotPaused
    {
        Stake storage userStake = stakes[msg.sender];
        if (userStake.amount == 0) revert NoStakeFound();
        if (userStake.claimed) revert StakeAlreadyClaimed();
        if (dayIndex >= userStake.durationDays) revert InvalidDayIndex();
        if (dayVerified[msg.sender][dayIndex]) revert DayAlreadyVerified();

        uint256 dayEndTimestamp = userStake.startTimestamp + ((dayIndex + 1) * SECONDS_PER_DAY);
        uint256 windowEnd = dayEndTimestamp + GRACE_PERIOD;

        if (block.timestamp < dayEndTimestamp) revert ProofSubmissionWindowClosed();
        if (block.timestamp > windowEnd) revert ProofSubmissionWindowClosed();

        bytes32 messageHash =
            keccak256(abi.encodePacked(msg.sender, dayIndex, goalAchieved, block.chainid, address(this)));

        bool valid = P256.verify(messageHash, r, s, userStake.pubKeyX, userStake.pubKeyY);
        if (!valid) revert InvalidSignature();

        dayVerified[msg.sender][dayIndex] = true;

        if (goalAchieved) {
            userStake.successfulDays++;
        }

        emit DayProofSubmitted(msg.sender, dayIndex, goalAchieved);
    }

    // ============ Claim ============

    /// @notice Claim stake after duration ends with tiered distribution
    function claim() external nonReentrant whenNotPaused {
        Stake storage userStake = stakes[msg.sender];
        if (userStake.amount == 0) revert NoStakeFound();
        if (userStake.claimed) revert StakeAlreadyClaimed();

        uint256 stakeEndTimestamp = userStake.startTimestamp + (userStake.durationDays * SECONDS_PER_DAY);
        if (block.timestamp < stakeEndTimestamp) revert StakeNotEnded();

        (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC) = _processClaim(msg.sender);

        emit Claimed(msg.sender, amountReturned, amountSlashed, winnerBonus, isUSDC);
    }

    /// @notice Resolve an expired stake for a user who hasn't claimed
    /// @dev Anyone can call after stake end + RESOLUTION_BUFFER. Funds go to the staker.
    /// @param user Address of the staker to resolve
    function resolveExpired(address user) external nonReentrant whenNotPaused {
        Stake storage userStake = stakes[user];
        if (userStake.amount == 0) revert NoStakeFound();
        if (userStake.claimed) revert StakeAlreadyClaimed();

        uint256 stakeEndTimestamp = userStake.startTimestamp + (userStake.durationDays * SECONDS_PER_DAY);
        if (block.timestamp < stakeEndTimestamp + RESOLUTION_BUFFER) revert ResolutionBufferNotElapsed();

        (uint256 amountReturned, uint256 amountSlashed,,) = _processClaim(user);

        emit ResolvedExpired(user, msg.sender, amountReturned, amountSlashed);
    }

    // ============ Internal Functions ============

    function _processClaim(address user)
        internal
        returns (uint256 amountReturned, uint256 amountSlashed, uint256 winnerBonus, bool isUSDC)
    {
        Stake storage userStake = stakes[user];
        userStake.claimed = true;

        uint256 totalAmount = userStake.amount;
        uint256 successfulDays = userStake.successfulDays;
        uint256 durationDays = userStake.durationDays;
        uint256 cohort = userStake.cohortWeek;
        isUSDC = userStake.isUSDC;

        // Binary outcome: full refund or nothing
        bool isWinner = successfulDays == durationDays;
        amountReturned = isWinner ? totalAmount : 0;
        amountSlashed = isWinner ? 0 : totalAmount;

        // Process slashed amount distribution
        if (amountSlashed > 0) {
            uint256 toWinnersPool = (amountSlashed * winnerPercent) / 100;
            uint256 toTreasury = (amountSlashed * treasuryPercent) / 100;
            uint256 toCharity = amountSlashed - toWinnersPool - toTreasury;

            if (isUSDC) {
                cohortPoolUSDC[cohort] += toWinnersPool;
            } else {
                cohortPoolETH[cohort] += toWinnersPool;
            }

            _transferFunds(treasury, toTreasury, isUSDC);
            _transferFunds(charity, toCharity, isUSDC);

            if (toCharity > 0) {
                emit CharityDonation(toCharity, cohort, isUSDC);
            }
        }

        // If user is a winner, get share of current pool
        if (isWinner) {
            uint256 remainingWinners = cohortRemainingWinners[cohort];
            if (remainingWinners > 0) {
                uint256 pool = isUSDC ? cohortPoolUSDC[cohort] : cohortPoolETH[cohort];
                if (pool > 0) {
                    winnerBonus = pool / remainingWinners;
                    if (isUSDC) {
                        cohortPoolUSDC[cohort] -= winnerBonus;
                    } else {
                        cohortPoolETH[cohort] -= winnerBonus;
                    }
                    amountReturned += winnerBonus;

                    emit WinnerBonusPaid(user, winnerBonus, cohort, isUSDC);
                }
                cohortRemainingWinners[cohort]--;
            }
        }

        // Decrement cohort staker count and finalize if last
        cohortTotalStakers[cohort]--;
        if (cohortTotalStakers[cohort] == 0 && !cohortFinalized[cohort]) {
            _finalizeLeftoverPool(cohort);
        }

        // Transfer user's return
        if (amountReturned > 0) {
            _transferFunds(user, amountReturned, isUSDC);
        }
    }

    function _validateAndRegisterKey(bytes32 pubKeyX, bytes32 pubKeyY) internal {
        if (!P256.isValidPublicKey(pubKeyX, pubKeyY)) revert InvalidPublicKey();

        bytes32 keyHash = keccak256(abi.encodePacked(pubKeyX, pubKeyY));
        if (registeredKeys[keyHash] != address(0)) revert KeyAlreadyRegistered();

        registeredKeys[keyHash] = msg.sender;
    }

    function _transferFunds(address to, uint256 amount, bool isUSDC) internal {
        if (amount == 0) return;

        if (isUSDC) {
            usdc.safeTransfer(to, amount);
        } else {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        }
    }

    function _finalizeLeftoverPool(uint256 cohort) internal {
        cohortFinalized[cohort] = true;

        // If there's leftover in the pool (no winners claimed it), split between treasury and charity
        uint256 leftoverETH = cohortPoolETH[cohort];
        uint256 leftoverUSDC = cohortPoolUSDC[cohort];

        if (leftoverETH > 0) {
            uint256 toTreasury = (leftoverETH * 67) / 100; // 67% to treasury
            uint256 toCharity = leftoverETH - toTreasury; // 33% to charity

            cohortPoolETH[cohort] = 0;
            _transferFunds(treasury, toTreasury, false);
            _transferFunds(charity, toCharity, false);

            if (toCharity > 0) {
                emit CharityDonation(toCharity, cohort, false);
            }
        }

        if (leftoverUSDC > 0) {
            uint256 toTreasury = (leftoverUSDC * 67) / 100;
            uint256 toCharity = leftoverUSDC - toTreasury;

            cohortPoolUSDC[cohort] = 0;
            _transferFunds(treasury, toTreasury, true);
            _transferFunds(charity, toCharity, true);

            if (toCharity > 0) {
                emit CharityDonation(toCharity, cohort, true);
            }
        }
    }

    // ============ View Functions ============

    /// @notice Get stake details for a user
    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }

    /// @notice Check if a user can submit a proof for a specific day
    function canSubmitProof(address user, uint256 dayIndex)
        external
        view
        returns (bool canSubmit, string memory reason)
    {
        Stake storage userStake = stakes[user];

        if (userStake.amount == 0) return (false, "No stake found");
        if (userStake.claimed) return (false, "Stake already claimed");
        if (dayIndex >= userStake.durationDays) return (false, "Invalid day index");
        if (dayVerified[user][dayIndex]) return (false, "Day already verified");

        uint256 dayEndTimestamp = userStake.startTimestamp + ((dayIndex + 1) * SECONDS_PER_DAY);
        uint256 windowEnd = dayEndTimestamp + GRACE_PERIOD;

        if (block.timestamp < dayEndTimestamp) return (false, "Day has not ended yet");
        if (block.timestamp > windowEnd) return (false, "Submission window closed");

        return (true, "");
    }

    /// @notice Get the current day index for a user's stake
    function getCurrentDayIndex(address user) external view returns (uint256) {
        Stake storage userStake = stakes[user];
        if (userStake.amount == 0) return type(uint256).max;

        if (block.timestamp < userStake.startTimestamp) return 0;

        uint256 elapsed = block.timestamp - userStake.startTimestamp;
        uint256 dayIndex = elapsed / SECONDS_PER_DAY;

        if (dayIndex >= userStake.durationDays) return userStake.durationDays - 1;

        return dayIndex;
    }

    /// @notice Check if a public key is already registered
    function getKeyOwner(bytes32 pubKeyX, bytes32 pubKeyY) external view returns (address) {
        bytes32 keyHash = keccak256(abi.encodePacked(pubKeyX, pubKeyY));
        return registeredKeys[keyHash];
    }

    /// @notice Get cohort pool info
    function getCohortInfo(uint256 cohortWeek)
        external
        view
        returns (uint256 poolETH, uint256 poolUSDC, uint256 remainingWinners, uint256 totalStakers, bool finalized)
    {
        return (
            cohortPoolETH[cohortWeek],
            cohortPoolUSDC[cohortWeek],
            cohortRemainingWinners[cohortWeek],
            cohortTotalStakers[cohortWeek],
            cohortFinalized[cohortWeek]
        );
    }

    /// @notice Get current week number
    function getCurrentWeek() external view returns (uint256) {
        return block.timestamp / SECONDS_PER_WEEK;
    }

    /// @notice Get contract version
    function version() external pure returns (string memory) {
        return "2.1.0";
    }

    // ============ UUPS ============

    /// @notice Authorize upgrade to new implementation (owner only)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit UpgradeAuthorized(newImplementation);
    }

    // ============ Receive ============

    /// @notice Accept direct ETH transfers (for emergencyWithdraw recovery)
    receive() external payable {}
}
