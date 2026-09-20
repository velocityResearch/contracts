# 0x Settler compatibility

Whether 0x can settle our pools with the code it already has, and what evidence supports that.
Chain: Robinhood Chain mainnet, `chainId 4663`.

Short version: **no new Solidity adapter appears to be required.** Settler's existing
`UNISWAPV4` action already targets the PoolManager our pools live in, already forwards an
arbitrary hook address with arbitrary hook data, and already credits the taker with the actual
`BalanceDelta` the PoolManager returns. Our fee is an `afterSwap` return delta, so it is
consumed by that accounting without Settler knowing anything about us.

The open work is on the quoting and discovery side, not the settlement side.

## 1. The chain and the PoolManager already match

Settler pins one PoolManager per chain. For Robinhood that constant is:

```solidity
// src/core/UniswapV4Addresses.sol
IPoolManager constant ROBINHOOD_POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
```

That is the canonical PoolManager, and it is the one all six of our pools are initialized in.
This matters because a pool in any other PoolManager would be a separate integration even with
an identical ABI.

`src/chains/RobinHood/Common.sol` asserts the chain and wires the v4 action:

```solidity
abstract contract RobinHoodMixin is FreeMemory, SettlerBase, UniswapV4, EkuboV3, Hanji, PancakeInfinity, Bebop {
    constructor() {
        assert(block.chainid == 4663 || block.chainid == 31337);
    }
```

`RobinHood/Common.sol` dispatches `UNISWAPV4`, `EKUBOV3`, `PANCAKE_INFINITY`, `HANJI` and
`BEBOP`. `RobinHood/TakerSubmitted.sol` additionally dispatches `UNISWAPV4_VIP`.

Source at commit `cdf29a06769749674ffe7846e154f1d1566b0cc2`:
<https://github.com/0xProject/0x-settler/blob/cdf29a06769749674ffe7846e154f1d1566b0cc2/src/chains/RobinHood/Common.sol>

## 2. Settler is deployed on 4663

Verified over RPC against `https://rpc.mainnet.chain.robinhood.com`:

| Contract | Address | Evidence |
|---|---|---|
| 0x deployment registry (ERC-721) | `0x00000000000004533Fe15556B1E086BB1A72cEae` | codesize 58 |
| Settler, registry token 2 | `0x6aa80DbBed9ae5aB45FbF61f9644faDA3b29326E` | `ownerOf(2)` returns it; codesize 19,872 |
| Registry token 3 | `0x03390030a8054ceDbf49920A91ec84d3210B2EAE` | `ownerOf(3)` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | codesize 9,152 |
| AllowanceHolder | `0x0000000000001fF3684f28c67538d4D072C22734` | codesize 1,009 |

`ownerOf(1)` reverts, which is consistent with the registry's versioning rather than an error.

Blockscout reports the Settler at `0x6aa80DbB...` as verified on 2026-09-03, compiler
`v0.8.34+commit.80d5c536`, with constructor `gitCommit` =
`0x1df908742d38cf407f667df6518dae6e04a01ac3`.

Per 0x's own README an integrator must resolve the Settler address from the registry at call
time rather than hardcoding it. We are not hardcoding it anywhere; the address above is quoted
only as evidence that the deployment exists.

## 3. The decisive property: Settler credits the real delta

This is the question that determines whether our hook needs special handling. It does not.

From `src/core/UniswapV4.sol`, inside the unlock callback:

```solidity
BalanceDelta delta = IPoolManager(msg.sender).unsafeSwap(key, params, hookData);
{
    (int256 settledSellAmount, int256 settledBuyAmount) =
        zeroForOne.maybeSwap(delta.amount1(), delta.amount0());
    NotePtr sell = state.sell();
    sell.setAmount(sell.amount() - uint256(settledSellAmount.unsafeNeg()));
    unchecked {
        NotePtr buy = state.buy();
        buy.setAmount(buy.amount() + settledBuyAmount.asCredit(buy));
    }
}
```

and from `src/core/FlashAccountingCommon.sol`:

```solidity
IERC20 buyToken = state.buy().token();
buyAmount = state.buy().amount();
if (buyAmount < minBuyAmount) {
    revertTooMuchSlippage(buyToken, minBuyAmount, buyAmount);
}
_callSelector(selector, buyToken, recipient, buyAmount);
```

The credited amount is `settledBuyAmount`, taken from the `BalanceDelta` the PoolManager
returned. There is no precomputed gross expectation and no per-venue fee assumption anywhere in
this path. Our `afterSwap` return delta reduces that delta before Settler ever sees it, so the
protocol fee is already netted out of `buyAmount`, out of the `minBuyAmount` check, and out of
any subsequent hop's input.

Uniswap's own warning, which Settler reproduces in `src/core/UniswapV4Types.sol`, is the
relevant standard here:

> Additionally note that if interacting with hooks that have the BEFORE_SWAP_RETURNS_DELTA_FLAG
> or AFTER_SWAP_RETURNS_DELTA_FLAG the hook may alter the swap input/output. Integrators should
> perform checks on the returned swapDelta.

Settler does perform exactly that check. That is why we are compatible.

### Only exact-input is generated

`params.amountSpecified` is always constructed negative:

```solidity
params.amountSpecified = int256((state.sell().amount() * ppm).unsafeDiv(Constants.BASIS)).unsafeNeg();
```

