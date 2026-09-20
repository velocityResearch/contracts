# deployments/

Two kinds of file live here and they are maintained in opposite ways. Confusing them is what
produced the contradiction this directory used to carry: `asset-markets-mainnet-v6.json` claimed
zero markets and zero launches while other keys in the same file described a live market and a
graduated token.

## Generated: never hand-edit

`mainnet-state.json` is the only generated file here. Every value in it is an `eth_call` or an
`eth_getStorageAt` result read from chain 4663, and it carries `generatedAt`, `blockNumber` and
`generatedBy` at the top so a stale copy is self-evident: compare `blockNumber` against the
chain and the file either is or is not current. The snapshot in this repository was taken at
block 68196940 on 2026-09-20.

**The generator itself is not in this repository.** `script/sync-mainnet-state.mjs` was a Node
script that imported from the web application, so it did not survive the extraction of this
contracts-only tree, and the `generatedBy` / `regenerateWith` strings inside the JSON still
name it. Treat the file as a frozen, dated snapshot rather than something you can refresh
here. Nothing in `src/`, `test/` or `script/` reads it; it exists so a reviewer can see what
the chain said without an RPC endpoint.

To check a value rather than trust the snapshot, read it off the chain directly — every field
in it is one `cast call` away, and `script/VerifyAssetMarketsMainnet.s.sol` re-derives the
important ones in a single read-only run:

```
SHARED_RESERVE_POOL=0x… ASSET_MARKET_FACTORY=0x… MARKET_ROUTER=0x… forge script script/VerifyAssetMarketsMainnet.s.sol --rpc-url robinhood
```

Raw integer fields carry a `Raw` suffix and are decimal strings in base units. The suffix-free
sibling is the same number scaled by the token's decimals and exists only so a human can read a
balance without counting zeros. Reads that fail are collected in the top-level `failures` array
rather than silently zeroed, because a zero and a missing selector look identical in JSON and
mean opposite things.

## Hand-maintained: the address book and the reasoning

Everything else, one file per deployment generation. Their job is to record addresses, the
decisions behind them, and the open items that follow. They do not record counts, balances, fee
rates, caps, owners, pending nominations, proxy implementations or per-pool fees. Those all
moved into `mainnet-state.json`, and the corresponding keys were deleted rather than updated.

**Mainnet, chain 4663:**

- `asset-markets-mainnet-v6.json` is the live generation. Start here.
- `asset-markets-mainnet-v5.json`, `asset-markets-mainnet-v4.json`, `asset-markets-mainnet.json`
  describe superseded generations that are still deployed on chain 4663. They are the record of
  what exists, not of what is in use, and they are deliberately not deleted. Gen-4 is the only
  abandoned generation that ever held value; its live residual is under the `gen4` key of
  `mainnet-state.json`, not in its own manifest.
- `safe-batches/` holds the Safe Transaction Builder batches for the custody migration, plus
  its own README explaining which ran and which is still only prepared.

**Other chains and environments**, all per-run snapshots that are not regenerated:

- `asset-markets-testnet.json`, `asset-markets-web-testnet.json`, `susdai-testnet.json`,
  `susdai-web-testnet.json` — Robinhood testnet 46630.
- `asset-markets-base-sepolia.json`, `base-sepolia-launchpad-2026-09-16.json` — the Base
  Sepolia integration environment, including the Across round-trip accounting.
- `asset-markets-qa-2026-09-09.json` — one dated QA run.
- `app-networks.json` — addresses only, in the shape the web application consumes at build
  time. That application is not in this repository; the file is kept here because this is
  where the addresses are decided.

The dividing rule, applied to anything you are about to write down: if a getter can answer it,
the chain owns it and a copy here will be wrong within days. If it explains a decision, a
tradeoff or a risk, it belongs here and no generator can recover it.

## Adding a field

Two copies of one fact is the failure mode, not the fix: the sUSDai adapter's implementation
address was recorded twice in the v6 manifest and the two copies disagreed for two days, which
is why all ten ERC-1967 slots are read from chain and the manifests record none of them. If you
add a fact that a getter can answer, delete the hand-written key it replaces in the same change.

Addresses were never hardcoded in the generator; they were resolved from the manifests. Four
generations live on chain 4663 and three are abandoned, so a constant pasted from the wrong
manifest reads the wrong contract and reports a healthy-looking lie. The same care applies to
anything you write by hand: say which generation an address belongs to.
