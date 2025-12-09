# Proofwell Contracts

Smart contracts for Proofwell - stake ETH on your screen time goals with cryptographic proof verification.

## Deployed Contracts

| Network | Address |
|---------|---------|
| Base Sepolia | `0x0c3FAE9B28faE66B0e668774eA3909B42729e4B6` |

## Overview

ProofwellStaking allows users to:
- Stake ETH with a screen time goal and duration
- Submit daily P-256 signed proofs from iOS App Attest
- Claim proportional returns based on successful days

### Key Features

- **P-256 Signature Verification**: Uses RIP-7212 precompile with OpenZeppelin fallback
- **Sybil Prevention**: One App Attest key per wallet
- **Proportional Returns**: `(stake * successfulDays) / totalDays`
- **Time Windows**: 6-hour grace period for daily proof submission

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Deploy

```shell
source .env && forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

## License

MIT
