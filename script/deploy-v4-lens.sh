#!/usr/bin/env bash
# Deploy Uniswap's stock `V4Quoter` and `StateView` for the chain's canonical `PoolManager`.
#
# Neither contract can be compiled from this repo: `lib/v4-periphery` vendors its own v4-core and
# its own OpenZeppelin, and importing anything from it breaks the build for the whole project. So
# they are built and broadcast from inside that checkout, unmodified — the same bytecode Uniswap
# ships everywhere else, at whatever address CREATE gives it here. Both are ownerless and stateless
# and need no wiring afterwards. `MarketLens` no longer calls either of them — it replays the swap
# itself so its quotes are `view` — but both stay deployed and documented, because they are what an
# integrator checks our numbers against and what `MarketLensSimulatorFork` measures us by.
#
# Usage:  script/deploy-v4-lens.sh                 # compile, print constructor args, broadcast nothing
#         script/deploy-v4-lens.sh --broadcast
#
# Reads PRIVATE_KEY from .env. POOL_MANAGER defaults to Robinhood Chain mainnet's; RPC_URL to its
# public endpoint. Override both for another chain.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

RPC_URL="${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
POOL_MANAGER="${POOL_MANAGER:-0x8366a39CC670B4001A1121B8F6A443A643e40951}"
DEPLOYER="${DEPLOYER:-$(cast wallet address --private-key "$PRIVATE_KEY")}"

# Refuse an address that is not a PoolManager: `extsload(bytes32)` is its storage door and nothing
# else on the chain answers it. A wrong POOL_MANAGER would otherwise deploy a quoter that reverts
cast call "$POOL_MANAGER" 'extsload(bytes32)(bytes32)' "$(cast --to-bytes32 0)" --rpc-url "$RPC_URL" >/dev/null ||
  { echo "$POOL_MANAGER does not answer extsload; not a PoolManager" >&2; exit 1; }

BROADCAST=""
[ "${1:-}" = "--broadcast" ] && BROADCAST="--broadcast --private-key $PRIVATE_KEY"

cd lib/v4-periphery
echo "== compiling V4Quoter and StateView in lib/v4-periphery =="
forge build src/lens/V4Quoter.sol src/lens/StateView.sol --offline >/dev/null

deploy() {
  local path="$1" name="$2"
  if [ -z "$BROADCAST" ]; then
    echo "$name: would deploy $path with constructor ($POOL_MANAGER) from $DEPLOYER"
    return
  fi
  # `forge create` prints "Deployed to: 0x…"; keep only the address so the caller can capture it.
  # `--constructor-args` swallows every token after it, so it goes last.
  forge create "$path:$name" --rpc-url "$RPC_URL" $BROADCAST --constructor-args "$POOL_MANAGER" |
    grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}' |
    sed "s/^/$name: /"
}

deploy src/lens/V4Quoter.sol V4Quoter
deploy src/lens/StateView.sol StateView

# `if`, not `[ … ] && { … }`: a trailing test that fails is the script's exit status under
# `set -e`, so the documented dry run would report failure while having done its job.
if [ -n "$BROADCAST" ]; then
  echo
  echo "record both under core in the chain's deployments manifest. MarketLens takes no quoter"
  echo "argument; deploy it with script/DeployMarketLens.s.sol and ASSET_MARKET_FACTORY alone."
fi
