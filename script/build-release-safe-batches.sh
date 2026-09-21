#!/usr/bin/env bash
# Emit the two Safe Transaction Builder batches for the graduate-into-launch-dollar + keeper
# LP-fee release (docs/GRADUATE_INTO_LAUNCH_DOLLAR_RUNBOOK.md, steps 4, 5, 7-10 and 11c-d).
#
# The EOA deploys come first and are yours (runbook steps 1, 2, 6, 11b); this script only
# needs their addresses. It writes nothing on chain: it encodes calldata with `cast` and
# checks, by reading the chain, that every address is the kind of thing the step expects, so
# a pasted implementation cannot be mistaken for a proxy or a beacon for its implementation.
#
#   AMF_IMPL=0x… LF_IMPL=0x… HOOK_IMPL=0x… PBT_IMPL=0x… BFV_IMPL=0x… LPRD_IMPL=0x… \
#   LOCKER=0x… GRAD=0x… LAUNCH_DEPLOYER=0x… KEEPER=0x… ./script/build-release-safe-batches.sh
#
# Output: deployments/safe-batches/04-upgrade-implementations.json and
#         deployments/safe-batches/05-wire-graduation-and-keeper.json
#
# Load 04 in the Safe app (Transaction Builder → Load batch), sign with two of three, execute,
# run runbook post-conditions C2 and 11c, then load 05. The order inside each file matters and
# is the runbook's.
set -euo pipefail

R=${R:-https://rpc.mainnet.chain.robinhood.com}
SAFE=0x28569c1716EF81f307d666A1EC08bDAE92AC0373
AMF=0x22AA61c589B90731752236c07d1455D0065bfc79
LF=0x95fe000285DA7797cC01394cCc410628B26e898d
HOOK=0xc9932584c5154e4F58313a2e5423522E74e540Cc
TB=0xf8b758dfb9d22448Ab13C7FcC1f23b75A998C34E
VB=0x65876276feE875e1A120F63575150593E6AEa0d3
DB=0xb6b86f5A01d8c04f68f827532C8aCE9458Db57a6
AIUSD_TREASURY=0xE2d144F8b18d4743fdC4D74e4AE621307e443e38
SUSDAI_RESERVE=0xCFa888f6F124452fDe0C7348328A7c73A8fd33B2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/deployments/safe-batches"

for v in AMF_IMPL LF_IMPL HOOK_IMPL PBT_IMPL BFV_IMPL LPRD_IMPL LOCKER GRAD LAUNCH_DEPLOYER KEEPER; do
  [ -n "${!v:-}" ] || { echo "missing \$$v" >&2; exit 1; }
done

owner() { cast call "$1" 'owner()(address)' --rpc-url "$R"; }
impl_of() { cast implementation "$1" --rpc-url "$R"; }
codesize() { cast codesize "$1" --rpc-url "$R"; }
lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

# Every implementation must have code and must NOT be a proxy; every proxy and beacon must be
# the Safe's. A wrong paste fails here, not in the Safe UI.
for v in AMF_IMPL LF_IMPL HOOK_IMPL PBT_IMPL BFV_IMPL LPRD_IMPL; do
  a=${!v}
  [ "$(codesize "$a")" -gt 0 ] || { echo "$v $a has no code" >&2; exit 1; }
  if [ "$(impl_of "$a" 2>/dev/null || true)" != "" ] && [ "$(impl_of "$a")" != "0x0000000000000000000000000000000000000000" ]; then
    echo "$v $a is a proxy, not an implementation" >&2; exit 1
  fi
done
for p in $AMF $LF $HOOK $TB $VB $DB $AIUSD_TREASURY; do
  case "$p" in
    $AIUSD_TREASURY) o=$(cast call "$p" 'admin()(address)' --rpc-url "$R") ;;
    *) o=$(owner "$p") ;;
  esac
  [ "$(lower "$o")" = "$(lower $SAFE)" ] || { echo "$p is not the Safe's (owner/admin $o)" >&2; exit 1; }
done
[ "$(lower "$(owner "$LOCKER")")" = "$(lower $SAFE)" ] || { echo "LOCKER $LOCKER is not owned by the Safe" >&2; exit 1; }
[ "$(lower "$(cast call "$GRAD" 'factory()(address)' --rpc-url "$R")")" = "$(lower $LF)" ] || { echo "GRAD $GRAD was not built for the launch factory" >&2; exit 1; }
[ "$(lower "$(cast call "$GRAD" 'locker()(address)' --rpc-url "$R")")" = "$(lower "$LOCKER")" ] || { echo "GRAD $GRAD does not point at LOCKER" >&2; exit 1; }
[ "$(lower "$(cast call "$LAUNCH_DEPLOYER" 'factory()(address)' --rpc-url "$R")")" = "$(lower $LF)" ] || { echo "LAUNCH_DEPLOYER $LAUNCH_DEPLOYER was not built for the launch factory" >&2; exit 1; }
[ "$(codesize "$KEEPER")" -eq 0 ] || { echo "KEEPER $KEEPER has code; the keeper is an EOA" >&2; exit 1; }

