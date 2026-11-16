# Morpheus bug F1 — Proof of Concept: DepositPool self-referral double-dip

## What this proves

`DepositPool.stake()` on Ethereum accepts any `referrer` with **no check that
`referrer != msg.sender`**. A staker can name themselves as their own referrer
and earn rewards twice on the same deposit: once as a staker (with the 1%
referral bonus) and once as a referrer (3–15% of their own deposit as extra
virtual stake, credited to the pool's `totalVirtualDeposited`, diluting every
other staker). The referrer leg pays out real MOR via `claimReferrerTier` →
Distributor `sendMintMessage` → LayerZero → `L2MessageReceiver` mint on
Arbitrum.

This test stakes the same amount from two fresh, permissionless accounts on a
mainnet fork — one self-referred, one honest — and shows the self-referrer
ends up with measurably more claimable MOR, then executes both claims
(`claimReferrerTier` + `claim`) and asserts the exact `ReferrerClaimed` /
`UserClaimed` events.

## Result

```
[PASS] test_selfReferralDoubleDip() (gas: 4301817)
```

## Pinned fork

- **Chain:** Ethereum mainnet
- **RPC:** `https://ethereum-rpc.publicnode.com` (public)
- **Fork block:** **26,426,672** (2026-11-16)
- **Foundry:** forge 1.9.0, solc 0.8.28

## Target

- **Contract:** DepositPool, implementation `0xdB10dAEF167eA2233Ba6811457dD24D676FbD670`, version 7
- **Proxy used:** stETH pool `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790` (all 5 pools share the implementation)
- **Distributor:** `0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A`
- **stETH:** `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`

## Exact amounts (this PoC)

Both accounts stake ~62.51 stETH (tier 3, 15% referrer multiplier).
All figures are exact wei values from the passing test run.

| Quantity | Attacker (self-referred) | Honest (no referrer) |
|---|---|---|
| Staked (stETH) | 62.509999999999999999 | 62.509999999999999999 |
| Referrer `amountStaked` | 62.509999999999999998 | 0 |
| Referrer `virtualAmountStaked` | 9.376499999999999999 (15%) | 0 |
| Own `virtualDeposited` | 63.135099999999999997 (1.01x) | 62.509999999999999999 (1.00x) |
| Own pending MOR after 30 days | 517.461622861348225816 | 512.338240456780421616 |
| Referrer pending MOR after 30 days | 76.850736068517063235 | 0 |
| **Total pending MOR after 30 days** | **594.312358929865289051** | **512.338240456780421616** |
| **Extra MOR vs honest (30 days)** | **81.974118473084867435** | — |

- Pool `totalVirtualDeposited` after both stakes: 9,558.907343128859587346
  stETH-equiv (was 9,423.89 at the fork block).
- The extra 81.97 MOR over 30 days annualises to ~997 MOR/year — exactly the
  audit's projection for a 62.5 stETH tier-3 self-referrer (~997 MOR/yr,
  ~6,845 MOR / ~$4,893 over the full remaining schedule at MOR $0.7148).
- The referrer leg alone is worth 76.85 MOR in 30 days; the remaining ~5.12
  MOR of the extra comes from the 1% referral bonus on the attacker's own
  stake.
- After the claims, all three pending-reward views read 0 for both accounts,
  and the `ReferrerClaimed` / `UserClaimed` events carry the exact amounts
  above. The LayerZero `send()` executes on the fork (the packet is recorded);
  the actual MOR mint happens on Arbitrum and is therefore not observable on
  this fork — the ETH-side state change and events are the proof that the
  claim path pays out.

## How to reproduce

```bash
cd poc
forge test
```

That is the whole command. The test is self-contained: it forks Ethereum
mainnet at block 26,426,672 from the public RPC above and needs no API key,
no private key, and no local state. It performs **no mainnet transactions and
spends no real funds** — everything runs on the fork.

## How the test sets up the fork state (and why)

