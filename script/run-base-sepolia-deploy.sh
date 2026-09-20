#!/usr/bin/env bash
# Deploy the Base Sepolia stack end to end: home platform, remote hub rewiring, first market.
#
# The three broadcasts have to happen in this order and each one feeds the next, which is why they
# live in a script rather than a runbook step someone retypes: the platform deploy prints the
# adapter the Arbitrum hub must point at, and the seed needs the factory and router it created.
#
# Usage:  script/run-base-sepolia-deploy.sh            # simulate everything, broadcast nothing
#         script/run-base-sepolia-deploy.sh --broadcast
#
# Reads PRIVATE_KEY from .env. Everything else is derived or defaulted here.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

BASE_RPC="${BASE_SEPOLIA_RPC_URL:-https://base-sepolia-rpc.publicnode.com}"
ARBITRUM_RPC="${ARBITRUM_SEPOLIA_RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}"
export DEPLOYER="${DEPLOYER:-$(cast wallet address --private-key "$PRIVATE_KEY")}"
export REMOTE_HUB="${REMOTE_HUB:-0x9050dF2f672dEb3Cf4900349005ecd11b2497654}"
export SUSDAI_DEPLOYER="$DEPLOYER"
export ASSET_SEED_WHOLE="${ASSET_SEED_WHOLE:-1}"

# `--slow` waits for each receipt before sending the next transaction. Base Sepolia's public RPCs
# cap how many transactions a *delegated* account (one carrying an EIP-7702 delegation, which this
# deployer does) may have in flight, and a 30-transaction stack deploy blows straight through that
# cap and aborts halfway. Sending one at a time is slower and always lands.
BROADCAST=""
[ "${1:-}" = "--broadcast" ] && BROADCAST="--broadcast --slow --private-key $PRIVATE_KEY"

# A whole-stack deploy is ~55M gas. At Base Sepolia's floor that is well under a hundredth of an
# ETH, but running out halfway leaves a half-wired stack that has to be redeployed from scratch,
# so refuse to start without comfortable headroom.
balance=$(cast balance "$DEPLOYER" --rpc-url "$BASE_RPC")
minimum=3000000000000000 # 0.003 ETH
if [ "$(printf '%s\n%s\n' "$balance" "$minimum" | sort -g | head -1)" = "$balance" ] && [ "$balance" != "$minimum" ]; then
  echo "deployer $DEPLOYER holds $(cast from-wei "$balance") ETH on Base Sepolia; want at least 0.003" >&2
  echo "fund it from a Base Sepolia faucet and rerun" >&2
  exit 1
fi

# `MarketDeployer` is a linked library. Forge deploys it out of band, through the CREATE2 factory,
# BEFORE the sequence it planned — and then aborts the whole run because the account's nonce moved
# by one more than its own plan accounted for. That is only fatal here because this deployer
# carries an EIP-7702 delegation, which makes Foundry strict about unexpected nonce movement.
# The library's CREATE2 address is deterministic and already deployed, so pin it and the extra
# transaction never happens.
MARKET_DEPLOYER="${MARKET_DEPLOYER:-0xbd7706Ffa5856232C3d64dE6269cc78c13229bdf}"
[ "$(cast code "$MARKET_DEPLOYER" --rpc-url "$BASE_RPC" | wc -c)" -gt 3 ] ||
  { echo "MarketDeployer library has no code at $MARKET_DEPLOYER" >&2; exit 1; }
LIBS="--libraries src/markets/MarketDeployer.sol:MarketDeployer:$MARKET_DEPLOYER"

echo "== 1/3 home platform =="
forge script script/DeployBaseSepoliaPlatform.s.sol --tc DeployBaseSepoliaPlatform \
  --rpc-url "$BASE_RPC" --sender "$DEPLOYER" $LIBS $BROADCAST | tee /tmp/base-deploy.log

# The script logs one address per labelled line; take the label verbatim so a renamed log line
# fails loudly here instead of silently deploying against an empty address.
address_after() { grep -oE "$1 0x[0-9a-fA-F]{40}" /tmp/base-deploy.log | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
adapter=$(address_after 'sUSDai adapter:')
factory=$(address_after 'AssetMarketFactory:')
router=$(address_after 'MarketRouter:')
asset=$(address_after 'faucet market asset:')
for pair in "adapter:$adapter" "factory:$factory" "router:$router" "asset:$asset"; do
  [ -n "${pair#*:}" ] || { echo "could not read ${pair%%:*} from the deploy log" >&2; exit 1; }
done
echo "adapter=$adapter factory=$factory router=$router asset=$asset"

# The hub is on Arbitrum Sepolia and survives a home redeploy: it is a UUPS proxy holding the
# sUSDai position, and only its home receiver changes. Redeploying it would strand that position.
echo "== 2/3 point the Arbitrum hub at the new adapter =="
HOME_ADAPTER="$adapter" forge script script/ConfigureSUSDaiTestnetRemote.s.sol \
  --tc ConfigureSUSDaiTestnetRemote --rpc-url "$ARBITRUM_RPC" --sender "$DEPLOYER" $BROADCAST

echo "== 3/3 approve the asset, create and seed market 1 =="
FACTORY="$factory" ROUTER="$router" ASSET="$asset" forge script script/SeedBaseSepoliaPlatform.s.sol \
  --tc SeedBaseSepoliaPlatform --rpc-url "$BASE_RPC" --sender "$DEPLOYER" $BROADCAST

echo
echo "done. Write these into deployments/asset-markets-base-sepolia.json and"
echo "web-stable/.env.local, then rerun the live scenario suite."
