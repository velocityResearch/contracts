#!/usr/bin/env bash
set -euo pipefail

# Funds an address with real USDG on a running local Anvil fork (see anvil-fork.sh),
# by impersonating a large existing holder and transferring directly — no minting
# or storage hacking needed since the fork already has the real token + balances.
#
# Usage: script/fund-usdg.sh <recipient> [amount-in-usdg] [whale]
#   recipient        address to receive USDG (required)
#   amount-in-usdg   whole USDG to send, default 10000
#   whale            address to impersonate as source, default the Morpho Blue
#                     singleton (it holds >$300M in USDG as pooled market supply)
#
# NOTE: the default whale is Morpho Blue itself. Pulling USDG out of it moves real
# ERC20 balance without updating Morpho's internal market accounting, so its own
# supply/withdraw bookkeeping for that market will be slightly off afterward on
# this fork. Fine for testing vault deposits/withdrawals and the frontend; pass a
# different whale (e.g. an EOA holder found via the explorer) if you need Morpho's
# own accounting to stay consistent too.

RECIPIENT="${1:?usage: script/fund-usdg.sh <recipient> [amount-in-usdg] [whale]}"
AMOUNT="${2:-10000}"
WHALE="${3:-0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
USDG="0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" # 6 decimals

RAW_AMOUNT=$((AMOUNT * 1000000))

echo "Impersonating whale $WHALE on $RPC_URL"
cast rpc anvil_impersonateAccount "$WHALE" --rpc-url "$RPC_URL" >/dev/null

echo "Topping up whale's ETH for gas..."
cast rpc anvil_setBalance "$WHALE" "$(cast to-hex "$(cast to-wei 100 ether)")" --rpc-url "$RPC_URL" >/dev/null

echo "Transferring $AMOUNT USDG to $RECIPIENT..."
cast send "$USDG" "transfer(address,uint256)" "$RECIPIENT" "$RAW_AMOUNT" --from "$WHALE" --unlocked --rpc-url "$RPC_URL" >/dev/null

cast rpc anvil_stopImpersonatingAccount "$WHALE" --rpc-url "$RPC_URL" >/dev/null

BALANCE_RAW=$(cast call "$USDG" "balanceOf(address)(uint256)" "$RECIPIENT" --rpc-url "$RPC_URL" | awk '{print $1}')
echo "Done. $RECIPIENT now holds $((BALANCE_RAW / 1000000)) USDG"