1. **Funding with stETH.** stETH is rebasing: its "balance" slot holds
   shares, so forge-std `deal()` fails its `balanceOf` check. The test writes
   shares directly with `vm.store` — the shares mapping lives at storage
   slot 0 (verified: `keccak256(abi.encode(who, 0))` matches the slot
   `stdstore` found). Amounts are converted with `getSharesByPooledEth`
   (62.51 ether of pooled ETH ≈ 50.03 ether of shares at the fork-block
   ratio of ~1.2493). The 1-wei difference between the funded balance and the
   recorded `amountStaked` is share→pooled rounding in the Distributor's
   balance-difference measurement.
2. **Approval target.** The Distributor — not the Pool — pulls the tokens in
   `supply()`, so the approval goes to the Distributor
   (`0xDf1AC1AC…`). Approving the Pool reverts with `ALLOWANCE_EXCEEDED`.
3. **Lido yield simulation.** Lido's share price only advances when the
   oracle reports new beacon rewards; a bare time warp leaves it frozen, so
   the stETH pool (which holds stETH directly, Strategy `NONE`) would show
   zero yield and `distributeRewards` would park the period rewards in
   `undistributedRewards` instead of crediting the pools. The test simulates
   30 days of beacon-chain rewards by lifting the CL validators balance —
   the low 128 bits of slot
   `0x096e465397f38e659238ccd5d5a2c434ced54a63fd8d694045bfb058ab9d8112`
   (`keccak256("lido.Lido.clValidatorsBalanceAndClPendingBalance")`) — by
   0.25% (~3% APR), exactly as an oracle report would (9,606,402.64 →
   9,630,418.65 ETH). This only changes the fork's local state; it does not
   touch the vulnerability or any Morpheus accounting.
4. **Chainlink price refresh.** After the warp the feeds are stale (delays
   1h/24h) and `distributeRewards` reverts with `DR: price for pair is
   zero`. The test lifts each feed's `allowedPriceUpdateDelay` to max for all
   5 pool paths (`stETH/USD`, `wBTC/BTC,BTC/USD`, `wETH/USD`, `USDC/USD`,
   `USDT/USD`). The consumer's storage layout (verified on the fork): the
   `dataFeeds` mapping lives at slot 201 and `allowedPriceUpdateDelay` at
   slot 202 (OZ v4 storage gaps push them out). Note: the deployed
   implementation's `dataFeeds` getter selector (`0x67a7cfb7`) is absent from
   its bytecode even though the verified source declares the mapping public,
   so the feeds are read from raw storage instead of via the getter.
5. **Reward split on the fork.** Only the stETH pool shows yield on the fork
   (the other four pools use the AAVE strategy, and their Aave interest does
   not advance without a reserve interaction), so the stETH pool receives the
   full period rewards (~82,578 MOR for the 30 days). On mainnet the rewards
   would be split pro-rata by yield across all pools. This inflates the
   absolute 30-day figures slightly versus mainnet, but it does not affect
   the proof: the attacker-vs-honest delta is driven by the referrer virtual
   stake, and the audit's quantification (which uses the real on-chain pool
   totals and schedule) stands on its own.

## What the test asserts

1. The attacker's `stake(0, 62.5 ether, 0, attacker)` succeeds — no
   `referrer != msg.sender` check exists.
2. The attacker's `referrersData` shows `amountStaked` == their deposit and
   `virtualAmountStaked` == 15% of it; the honest staker's referrer record is
   0. The attacker's own virtual deposit is 1.01x; the honest staker's is
   1.00x.
3. After 30 days and `distributeRewards(0)`, the attacker's referrer pending
   reward is > 0, the honest staker's is 0, and the attacker's total pending
   exceeds the honest staker's by ~82 MOR.
4. `claimReferrerTier` and `claim` execute (0.5 ETH each for the LayerZero
   fee) and emit `ReferrerClaimed` / `UserClaimed` with the exact pending
   amounts; afterwards all pending-reward views read 0.

## Suggested fix (from the audit)

In `DepositPool.stake` (and any path that sets/changes a referrer), add
`require(referrer_ != _msgSender(), "DS: referrer can't be the staker")`.
Existing self-referrals (if any) should be migrated off by the owner; the fix
only stops new ones.

## Files

- `test/SelfReferral.t.sol` — the PoC test
- `foundry.toml`, `lib/` — Foundry project (forge-std is auto-detected from `lib/`)
