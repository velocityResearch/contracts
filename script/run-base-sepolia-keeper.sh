#!/usr/bin/env bash
# The sUSDai keeper, pointed at the Base Sepolia integration deployment.
#
# Addresses are read from deployments/asset-markets-base-sepolia.json rather than repeated here,
# so this cannot drift from the deployment record. The keeper key is the deployment's own signer
# (`adapter.keeper()`); it is read from .env and never printed.
#
# BRIDGE_MODE=selfRelay because no third-party Across relayer prices a few dollars of test USDC:
# the public API quotes this route at hundreds of basis points and the adapter's 20 bps
# `maxBridgeFeeBps` correctly refuses it. The keeper therefore fills its own deposits on the real
# SpokePools, which is the role a relayer would play on a funded network.
#
#   DRY_RUN=true  script/run-base-sepolia-keeper.sh   # plan and simulate only (default)
#   DRY_RUN=false script/run-base-sepolia-keeper.sh   # send
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST=deployments/asset-markets-base-sepolia.json
read -r ADAPTER HUB HOME_USDC REMOTE_USDC < <(
  jq -r '[.contracts.susdaiAdapter, .remote.hub, .contracts.usdg, .remote.usdc] | @tsv' "$MANIFEST"
)

set -a
[ -f .env ] && . ./.env
set +a

export DRY_RUN="${DRY_RUN:-true}"
# The Base deployment's keeper is the deployer key. A different environment can override it.
export KEEPER_PRIVATE_KEY="${BASE_KEEPER_PRIVATE_KEY:-${PRIVATE_KEY:-}}"
export ROBINHOOD_RPC_URL="${BASE_RPC_URL:-https://sepolia.base.org}"
export ARBITRUM_RPC_URL="${ARBITRUM_SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}"
export ROBINHOOD_CHAIN_ID=84532
export ARBITRUM_CHAIN_ID=421614
export USDG_ADDRESS="$HOME_USDC"
export ARBITRUM_USDC_ADDRESS="$REMOTE_USDC"
export ROBINHOOD_SPOKE_POOL_ADDRESS=0x82B564983aE7274c86695917BBf8C99ECb6F0F8F
export ARBITRUM_SPOKE_POOL_ADDRESS=0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75
export ADAPTER_ADDRESS="$ADAPTER"
export HUB_ADDRESS="$HUB"
export BRIDGE_MODE=selfRelay
export SELF_RELAY_FEE_BPS="${SELF_RELAY_FEE_BPS:-10}"
# The whole group holds a few dollars, so the production floor of 1,000 USDC would never act.
export MIN_BRIDGE_AMOUNT="${MIN_BRIDGE_AMOUNT:-100000}"
# The 10-15% local band is the service default; overriding it here would fork the policy.
export POLL_INTERVAL_MS="${POLL_INTERVAL_MS:-15000}"
# Testnet blocks are cheap and reorg depth here is shallow; waiting 20 confirmations on Base
# Sepolia's 2-second blocks would leave a fill unrecognised for a minute per leg.
export LOG_CONFIRMATION_BLOCKS="${LOG_CONFIRMATION_BLOCKS:-2}"
export STATE_PATH="${STATE_PATH:-$PWD/.keeper/base-sepolia.json}"
mkdir -p "$(dirname "$STATE_PATH")"

exec npm --prefix services/susdai-keeper start
