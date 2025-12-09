# PROOFWELL Product Context

## One-Liner

Stake your screen time. Apple verifies. Ethereum enforces.

## Core Differentiator

**This is NOT another screen time tracker.** Users don't come here to feel guilty about phone usage.

They come here to **put money on the line** and **get rewarded** for hitting their goals.

The financial stakes are the product. Everything else is infrastructure.

## What It Is

A screen time accountability app where users stake crypto ($10-100) on their daily screen time goals. Hit your goals → keep your stake + win bonus from the pool. Miss your goals → lose a portion to those who succeeded.

**The motivation loop:**
- Other apps: "You used your phone too much today" → guilt → ignore app
- Proofwell: "You're $12 ahead. 3 more days to lock it in." → motivation → good behavior

## How It Works

1. User sets a screen time goal (e.g., "max 4 hours/day for 30 days")

2. User stakes ETH/USDC via connected wallet → enters the pool

3. Daily: iOS reads Screen Time data, signs proof with App Attest

4. Proof submitted to Base L2 smart contract

5. End of period: Successful users claim stake + share of forfeited funds

## The Economics (Why Good Behavior Pays)

- User stakes $50 for 30 days
- If they hit 30/30 days: Get $50 back + bonus from pool
- If they hit 25/30 days: Get proportional return (~$42)
- If they hit 15/30 days: Get ~$25 back (lost half)
- Those who miss goals fund those who succeed → good behavior is rewarded

**Key insight**: Crypto-native users understand this model. They're used to staking, pools, and earning yield. This is DeFi for self-improvement.

## Target User

- 25-40 year old professionals who know they use their phone too much

- Already crypto-native (has a wallet, understands staking)

- Motivated by financial accountability ("I'll actually do it if money is on the line")

- Wants to be rewarded for good behavior, not just shamed for bad

- Values privacy (exact screen time never leaves device)

## Design Principles

### Visual

- Dark mode only (#0A0A0A background)

- Green accent (#00FF88) for success/progress

- Red (#FF4444) for failures/warnings

- Minimal, clean, no clutter

- Premium feel - this handles real money

### Tone

- Confident, not preachy

- "You got this" not "Stop using your phone"

- Treats user as capable adult

- Acknowledges this is hard but worth it

### UX

- Frictionless onboarding (3 screens max)

- One primary action per screen

- Progress always visible on dashboard

- Wallet connection should feel safe and familiar

- Clear feedback on success/failure states

## Key Screens

1. **Onboarding**: Explain value prop, request permissions

2. **Goal Setup**: Category, time limit, stake amount, duration

3. **Dashboard**: Today's usage, streak, stake status, days remaining

4. **Wallet**: Connection status, address, transaction history

5. **Results**: End-of-period summary, claim button

## Technical Constraints

- iOS only (Screen Time API)

- Requires Family Controls entitlement (pending Apple approval)

- Physical device needed for wallet connections and Screen Time

- Smart contract on Base L2 (low gas fees)

## What Success Looks Like

User opens app once per day, sees they're on track, feels good. At end of month, claims stake and sets a new goal. Simple, effective, not addictive itself.
