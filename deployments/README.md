# deployments/

Two kinds of file live here and they are maintained in opposite ways. Confusing them is what
produced the contradiction this directory used to carry: `asset-markets-mainnet-v6.json` claimed
zero markets and zero launches while other keys in the same file described a live market and a
graduated token.

## Generated: never hand-edit

| File | Written by |
| --- | --- |
| `mainnet-state.json` | `script/sync-mainnet-state.mjs` |

Regenerate it with one command, from the repository root:

```
node script/sync-mainnet-state.mjs
```

That is the whole interface. The script is read-only: every call is an `eth_call` or an
`eth_getStorageAt`, there is no signer, and no private key is read, so an auditor holding
nothing but the RPC URL can reproduce the file. It refuses to run against any chain other than
4663. Optional environment: `ROBINHOOD_RPC_URL` to point at a different endpoint, `OUT` to
write elsewhere, `DRY_RUN=true` to print to stdout and write nothing.

`mainnet-state.json` carries `generatedAt`, `blockNumber` and `generatedBy` at the top so a
stale copy is self-evident: compare `blockNumber` against the chain and the file either is or
is not current. There is no merge story for hand edits, and none is wanted. If a value in it
looks wrong, re-run the script; if it still looks wrong, the chain disagrees with you.

Raw integer fields carry a `Raw` suffix and are decimal strings in base units. The suffix-free
sibling is the same number scaled by the token's decimals and exists only so a human can read a
balance without counting zeros. Reads that fail are collected in the top-level `failures` array
rather than silently zeroed, because a zero and a missing selector look identical in JSON and
mean opposite things.

## Hand-maintained: the address book and the reasoning

Everything else, one file per deployment generation. Their job is to record addresses, the
decisions behind them, and the open items that follow. They do not record counts, balances, fee
rates, caps, owners, pending nominations, proxy implementations or per-pool fees. Those all moved
into `mainnet-state.json`, and the corresponding keys were deleted rather than updated.

- `asset-markets-mainnet-v6.json` is the live generation. Start here.
- `asset-markets-mainnet-v5.json`, `asset-markets-mainnet-v4.json`, `asset-markets-mainnet.json`
  describe superseded generations that are still deployed on chain 4663. They are the record of
  what exists, not of what is in use, and they are deliberately not deleted. Gen-4 is the only
  abandoned generation that ever held value; its live residual is under the `gen4` key of
  `mainnet-state.json`, not in its own manifest.
- `app-networks.json` is consumed by the application at build time. Addresses only.
- The testnet and QA manifests are per-run snapshots and are not regenerated.

The dividing rule, applied to anything you are about to write down: if a getter can answer it,
the generator owns it and a copy here will be wrong within days. If it explains a decision, a
tradeoff or a risk, it belongs here and no generator can recover it.

## Adding a field to the generated file

Add the read to `script/sync-mainnet-state.mjs` and delete the hand-written key it replaces in
the same change. Two copies of one fact is the failure mode, not the fix: the sUSDai adapter's
implementation address was recorded twice in the v6 manifest and the two copies disagreed for
two days, which is why the script now reads all ten ERC-1967 slots directly and the manifest
records none of them.

Addresses in the generator are resolved from the manifests, never hardcoded. Four generations
live on chain 4663 and three are abandoned, so a constant pasted from the wrong manifest reads
the wrong contract and reports a healthy-looking lie.