So every fill Settler produces is exact-input. For us that means the unspecified leg is always
the OUTPUT leg, and our fee is always denominated in the token the taker receives. The
exact-output branch of our hook is never exercised by Settler. This narrows the review surface
considerably, and it is the case we have the most evidence for.

## 4. Fill encoding

Our pools need no unusual encoding. The packed v4 fill is, in order:

| Field | Width | Our value |
|---|---|---|
| `ppm` | 3 bytes | routing decision, `1_000_000` = 100% |
| `sqrtPriceLimitX96` | 20 bytes | routing decision |
| packing key | 1 byte | `0x01` for a single fill |
| token payload | 0, 20 or 40 bytes | per key |
| pool `fee` | 3 bytes | **5000** for all six pools |
| pool `tickSpacing` | 3 bytes | **50** for all six pools |
| hook address | 20 bytes | **`0xc9932584c5154e4F58313a2e5423522E74e540Cc`** |
| hookData length | 3 bytes | **`0`** |
| hookData | that many bytes | **empty** |

Empty hook data is supported and is exercised by 0x's own integration test encoder, which packs
`uint24(0)` followed by `""`. Our hook never reads `hookData`, so empty is correct and anything
else is ignored.

**The `fee` field is the pool's LP fee tier, not our protocol fee.** Encode `5000` because that
is `PoolKey.fee` and part of pool identity. Our protocol fee is a separate, hook-internal rate
that is also currently 5000, but in parts per million rather than hundredths of a basis point.
Do not substitute one for the other; they are equal today by coincidence and will not stay that
way if either is retuned.

## 5. The ppm-versus-bps hazard

0x PR #617 (merged 2026-08-25) converted balance-fraction fields from basis points to parts per
million and widened the packed field from 2 bytes to 3. The PR is explicit that:

> Action selectors are unchanged (parameter names are not part of the selector), so the unit is
> a property of the Settler deployment: encoders must key bps vs ppm on the Settler address they
> target.

`Constants.sol` at the commit the deployed Robinhood Settler declares
(`1df90874...`) has `BASIS = 1_000_000`, so the live deployment is the ppm generation. We note
this only so nobody reuses an older encoder against it. It does not affect us: our fee is
internal to the hook and is never encoded into a Settler action.

## 6. Quote-to-execution equivalence, measured

0x's stated concern with v4 hooks is that a pool's quoted amount may not match its actual
execution. Read block 68,293,146.

An **unmodified Uniswap `V4Quoter`** at `0x6492C2e9340A6Cc1b12963D4723D819Af5B3CC5F`, called
with empty hook data, was compared against our own `MarketLens`, which composes the reserve leg
and the pool leg independently. Input in every case is 100.000000 units of the pool's brand
dollar, exact-input.

| Market | Pair | Stock `V4Quoter` output | `MarketLens.quoteBuy` | Equal |
|---|---|---|---|---|
| 13 | NVDA / AIUSD | 361978989930279627 | 361978989930279627 | yes |
| 14 | SPCX / AIUSD | 517398474958144631 | 517398474958144631 | yes |
| 15 | AI / AIUSD | 314691598328418216381 | 314691598328418216381 | yes |
| 16 | SDOGE / SDOGE.d | 2418000850077549375368228 | 2418000850077549375368228 | yes |
| 17 | ABR.d / ABR | 18791151944880663428638893 | 18791151944880663428638893 | yes |
| 18 | CORGIGG / CORGIGG.d | 8151736636379031642403991 | 8151736636379031642403991 | yes |

Exact to the wei on all six.

What this does and does not prove, stated precisely. `V4Quoter` performs a real swap inside the
PoolManager and reverts with the result, so it exercises the real hook along the real code path,
including the `afterSwap` return delta. The agreement therefore shows that the protocol fee is
fully contained in the `BalanceDelta` a quoter observes, and that two independent
implementations agree on the number. It is not the same thing as a settled Settler transaction
on chain, and we do not claim it is. We would be glad to co-sign a settled trade through the
Robinhood Settler as a final check.

**The practical instruction that follows: do not subtract our protocol fee yourself.** It is
already gone from the quoted amount. Subtracting it again underquotes by the fee, and at the
current 5,000 pips that is 50 bps of phantom slippage that would push us out of routes we should
win.

## 7. What is still open

These are questions for 0x, not claims:

1. Does the production v4 quoting engine already execute arbitrary `afterSwap` return-delta
   hooks when it samples, or does a hook need to be modeled or allowlisted first?
2. How should a pending fee increase be surfaced? Ours is readable on chain as
   `feePipsEffectiveAt(poolId)` with a one hour lead time, and we can emit or expose whatever
   shape is most convenient.
3. What is the preferred discovery mechanism? Our pools are enumerable from a factory with no
   subgraph required. See [MARKETS.md](./MARKETS.md).
4. Does the reserve mint and redeem leg need its own source, or can it ride the generic `BASIC`
   action? Its methods take the amount at a fixed calldata offset, which is what `BASIC` needs,
   but we have not validated approval and recipient semantics against it and will not assert
   that it works.
5. Should we also file the DEX Integration Request form for the reserve leg, or does the hook
   form cover both?

## 8. Our position on contributing code

0x's `CONTRIBUTING.md` accepts functional pull requests with a written business case, and
requires that contributions not be majority AI-authored without human review, with model
attribution where AI assisted. We are willing to write and maintain a Settler core mixin or a
sampler if 0x decides one is needed, under those terms. We would rather not send an unsolicited
pull request for something the existing `UNISWAPV4` action already handles.
