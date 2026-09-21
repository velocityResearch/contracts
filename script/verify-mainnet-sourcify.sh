#!/usr/bin/env bash
# Verify every mainnet contract's source, via Sourcify.
#
# WHY SOURCIFY AND NOT BLOCKSCOUT DIRECTLY. The Blockscout instance for chain 4663
# (robinhoodchain.blockscout.com) puts its API behind a Cloudflare interactive JS challenge.
# `forge verify-contract --verifier blockscout` gets an HTML "Just a moment..." page instead of
# JSON and dies deserialising it, and no API key changes that because it is a bot challenge and
# not an auth failure. Driving it from a real browser does clear the challenge, but the API then
# rate-limits hard enough that a batch of this size takes hours of waiting.
#
# Sourcify supports chain 4663 natively (`curl https://sourcify.dev/server/chains | jq '.[] |
# select(.chainId==4663)'` reports supported: true), has no challenge and no meaningful rate
# limit, and Blockscout consumes Sourcify verifications, so publishing here is what makes source
# readable in the explorer. Verified end to end on 2026-09-19: MarketRouter's implementation came
# back `exact_match` on both creation and runtime bytecode.
#
# Sourcify matches on compiled bytecode plus embedded metadata, so no constructor arguments are
# needed. That is the other reason to prefer it: half of these contracts take constructor
# arguments that would otherwise have to be recovered from broadcast artifacts by hand.
#
# IDEMPOTENT AND RESUMABLE. Every contract is checked first and skipped if already verified, so
# re-running after a partial run is free and safe. Nothing here signs a transaction or spends
# gas; verification is an off-chain publication. Safe to run unattended.
#
#   ./script/verify-mainnet-sourcify.sh            # verify everything still unverified
#   ./script/verify-mainnet-sourcify.sh --status   # report only, submit nothing
set -uo pipefail

CHAIN_ID=4663
SOURCIFY=https://sourcify.dev/server
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STATUS_ONLY=0
[ "${1:-}" = "--status" ] && STATUS_ONLY=1

