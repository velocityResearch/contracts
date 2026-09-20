#!/usr/bin/env bash
set -euo pipefail

# Rehearse the ENTIRE mainnet deployment against a local fork of Robinhood Chain, then
# launch and seed a market on it — using the same scripts and the same runbook commands
# a real deployment would use, in the same order.
#
# Why this exists. Both deploy scripts assert their own wiring, but those assertions only
# run if the scripts run, and the parts most likely to break are the parts a unit test
# cannot reach: CREATE2 hook mining against forge's deterministic factory, linking the
# MarketDeployer library into an EIP-170-sized factory, and the runbook's own `cast`
# argument encodings. Every one of those fails at broadcast time, on mainnet, with money
# already spent. This runs all of it locally first.
#
# It is a rehearsal, not a deployment. It never touches mainnet: anvil forks the chain
# into local state and every transaction lands there.
#
# Usage:
#   script/rehearse-mainnet.sh
#
# Environment:
#   PORT               local anvil port (default 8545)
#   FORK_BLOCK_NUMBER  pin a block for reproducibility (default: chain head)
#   KEEP_ALIVE=1       leave anvil running afterwards so you can poke at the stack
#
# Requires: anvil, cast, forge, python3.

PORT="${PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Anvil's first dev account. A well-known key, which is the point: it is worthless, and
# nothing in this script should ever be pointed at a chain where that matters.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ME=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

# Live mainnet addresses, mirroring script/MainnetAddresses.sol.
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
SPCX=0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa
MORPHO=0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010
POSM=0x58daec3116aae6D93017bAAea7749052E8a04fA7
# The live SPCX/USDG 0.05% v3 pool. Read for a starting price, and impersonated as a
# source of SPCX — a tokenized equity is an issuer-controlled proxy, so its balance slot
# cannot be written directly with any confidence.
V3POOL=0xc61284332117c3FB23A2A56cceFFD07F7aF60029

# forge writes its broadcast records under broadcast/<script>/<chainid>/, and this rehearsal
# runs on chain 4663 — the same directory that holds the record of the REAL mainnet
# deployment. Left alone, a rehearsal silently overwrites run-latest.json with a fork's
# addresses, and the file that is supposed to say what is deployed on mainnet says something
# that only ever existed locally. Redirected here instead, so the rehearsal touches nothing
# the repo tracks.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rehearse-mainnet.XXXXXX")"
export FOUNDRY_BROADCAST="$WORK/broadcast"

