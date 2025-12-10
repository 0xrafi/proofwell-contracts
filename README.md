# Proofwell Contracts

Stake ETH/USDC on screen time goals. Miss your goal = lose stake. Beat it = keep stake + earn from others who failed.

## Deployed (Base Sepolia)

| Contract | Address |
|----------|---------|
| ProofwellStakingV2 (Proxy) | `0xb1184802b3f7129Ae710f5c24F7d49912013dAF0` |
| ProofwellStaking (V1) | `0x0c3FAE9B28faE66B0e668774eA3909B42729e4B6` |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

## How It Works

1. **Stake** - Lock ETH or USDC with a daily screen time goal (e.g., "< 2 hours/day for 14 days")
2. **Prove** - Submit daily proofs via P-256 signatures (Apple App Attest)
3. **Claim** - After challenge ends: get back (stake × successful_days / total_days) + winner bonus

### Slashed Funds Distribution
```
40% → Winner pool (split among 100% successful users in same cohort)
40% → Treasury
20% → Charity
```

## Functions

### User
| Function | Description |
|----------|-------------|
| `stakeETH(goal, days, pubKeyX, pubKeyY)` | Stake ETH (min 0.001) |
| `stakeUSDC(amount, goal, days, pubKeyX, pubKeyY)` | Stake USDC (min 1, needs approval) |
| `submitDayProof(dayIndex, achieved, r, s)` | Submit P-256 signed daily proof |
| `claim()` | Withdraw after challenge ends |

### View
| Function | Description |
|----------|-------------|
| `getStake(user)` | Get stake details |
| `canSubmitProof(user, day)` | Check if proof window is open |
| `getCurrentDayIndex(user)` | Current day in challenge |
| `getCohortInfo(week)` | Pool balances and winner count |

### Admin (owner only)
| Function | Description |
|----------|-------------|
| `pause()` / `unpause()` | Emergency stop |
| `setTreasury(addr)` | Update treasury |
| `setCharity(addr)` | Update charity |
| `setDistribution(w, t, c)` | Change split % (must sum to 100) |
| `emergencyWithdraw(token)` | Recover stuck funds |
| `upgradeToAndCall(impl, data)` | UUPS upgrade |

## Development

```bash
forge build
forge test
forge script script/DeployV2.s.sol --rpc-url $RPC_URL --broadcast
```

## Architecture

- UUPS upgradeable proxy pattern
- P-256 signature verification (RIP-7212 precompile on Base)
- Weekly cohorts for winner redistribution
- 6-hour grace period for daily proofs

## License

MIT