# address <TAB> source path:ContractName
#
# Implementations, not proxies: a proxy's own source is OpenZeppelin's ERC1967Proxy and carries
# no protocol logic, and Blockscout links a proxy to its verified implementation on its own once
# the implementation is published. Addresses are the live ones as of 2026-09-19; regenerate with
# `node script/sync-mainnet-state.mjs` and re-read `deployments/mainnet-state.json` if in doubt,
# because two of these moved on 2026-09-19 and one had never been recorded correctly.
#
# THE OLD LIQUIDITYZAPPER ROW IS HISTORICAL. 0x6f67108e... was compiled from the ownerless,
# un-upgradeable first version of src/markets/LiquidityZapper.sol, which this tree no longer
# contains — the file is now the UUPS one. That address is already verified on Sourcify, so
# `is_verified` short-circuits and the row is a no-op; it is kept only so the table still
# accounts for every live contract. If it is ever un-verified upstream, do not resubmit it from
# this tree: the source would not match and the row must be deleted instead.
read -r -d '' TARGETS <<'EOF'
0x95106c6424B81A8f45590Ff64B31DdB40897Dc2A	src/markets/MarketRouter.sol:MarketRouter
0x45Ce2F93aD46d1393Eff5da56fFc4537740022C0	src/markets/AssetMarketFactory.sol:AssetMarketFactory
0xd4AC6b17338866E43E1922cfb563A81Ff36b425B	src/markets/ProtocolFeeHook.sol:ProtocolFeeHook
0x1Bd23DdCDC464CD0555C4B167a835D7F55b2b27e	src/pool/SharedReservePool.sol:SharedReservePool
0x0C23b7628E1bfED0b082447c0746C9760C386DAe	src/yield/MorphoBlueYieldSource.sol:MorphoBlueYieldSource
0x15456BA172184DB87333022BF01a7c529C6ED159	src/yield/SUSDaiYieldSource.sol:SUSDaiYieldSource
0xbA57AE21F91725Ea613248d5FC5D44Aef954fc03	src/upgrade/ProtocolGuard.sol:ProtocolGuard
0xd08D14d5D0d86D56bCeE10703613E1822831DfCE	src/registry/StrategyGroupRegistry.sol:StrategyGroupRegistry
0xFCC13E959E4e441F0d83dd05B4dfaEA7CE459be3	src/launchpad/LaunchFactory.sol:LaunchFactory
0x2F26F8fE6c8f6BA3F72D062f1a4E64fFe596963C	src/launchpad/LaunchLocker.sol:LaunchLocker
0xF5f4Eb45347ec69CB56D1c682a0FdA83bb9f4efC	src/launchpad/LaunchGraduation.sol:LaunchGraduation
0xb1BeEbb3c077705273bcC4F80f560F43941205b6	src/launchpad/LaunchFeeEscrow.sol:LaunchFeeEscrow
0x7979708A371E9f9dDb43A432595c3F59f77dd5E7	src/launchpad/LaunchDeployer.sol:LaunchDeployer
0xf763CA4670Fa9eCB53821352B13450F514889C79	src/launchpad/LaunchRouter.sol:LaunchRouter
0x99141B1d1F6859A8830ED97EA359d96F79A8d52e	src/markets/LiquidityZapper.sol:LiquidityZapper
0x0a3d8332D949b4aE650f3aC6468620e403a50fF1	src/markets/MarketLens.sol:MarketLens
0xB1e0ED28e24d3999216979847f9473b5C7bf12bA	src/pool/BrandPsmFactory.sol:BrandPsmFactory
0x1339b306Ce53d1393995D306BF7a365d4c825300	src/pool/BrandPsm.sol:BrandPsm
0x6f36300eA9486e7615f29EFA5C6eAC5Ee2bb5A4A	src/pool/BrandPsm.sol:BrandPsm
0x1539CE28BD6837EFaA9EadEB8aa76669Fcef3f35	src/pool/BrandPsm.sol:BrandPsm
0x61bCD58B76cb703AAD74cAa64B85D094dcb0554f	src/pool/BrandPsm.sol:BrandPsm
# Release 2026-09-21: keeper LP fees + graduate into launch dollar (runbook 11k). The
# implementations behind the three proxies and three beacons, the linked library, and the
# three fresh launchpad modules. The AssetMarketFactory row is the cast-send deploy of the
# built artifact, not the oversized forge-create one at 0xBD8D…09ED.
0x77153c0482e393375F25cbdBfE47e204d22cF951	src/markets/AssetMarketFactory.sol:AssetMarketFactory
0x1fd586D714F66c120aa258ce29671634Cff556bC	src/launchpad/LaunchFactory.sol:LaunchFactory
0xfe4014D1ee20cC77349fAd24C1e9CeA69b03db03	src/markets/ProtocolFeeHook.sol:ProtocolFeeHook
0x317d1C9319E461658F6716382Dcf81d0C39C8A77	src/pool/PoolBrandTreasury.sol:PoolBrandTreasury
0x57f700f8AbC9FB73B9Ee6e5297304421f041065D	src/markets/BrandFeeVault.sol:BrandFeeVault
0xCe9F3b9e864EDD05a64544B228c509E6Ff63fb44	src/markets/LpRewardDistributor.sol:LpRewardDistributor
0xa4ea459Bb5f1dcE94231b57A9BC7DbdE5F1f342d	src/launchpad/libraries/LaunchGuardDeployer.sol:LaunchGuardDeployer
0x27dA5A098ea5d8ef2a0c95Df5Dc79fe6E2440244	src/launchpad/LaunchLocker.sol:LaunchLocker
0x254C5Ad46dFf09C5F2e646C3221B5125EDe649A9	src/launchpad/LaunchGraduation.sol:LaunchGraduation
0x50571945e7CdBa099745A20Deb762deB81f81331	src/launchpad/LaunchDeployer.sol:LaunchDeployer
EOF

