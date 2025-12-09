// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";

/// @title ProofwellStaking
/// @notice Stake ETH with screen time goals, submit daily proofs via App Attest, claim proportional rewards
/// @dev Uses RIP-7212 precompile with OpenZeppelin P256 fallback for signature verification
contract ProofwellStaking is ReentrancyGuard {
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
    error DayAlreadyVerified();
    error InvalidDayIndex();
    error ProofSubmissionWindowClosed();
    error InvalidSignature();
    error GoalNotAchieved();

    // ============ Events ============
    event Staked(
        address indexed user,
        uint256 amount,
        uint256 goalSeconds,
        uint256 durationDays,
        uint256 startTimestamp
    );
    event DayProofSubmitted(address indexed user, uint256 dayIndex, bool goalAchieved);
    event Claimed(address indexed user, uint256 amountReturned, uint256 amountSlashed);

    // ============ Constants ============
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant GRACE_PERIOD = 6 hours;
    uint256 public constant MIN_STAKE = 0.001 ether;
    uint256 public constant MAX_DURATION_DAYS = 365;
    uint256 public constant MAX_GOAL_SECONDS = 24 hours;

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
    }

    // ============ State ============
    mapping(address => Stake) public stakes;
    mapping(bytes32 => address) public registeredKeys;
    mapping(address => mapping(uint256 => bool)) public dayVerified;

    address public immutable protocolTreasury;

    // ============ Constructor ============
    constructor(address _protocolTreasury) {
        protocolTreasury = _protocolTreasury;
    }

    // ============ External Functions ============

    /// @notice Stake ETH with a screen time goal
    /// @param goalSeconds Maximum screen time goal in seconds
    /// @param durationDays Number of days for the challenge
    /// @param pubKeyX P-256 public key X coordinate (App Attest)
    /// @param pubKeyY P-256 public key Y coordinate (App Attest)
    function stake(
        uint256 goalSeconds,
        uint256 durationDays,
        bytes32 pubKeyX,
        bytes32 pubKeyY
    ) external payable nonReentrant {
        if (stakes[msg.sender].amount != 0) revert StakeAlreadyExists();
        if (goalSeconds == 0 || goalSeconds > MAX_GOAL_SECONDS) revert InvalidGoal();
        if (durationDays == 0 || durationDays > MAX_DURATION_DAYS) revert InvalidDuration();
        if (msg.value < MIN_STAKE) revert InsufficientStake();

        // Validate public key is on the curve
        if (!P256.isValidPublicKey(pubKeyX, pubKeyY)) revert InvalidPublicKey();

        // Check key hasn't been registered by another wallet (sybil prevention)
        bytes32 keyHash = keccak256(abi.encodePacked(pubKeyX, pubKeyY));
        if (registeredKeys[keyHash] != address(0)) revert KeyAlreadyRegistered();

        // Register the key
        registeredKeys[keyHash] = msg.sender;

        // Create the stake
        stakes[msg.sender] = Stake({
            amount: msg.value,
            goalSeconds: goalSeconds,
            startTimestamp: block.timestamp,
            durationDays: durationDays,
            pubKeyX: pubKeyX,
            pubKeyY: pubKeyY,
            successfulDays: 0,
            claimed: false
        });

        emit Staked(msg.sender, msg.value, goalSeconds, durationDays, block.timestamp);
    }

    /// @notice Submit proof for a specific day
    /// @param dayIndex The day index (0-indexed from stake start)
    /// @param goalAchieved Whether the goal was achieved that day
    /// @param r Signature r value
    /// @param s Signature s value
    function submitDayProof(
        uint256 dayIndex,
        bool goalAchieved,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        Stake storage userStake = stakes[msg.sender];
        if (userStake.amount == 0) revert NoStakeFound();
        if (userStake.claimed) revert StakeAlreadyClaimed();
        if (dayIndex >= userStake.durationDays) revert InvalidDayIndex();
        if (dayVerified[msg.sender][dayIndex]) revert DayAlreadyVerified();

        // Check submission window: must be after day ends, within grace period
        uint256 dayEndTimestamp = userStake.startTimestamp + ((dayIndex + 1) * SECONDS_PER_DAY);
        uint256 windowEnd = dayEndTimestamp + GRACE_PERIOD;

        if (block.timestamp < dayEndTimestamp) revert ProofSubmissionWindowClosed();
        if (block.timestamp > windowEnd) revert ProofSubmissionWindowClosed();

        // Construct the message hash
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                msg.sender,
                dayIndex,
                goalAchieved,
                block.chainid,
                address(this)
            )
        );

        // Verify P-256 signature using RIP-7212 precompile with fallback
        bool valid = P256.verify(
            messageHash,
            r,
            s,
            userStake.pubKeyX,
            userStake.pubKeyY
        );
        if (!valid) revert InvalidSignature();

        // Mark day as verified
        dayVerified[msg.sender][dayIndex] = true;

        // Only count as successful if goal was achieved
        if (goalAchieved) {
            userStake.successfulDays++;
        }

        emit DayProofSubmitted(msg.sender, dayIndex, goalAchieved);
    }

    /// @notice Claim stake after duration ends
    function claim() external nonReentrant {
        Stake storage userStake = stakes[msg.sender];
        if (userStake.amount == 0) revert NoStakeFound();
        if (userStake.claimed) revert StakeAlreadyClaimed();

        uint256 stakeEndTimestamp = userStake.startTimestamp + (userStake.durationDays * SECONDS_PER_DAY);
        if (block.timestamp < stakeEndTimestamp) revert StakeNotEnded();

        userStake.claimed = true;

        // Calculate proportional return
        uint256 totalAmount = userStake.amount;
        uint256 successfulDays = userStake.successfulDays;
        uint256 durationDays = userStake.durationDays;

        uint256 amountReturned = (totalAmount * successfulDays) / durationDays;
        uint256 amountSlashed = totalAmount - amountReturned;

        // Transfer funds
        if (amountReturned > 0) {
            (bool successUser, ) = msg.sender.call{value: amountReturned}("");
            require(successUser, "Transfer to user failed");
        }

        if (amountSlashed > 0) {
            (bool successProtocol, ) = protocolTreasury.call{value: amountSlashed}("");
            require(successProtocol, "Transfer to protocol failed");
        }

        emit Claimed(msg.sender, amountReturned, amountSlashed);
    }

    // ============ View Functions ============

    /// @notice Get stake details for a user
    /// @param user The user address
    /// @return The stake struct
    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }

    /// @notice Check if a user can submit a proof for a specific day
    /// @param user The user address
    /// @param dayIndex The day index
    /// @return canSubmit Whether proof can be submitted
    /// @return reason Human readable reason if cannot submit
    function canSubmitProof(address user, uint256 dayIndex) external view returns (bool canSubmit, string memory reason) {
        Stake storage userStake = stakes[user];

        if (userStake.amount == 0) {
            return (false, "No stake found");
        }
        if (userStake.claimed) {
            return (false, "Stake already claimed");
        }
        if (dayIndex >= userStake.durationDays) {
            return (false, "Invalid day index");
        }
        if (dayVerified[user][dayIndex]) {
            return (false, "Day already verified");
        }

        uint256 dayEndTimestamp = userStake.startTimestamp + ((dayIndex + 1) * SECONDS_PER_DAY);
        uint256 windowEnd = dayEndTimestamp + GRACE_PERIOD;

        if (block.timestamp < dayEndTimestamp) {
            return (false, "Day has not ended yet");
        }
        if (block.timestamp > windowEnd) {
            return (false, "Submission window closed");
        }

        return (true, "");
    }

    /// @notice Get the current day index for a user's stake
    /// @param user The user address
    /// @return The current day index (0-indexed), or type(uint256).max if no stake
    function getCurrentDayIndex(address user) external view returns (uint256) {
        Stake storage userStake = stakes[user];
        if (userStake.amount == 0) {
            return type(uint256).max;
        }

        if (block.timestamp < userStake.startTimestamp) {
            return 0;
        }

        uint256 elapsed = block.timestamp - userStake.startTimestamp;
        uint256 dayIndex = elapsed / SECONDS_PER_DAY;

        if (dayIndex >= userStake.durationDays) {
            return userStake.durationDays - 1;
        }

        return dayIndex;
    }

    /// @notice Check if a public key is already registered
    /// @param pubKeyX Public key X coordinate
    /// @param pubKeyY Public key Y coordinate
    /// @return The address that registered the key, or address(0) if not registered
    function getKeyOwner(bytes32 pubKeyX, bytes32 pubKeyY) external view returns (address) {
        bytes32 keyHash = keccak256(abi.encodePacked(pubKeyX, pubKeyY));
        return registeredKeys[keyHash];
    }
}
