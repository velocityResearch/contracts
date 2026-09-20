# AssetMarkets — feature and integration spec

> **Audience:** whoever builds the frontend, whoever audits the contracts, and whoever operates
> the deployment. Part 1 is conceptual and assumes no knowledge of this repo. Part 2 is the
> contract-by-contract reference. Part 3 is the security model.
>
> **Status:** Phase 1 is written, tested (67 tests, including fork suites against both Robinhood
> Chain mainnet and testnet), **live on testnet** and **connected end to end to the frontend in
> `web-stable/`** — see [Part 4](#part-4--the-live-testnet-deployment) for addresses and a runbook,
> or `deployments/asset-markets-testnet.json` for the machine-readable version. Nothing is
> deployed to mainnet.
>
> ⚠️ **Four confirmed defects were found. Three are fixed in source; the fourth is accepted** —
> see [§3.3](#33-confirmed-defects--fixed-in-source-and-live-on-testnet). None threatens the
> reserve or the peg. **The testnet deployment in Part 4 was redeployed on 2026-09-09 and now
> carries all three fixes**; the addresses that predated them are gone. The fixes changed two
> signatures ([ASSET_MARKETS_AUDIT.md §4](ASSET_MARKETS_AUDIT.md)).
>
> ⚠️ **`AssetMarketFactory` is 2,046 bytes over the EIP-170 contract size limit.** Robinhood Chain
> accepts it and the test suite does not enforce the limit, so nothing goes red — but the factory
> as it stands cannot be deployed to Ethereum or any chain that does enforce it. See
> [Part 4](#part-4--the-live-testnet-deployment).
>
> For the product rationale and the market research behind it, see
> [ASSET_MARKETS.md](ASSET_MARKETS.md); this document is the specification.

---

# Part 1 — What it does

## 1.1 The idea in one paragraph

Take a token that already exists — a tokenized stock like SPCX, or a memecoin that launched
somewhere else. Give it a trading venue whose quote currency is a **branded stablecoin**: always
worth exactly $1, freely mintable and redeemable against USDG. Because that stablecoin is backed
by real USDG parked in a lending market, the whole float earns interest — and that interest is
**programmable**, split between whoever runs the market, the people providing its liquidity, and
the protocol. Nobody issues a new asset; the venue and the yield are the product.

## 1.2 The five concepts

**Asset.** The pre-existing token being traded. Brought by the operator, never minted or
controlled by this system.

**Branded stablecoin.** A market's own dollar. Permanently worth 1 USDG, minted 1:1, redeemed
1:1, no fee and no slippage in either direction. Holders never earn on it — that is the trade
they make in exchange for a permanent peg.

**Float.** Every branded stablecoin in existence is backed by a USDG deposit earning lending
interest. Crucially, tokens sitting **inside the market's own AMM pool** count exactly like
tokens in a wallet — so the pool's stablecoin reserves *are* the float. Deeper pool, more yield.

**Market.** One asset, one branded stablecoin, one Uniswap V3 pool, one yield split.

**Split.** The interest the float earns, divided by percentage between the operator, the
liquidity providers, and the protocol.

## 1.3 Why the yield split has a floor

In a market's pool, the stablecoin side was deposited by **liquidity providers**. It is their
capital earning the interest. If all of it went to the operator, a rational LP would simply
provide to an ordinary USDG pool instead — same fees, nothing extracted. The market would look
fine and never get deep.

So a minimum share of the yield is locked away for LPs and **the operator cannot reach it**. With
that floor, providing liquidity here strictly beats providing it to a plain pool: you earn swap
fees *plus* lending yield on your stablecoin side.

## 1.4 The flows

### Operator

1. Picks an asset and a name for their stablecoin, and creates the market. One transaction.
2. Seeds the pool with USDG and the asset. The USDG is converted to the branded stablecoin
   automatically; they receive a normal Uniswap V3 LP position.
3. Configures the split — who gets what percentage of the yield, above the LP floor.
4. Collects their share whenever yield is harvested.
5. Can hand the market to a new operator at any time.

### Trader

1. **Buy with USDG.** USDG goes in, the asset comes out. Under the hood the USDG becomes branded
   stablecoin and lands in the pool, growing the float.
2. **Buy holding another market's stablecoin.** Any market's dollar converts into any other's at
   exactly 1:1, so liquidity is not trapped behind a choice of quote asset.
3. **Sell.** The asset goes in, USDG comes out.

A buy-then-sell round trip loses money — two swap fees plus price impact. This is a normal AMM,
not a peg.

### Liquidity provider

Deposits USDG and the asset, receives a Uniswap V3 position, earns swap fees.

> ⚠️ **LPs receive no share of the lending yield.** All of it, less the protocol fee, funds the
> buyback. The pitch to liquidity is that the buyback is a standing bid on the asset they are
> quoting, funded by the depth they supply — not a yield split. **The UI must not imply otherwise,
> and must never show the reserve APY as an LP return.** See ASSET_MARKETS.md §8 for why this is
> the live risk in the design.

### Anyone (keeper)

Two open, unpermissioned jobs, both of which only ever move a market's own money to destinations
it already chose:

- **Sweep idle reserves** into the lending market. Minting already supplies inline, so this is
  normally a no-op — it exists for reserves that arrive by another route (a direct transfer,
  rounding dust, or the whole position after a yield-source migration).
- **Harvest and pay out** the accrued yield.

### Protocol

Sets the fee and the LP floor for *new* markets — live markets keep the terms they were created
with. Controls who may release escrowed LP rewards.

## 1.5 Verified vs unverified markets

Robinhood's tokenized equities can be told apart from impersonators with certainty: every genuine
one is the identical beacon proxy, with the beacon address compiled into its runtime code. The
factory checks this and stamps each market `verified` or not.

This is a statement about **bytecode provenance only**. It says the token is the real
Robinhood-issued one. It says nothing about whether a market is liquid, fairly priced, or worth
trading, and an unverified market is not necessarily a scam — every memecoin is unverified by
construction.

## 1.6 What is deliberately not built

| | |
|---|---|
| LP incentives of any kind | Removed with the split. LPs earn swap fees only; see ASSET_MARKETS.md §8 for the bet this makes |
| Keeper automation | `harvest`, `pushAll` and `execute` are permissionless, so this is scripted rather than automated |
| More than 32 pools per brand at once | `MarketYieldSplitter.MAX_LEGS` bounds the `poke` and `harvest` loops, which are linear in it. `retireLeg` frees a slot |
| Routed markets against existing deep pools | Phase 4 |
| Frontend | This document is the input to it |

---

# Part 2 — Technical reference

## 2.1 Contract map

| Contract | File | Instances |
|---|---|---|
| `AssetMarketFactory` | `src/markets/AssetMarketFactory.sol` | One, global |
| `MarketRouter` | `src/markets/MarketRouter.sol` | One, global |
| `MarketYieldSplitter` | `src/markets/MarketYieldSplitter.sol` | One per market |
| `BuybackEngine` | `src/markets/BuybackEngine.sol` | One per market |
| `AssetLockbox` | `src/markets/AssetLockbox.sol` | One per market |
| `IYieldDestination` | `src/markets/IYieldDestination.sol` | Interface |

Depends on, and does not modify:

| Contract | File | Role |
|---|---|---|
| `SharedReservePool` | `src/pool/SharedReservePool.sol` | The reserve; mints/redeems/swaps brand tokens, tracks yield per brand |
| `PooledBrandToken` | `src/pool/PooledBrandToken.sol` | A market's branded stablecoin |
| `PoolBrandTreasury` | `src/pool/PoolBrandTreasury.sol` | A brand's yield claim point; its admin is the splitter |
| `MorphoBlueYieldSource` | `src/yield/MorphoBlueYieldSource.sol` | Where the reserve earns |

Deploy with `script/DeployAssetMarkets.s.sol`. It requires `SHARED_RESERVE_POOL` and refuses to
run without it.

## 2.2 Chain constants (Robinhood Chain mainnet, id 4663)

| | |
|---|---|
| USDG (reserve asset, **6 decimals**) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Uniswap V3 factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| Morpho Blue | `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` |
| Reference equity (SPCX) | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` |

> ⚠️ The Uniswap deployment is at **non-canonical addresses**. The canonical `SwapRouter` address
> `0xE592427A0AEce92De3Edee1F18E0157C05861564` holds an unrelated funds-forwarding contract on
> this chain; approving it is a real loss. Never substitute the usual addresses.

Enabled fee tiers and their tick spacing: `100`→1, `500`→10, `3000`→60, `10000`→200.
There is **no Quoter deployed** — see [2.8](#28-pricing-and-quoting).

## 2.3 `AssetMarketFactory`

### Creating a market

```solidity
struct CreateParams {
    address asset;                 // the pre-existing token
    string  brandName;             // e.g. "Starbase Dollar"
    string  brandSymbol;           // e.g. "starUSD"
    uint24  fee;                   // 100 | 500 | 3000 | 10000
    uint256 assetPriceE18;         // ONE WHOLE asset in WHOLE USDG, 1e18-scaled
    uint16  observationCardinality;// TWAP buffer to grow to; 0 to skip; max 1000
    uint16  maxSqrtDeviationBps;   // tolerance if the pool is ALREADY priced; 0 = exact match
    address operator;              // zero defaults to msg.sender; carries NO authority
}

function createMarket(CreateParams calldata p)
    external
    returns (uint256 marketId, address brandToken, address splitter, address pool);
```

**Permissionless.** In one transaction it registers a new brand on the reserve pool; creates,
initialises and grows the observation buffer of the Uniswap V3 pool; deploys the splitter,
which deploys its buyback engine, which deploys its lockbox; then transfers the brand
treasury's admin rights to the splitter.

**The pool is created before the splitter**, because the engine holds the pool address in an
`immutable` and reads its TWAP.

`assetPriceE18` is a **human price**, not a `sqrtPriceX96`. SPCX at $154 is `154e18`. This is
deliberate: the brand token does not exist until this transaction runs, so a caller cannot know
Uniswap's `token0 < token1` ordering in advance, and getting it wrong would initialise the pool at
the reciprocal price. The factory derives the sqrt price itself once the ordering is known.

`observationCardinality` grows the pool's TWAP ring buffer. Costs gas linear in the value, and is
raised to `MIN_OBSERVATION_CARDINALITY` (32) when lower, including when zero: a buyback that
cannot observe its pool cannot run, so the buffer is not optional. 60 is a sensible default.

`maxSqrtDeviationBps` is the guard against a **pre-priced pool**. The brand token is deployed by
the reserve pool with `CREATE`, so its address is a pure function of that pool's public nonce and a
front-runner can compute it, create the V3 pool first, and initialise it at a price of their
choosing. When the pool this call resolves to is already priced and `assetPriceE18 != 0`, the live
price must sit within this band of the requested one or the call reverts `PoolPriceOutOfBand`.
**Leave it at 0** — an exact match, i.e. "this call must be the one that prices the pool" — unless
you are deliberately attaching a market to a pool that already exists. The band is measured on the
square-root price, so `d` bps of band is roughly `2d` bps of price. Passing `assetPriceE18 == 0`
remains the way to say "take whatever price the pool has".

**Reverts:** `ZeroAddress` (asset is zero), `AssetHasNoCode`, `FeeTierNotEnabled`,
`CardinalityTooHigh` (>1000), `PoolNotInitialised` (`assetPriceE18 == 0` and the
pool is not already priced), `AssetIsBrandToken`, `PoolAlreadyRegistered`, `PriceOutOfRange`,
`PoolPriceOutOfBand(live, requested)`.

**Emits:**
```solidity
event MarketCreated(
    uint256 indexed marketId, address indexed asset, address indexed operator,
    address brandToken, address treasury, address splitter, address buybackEngine,
    address lockbox, address pool, uint24 fee, bool verified, uint160 sqrtPriceX96
);
```

`sqrtPriceX96` is the price the pool **actually** holds on return, which is not always the one
derived from `assetPriceE18` — a pool that was already initialised within the requested band keeps
its own. Index this rather than re-deriving the requested price.

### Attaching more pools to a brand

```solidity
struct AttachParams {
    address brandToken;            // a brand this factory already created
    address asset;
    uint24  fee;
    uint256 assetPriceE18;
    uint16  observationCardinality;
    uint16  maxSqrtDeviationBps;
}

function attachMarket(AttachParams calldata p)
    external
    returns (uint256 marketId, address pool);
```

**`brandOperator` only**, read off the brand's splitter. A stablecoin's issuer decides what it is
paired with; letting anyone attach would put their brand's name on markets they did not choose,
and would let a large attached pool skim a share of the yield earned by brand held in wallets.
That authority reaches nothing else — not the fee, not the weighting, not a lockbox, not an
engine's schedule — and `setBrandOperator` on the splitter hands it on.

The new pool starts weighing its float from this transaction and earns nothing for any period
before it, so attaching takes nothing from the pools already present. Capped at
`MarketYieldSplitter.MAX_LEGS` (32); `retireLeg` frees a slot that holds nothing.

**Reverts:** `UnknownBrand`, `OnlyBrandOperator`, plus everything `createMarket` can revert with.

### Reading markets

```solidity
struct Market {
    address asset;
    address brandToken;
    address treasury;
    address splitter;
    address buybackEngine;
    address lockbox;
    address pool;      // Uniswap V3
    uint24  fee;
    address operator;
    bool    verified;
    uint64  createdAt;
}

function market(uint256 marketId) external view returns (Market memory); // reverts UnknownMarket
function marketCount() external view returns (uint256);                  // ids are 1-indexed
function marketOfBrand(address brandToken) external view returns (uint256);  // the FIRST one
function marketsOfBrand(address brandToken) external view returns (uint256[] memory);
function marketsOfBrandLength(address brandToken) external view returns (uint256);
function splitterOfBrand(address brandToken) external view returns (address);
function marketOfPool(address uniswapPool) external view returns (uint256);
function marketsOfAsset(address asset) external view returns (uint256[] memory);
function marketsOfAssetLength(address asset) external view returns (uint256);
```

Market ids start at **1**; `0` means "none", so a zero from `marketOfBrand`/`marketOfPool` is a
miss, not market zero.

### Pricing helper

```solidity
function quoteSqrtPriceX96(address brandToken, address asset, uint256 assetPriceE18)
    external view returns (uint160);
```

Pure derivation, exposed so a UI can preview a market's starting price before creating it.
Reverts `ZeroAmount` on a zero price and `PriceOutOfRange` outside Uniswap's bounds.

### Verification

```solidity
function isCanonicalEquity(address token) external view returns (bool);
function equityCodehash() external view returns (bytes32); // zero = verification disabled
```

`EXTCODEHASH` equality against a reference token captured at deployment. Returns false for EOAs,
empty accounts, and any factory deployed with no reference (e.g. testnet).

### Protocol parameters

```solidity
struct BuybackParams {
    uint256 minNotional;      // minimum round size, in reserve-asset units
    uint32  minInterval;      // minimum seconds between rounds
    uint32  twapWindow;       // >= MIN_BUYBACK_TWAP_WINDOW (300)
    uint16  maxDeviationBps;  // 1..MAX_BUYBACK_DEVIATION_BPS (2000), of the SQRT price
}

function protocolTreasury() external view returns (address);
function protocolBps() external view returns (uint16);   // <= MAX_PROTOCOL_BPS (2000)
function swapRouter() external view returns (address);   // immutable, identity-checked
function buybackParams() external view returns (uint256, uint32, uint32, uint16);

function setProtocolParams(address _protocolTreasury, uint16 _protocolBps) external; // onlyOwner
function setBuybackParams(BuybackParams calldata _buyback) external;                 // onlyOwner
```

**These apply to future markets only.** A live market's splitter and engine hold their rates and
their schedule immutably, so no deployed market can be repriced or have its price band widened.
Emits `ProtocolParamsUpdated` and `BuybackParamsUpdated`.

`protocolBps` is shipped at **zero**: the protocol's revenue is the trading skim, not the yield.
The yield is divided by `lpBps`, shipped at **5_000**, so half is donated to the pool's LPs and
half buys the asset back. Both move future markets only. See ASSET_MARKETS.md §7 and §7a.

The constructor identity-checks `swapRouter.factory()` against `uniFactory` and reverts
`SwapRouterFactoryMismatch`. On Robinhood Chain the canonical `SwapRouter` address holds an
unrelated funds-forwarding contract, so a copy-pasted constant would silently become every
market's buyback approving a stranger.

## 2.4 `MarketRouter`

Every entry point is `nonReentrant`. Amounts on the asset side are measured by balance delta, not
taken from return values, because the asset is arbitrary and issuer-upgradeable.

```solidity
function buyWithUsdg(uint256 marketId, uint256 usdgIn, uint256 minAssetOut, address receiver)
    external returns (uint256 assetOut);

function buyWithBrand(uint256 marketId, address brandIn, uint256 amountIn,
                      uint256 minAssetOut, address receiver)
    external returns (uint256 assetOut);

function sellForBrand(uint256 marketId, uint256 assetIn, uint256 minBrandOut, address receiver)
    external returns (uint256 brandOut);

function seedLiquidity(uint256 marketId, uint256 usdgIn, uint256 assetIn,
                       int24 tickLower, int24 tickUpper, address recipient,
                       uint256 minBrandUsed, uint256 minAssetUsed, uint256 deadline)
    external returns (uint256 tokenId, uint128 liquidity);
```

Paths:

```
buyWithUsdg    USDG   --mint 1:1-->  brandUSD  --V3 swap-->  asset
buyWithBrand   brandY --swap 1:1-->  brandUSD  --V3 swap-->  asset   (skips leg 1 if brandY == brandUSD)
sellForBrand   asset  --V3 swap-->   brandUSD                (redeem to USDG is a separate call)
```

`seedLiquidity` mints the brand side from `usdgIn`, mints a V3 position to `recipient`, and
refunds unused amounts to `msg.sender` — with the brand leg redeemed back to USDG, so a caller who
arrives with USDG leaves with USDG. Either side may be zero (but not both). Ticks are computed
off-chain and must be multiples of the tier's spacing; an invalid pair reverts inside the position
manager.

⚠️ **`minBrandUsed` / `minAssetUsed` are the caller's only protection and are not optional.** How
much of each side a V3 mint consumes is decided by the pool's price at execution time; an attacker
who moves that price first makes the deposit land at their ratio, restores it afterwards, and keeps
the difference. This is cheap in a Mode B pool, which is thin by construction. `minBrandUsed` is
denominated in USDG (the brand side is minted 1:1 from `usdgIn`). **Every** router entry point
carries a real `deadline` and reverts `DeadlineExpired` past it — the buy and sell paths too, not
just this one.

**Reverts:** `ZeroAmount`, `ZeroAddress` (zero receiver), `NotAPooledBrand` (`brandIn` is not
registered in the reserve pool), `InsufficientOutput(received, minimum)`, `DeadlineExpired`, plus
anything the reserve pool or Uniswap raises — a seed whose minimums cannot be met reverts inside
the position manager with `Price slippage check`.

The constructor additionally reverts `PeripheryFactoryMismatch(periphery, reported, expected)`
unless both `swapRouter.factory()` and `positionManager.factory()` equal the market factory's
`uniFactory()` — the Uniswap deployment here is at non-canonical addresses and a copy-pasted
constant would otherwise produce a router that approves a stranger on every trade.

**Emits:** `Bought`, `Sold`, `LiquiditySeeded`.

### Approvals — exactly which ones are needed

| Flow | Approve | To |
|---|---|---|
| `buyWithUsdg` | USDG | the router |
| `buyWithBrand` | the incoming brand token | the router |
| `sellForBrand` | the asset | the router |
| `seedLiquidity` | USDG **and** the asset | the router |
| `SharedReservePool.mint` (direct) | USDG | the reserve pool |
| `SharedReservePool.redeem` / `swap` (direct) | **none** | — |

The last row matters: the reserve pool burns from the caller through a pool-only path that takes
no allowance. **Never render an approve step for a direct redeem or brand-to-brand swap.**

## 2.5 `MarketYieldSplitter` (one per market)

### Harvest and payout — why they are separate

`harvest` claims the brand's accrued USDG and only **credits an internal ledger**; it calls no
destination. `push` then delivers one recipient's balance. A destination that reverts fails its
own `push` and nothing else — the harvest still lands, every other recipient is still paid, and
the failed slice stays credited for a retry. This exists because the assets these markets trade
are issuer-controlled: a design where a destination can revert the harvest hands the issuer a
switch that bricks an operator's yield claim.

```solidity
function harvest() external returns (uint256 claimed);   // permissionless
function push(address to) external returns (uint256);    // permissionless; reverts NothingOwed
function pushAll() external;                             // skips failures, emits PushFailed
```

### Reading the split and the ledger

```solidity
function pendingYield() external view returns (uint256);   // accrued, not yet harvested
function owed(address to) external view returns (uint256); // credited, not yet pushed
function totalOwed() external view returns (uint256);
function totalHarvested() external view returns (uint256);
function totalToBuyback() external view returns (uint256);
function totalToProtocol() external view returns (uint256);
function unallocated() external view returns (uint256);

function buybackBps() external view returns (uint16);   // 10000 - protocolBps - lpBps
function lpBps() external view returns (uint16);        // immutable; donated to the pool
function protocolBps() external view returns (uint16);  // immutable
function protocolTreasury() external view returns (address); // immutable
function brandToken() external view returns (address);
function treasury() external view returns (address);
function carried() external view returns (uint256);     // claimed, not yet attributable

struct Leg {
    BuybackEngine engine;        // immutable once attached
    address pool;                // the V3 pool whose liquidity this leg represents
    uint160 lastAccumulatorX128; // pool secondsPerLiquidityCumulativeX128 at the last poke
    bool observed;               // false until a poke has managed to read the pool
    uint256 weight;              // liquidity-seconds since the last harvest
}

function legs() external view returns (Leg[] memory);
function legsLength() external view returns (uint256);
function legAt(uint256 i) external view returns (Leg memory);   // indices shift on retire
function MAX_LEGS() external view returns (uint256);            // 32
function brandOperator() external view returns (address);
function setBrandOperator(address newOperator) external;  // onlyBrandOperator
function retireLeg(uint256 index) external;               // onlyBrandOperator

function poke() external;                                  // permissionless
function projectedWeights()
    external
    view
    returns (address[] memory engines, uint256[] memory weights, uint256 total);
```

**One splitter per brand, one leg per pool.** `protocolBps` goes to `protocolTreasury` and
everything else is divided between the legs' engines by measured liquidity. The buyback side
takes the **remainder** rather than its own `mulDiv`, so the two sides sum to the claim exactly
and rounding at that level favours the buyback rather than the fee; leftover wei inside the
buyback side go to the leg that quoted the most liquidity.

**Weight is liquidity × seconds, read from the pool, never from a token balance.** Minting
brandUSD is 1:1 and reversible and `poke` is permissionless, so any measure built on `balanceOf`
can be moved by anyone in a single transaction: park float in a pool, poke, withdraw, and the
leg is paid for a period it held nothing. Sampling more carefully does not save it, because the
manipulation is atomic and the attacker picks both endpoints.

`poke` therefore reads each pool's `secondsPerLiquidityCumulativeX128` and differences it.
Uniswap advances that accumulator only as blocks are produced, in proportion to in-range
liquidity while they were, so no single transaction can move it — the same property, and the
same argument, as the TWAP the buyback price guard uses. Two consequences worth stating: tokens
sitting in a pool contract outside a position earn their leg nothing, and neither does an
engine's unspent inventory rolled forward from a partial fill. `harvest` pokes first.

`projectedWeights` is what a UI should show as "share of the buyback": it includes the period
since the last poke, which `legAt(i).weight` alone does not.

**Nothing is lost to the measure.** A harvest with no weight anywhere *carries* its claim into
the next one that has weight, and a harvest that claims nothing leaves the accumulators alone —
so `harvest` on an idle market cannot wipe weight a pool has earned.

`retireLeg` frees a slot. It requires the leg to carry no unsettled weight and its engine to have
no unpaid credit. It pokes first, so a pool that is still quoting fails the weight check, and so
does one that stopped quoting earlier in the period — that pool's weight is surfaced by the poke,
and the call reverts until a `harvest` has settled it. The engine and its lockbox keep working afterwards; only the claim on
future yield ends. Legs are removed by swapping the last into the gap, so **indices are not
stable across a retire** — address legs by their engine.

**Reverts:** `OnlyBrandOperator`, `UnknownLeg`, `LegNotEmpty`.

### There is no configuration

`buybackEngine` is deployed by this constructor and held in an `immutable`; `protocolBps` is
fixed at the same moment. **Neither has a setter, and no function on this contract changes any
state a recipient depends on.** A market's economics are readable from its bytecode.

This replaced an operator-configurable `Destination[]` with a `setSplit`. Two audit findings
(F-2 and F-3 below) were consequences of having a split at all; both are now unreachable rather
than fixed. `IYieldDestination` survives as the interface between the splitter and the engine —
`push` notifies the engine after transferring, and a revert there fails only that `push`.

**Reverts:** `ZeroAddress`, `NothingOwed`, `ProtocolFeeTooHigh`, `UnregisteredBrand`.

**Emits:** `Harvested(amount, toBuyback, toProtocol, totalHarvested)`, `Pushed`, `PushFailed`.

## 2.6 `BuybackEngine` (one per market)

```solidity
function onYieldReceived(address asset, uint256 amount) external;  // splitter only; counts
function execute() external returns (uint256 spent, uint256 locked); // permissionless

function budget() external view returns (uint256);      // brand held + USDG held
function readyAt() external view returns (uint256);     // lastExecutedAt + minInterval
function canExecute() external view returns (bool ok, string memory reason);
function twapSqrtPriceX96() external view returns (uint160);
function sqrtPriceLimitX96() external view returns (uint160);

function lockbox() external view returns (address);       // immutable
function brandIsToken0() external view returns (bool);    // immutable
function minNotional() external view returns (uint256);   // immutable
function minInterval() external view returns (uint32);    // immutable
function twapWindow() external view returns (uint32);     // immutable
function maxDeviationBps() external view returns (uint16);// immutable
function totalReceived() external view returns (uint256);
function totalSpent() external view returns (uint256);
function totalLocked() external view returns (uint256);
function rounds() external view returns (uint256);
```

```
USDG --mint 1:1--> brandUSD --V3 swap, TWAP-bounded--> asset --> AssetLockbox (no way out)
```

**Receiving and spending are separate transactions.** `onYieldReceived` only counts. Everything
that can fail — the mint, the pool, the price guard, the asset's own transfer hooks — lives in
`execute`, so a paused asset costs one round and never touches the harvest.

**Inventory is held as brandUSD, not USDG.** Minting is 1:1 and free, and brandUSD counts toward
outstanding supply, so yield waiting to be spent keeps earning yield. Unspent input from a
partial fill stays in brandUSD for the same reason.

**The price guard is the pool's own TWAP.** This chain ships no `QuoterV2`. `execute` reads
`observe()` over `twapWindow`, places a `sqrtPriceLimitX96` `maxDeviationBps` from it on the side
the swap moves (below when the brand is `token0`, above when it is `token1`), and hands that to
the swap with `amountOutMinimum: 0`. A minimum-out on top would turn the partial fill the limit
exists to produce into a revert. The band is on the **square-root** price, so it is roughly
double that figure on price itself.

`canExecute` returns `"too-soon"`, `"below-min"` or `"no-twap"`. The last means the pool's
observation buffer does not reach back a full window yet — normal for a young market, and the
reason `increaseObservationCardinalityNext` is worth calling directly on a busy pool.

**Reverts:** `OnlySplitter`, `WrongAsset`, `InvalidParams`, `BelowMinNotional(budget, minimum)`,
`TooSoon(now, readyAt)`, `NoProgress` (the swap filled nothing, so neither the funds nor the
interval are consumed).

**Emits:** `YieldReceived`, `BoughtBack(round, brandSpent, assetLocked, brandRolledForward,
sqrtPriceLimitX96)`.

## 2.6b `AssetLockbox` (one per market)

```solidity
function lock(uint256 amount) external;   // engine only; accounting, no transfer
function balance() external view returns (uint256);
function totalLocked() external view returns (uint256);
function asset() external view returns (address);   // immutable
function engine() external view returns (address);  // immutable
```

No owner, no admin, no `withdraw`, no `rescue`, no upgrade path, no `receive`. `lock` is the only
state-changing function and it moves a counter.

**It is not an ERC-20 burn and no surface should call it one.** `totalSupply` does not move and an
explorer keeps counting these tokens as outstanding; what it removes is the float. A
supply-reducing `burn()` was unavailable — Robinhood equities gate `burn` behind the issuer's
AccessControl and `Memecoin` has none — so an address that provably cannot spend is the only sink
that works for every asset.

An issuer who holds `burn(address,uint256)` over their own token can burn this balance, and an
upgradeable proxy could move it. Neither is a hole in the lockbox: those are powers the issuer
already holds over every holder.

**Emits:** `Locked(amount, totalLocked)`.

## 2.7 `SharedReservePool` — the parts a market touches

```solidity
function mint(address token, uint256 amount, address receiver) external returns (uint256);
function redeem(address token, uint256 amount, address receiver) external returns (uint256 paidOut);
function swap(address tokenIn, address tokenOut, uint256 amount, address receiver) external returns (uint256);
function deployIdle() external;   // normally a no-op: `mint` supplies inline

function pendingYield(address token) external view returns (uint256);
function outstandingOf(address token) external view returns (uint256);
function isRegistered(address token) external view returns (bool);
function totalAssets() external view returns (uint256);
function totalPooledSupply() external view returns (uint256);
```

Two behaviours the UI must respect:

- **`redeem` can return less than requested**, by a wei or two, when the yield source's own
  share↔asset rounding leaves it short. Display the returned amount, never the requested one, and
  do not treat the difference as an error.
- **`swap` has no slippage surface at all** — no min-out, no deadline, no price impact, no route.
  A brand-to-brand swap UI is an amount box and two token pickers; anything more invents risk that
  does not exist.

## 2.8 Pricing and quoting

**There is no `QuoterV2` on this chain.** The working approach already exists in
`web/src/web3/quote-v3.ts`: run the real swap under `eth_call` with a state override that supplies
a callback which reverts carrying the swap's amount deltas. Do not substitute:

- simulating `exactInputSingle` reverts with `STF` before an approval exists — exactly when a
  price is needed;
- deriving a price from `slot0` gives spot at the current tick only, and cannot see that a side of
  the pool is exhausted.

**Price display.** The branded stablecoin is always exactly 1 USDG, so the pool price *is* the
asset's USD price. No conversion, no oracle.

**Decimals.** The brand token mirrors the reserve asset — **6 decimals** for USDG. Assets are
typically 18. Every raw ratio crosses a 1e12 gap; get this wrong and prices are off by a trillion.

**Full-range ticks by fee tier:** `100`→±887272, `500`→±887270, `3000`→±887220, `10000`→±887200.

## 2.9 Indexing and discovery

Enumerate markets from `marketCount()` and `market(id)` — ids are dense and 1-indexed, so this
batches cleanly through multicall3, the same shape as `BrandedVaultFactory.allVaults`. Or index
`MarketCreated`.

Per-market live reads: pool `slot0` and `liquidity`; `outstandingOf(brandToken)` for the float;
`pendingYield()` and `totalHarvested()` on the splitter; `budget()`, `canExecute()` and
`totalSpent()` on the engine; `totalLocked()` on the lockbox; `brandToken.balanceOf(pool)` for how
much of the float is the pool's own reserves.

**A market's headline yield number** is the reserve's APY applied to `outstandingOf(brandToken)`,
and `buybackBps / 10000` of that is the annual buy pressure on the asset. Do not present the
reserve APY as something a brand-token *holder* earns — they earn nothing, by design. Do not
present it as an LP yield either: LPs earn swap fees only.

## 2.10 UI honesty requirements

These are not style notes; each corresponds to a real property of the system.

- **Holders of a branded stablecoin earn no yield.** Any APY shown against the token itself is a
  lie. Yield belongs to the market, and is displayed on the operator/LP surface.
- **LPs earn swap fees and nothing else.** No part of the float yield reaches them. Showing the
  reserve APY anywhere near the liquidity screen would be a lie.
- **The lockbox is not a burn.** `totalSupply` does not move. Say "bought and locked forever" and
  link the lockbox; never say "burned".
- **A round trip loses money.** Two swap fees plus impact. Show the expected loss on a buy/sell
  preview.
- **`verified` means bytecode provenance only.** It is not a safety rating, a liquidity signal or
  an endorsement. Unverified is the normal state for a memecoin.
- **Assets are issuer-controlled.** Robinhood can pause transfers, blocklist an address, burn
  tokens out of one, and upgrade the token. LP inventory in an equity market is freezable by the
  issuer. This belongs on the screen.
- **Float earns from the moment it is minted.** `mint` supplies to the lending market in the same
  transaction, so there is no "deployed yet?" state to explain to a user. The flip side belongs on
  an ops dashboard rather than the trading screen: **minting is coupled to the lending market**, so
  if it is paused, capped or broken, minting reverts — and because buying mints, buying stops with
  it. Redemption is unaffected and the peg holds throughout.

---

# Part 3 — Security model

## 3.1 Trust assumptions

| Party | Can do | Cannot do |
|---|---|---|
| Market operator | Seed and withdraw their own liquidity, like anyone else | **Nothing else.** There is no operator payout, no split to set, and no setter anywhere in a market's contracts. The name is recorded for attribution |
| Protocol owner (factory) | Set the fee, the treasury and the buyback schedule **for future markets** | Change any live market's terms or schedule; touch any market's funds; reach a lockbox |
| Reserve pool owner (timelock) | Change the yield source | Mint, burn, or redirect brand tokens |
| Anyone | `createMarket`, `harvest`, `push`/`pushAll`, `execute`, `deployIdle`, trade | Redirect any payout to *themselves* — recipients come from the ledger and from immutables, never from the caller. `execute` takes no arguments; its route, band and destination are all immutable. **But** F-1 lets anyone pre-price a market's pool, and choosing *when* to call `execute` is a real if bounded lever |
| Asset issuer (e.g. Robinhood) | Pause, blocklist, burn, upgrade **their own token** | Affect the reserve, redemption, or any brand token's peg |

## 3.2 Invariants worth asserting

1. `sum(owed) == totalOwed` and `totalOwed <= asset.balanceOf(splitter)` — the ledger never
   promises more than the contract holds.
2. Exactly two recipients, and `owed[buybackEngine] + owed[protocolTreasury]` absorbs every
   harvested wei: the fee floors and the buyback takes the remainder.
3. `totalToBuyback + totalToProtocol == totalHarvested`.
4. `SharedReservePool.totalAssets() + dust >= totalPooledSupply()` — the reserve stays solvent
   through every market operation, to within the rounding a share-based yield source floors away.
   Because `mint` supplies inline, a mint/redeem round trip at a non-unit share price can retire
   up to a wei of backing; `claimYield` refuses to pay yield while backing is under supply, so the
   shortfall is repaid out of the next yield earned rather than forgiven. `totalAssets()` must
   never *exceed* supply plus genuinely earned yield — that direction is exact.
5. `outstandingOf(brandToken) == brandToken.totalSupply()`.
6. The router holds no token balance and no standing allowance between transactions.
7. A market's `protocolBps`, `buybackEngine`, `lockbox` and the engine's whole schedule and price
   band never change after creation. There is no code path that writes any of them.
8. The lockbox's balance is monotonically non-decreasing under every function this system
   exposes.

## 3.3 Confirmed defects — fixed in source and live on testnet

Found by an adversarial review pass; the full write-up, including seven further findings accepted
with rationale and the list of properties that were verified as *sound*, is in
[ASSET_MARKETS_AUDIT.md](ASSET_MARKETS_AUDIT.md).

**F-1, F-2 and F-3 are fixed. F-4 is accepted, not fixed.** None threatens the reserve — the peg
holds and `totalAssets() >= totalPooledSupply()` survived all four.

> ✅ **The live testnet deployment carries all three fixes.** It was redeployed on 2026-09-09
> from post-audit source ([Part 4](#part-4--the-live-testnet-deployment)); the earlier addresses,
> whose bytecode still contained F-1, F-2 and F-3, are no longer referenced anywhere. Nothing on
> chain carried those defects as state — they were in the contracts themselves — so replacing the
> contracts is the whole of the remedy.

Each defect began as a passing exploit in `test/audit/AssetMarketAudit.t.sol`. Those tests now
assert the *fixed* behaviour, so a regression re-opens the hole and fails the suite.

### F-1 · A front-runner can pre-price any market's pool — **high** · ✅ fixed

`AssetMarketFactory._ensurePool` adopts an existing, already-initialised pool and silently
discards `assetPriceE18`. The brand token is deployed with `CREATE` from the reserve pool, so its
address is a pure function of that pool's nonce and is computable from the mempool. An attacker
creates and initialises the pool first, at any price, and the victim's `createMarket` adopts it —
then the operator seeds liquidity into a pool priced arbitrarily far from the truth and is
arbitraged out of the difference.

This was considered during design and dismissed in a code comment on the reasoning that a
brand token minted moments ago cannot already have a pool. That reasoning is the bug: it is
predictable, not impossible.

*Fixed by* `CreateParams.maxSqrtDeviationBps`: when the resolved pool is already priced and
`assetPriceE18 != 0`, the live price must sit within that band of the requested one or the call
reverts `PoolPriceOutOfBand`. Zero — the default — demands an exact match. `assetPriceE18 == 0`
remains the explicit opt-in for adopting an existing pool's price, and `MarketCreated` now carries
the `sqrtPriceX96` the market actually starts at.
*Regression:* `test_fix_preInitialisedPoolIsRejectedByDefault`,
`test_fix_priceIsStillEnforcedWhenTheSquatIsClose`,
`test_fix_anExplicitBandAdoptsAPoolThatIsCloseEnough`, `test_fix_zeroPriceStillMeansTakeThePoolAsItIs`

### F-2 · `setOperator` transfers control but not the payout — **medium** · ✅ unreachable

`MarketYieldSplitter`'s constructor pushes the operator as `destinations[0]`. `setOperator`
updates the `operator` variable and leaves that destination pointing at the old address. After
selling or handing over a market, the previous operator keeps collecting until somebody calls
`setSplit`, and nothing in the contract or the UI signals it.

*Retired* rather than patched. The operator is no longer a destination and there is no
`setOperator`, so there is no payout to move and nothing to leave behind. The finding is now a
statement about a design that no longer exists.
*Regression:* `test_fix_theOperatorIsALabelNotAnAuthority`

### F-3 · `setSplit` applies retroactively to yield already earned — **high** · ✅ unreachable

`harvest` credits everything accrued since the last harvest at the weights in force *at harvest
time*, not the weights that were in force while it accrued. An operator can advertise a generous
LP share, attract float on that promise, then cut back to the floor immediately before harvesting
and capture the difference.

This is the most damaging of the four, because the LP floor's credibility is the economic core of
the design (§1.3). A floor that can be honoured in advertising and withdrawn before payout is not
a floor.

*Retired* rather than patched. There are no weights to change: the fee is fixed at creation and
the buyback takes the remainder, so the rate a wei is credited at is the same rate it accrued
under. The finding was first fixed by settling before every setter; the setters are now gone.
*Regression:* `test_fix_thereIsNoWayToRedirectAMarketsYield`

### F-4 · Permissionless `harvest` is a dust-griefing vector — **medium** · accepted, not fixed

Flooring dust was routed to the LP escrow, on the principle that rounding should favour the party
the floor protects. Because `harvest` is permissionless, an attacker could call it whenever a wei
or two had accrued, so every share floored to zero and the entire amount became dust. The PoC ran
400 such rounds against a $2,000 market: the operator received 0, the protocol received 0, and
100% landed in the escrow.

**This is no longer griefing, because there is nowhere else for the dust to go.** With two
recipients and the buyback taking the remainder rather than its own `mulDiv`, spamming `harvest`
floors the protocol fee to nothing and sends every wei to the buyback — which is where the market
was sending it anyway. The cost is a transaction per wei and the effect is to forgo the fee.
*Characterisation:* `test_known_harvestSpamOnlyEverFavoursTheBuyback`

This contradicts the claim in `MarketYieldSplitter`'s own documentation that a permissionless
harvest "can only move a market's own money to destinations it already chose". It can also move
*all* of it to one destination.

**Accepted, not fixed.** It costs a transaction per wei, it can only ever favour the party the
floor exists to protect, and it stops mattering as soon as a market's per-block accrual exceeds
`BPS_DENOMINATOR / min(bps)` — a few hundred wei. The documentation claim it contradicts has been
narrowed rather than the behaviour changed. If a market ever runs thin enough for this to bite,
the fix is a minimum-notional threshold below which `harvest` is a no-op, or an accumulator that
rolls the remainder into the next harvest.
*Characterised by:* `test_known_harvestSpamRoundsEverythingIntoTheLpEscrow`

## 3.4 Known and accepted risks

**Trades are sandwichable.** The router calls Uniswap with `amountOutMinimum: 0` and
`sqrtPriceLimitX96: 0`, and enforces the bound itself against a measured balance afterwards. The
caller's `minAssetOut` / `minUsdgOut` is therefore the *only* protection against a sandwich. The
frontend must set meaningful minimums; a zero minimum is an unbounded loss.
`seedLiquidity` is the same story with `minBrandUsed` / `minAssetUsed`. Every entry point does
carry a `deadline` and reverts `DeadlineExpired` past it, so a stale pending transaction fails
rather than executing at whatever the price has become.

**Listing is a race until the pool is priced.** A front-runner can predict a market's brand-token
address from the reserve pool's nonce and pre-create its Uniswap pool. `maxSqrtDeviationBps`
defaults to an exact-match requirement so the attempt reverts rather than being adopted, but the
squatter can still make a creation attempt fail. Retrying draws a fresh brand address.

**Issuer control of the asset.** `pause()`, `isBlocked(address)`, `burn(address,uint256)` and
beacon upgrade all exist on the tokenized equities. Mitigated where it matters: the reserve is
USDG-only so redemption is never at risk, and harvest cannot be blocked by a failing destination.
Not mitigated, and not mitigable: LP inventory can be frozen.

**Escrow centralisation.** The LP floor is custodied by a protocol-appointed distributor with no
on-chain rule about who receives it. This is a deliberate Phase 1 placeholder and the single
largest trust concession in the design.

**Permissionless listing.** Anyone can create a market on any token, including a fake one. The
`verified` flag is the only on-chain signal, and it cannot exist for memecoins. Curation is a job
for the surface above the contracts.

**Split destinations are arbitrary addresses.** An operator can point their slice anywhere,
including at a contract that reverts. That only costs them their own payout.

**Yield source concentration.** All brands share one reserve and one adapter. A bad market cannot
harm another brand — yield splits strictly by outstanding supply — but a bad adapter harms every
brand at once.

**Redemption liquidity.** The reserve recalls from Morpho on demand and can fall short at 100%
market utilisation. There is no idle-buffer policy today, and a market layer that encourages large
float makes this matter more than it currently does.

**Thin-pool reflexivity.** A market whose only meaningful flow is its own buyback is a price of
one participant's making. The threshold, the interval and the TWAP band bound how hard a single
round can push, and they do not make the underlying problem go away. A market whose only buyer is
its own buyback is not a market, and the UI should not present it as one.

## 3.5 Out of scope for these contracts, but blocking deployment

Pre-existing and tracked in `README.md`:

1. `SharedReservePool` has never been broadcast — only a dry run exists.
2. Both `MorphoBlueYieldSource` instances live on mainnet predate the per-consumer share
   accounting; their `withdraw(asset, amount, to)` has no access control and an arbitrary
   recipient. A fixed adapter must be deployed and set before any float arrives.
3. The reserve pool's timelock delay is `0`, which means it is not a timelock.

## 3.6 Test coverage

57 tests. `test/markets/MarketYieldSplitter.t.sol` (25) covers the split arithmetic, the ledger,
failure isolation and every configuration guard, including a fuzz test that every harvested wei is
credited. `test/markets/AssetMarketFactory.t.sol` (22) covers wiring, both price orderings, the
codehash test against a same-code clone and a different-code impersonator, and that protocol
parameter changes never reach live markets.

`test/markets/AssetMarketFork.t.sol` (10) runs against real USDG, real Morpho Blue, real Uniswap
V3 and the real SPCX token: verification against live SPCX/AAPL/NVDA, pricing agreement with the
live SPCX/USDG pool, the AMM reserve counting as float, buy/sell through the real SwapRouter02,
brand-to-brand crossing at exact par, and a real 180-day harvest — **$45,808 of float earning
$1,739.74, an effective 3.8% APY**.

```bash
forge test --offline --match-path 'test/markets/*' --no-match-contract Fork
forge test --match-contract AssetMarketFork -vv --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number <recent>
```

`test/markets/AssetMarketTestnetFork.t.sol` (10) runs the same lifecycle against Robinhood Chain
testnet, as the dry run for the deployment in Part 4.

`test/audit/AssetMarketAudit.t.sol` (14) is the audit regression suite behind §3.3. Each
`test_fix_*` began as a passing exploit against the pre-fix contracts and now asserts the fixed
behaviour, so a regression re-opens the hole and turns the suite red. The one `test_known_*`
characterises F-4, which is accepted rather than fixed.

Not covered, and deliberately so: the router is exercised only against real Uniswap, because the
repo's shared V3 mock has no curve and no token custody by design.

---

# Part 4 — The live testnet deployment

Deployed and exercised on **Robinhood Chain testnet (46630)** on 2026-09-09, from post-audit
source. Machine-readable copy: `deployments/asset-markets-testnet.json`. Every address below was
read back off chain, not copied from a deploy log.

This deployment is the **buyback generation**: a `BuybackEngine` and an `AssetLockbox` per market,
a multi-leg `MarketYieldSplitter` with no operator payout and no LP escrow, `maxSqrtDeviationBps`
on `CreateParams` (the F-1 fix), and a `deadline` plus real minimums on every `MarketRouter` entry
point. A client built from HEAD reads and writes it without an ABI shim.

> ⚠️ **`AssetMarketFactory`'s runtime is 26,622 bytes, 2,046 over the EIP-170 limit of 24,576.**
> The factory embeds the splitter's creation code, which embeds the engine's, which embeds the
> lockbox's. Robinhood Chain accepts it — verified by deploying a 27,000-byte probe contract, and
> then by this deployment succeeding — but **an EIP-170 chain would reject this factory as it
> stands**, and `forge test` does not enforce the limit, so the suite stays green either way.
> Deploying to such a chain needs the splitter construction moved behind a deployer contract or a
> lower `optimizer_runs`. `forge script` also needs `--code-size-limit` raised to simulate it.

## 4.1 Addresses

| | Address |
|---|---|
| `AssetMarketFactory` | `0xdf9C44719a0a580544F1Ba3384f8C00Dd282d92c` |
| `MarketRouter` | `0x0da312531363DB31297C2fDbb0585ABA1B962E6C` |
| `SharedReservePool` | `0x22AA61c589B90731752236c07d1455D0065bfc79` |
| Reserve asset — **tUSDG**, 6dp, freely mintable | `0xB714D2E06a081929824381Fc360ada2c2e7f9fcF` |
| Faucet asset — **tASSET**, 18dp, freely mintable | `0x65876276feE875e1A120F63575150593E6AEa0d3` |
| Yield source (transfer-funded simulator) | `0xad46f2a29317096047aD6D036dDa24Bf260C5f62` |
| Deployer / protocol owner / reserve owner | `0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9` |

Genuine pinned Uniswap V3 bytecode, deployed by the same script:

| | Address |
|---|---|
| Factory | `0x25481313442a01E4C4C32fab1c097205A856c402` |
| NonfungiblePositionManager | `0x0C1817828299b8c36A02a721ff58fbd2d53f74Bc` |
| SwapRouter02 | `0xdf04E3cbCcdE64027eb35963F6817540BE4F96d7` |
| Wrapped test ether | `0xb6b86f5A01d8c04f68f827532C8aCE9458Db57a6` |

`protocolBps` is **0**, so 100% of every harvest reaches the buyback and "the whole float yield
buys the asset back" is literal here rather than approximate. Equity verification is disabled
(`equityCodehash` is zero), so every market on this stack is correctly `verified: false`.

### Market 1 — tASSET / tstUSD, seeded and traded

| | |
|---|---|
| Brand token | `0xDE78eCF9E7255fFdf871387d8b7505AC7011a6f8` (**tmUSD**, 6dp) |
| Treasury | `0x9d269283631Fac981f75126DF60E01Ca39AD21cc` |
| Splitter | `0xC8e25Cd9f50f0274e6ace29f713AA423B1254e53` |
| Buyback engine | `0xbA93f34D30b13cb717F3CAE872530c60AB001ddA` |
| Lockbox | `0x70CE4Bf51861eaDFE3A0fA822303f25Ef2b81080` |
| Uniswap pool | `0x3ecEA35fd2C5740afff209ad7A625af37356cf07` (0.3%) |

Seeded full range at $1.00 with 10,000 tUSDG and 10,000 tASSET.

### Market 2 — tASSET / orbUSD

| | |
|---|---|
| Brand token | `0xDEbc0B40C895286781156F461b742Ca484381722` (**orbUSD**, 6dp) |

Seeded full range at $2.50 with 25,000 tUSDG and 10,000 tASSET. It exists so cross-brand entry
into market 1 has a second dollar to cross from.

### Standalone brand — no market

`0x66Fd40C7ed950459A878d57F78F1615F639EE019` (**CUSD**, "Commons Test Dollar") is registered on
the reserve with no paired asset. It exists to keep the frontend honest: a brand with
`marketOfBrand == 0` is a supported product, not a half-built market, and it appears in no
market enumeration at all. Any surface that discovers stablecoins by walking markets will drop it.

## 4.2 Two things that are not like mainnet

**The reserve asset is `tUSDG`, not USDG.** The genuine testnet USDG
(`0x7E955252E15c84f5768B83c41a71F9eba181802F`) has `mint` AccessControl-gated to an owner we are
not, so no one else can obtain any and nothing could be exercised against it. `tUSDG` has an open
`mint(address,uint256)` on purpose, as does `tASSET`.

**The yield source is a simulator.** Testnet has no lending market at all — nothing sits at Morpho
Blue's mainnet address, and none of the contracts named "Morpho" there holds a unit of either USDG
candidate. Yield arrives through `simulateYield(asset, consumer, amount)`, backed by a real
transfer, and is never accrued. The frontend labels the reserve strategy accordingly rather than
naming a lending protocol that does not exist on this chain.

## 4.3 Frontend environment block

Written to `web-stable/.env.local`, which is gitignored. `NEXT_PUBLIC_*` values are baked in at
build time, so restart the dev server or rebuild after editing.

```
NEXT_PUBLIC_CHAIN_ID=46630
NEXT_PUBLIC_RPC_URL=https://rpc.testnet.chain.robinhood.com
NEXT_PUBLIC_ASSET_MARKET_FACTORY=0xdf9C44719a0a580544F1Ba3384f8C00Dd282d92c
NEXT_PUBLIC_MARKET_ROUTER=0x0da312531363DB31297C2fDbb0585ABA1B962E6C
NEXT_PUBLIC_SHARED_RESERVE_POOL=0x22AA61c589B90731752236c07d1455D0065bfc79
NEXT_PUBLIC_USDG=0xB714D2E06a081929824381Fc360ada2c2e7f9fcF
```

`web-stable/scripts/testnet.mjs` reads the same values straight out of the deployment manifest, so
`npm run dev:testnet` needs no env file at all.

## 4.4 Runbook

Every command is one line. `$RPC` is `https://rpc.testnet.chain.robinhood.com`.

**Deploy a fresh stack.** Fetch the pinned artifacts, then broadcast. `--code-size-limit` is
required: the factory is over EIP-170 and `forge` refuses to simulate it otherwise.

```bash
npm install --prefix /private/tmp/asset-markets-deps --no-package-lock --ignore-scripts @uniswap/v3-core@1.0.1 @uniswap/v3-periphery@1.4.4 @uniswap/swap-router-contracts@1.3.1
```

```bash
FOUNDRY_PROFILE=asset_markets_testnet UNISWAP_NODE_MODULES=/private/tmp/asset-markets-deps/node_modules DEPLOYER=<you> forge script script/DeployAssetMarketsTestnet.s.sol:DeployAssetMarketsTestnet --rpc-url $RPC --account <keystore> --broadcast --slow --code-size-limit 40000
```

**Create and seed two markets** with the addresses that run printed:

```bash
FOUNDRY_PROFILE=asset_markets_testnet DEPLOYER=<you> FACTORY=<factory> ROUTER=<router> USDG=<tUSDG> ASSET=<tASSET> forge script script/SeedAssetMarketsTestnet.s.sol:SeedAssetMarketsTestnet --rpc-url $RPC --account <keystore> --broadcast --slow --code-size-limit 40000
```

**Get yourself faucet money** — both mints are open to anyone:

```bash
cast send 0xB714D2E06a081929824381Fc360ada2c2e7f9fcF 'mint(address,uint256)' <you> 100000000000 --rpc-url $RPC --account <keystore>
```

**Buy tASSET with tUSDG** (approve the *router*, then buy; `1` is the market id, last argument is a
Unix-seconds deadline):

```bash
cast send 0xB714D2E06a081929824381Fc360ada2c2e7f9fcF 'approve(address,uint256)' 0x0da312531363DB31297C2fDbb0585ABA1B962E6C 1000000000 --rpc-url $RPC --account <keystore>
```

```bash
cast send 0x0da312531363DB31297C2fDbb0585ABA1B962E6C 'buyWithUsdg(uint256,uint256,uint256,address,uint256)' 1 100000000 1 <you> <deadline> --rpc-url $RPC --account <keystore>
```

**Sell it back** (approve the router for the *asset*):

```bash
cast send 0x0da312531363DB31297C2fDbb0585ABA1B962E6C 'sellForBrand(uint256,uint256,uint256,address,uint256)' 1 <assetAmount18dp> 1 <you> <deadline> --rpc-url $RPC --account <keystore>
```

**Enter market 1 holding market 2's dollar.** Mint orbUSD from the reserve pool first — that mint
needs an approval to the *pool*, not the router — then approve the router for orbUSD and buy:

```bash
cast send 0x0da312531363DB31297C2fDbb0585ABA1B962E6C 'buyWithBrand(uint256,address,uint256,uint256,address,uint256)' 1 0xDEbc0B40C895286781156F461b742Ca484381722 50000000 1 <you> <deadline> --rpc-url $RPC --account <keystore>
```

**Mint and redeem a brand token directly** — mint needs an approval to the pool; **redeem needs
none**, because the pool burns from the caller through a path that takes no allowance:

```bash
cast send 0x22AA61c589B90731752236c07d1455D0065bfc79 'mint(address,uint256,address)' <brand> 1000000000 <you> --rpc-url $RPC --account <keystore>
```

```bash
cast send 0x22AA61c589B90731752236c07d1455D0065bfc79 'redeem(address,uint256,address)' <brand> 1000000000 <you> --rpc-url $RPC --account <keystore>
```

**Register a standalone stablecoin**, with no paired asset and no market:

```bash
cast send 0x22AA61c589B90731752236c07d1455D0065bfc79 'registerBrand(string,string,address)' 'Commons Test Dollar' CUSD <you> --rpc-url $RPC --account <keystore>
```

**Make yield happen, then spend it.** Inject, harvest, pay out, buy back. Every step after the
injection is permissionless:

```bash
cast send 0xad46f2a29317096047aD6D036dDa24Bf260C5f62 'simulateYield(address,address,uint256)' 0xB714D2E06a081929824381Fc360ada2c2e7f9fcF 0x22AA61c589B90731752236c07d1455D0065bfc79 200000000 --rpc-url $RPC --account <keystore>
```

```bash
cast send 0xC8e25Cd9f50f0274e6ace29f713AA423B1254e53 'harvest()' --rpc-url $RPC --account <keystore>
```

```bash
cast send 0xC8e25Cd9f50f0274e6ace29f713AA423B1254e53 'pushAll()' --rpc-url $RPC --account <keystore>
```

```bash
cast send 0xbA93f34D30b13cb717F3CAE872530c60AB001ddA 'execute()' --rpc-url $RPC --account <keystore>
```

> ℹ️ **`carried()` is worth watching on a young market.** A harvest that finds no weight anywhere
> banks its whole claim in `carried()` and distributes nothing, and the next harvest with weight
> pays out both. On the liquidity-seconds build this is rare: the leg records its accumulator
> baseline when the pool is attached, and a seeded pool starts earning immediately — the live run
> below harvested into a non-zero budget on the *first* attempt, with `carried()` at zero.
> The earlier balance-based build carried its first harvest every time, because weight was
> credited at the balance recorded at the previous poke and the pool was empty at creation. If a
> harvest ever pays out nothing, read `carried()` before assuming something is broken.

## 4.5 Useful reads

```bash
cast call 0xdf9C44719a0a580544F1Ba3384f8C00Dd282d92c 'marketCount()(uint256)' --rpc-url $RPC
```

```bash
cast call 0xdf9C44719a0a580544F1Ba3384f8C00Dd282d92c 'market(uint256)((address,address,address,address,address,address,address,uint24,address,bool,uint64))' 1 --rpc-url $RPC
```

```bash
cast call 0xbA93f34D30b13cb717F3CAE872530c60AB001ddA 'canExecute()(bool,string)' --rpc-url $RPC
```

```bash
cast call 0xC8e25Cd9f50f0274e6ace29f713AA423B1254e53 'carried()(uint256)' --rpc-url $RPC
```

## 4.6 State after the integration run

Read back off chain after exercising the stack end to end:

| | |
|---|---|
| Markets created and seeded | 2 |
| Registered brands | 4 — two paired, two standalone |
| Trades executed | `buyWithUsdg`, `sellForBrand`, `buyWithBrand` across brands, all successful |
| Direct reserve operations | 1:1 mint and redeem, redeem with no approval |
| Splitter `totalHarvested` (market 1) | 342.939746 tUSDG across two harvests |
| First harvest | carried in full — the leg had no measured float yet |
| Second harvest | 200.048185 tUSDG credited, 100% to the buyback, 0 to protocol |
| Buyback rounds | 0 — `canExecute` returns `"no-twap"` until the pool's observation buffer reaches back a full 30-minute window |

The buyback is funded and blocked only by the TWAP window, which is the engine refusing to trade
against a price it cannot yet observe. It is the young-market case `canExecute` exists to report.
