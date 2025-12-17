# Project Guidelines

## Overview
Proofwell is a protocol and iOS app that helps users reduce phone usage by staking money on their screen time goals. Users stake ETH or USDC, commit to daily screen time limits, and earn back their stake (plus a share of losers' funds) if they succeed.

## Architecture

### Sister Repository
The iOS app lives at `~/Projects/proofwell-mvp` with:
- SwiftUI app (iOS 17+) using `@Observable` pattern
- Screen time tracking via Family Controls / DeviceActivity APIs
- Secure Enclave P-256 keys for signing daily proofs
- Dual wallet support: WalletConnect (external) + Privy embedded smart wallets (ERC-4337)
- CDP gas sponsorship for embedded wallets (users don't pay gas)

### Contract Versions
- **V1** (`ProofwellStaking.sol`): Deprecated, ETH-only, no upgradability
- **V2** (`ProofwellStakingV2.sol`): Current production - UUPS upgradeable, ETH + USDC, tiered distribution, cohort system

## Deployed Addresses (Base Sepolia)

| Contract | Address |
|----------|---------|
| ProofwellStakingV2 (Proxy) | `0xb1184802b3f7129Ae710f5c24F7d49912013dAF0` |
| ProofwellStaking V1 | `0x0c3FAE9B28faE66B0e668774eA3909B42729e4B6` |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

## Core Flow

1. **Stake**: User calls `stakeETH()` or `stakeUSDC()` with goal, duration, and P-256 public key
2. **Daily Proof**: iOS app signs proof with Secure Enclave, submitted via `submitDayProof(dayIndex, goalAchieved, r, s)`
3. **Claim**: After challenge ends, user calls `claim()` to get base stake + winner pool share

## Key Technical Details

### P-256 Proof Verification
- iOS Secure Enclave generates hardware-backed P-256 keys
- Message hash: `keccak256(user, dayIndex, goalAchieved, chainId, contractAddress)`
- Contract verifies via RIP-7212 precompile (with OpenZeppelin fallback)

### Cohort System (V2)
- Users grouped by week of staking (`block.timestamp / 604800`)
- Slashed funds distributed: 40% winners, 40% treasury, 20% charity
- Winners = users with 100% success rate in their cohort

### Constants
- Grace period: 6 hours after each day
- Min stake: 0.001 ETH or 1 USDC
- Max duration: 365 days

## Development Commands

```bash
# Build
forge build

# Test
forge test

# Test with via_ir (for CI/size optimization)
FOUNDRY_PROFILE=ci forge test

# Format
forge fmt

# Deploy V2
forge script script/DeployV2.s.sol --broadcast --rpc-url base_sepolia
```

## Repomix

For AI context packing, run `npx repomix`. Config is in `repomix.config.json`.

### Cross-Repo Context
When working on contract changes that affect the iOS app, read the sister repo's repomix output for full context:
```bash
# Read iOS app codebase context
cat ~/Projects/proofwell-mvp/repomix-output.txt
```

This is especially useful for understanding:
- How the iOS app signs proofs (Secure Enclave P-256)
- Wallet integration (WalletConnect + Privy embedded wallets)
- How contract ABIs are consumed in Swift

## Git Workflow
- Keep commit messages concise
- Do not include Claude attribution or "Generated with Claude" footer
- Do not include Co-Authored-By lines mentioning Claude
- Focus on what changed and why
- Push meaningful changes when work is finished (don't wait to be prompted)
