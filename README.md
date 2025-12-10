# Proofwell Contracts

Stake ETH/USDC on screen time goals. Miss your goal = lose stake. Beat it = keep stake + earn from others who failed.

## Deployed (Base Sepolia)

| Contract | Address |
|----------|---------|
| ProofwellStakingV2 (Proxy) | `0xb1184802b3f7129Ae710f5c24F7d49912013dAF0` |
| ProofwellStaking (V1) | `0x0c3FAE9B28faE66B0e668774eA3909B42729e4B6` |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         USER FLOW                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. STAKE                    2. PROVE (daily)      3. CLAIM     │
│  ───────                     ───────────────       ─────────    │
│  Lock ETH/USDC         →     Submit P-256     →    Get back:    │
│  + screen time goal          signed proof          proportional │
│  + duration (days)           from iOS app          return +     │
│  + App Attest key            (6hr window)          winner bonus │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Slashed Funds Distribution

When users fail to meet their goals, their slashed stake is split:

```
Slashed Amount
     │
     ├── 40% → Winner Pool (cohort members who achieved 100%)
     │
     ├── 40% → Treasury (protocol revenue)
     │
     └── 20% → Charity (configurable address)
```

### Cohort System

Users who stake in the same week form a "cohort". Winners split the pool from that cohort's failed stakes.

```
Week 1 Cohort: [Alice, Bob, Carol]
  - Alice: 100% success → gets stake back + share of winner pool
  - Bob: 50% success → gets half stake back, half goes to distribution
  - Carol: 0% success → loses all, distributed to winners/treasury/charity
```

## Contract Structure

```
src/
├── ProofwellStaking.sol     # V1: Basic ETH staking (deprecated)
└── ProofwellStakingV2.sol   # V2: ETH + USDC, cohorts, charity
    │
    ├── State
    │   ├── stakes[user]           # User's stake details
    │   ├── dayVerified[user][day] # Proof submission tracking
    │   ├── registeredKeys[hash]   # Sybil prevention (1 key per wallet)
    │   ├── cohortPoolETH[week]    # Winner pool per cohort
    │   └── cohortPoolUSDC[week]
    │
    ├── User Functions
    │   ├── stakeETH()       # Lock ETH with goal
    │   ├── stakeUSDC()      # Lock USDC (needs approve first)
    │   ├── submitDayProof() # Daily P-256 signed proof
    │   └── claim()          # Withdraw after challenge ends
    │
    ├── View Functions
    │   ├── getStake()          # Stake details
    │   ├── canSubmitProof()    # Check proof window
    │   ├── getCurrentDayIndex()# Current challenge day
    │   └── getCohortInfo()     # Pool balances
    │
    └── Admin Functions (onlyOwner)
        ├── pause/unpause()     # Emergency stop
        ├── setTreasury()       # Update treasury address
        ├── setCharity()        # Update charity address
        ├── setDistribution()   # Change split percentages
        ├── emergencyWithdraw() # Recover stuck funds
        └── upgradeToAndCall()  # UUPS upgrade
```

## Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MIN_STAKE_ETH` | 0.001 ETH | Minimum ETH stake |
| `MIN_STAKE_USDC` | 1 USDC | Minimum USDC stake |
| `MAX_DURATION_DAYS` | 365 | Maximum challenge length |
| `MAX_GOAL_SECONDS` | 86400 (24h) | Maximum daily screen time goal |
| `GRACE_PERIOD` | 6 hours | Window to submit proof after day ends |
| `SECONDS_PER_WEEK` | 604800 | Cohort grouping period |

## Claim Math

```
baseReturn = (stakeAmount × successfulDays) / totalDays
slashedAmount = stakeAmount - baseReturn

If winner (100% success):
  winnerBonus = cohortPool / remainingWinners
  totalReturn = baseReturn + winnerBonus
```

## Security

- **Sybil Prevention**: One App Attest key per wallet address
- **Reentrancy Guard**: All state-changing functions protected
- **P-256 Signatures**: iOS App Attest ensures proofs come from real devices
- **UUPS Upgradeable**: Owner can upgrade implementation (for bug fixes)
- **Pausable**: Emergency stop for all operations
- **2-Step Ownership**: Ownable2Step prevents accidental ownership transfer

## Charity Integration

The contract supports any ERC-20 compatible charity address. Recommended on-chain charity platforms:
- [Endaoment](https://endaoment.org) - On Base L2, supports DAF donations
- [The Giving Block](https://thegivingblock.com) - Dynamic wallet addresses for tax-deductible donations

Current charity address can be updated via `setCharity()` by owner.

## Development

```bash
forge build           # Compile
forge test            # Run tests (103 tests)
forge test -vvv       # Verbose output

# Deploy
source .env && forge script script/DeployV2.s.sol --rpc-url $RPC_URL --broadcast
```

## Architecture

- **UUPS Proxy**: Upgradeable via ERC-1967 proxy pattern
- **P-256 Verification**: Uses RIP-7212 precompile on Base (with OZ fallback)
- **Weekly Cohorts**: Users grouped by stake week for fair winner distribution
- **Dual Token**: Separate pools for ETH and USDC

## License

MIT