ANVIL_PID=""
cleanup() {
  if [[ -n "$ANVIL_PID" && "${KEEP_ALIVE:-0}" != "1" ]]; then
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
  if [[ -n "${WORK:-}" ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

step() { echo ""; echo "=== $* ==="; }

# Read a deployed address out of a deploy script's own output.
#
# This used to parse broadcast/<script>/4663/run-latest.json by `contractName`. The stack is now
# eleven ERC1967 proxies plus five beacons, so forge records almost every deployment under the
# name "ERC1967Proxy" and that JSON can no longer tell a factory from a beacon: a dict keyed on
# contractName silently collapses them onto whichever deployed last. Both scripts label every
# address they create, so read the label instead.
addr_of() { # addr_of <logfile> <label-without-colon>
  grep -F "$2:" "$1" | tail -1 | grep -oE "0x[0-9a-fA-F]{40}" | tail -1
}

# The chain id is forced to mainnet's 4663 because both deploy scripts guard on it, and
# that guard is exactly what this rehearsal is meant to exercise. This is safe here and
# NOT safe in a wallet — see the note in script/anvil-fork.sh.
step "Forking Robinhood Chain mainnet on $RPC"
CHAIN_ID=4663 PORT="$PORT" "$ROOT/script/anvil-fork.sh" > "${TMPDIR:-/tmp}/rehearse-anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  if cast block-number --rpc-url "$RPC" > /dev/null 2>&1; then break; fi
  sleep 1
done
echo "Forked at block $(cast block-number --rpc-url "$RPC")"

step "Step 1 of 2: the shared reserve"
STEP1_LOG="${TMPDIR:-/tmp}/rehearse-step1.log"
PRIVATE_KEY="$KEY" TIMELOCK_MIN_DELAY=172800 forge script "$ROOT/script/DeploySharedReservePool.s.sol" \
  --rpc-url "$RPC" --broadcast --slow --offline > "$STEP1_LOG" 2>&1
POOL=$(addr_of "$STEP1_LOG" "SharedReservePool")
[[ -n "$POOL" ]] || { echo "no SharedReservePool in $STEP1_LOG:"; tail -30 "$STEP1_LOG"; exit 1; }
echo "SharedReservePool:  $POOL"
echo "TimelockController: $(addr_of "$STEP1_LOG" "TimelockController (owns every proxy and beacon)")"
echo "ProtocolGuard:      $(addr_of "$STEP1_LOG" "ProtocolGuard")"

step "Step 2 of 2: the asset-market layer, with the launchpad"
# A non-zero trading skim on purpose: zero is the shipping default, and a rehearsal that
# used it would never register a fee destination with the hook at all.
#
# DEPLOY_LAUNCHPAD is set because the fresh mainnet stack ships with it. Left off, this
# rehearsal would prove the market layer and then leave the launchpad's own CREATE2
# deployments, its one-shot wiring and its cross-link into `setLaunchpad` to be discovered
# at broadcast time — which is the entire failure mode this script exists to prevent.
STEP2_LOG="${TMPDIR:-/tmp}/rehearse-step2.log"
PRIVATE_KEY="$KEY" SHARED_RESERVE_POOL="$POOL" PROTOCOL_FEE_PIPS=1000 DEPLOY_LAUNCHPAD=true \
  forge script "$ROOT/script/DeployAssetMarkets.s.sol" \
  --rpc-url "$RPC" --broadcast --slow --offline > "$STEP2_LOG" 2>&1
HOOK=$(addr_of "$STEP2_LOG" "ProtocolFeeHook")
FACTORY=$(addr_of "$STEP2_LOG" "AssetMarketFactory")
ROUTER=$(addr_of "$STEP2_LOG" "MarketRouter")
DEPLOYER_LIB=$(addr_of "$STEP2_LOG" "MarketDeployer (library, linked)")
for named in "ProtocolFeeHook=$HOOK" "AssetMarketFactory=$FACTORY" "MarketRouter=$ROUTER" \
             "MarketDeployer=$DEPLOYER_LIB"; do
  [[ -n "${named#*=}" ]] || { echo "no ${named%%=*} in $STEP2_LOG:"; tail -40 "$STEP2_LOG"; exit 1; }
done
echo "MarketDeployer (library): $DEPLOYER_LIB"
echo "ProtocolFeeHook:          $HOOK"
echo "AssetMarketFactory:       $FACTORY"
echo "MarketRouter:             $ROUTER"

# The hook's permission bits ARE its address. If mining silently produced the wrong ones
# the deployment would have reverted, but assert it anyway: this is the one property no
# later step re-checks.
BITS=$(python3 -c "print(hex(int('$HOOK', 16) & 0x3FFF))")
[[ "$BITS" == "0xcc" ]] || { echo "hook permission bits are $BITS, expected 0xcc"; exit 1; }
echo "Hook permission bits:     $BITS (beforeSwap, afterSwap, both return-deltas)"

# The launchpad's own addresses, and the one link that lives on the market factory. A
# launchpad whose `setLaunchpad` never landed accepts launches and then reverts
# `OnlyLaunchpad` on every graduation, leaving each launch stranded in `Swept` — so the
# cross-link is asserted here rather than trusted from the log.
LAUNCH_FACTORY=$(addr_of "$STEP2_LOG" "LaunchFactory (proxy)")
LAUNCH_ROUTER=$(addr_of "$STEP2_LOG" "LaunchRouter")
LAUNCH_GRADUATION=$(addr_of "$STEP2_LOG" "LaunchGraduation")
for named in "LaunchFactory=$LAUNCH_FACTORY" "LaunchRouter=$LAUNCH_ROUTER" \
             "LaunchGraduation=$LAUNCH_GRADUATION"; do
  [[ -n "${named#*=}" ]] || { echo "no ${named%%=*} in $STEP2_LOG:"; tail -40 "$STEP2_LOG"; exit 1; }
done
echo "LaunchFactory (proxy):    $LAUNCH_FACTORY"
echo "LaunchRouter:             $LAUNCH_ROUTER"
echo "LaunchGraduation:         $LAUNCH_GRADUATION"

REGISTERED=$(cast call "$FACTORY" 'launchpad()(address)' --rpc-url "$RPC")
# Lowercased through `tr`; macOS's bash 3.2 has no `${var,,}`.
[ "$(echo "$REGISTERED" | tr 'A-Z' 'a-z')" = "$(echo "$LAUNCH_GRADUATION" | tr 'A-Z' 'a-z')" ] || {
  echo "market factory launchpad is $REGISTERED, expected $LAUNCH_GRADUATION"; exit 1; }
echo "Market factory launchpad: $REGISTERED (matches LaunchGraduation)"

# `positionManager()` is the selector that does not exist on the deployed gen-4 factory and
# is why the launchpad cannot be added to it. Asserting it here is what proves this fresh
# stack is the generation that can carry one.
FACTORY_POSM=$(cast call "$FACTORY" 'positionManager()(address)' --rpc-url "$RPC")
[ "$(echo "$FACTORY_POSM" | tr 'A-Z' 'a-z')" = "$(echo "$POSM" | tr 'A-Z' 'a-z')" ] || {
  echo "factory positionManager is $FACTORY_POSM, expected $POSM"; exit 1; }
echo "Factory positionManager:  $FACTORY_POSM"

step "Verifying the deployed stack"
SHARED_RESERVE_POOL="$POOL" ASSET_MARKET_FACTORY="$FACTORY" MARKET_ROUTER="$ROUTER" \
  forge script "$ROOT/script/VerifyAssetMarketsMainnet.s.sol" --rpc-url "$RPC" --offline \
  | sed -n '/=== Verifying/,/=== Verification/p'

step "Funding the rehearsal wallet"
# Morpho Blue custodies tens of millions of USDG here; the v3 pool holds real SPCX.
for holder in "$MORPHO" "$V3POOL"; do
  cast rpc anvil_impersonateAccount "$holder" --rpc-url "$RPC" > /dev/null
  cast rpc anvil_setBalance "$holder" 0xde0b6b3a7640000 --rpc-url "$RPC" > /dev/null
done
cast send "$USDG" 'transfer(address,uint256)' "$ME" 200000000000 --from "$MORPHO" --unlocked --rpc-url "$RPC" > /dev/null
cast send "$SPCX" 'transfer(address,uint256)' "$ME" 500000000000000000000 --from "$V3POOL" --unlocked --rpc-url "$RPC" > /dev/null
echo "USDG: $(cast call "$USDG" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC")"
echo "SPCX: $(cast call "$SPCX" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC")"

step "Approving the asset — the exact command the deploy script prints"
# The starting price is read off the live v3 pool rather than hardcoded, so a rehearsal
# run months from now still opens at a sane tick.
PRICE_E18=$(cast call "$V3POOL" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' --rpc-url "$RPC" \
  | head -1 | awk '{print $1}' \
  | python3 -c "import sys; sq = int(sys.stdin.read().strip()); print((sq * sq * 10**18 * 10**12) >> 192)")
echo "SPCX starting price (e18): $PRICE_E18"

# Creation carries no economic parameters any more: the owner's approval fixes the fee tier,
# the starting price, the oracle depth and the unit's name and symbol, and `createMarket` is
# permissionless afterwards. So the listing is the step that has to be rehearsed — an asset
# the owner never approved reverts `AssetNotApproved`, and that revert is the whole reason
# this pair of calls is here rather than one.
cast send "$FACTORY" \
  'approveAsset(address,(bool,uint24,uint256,uint16,string,string))' \
  "$SPCX" "(true,3000,$PRICE_E18,128,Starbase Dollar,starUSD)" \
  --private-key "$KEY" --rpc-url "$RPC" > /dev/null
echo "SPCX approved: unit starUSD, fee tier 3000, oracle depth 128."

step "Launching its market — also straight from the runbook"
# The zero reserve selects the factory's default. Anything else must be an approvedReservePool.
cast send "$FACTORY" 'createMarket(address,address)' \
  "$SPCX" 0x0000000000000000000000000000000000000000 \
  --private-key "$KEY" --rpc-url "$RPC" > /dev/null
echo "Market 1 created."

step "Minting the market's unit — the reserve's job, and the step the router refuses to bury"
# `seedLiquidity` takes both of the pool's OWN tokens and mints nothing: the stable side is
# the market's brandUSD, not USDG. A seeder holding USDG mints 1:1 at the reserve first, for
# free. An earlier revision folded that in, and a rehearsal written against it approved USDG
# to the router and got `ERC20InsufficientAllowance` from the brand token instead.
BRAND=$(cast call "$FACTORY" \
  'market(uint256)((address,address,address,address,address,bytes32,uint24,int24,address,bool,uint64,address))' \
  1 --rpc-url "$RPC" --json | python3 -c "import json,sys; print(json.load(sys.stdin)[0][1])")
[[ -n "$BRAND" ]] || { echo "could not read market 1's brand token"; exit 1; }
echo "Market unit (starUSD): $BRAND"
cast send "$USDG" 'approve(address,uint256)' "$POOL" 60000000000 --private-key "$KEY" --rpc-url "$RPC" > /dev/null
cast send "$POOL" 'mint(address,uint256,address)' "$BRAND" 60000000000 "$ME" --private-key "$KEY" --rpc-url "$RPC" > /dev/null
MINTED=$(cast call "$BRAND" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$RPC" | awk '{print $1}')
echo "starUSD minted 1:1 from USDG: $MINTED"
[[ "$MINTED" == "60000000000" ]] || { echo "the reserve did not mint 1:1"; exit 1; }

step "Seeding it — also straight from the runbook"
cast send "$BRAND" 'approve(address,uint256)' "$ROUTER" 60000000000 --private-key "$KEY" --rpc-url "$RPC" > /dev/null
cast send "$SPCX" 'approve(address,uint256)' "$ROUTER" 300000000000000000000 --private-key "$KEY" --rpc-url "$RPC" > /dev/null
DEADLINE=$(( $(cast block latest --rpc-url "$RPC" -f timestamp) + 3600 ))
# Real minimums, not zeros: the deploy script says they are not optional, so a rehearsal
# that passed zeros would not be rehearsing the documented call.
cast send "$ROUTER" 'seedLiquidity(uint256,uint256,uint256,uint256,uint256,uint256)' \
  1 60000000000 300000000000000000000 40000000000 200000000000000000000 "$DEADLINE" \
  --private-key "$KEY" --rpc-url "$RPC" > /dev/null

TOKEN_ID=$(( $(cast call "$POSM" 'nextTokenId()(uint256)' --rpc-url "$RPC" | awk '{print $1}') - 1 ))
OWNER=$(cast call "$POSM" 'ownerOf(uint256)(address)' "$TOKEN_ID" --rpc-url "$RPC")
echo "Uniswap v4 LP NFT #$TOKEN_ID owned by $OWNER"
# Lowercased through `tr` rather than with `${var,,}`, which macOS's bash 3.2 does not have.
[ "$(echo "$OWNER" | tr 'A-Z' 'a-z')" = "$(echo "$ME" | tr 'A-Z' 'a-z')" ] || { echo "the LP NFT did not go to the seeder"; exit 1; }

step "Verifying again, now with a live market"
SHARED_RESERVE_POOL="$POOL" ASSET_MARKET_FACTORY="$FACTORY" MARKET_ROUTER="$ROUTER" \
  forge script "$ROOT/script/VerifyAssetMarketsMainnet.s.sol" --rpc-url "$RPC" --offline \
  | sed -n '/--- Markets ---/,/=== Verification/p'

echo ""
echo "=== Rehearsal complete. Nothing was deployed to mainnet. ==="
if [[ "${KEEP_ALIVE:-0}" == "1" ]]; then
  echo "anvil is still up on $RPC (pid $ANVIL_PID). Kill it when you are done."
fi