tx() { # to, calldata
  jq -cn --arg to "$1" --arg data "$2" '{to:$to,value:"0",data:$data,contractMethod:null,contractInputsValues:null}'
}
batch() { # name, description, txs...
  local name=$1 desc=$2; shift 2
  jq -n --arg name "$name" --arg desc "$desc" --argjson now "$(date +%s)000" \
    --argjson txs "$(printf '%s\n' "$@" | jq -s .)" \
    '{version:"1.0",chainId:"4663",createdAt:$now,meta:{name:$name,description:$desc,txBuilderVersion:"1.16.5",createdFromSafeAddress:"'"$SAFE"'"},transactions:$txs}'
}

batch "Upgrade six implementations: graduate into launch dollar + keeper LP fees" \
  "Three UUPS proxies (AssetMarketFactory, LaunchFactory, ProtocolFeeHook) with empty calldata and three beacons (treasury, fee vault, distributor). Graduation is closed from the first proxy upgrade until batch 05 wires the new module. No rate, recipient or keeper changes here." \
  "$(tx $AMF  "$(cast calldata 'upgradeToAndCall(address,bytes)' "$AMF_IMPL" 0x)")" \
  "$(tx $LF   "$(cast calldata 'upgradeToAndCall(address,bytes)' "$LF_IMPL" 0x)")" \
  "$(tx $HOOK "$(cast calldata 'upgradeToAndCall(address,bytes)' "$HOOK_IMPL" 0x)")" \
  "$(tx $TB   "$(cast calldata 'upgradeTo(address)' "$PBT_IMPL")")" \
  "$(tx $VB   "$(cast calldata 'upgradeTo(address)' "$BFV_IMPL")")" \
  "$(tx $DB   "$(cast calldata 'upgradeTo(address)' "$LPRD_IMPL")")" \
  > "$OUT/04-upgrade-implementations.json"

batch "Wire graduation, opt AIUSD in, set rates and reserve economics, authorise the fee keeper" \
  "Runbook steps 7-10, 11d and 11i in order: locker.setGraduation (one-shot), LaunchFactory.setGraduation, AssetMarketFactory.setLaunchpad, LaunchFactory.setLaunchDeployer (the segmented-curve deployer; without it every launch after the upgrade reverts), AIUSD treasury setFactory (one-way), the three graduated rates, setReserveEconomics for the sUSDai reserve at AIUSD's live figures, ProtocolFeeHook.setFeeKeeper. Nothing here opens a dynamic-fee market." \
  "$(tx "$LOCKER" "$(cast calldata 'setGraduation(address)' "$GRAD")")" \
  "$(tx $LF   "$(cast calldata 'setGraduation(address)' "$GRAD")")" \
  "$(tx $AMF  "$(cast calldata 'setLaunchpad(address)' "$GRAD")")" \
  "$(tx $LF   "$(cast calldata 'setLaunchDeployer(address)' "$LAUNCH_DEPLOYER")")" \
  "$(tx $AIUSD_TREASURY "$(cast calldata 'setFactory(address)' $AMF)")" \
  "$(tx $LF   "$(cast calldata 'setLpFundRecipient(address)' $SAFE)")" \
  "$(tx $LF   "$(cast calldata 'setGraduatedLpFundShareBps(uint16)' 3000)")" \
  "$(tx $LF   "$(cast calldata 'setGraduatedCreatorShareBps(uint16)' 4000)")" \
  "$(tx $LF   "$(cast calldata 'setReserveEconomics(address,(uint256,uint256,uint256,uint8,bool))' $SUSDAI_RESERVE '(3236000000,8090000000,1000000,6,true)')")" \
  "$(tx $HOOK "$(cast calldata 'setFeeKeeper(address)' "$KEEPER")")" \
  > "$OUT/05-wire-graduation-and-keeper.json"

echo "wrote $OUT/04-upgrade-implementations.json ($(jq '.transactions|length' "$OUT/04-upgrade-implementations.json") txs)"
echo "wrote $OUT/05-wire-graduation-and-keeper.json ($(jq '.transactions|length' "$OUT/05-wire-graduation-and-keeper.json") txs)"
