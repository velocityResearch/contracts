# Ownership handover to the Safe — COMPLETE

Safe: `0x28569c1716EF81f307d666A1EC08bDAE92AC0373` (v1.4.1, 2-of-3) on Robinhood Chain 4663.
Retired key: `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9`.

All sixteen handles are owned by the Safe and no nomination is outstanding. This file is kept
as the record of how it was done and as the source of the batches, which are reusable if a
future handover repeats the pattern.

## What is in this directory

| File | State |
|---|---|
| `01-accept-strategy-group-registry.json` | **Executed.** One transaction |
| `02-accept-remaining-eleven.json` | **Executed.** The other eleven two-step handles |
| `03-repoint-fee-recipients.json` | **Prepared, not executed.** See the fee-recipient section below |

## What was done, in this order

**1. `01-accept-strategy-group-registry.json`** — one transaction. `StrategyGroupRegistry` is
read-only metadata that nothing settles against, so a failure cost nothing. The Safe had never
executed a transaction (`nonce` was 0), so this was also the first proof its signers work.

**2. `02-accept-remaining-eleven.json`** — the rest of the two-step handles, including both
reserves, the market factory, the router and the fee hook.

**3. `PHASE=2`** — the four beacons, one step and irreversible. The script refuses to run
until at least one phase-1 handle has been accepted, because that is the only real evidence
the signers can sign.

Verify the end state at any time:

```
forge test --match-contract OwnershipMigrationMainnetForkTest --threads 1 --fork-url https://rpc.mainnet.chain.robinhood.com
```

That suite asserts all sixteen are the Safe's, that no nomination is left, that the retired
key reverts on every owner-only call including all four beacons, and that the Safe can still
govern each class of handle. It also pins the Safe's own shape: threshold 2, three distinct
signers, none of them the retired key, and a nonce above zero.

## Known and accepted: the gen-4 MarketRouter

`0xcCDe2EcDE7072Efe61822551152663F204CF73ce` is an abandoned gen-4 UUPS proxy that is NOT in
`deployments/mainnet-state.json`, which is why the original address sweep missed it. It is
still owned by the retired key and carries a `pendingOwner` nomination to the Safe that was
deliberately left unaccepted. Only the Safe can accept it, so the dangling nomination is inert.

This is a conscious decision, not an oversight: the contract is dead, and the residual risk is
that someone holding the retired key could ship an implementation to a router that still looks
official. Accept the nomination later if that ever matters.

## Deliberately NOT migrated, but rotated: the guardian

`ProtocolGuard.guardian` is **not** the Safe and must never be. It is the address that can
`pause`, and pausing is incident response that must not wait on a second signature and a
coordination call. It stays a single hot key.

It has been rotated off the retired deployer EOA and onto a fresh hot key,
`0xc1d844d6478e450E62293882d2d6739c4a8693F9`, by a Safe transaction built with
`script/RotateGuardianMainnet.s.sol` — `setGuardian` is `onlyOwner`, so the script plans and
prints the batch rather than broadcasting it. There is no `broadcast/` artifact for that
reason; the chain is the record, and `deployments/mainnet-state.json` reads it back.

**The retired key now holds no authority over anything live.** Halting was the last power it
had. `test_live_theRetiredDeployerCannotEvenHalt` in `test/LiveGen5Mainnet.t.sol` asserts
exactly that, so the claim above fails loudly rather than rotting. It is still named as a fee
*recipient* and still owns the dead gen-4 router, both covered above and below; neither is a
power over the live protocol.

## Prepared but not executed: fee recipients

Fee *recipients* are not ownership and did not move with it. A recipient cannot upgrade, halt
or reconfigure anything; repointing one is a separate `onlyOwner` call.

`deployments/mainnet-state.json` records `ProtocolFeeHook.feeRecipientOf` on every registered
pool and `LaunchFactory.protocolFeeRecipient` as still the retired deployer
`0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9`.

`03-repoint-fee-recipients.json` is the batch that changes that, and it has **not** been
executed. Seven transactions:

- `setFeeRecipient` on the hook for four live pools — 13 NVDA, 14 SPCX, 15 AI, 16 SDOGE. The
  remaining registered pools keep the existing hot wallet on purpose.
- Both `LaunchFactory` recipient setters, `setProtocolFeeRecipient` and `setLpFundRecipient`.
- `AssetMarketFactory.setProtocolParams`, naming the Safe for FUTURE markets with `protocolBps`
  left at 0 so LPs keep 100% of float yield.

**Collect before repointing.** `ProtocolFeeHook.collect` pays whoever is named when it runs,
not when the fee accrued, and `LaunchFeeEscrow.claimToken` is `msg.sender`-scoped, so
repointing does not move what has already accrued to the old address. Sweep first with
`script/SweepFeesToSafeMainnet.s.sol`, then send this batch.
