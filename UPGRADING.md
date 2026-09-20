# Upgrading

How to change deployed contract logic on Robinhood Chain mainnet, and what you cannot change.

Every address below is the live generation in `web/.env.mainnet`, read back from chain on
2026-09-08 after the post-review redeploy (the README's deployment table is the full set).

> **⚠ The timelock delay is currently ZERO.** Schedule and execute land in the same block,
> so the beacon is effectively owned outright by the deployer EOA. This is a pre-launch
> iteration setting. **Raising it is a launch blocker** — see *Limits* at the bottom.

---

## What is upgradable

| Contract | Address | Mechanism | Controlled by |
|---|---|---|---|
| **All BrandedVaults** | via beacon `0x1a874e79Ab3cfC70362C4aA245130b96F6e38Baa` | `UpgradeableBeacon.upgradeTo` | Timelock |
| **BrandedVaultFactory** | proxy `0x1A5393af478B28c8AA3E60eAD24Ac8269ae059bb` | UUPS `upgradeToAndCall` | Timelock |

Current implementations: vault `0x19F9fDeafaF9cBD8C2140f40632e59de972e1E96`, factory
`0x8658354fd7CfA74eE12a82b47FCab3Ce7967709c`.

**One beacon upgrade changes every vault at once** — existing and future, instantly, with no
per-vault migration. That is the feature and the danger.

## What is NOT upgradable

| Contract | Address | Replaceable? |
|---|---|---|
| `StablecoinLauncher` | `0xecF46dC819Ef7523b842852B1026a5622889FB11` | **No** — see below |
| `SweepKeeper` | see README (not recorded for the live generation) | Yes — deploy a new one, re-register jobs |
| `MorphoBlueYieldSource` | `0x7CEDfC7d33336c59461350f411271C0ce6AF4343` | Yes — `vault.setYieldSource(new)`, brand only |
| `PoolDeployer` / `MarketLauncher` / `MemecoinFactory` | see README | Yes — deploy new, re-point clients |
| `VaultTreasury` (per vault) | via `factory.getTreasury(vault)` | Yes — `treasury.setVaultBrand(newBrand)`. **Migration pending, see below** |

### The launcher is permanent for coins already launched

`StablecoinLauncher`'s entire external surface is `launch`, `launchAtPar`, `sweep` and
`onERC721Received`. There is no owner, no arbitrary call, and **no way to transfer the sell
wall's LP NFT out of it**. `BrandedVault.configureSeed` is one-shot, so a replacement
launcher can never become an existing vault's `seedMinter`.

That is deliberate — it is what stops a brand from re-pointing the unbacked mint at an
address they control — but it is one-way. If `sweep` ever proves broken for `sphUSDG`:

- the USDG buyers pay in can never reach the vault, so no yield ever accrues on it
- `maxRedeem` stays capped, so NAV redemption stays broken
- holders can still exit by selling back into the pool on Uniswap, at market rather than NAV
- upgrading `BrandedVault` does **not** rescue it — the NFT is still stuck in the launcher
- the only real fix is relaunching a new coin with a fixed launcher

**If you want an escape hatch, add it to `StablecoinLauncher` before the next launch.**
Already-launched coins cannot be retrofitted.

---

## Before you upgrade anything: storage rules

This is the part that loses money. A bad layout does not revert — the proxy silently
reinterprets live state, so `seedMinted` starts being read as `lastHarvestPPS` on real
balances, across every vault simultaneously.

`BrandedVault` currently occupies **55 slots**: 11 declared (0–10) plus `__gap[44]`
(11–54). Verify any time with `forge inspect BrandedVault storageLayout`.

Rules for a V2:

1. **Only append.** New variables go immediately before `__gap`, never inserted or
   reordered, never retyped, never removed.
2. **Shrink `__gap` by exactly the number of slots you added**, so the 55-slot footprint is
   unchanged. Two `address` fields do not share a slot — that is 2 slots, not 1.
3. **Update `test_storageLayout_slotsArePinned`** in `test/Upgradeability.t.sol`
   deliberately, as a review checkpoint. Never edit it just to make a red test go green —
   that test failing is the alarm working.
4. `initialize` has `initializer` and cannot run again. New state needs a `reinitializer(n)`
   function, executed through the same timelock flow.

Run `forge test --match-contract Upgradeability` before proposing anything.

---

## Rehearse on a fork first

Non-negotiable for the beacon: it touches every vault at once.

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8545
```

Then run the whole schedule/execute flow below against `http://127.0.0.1:8545`, using
`cast rpc anvil_impersonateAccount` for the proposer. If the delay is non-zero by then, jump
it with `cast rpc evm_increaseTime <delay>`. Confirm afterwards that a real vault reports the
right
`totalAssets`, `circulatingSupply`, `seedMinted` and `convertToAssets(1e6)`.

---

## Procedure A — upgrade every vault (beacon)

**1. Deploy the new implementation.** It must never be initialized directly; the constructor
already calls `_disableInitializers()`.

```bash
forge create src/BrandedVault.sol:BrandedVault --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
```

**2. Build the calldata.**

```bash
cast calldata 'upgradeTo(address)' <NEW_IMPL>
```

**3. Compute the operation id.** Pick a unique `SALT` — reusing one with identical calldata
collides with a past operation and `schedule` reverts.

```bash
cast call 0x073fAE6c633e914e3BEf20e71b0352742C70508B 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' 0x1a874e79Ab3cfC70362C4aA245130b96F6e38Baa 0 <CALLDATA> 0x0000000000000000000000000000000000000000000000000000000000000000 <SALT> --rpc-url $ETH_RPC_URL
```

**4. Schedule it.** Delay must be ≥ the current `getMinDelay()`, which is `0` today — so
pass `0` and it is executable immediately. Once you raise the delay before launch, pass that
value here instead.

```bash
cast send 0x073fAE6c633e914e3BEf20e71b0352742C70508B 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' 0x1a874e79Ab3cfC70362C4aA245130b96F6e38Baa 0 <CALLDATA> 0x0000000000000000000000000000000000000000000000000000000000000000 <SALT> 0 --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
```

**5. Wait for the delay.** At zero there is no wait — it is ready in the same block. Check
either way:

```bash
cast call 0x073fAE6c633e914e3BEf20e71b0352742C70508B 'isOperationReady(bytes32)(bool)' <ID> --rpc-url $ETH_RPC_URL
```

**6. Execute** — same arguments, minus the delay:

```bash
cast send 0x073fAE6c633e914e3BEf20e71b0352742C70508B 'execute(address,uint256,bytes,bytes32,bytes32)' 0x1a874e79Ab3cfC70362C4aA245130b96F6e38Baa 0 <CALLDATA> 0x0000000000000000000000000000000000000000000000000000000000000000 <SALT> --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
```

**7. Verify.**

```bash
cast call 0x1a874e79Ab3cfC70362C4aA245130b96F6e38Baa 'implementation()(address)' --rpc-url $ETH_RPC_URL
```

Then spot-check a live vault's `totalAssets`, `circulatingSupply` and `seedMinted` against
what they read before the upgrade.

---

## Procedure B — upgrade the factory (UUPS)

Identical flow, with two differences: the **target is the proxy**, not an implementation,
and the function is `upgradeToAndCall`. OpenZeppelin v5 removed plain `upgradeTo` from UUPS
— calling it will fail.

```bash
cast calldata 'upgradeToAndCall(address,bytes)' <NEW_IMPL> 0x
```

Pass `0x` for `data` unless you need a `reinitializer` call in the same transaction. Then
schedule/execute exactly as above, with target `0x1A5393af478B28c8AA3E60eAD24Ac8269ae059bb`.

---

## Procedure C — replace a yield-source adapter (no timelock involved)

Adapters are plain contracts: no proxy, no beacon, no upgrade path. Changing one means deploying
a new instance and moving each consumer across. This is **not** governed by the timelock for
vaults — `BrandedVault.setYieldSource` is gated on `brand`, the vault's treasury.

### Why this is pending on mainnet

Both deployed `MorphoBlueYieldSource` instances predate the per-consumer share accounting added on
2026-09-08 and carry the version whose `withdraw(asset, amount, to)` has **no access control and
an arbitrary `to`** — anyone can send the whole Morpho position to themselves. Verified by calling
`sharesOf(address)` on each: both revert, so the mapping is not in the deployed bytecode.

| Adapter | Used by | Morpho position today |
|---|---|---|
| `0x79a9ca5Fa46a0C4779E6332e7D49d2c241c50281` | flagship vault `0x54f8…0454` | **0** |
| `0x2cEb049DC891Ca7546ec93467eD9A3DdC31e21ba` | superseded vault `0x048B…1E92` | **0** |

**Nothing is exposed while those are zero.** The flagship vault's `totalAssets()` is 0 — its 1B
shares are unbacked seed inventory resting in the sell wall. The position becomes drainable the
first time `deployIdle()` runs after a sweep moves real USDG into the vault. **Migrate before that
happens.**

### Steps

**1. Deploy a fresh adapter** from current source, one per consumer:

```bash
forge create src/yield/MorphoBlueYieldSource.sol:MorphoBlueYieldSource --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY --constructor-args 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010 0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6
```

Confirm it is the fixed build — this must return `0`, not revert:

```bash
cast call <NEW_ADAPTER> 'sharesOf(address)(uint256)' 0x0000000000000000000000000000000000000001 --rpc-url $ETH_RPC_URL
```

**2. Point the vault at it.** Brand (treasury) key only:

```bash
cast send <VAULT> 'setYieldSource(address)' <NEW_ADAPTER> --rpc-url $ETH_RPC_URL --private-key $BRAND_KEY
```

`setYieldSource` harvests fees, recalls the **entire** deployed balance from the old adapter, then
swaps the pointer. Capital lands idle on purpose — it never auto-commits to a freshly-set adapter.

**3. Redeploy the capital:**

```bash
cast send <VAULT> 'deployIdle()' --rpc-url $ETH_RPC_URL --private-key $ANY_FUNDED_KEY
```

**4. Verify** the old adapter is empty and the new one carries the position:

```bash
cast call <VAULT> 'deployedAssets()(uint256)' --rpc-url $ETH_RPC_URL
cast call <OLD_ADAPTER> 'balanceOf(address)(uint256)' 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 --rpc-url $ETH_RPC_URL
```

For `SharedReservePool` the same procedure applies with `pool.setYieldSource(...)`, except it is
**owner-only**, so it goes through that pool's timelock as a scheduled operation.

---

## Procedure D — replace a VaultTreasury (also not upgradeable)

Same situation as the adapters, same reason: the flagship treasury
`0x9fe9edC896D7Bce0d072EdcE3fBbE83Afbc5166F` was deployed by the factory during the 2026-09-08
redeploy, which is **before** `redeemAll`/`redeem` were gated to `onlyAdmin`. It is still open to
anyone with an arbitrary `receiver`.

Confirm which build a treasury is, without spending gas — a gated one reverts `OnlyAdmin`, an
ungated one falls through to the `shares == 0` early return and answers `0`:

```bash
cast call <TREASURY> 'redeemAll(address)(uint256)' 0x000000000000000000000000000000000000dEaD --from 0x00000000000000000000000000000000DeaDBeef --rpc-url $ETH_RPC_URL
```

**Nothing is at risk while the treasury holds no shares.** It only receives them from
`vault.harvestFees()`, which mints against yield the vault has earned — currently zero. **The
first harvest is the deadline.**

**1. Deploy a treasury from current source**, pointed at the same vault and admin:

```bash
forge create src/VaultTreasury.sol:VaultTreasury --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY --constructor-args <VAULT> <ADMIN>
```

**2. Point the vault at it**, as the *current* treasury's admin. `setVaultBrand` calls the
brand-gated `vault.setBrand` on your behalf — the vault will not accept the change any other way:

```bash
cast send <OLD_TREASURY> 'setVaultBrand(address)' <NEW_TREASURY> --rpc-url $ETH_RPC_URL --private-key $ADMIN_KEY
```

**3. Verify**, and re-run the probe above against the new treasury — it must now revert:

```bash
cast call <VAULT> 'brand()(address)' --rpc-url $ETH_RPC_URL
```

If the old treasury already holds shares when you migrate, redeem or transfer them out **first**
— `setVaultBrand` redirects future fee shares and moves nothing that has already accrued.

### One adapter per consumer

`sharesOf` makes sharing an instance *safe* — two consumers stay fully isolated — but a dedicated
instance is still the rule: it keeps each position independently readable, and it is the only
arrangement `AaveV3YieldSource` permits at all (`bindController` binds it to one consumer for
life, and an unbound adapter is inert). Bind atomically at deploy time; a bound controller cannot
be changed.

---

## Cancelling a scheduled upgrade

Proposers are also cancellers (OpenZeppelin grants both), and the deployer holds the role —
verified on-chain.

**At the current zero delay there is no window to cancel in**: an operation is executable in
the block it was scheduled. This only becomes a real safety net once the delay is raised.

```bash
cast send 0x073fAE6c633e914e3BEf20e71b0352742C70508B 'cancel(bytes32)' <ID> --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY
```

---

## Limits you should know

**The delay is zero, so there is currently no timelock protection at all.** A leaked
deployer key drains every vault in one transaction: schedule and execute in the same block,
with nobody able to cancel in between. This is acceptable only because nothing meaningful is
deposited yet.

**Raising it is cheap; lowering it is not.** `updateDelay` is callable only by the timelock
itself, so a change must go through schedule/execute at the *current* minimum. From zero,
raising executes immediately. From 48h, lowering costs a 48-hour wait — which is exactly why
this deployment was rebuilt rather than waiting one out. Do the raise last, right before you
announce:

```bash
cast calldata 'updateDelay(uint256)' 172800
```

Schedule that against the timelock's **own address**, then execute it.

**There is no pause.** Nothing in `BrandedVault` or `BrandedVaultFactory` can be halted, so
once the delay is raised it also becomes your floor on incident response. Adding `Pausable`
is worth considering in a V2 — but the pause switch is itself a censorship lever, so it
belongs behind the timelock or a multisig, not an EOA.

**The timelock is one EOA.** `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` is proposer,
executor and canceller. It is not the admin — the timelock is its own admin — so role
changes cost whatever the delay is at the time. A leaked key means an attacker schedules a
malicious implementation and drains every vault — instantly at the current zero delay, or
after the delay once raised. The delay only helps if somebody is watching.

**The contracts are unverified on the explorer.** Nobody can read what a pending upgrade
actually does during its window, which removes most of the delay's value. Verify before the
first real upgrade.

### Migrating roles to a multisig

Role changes go through the timelock itself, so they cost the current delay too. Grant
first, renounce
second, and confirm the new holder works before giving up the old one:

```bash
cast calldata 'grantRole(bytes32,address)' <PROPOSER_ROLE> <MULTISIG>
```

Schedule that against the timelock's own address, wait, execute, then repeat for
`EXECUTOR_ROLE` and `CANCELLER_ROLE` before renouncing the EOA's roles.

---

## Pre-flight checklist

- [ ] `forge test` green, including `test_storageLayout_slotsArePinned`
- [ ] `forge inspect BrandedVault storageLayout` still totals 55 slots
- [ ] Fork rehearsal completed, vault state intact afterwards
- [ ] New implementation deployed and **verified on the explorer**
- [ ] Operation id computed and recorded before scheduling
- [ ] Salt is unique to this operation
- [ ] Delay raised to a real value before any announcement (currently **0**)
- [ ] Someone is watching the delay window and can `cancel`
- [ ] Post-execute spot-check planned against real vault state
- [ ] **Yield adapter migrated (Procedure C) before any USDG is deployed** — both live adapters
      are the pre-fix, drainable build
- [ ] **Flagship VaultTreasury migrated (Procedure D) before the first `harvestFees`** — the
      deployed one still has permissionless `redeemAll`/`redeem`
