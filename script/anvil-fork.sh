#!/usr/bin/env bash
set -euo pipefail

# Spins up a local Anvil node forked from live Robinhood Chain mainnet, so it has
# the exact same state — including our deployed contracts (factory, vaults,
# Uniswap and Morpho Blue/USDG — but runs entirely locally.
#
# Uses a different chain ID (31337, the conventional local Anvil/Hardhat devnet ID)
# than mainnet's 4663 on purpose: wallets like MetaMask key their RPC routing off
# chain ID, and a real "Robinhood Chain" (4663) entry pointing at the real mainnet
# RPC almost certainly already exists there. Reusing 4663 means signing a tx in the
# app would silently broadcast to real mainnet via that existing entry instead of
# this fork — a distinct chain ID lets you add this fork as a genuinely separate
# network with no ambiguity. None of our contracts use block.chainid/EIP-712, so
# this doesn't affect contract behavior.
#
# Usage:
#   script/anvil-fork.sh                # fork latest block
#   FORK_BLOCK_NUMBER=12345 script/anvil-fork.sh   # pin to a specific block (reproducible)
#   PORT=9545 script/anvil-fork.sh                 # use a different local port
#   CHAIN_ID=4663 script/anvil-fork.sh             # force mainnet's real chain ID instead
#                                                   # (fine for forge/cast, NOT for wallet signing)

FORK_URL="${FORK_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
PORT="${PORT:-8545}"
CHAIN_ID="${CHAIN_ID:-31337}"

ARGS=(--fork-url "$FORK_URL" --chain-id "$CHAIN_ID" --port "$PORT")
if [[ -n "${FORK_BLOCK_NUMBER:-}" ]]; then
  ARGS+=(--fork-block-number "$FORK_BLOCK_NUMBER")
fi

echo "Forking $FORK_URL (chain $CHAIN_ID) on http://127.0.0.1:$PORT"
echo "Use verified deployment addresses for the forked network; see deployments/ and README.md."
echo ""

exec anvil "${ARGS[@]}"