is_verified() {
  # v2 returns 200 with a match field when known, 404 when not. `match: null` means Sourcify has
  # a record but no successful match, which counts as unverified so a retry is attempted.
  local body
  body=$(curl -s -m 25 "$SOURCIFY/v2/contract/$CHAIN_ID/$1" 2>/dev/null) || return 1
  case "$body" in
    *'"match":"exact_match"'*) return 0 ;;
    *'"match":"match"'*) return 0 ;;
    # Sourcify v2 enforces EIP-55 and rejects a mis-cased address outright. That is NOT
    # "unverified": it means the table below is wrong, and treating it as unverified is how
    # SharedReservePool spent a day reported as the one failing target while being
    # exact_match on Sourcify the whole time. Fail loudly instead of resubmitting forever.
    *'"customCode":"invalid_parameter"'*)
      echo "  FATAL: $1 is not a valid EIP-55 address. Fix the table; run:" >&2
      echo "         cast to-check-sum-address $1" >&2
      exit 2
      ;;
    *) return 1 ;;
  esac
}

total=0; already=0; ok=0; failed=0
declare -a FAILED=()

while IFS=$'\t' read -r addr target; do
  # A row whose first column is not an address is a placeholder for something not deployed yet.
  # An empty first field does NOT survive to `addr`: TAB is IFS whitespace, so `read` strips the
  # leading one and shifts the source path into `addr`. Testing for the 0x prefix is therefore
  # what actually skips an unfilled row; `-z` looked like it did and did not.
  case "${addr:-}" in 0x*) ;; *) continue ;; esac
  total=$((total + 1))
  name="${target##*:}"

  if is_verified "$addr"; then
    printf '  %-26s %s  already verified\n' "$name" "$addr"
    already=$((already + 1))
    continue
  fi

  if [ "$STATUS_ONLY" = "1" ]; then
    printf '  %-26s %s  UNVERIFIED\n' "$name" "$addr"
    failed=$((failed + 1))
    continue
  fi

  printf '  %-26s %s  submitting... ' "$name" "$addr"
  out=$(forge verify-contract "$addr" "$target" --verifier sourcify --chain-id "$CHAIN_ID" 2>&1)
  job=$(printf '%s' "$out" | sed -n 's/.*Verification Job ID: `\([0-9a-f-]*\)`.*/\1/p' | head -1)
  if [ -z "$job" ]; then
    echo "SUBMIT FAILED"
    printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    FAILED+=("$name $addr submit")
    failed=$((failed + 1))
    continue
  fi

  # Poll the job rather than assuming submission means success: a metadata mismatch is reported
  # here, not at submit time, and silently counting it as verified is how a stale source ends up
  # advertised as matching.
  result=""
  for _ in $(seq 1 20); do
    sleep 3
    body=$(curl -s -m 25 "$SOURCIFY/v2/verify/$job" 2>/dev/null)
    case "$body" in
      *'"isJobCompleted":true'*) result="$body"; break ;;
    esac
  done

  case "$result" in
    *'"match":"exact_match"'*) echo "exact_match"; ok=$((ok + 1)) ;;
    *'"match":"match"'*) echo "match (metadata differs)"; ok=$((ok + 1)) ;;
    "") echo "TIMED OUT waiting for job $job"; FAILED+=("$name $addr timeout"); failed=$((failed + 1)) ;;
    *) echo "NO MATCH"; printf '%s' "$result" | head -c 300 | sed 's/^/      /'; echo
       FAILED+=("$name $addr nomatch"); failed=$((failed + 1)) ;;
  esac
done <<< "$TARGETS"

echo
echo "targets: $total   already verified: $already   newly verified: $ok   failed: $failed"
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "failures:"
  printf '  %s\n' "${FAILED[@]}"
  exit 1
fi
echo "Blockscout imports Sourcify matches, so source becomes readable at"
echo "https://robinhoodchain.blockscout.com/address/<address>?tab=contract"
