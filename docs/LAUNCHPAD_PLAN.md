# Launchpad — integration plan and contract spec

> **Status: implementation spec for branch `feature/launchpad`.** Everything below is the
> contract the implementing agents build to. Sections 3–6 are normative; a change to a
> signature or an event in them must be made here first.

## 1. What is being built

A pump.fun-style launchpad whose quote asset is a **branded stablecoin** and whose
graduation target is an **asset market** created by `AssetMarketFactory`:

```
launch ─► LaunchCurve (x·y=k, quoted in brand X) ─► threshold ─► graduateToMarket
                                                                    │
                    AssetMarketFactory.createLaunchMarket(token) ◄──┘
                    ├─ mints the market unit "TOKEN.d" (6 dec, 1:1 reserve)
                    ├─ v4 pool (unit, token) + ProtocolFeeHook skim + LpRewardDistributor
                    └─ LaunchGraduation: swap X→unit 1:1, mint full-range POSM NFT,
                       stake it in the distributor with LaunchLocker as the staker
```

The fork base is **Pons V2** (MIT), the launchpad that runs 40k launches/day on Robinhood
Chain against the same Uniswap v4 singleton this repo uses. The unmodified upstream is in
`vendor/pons-v2/` (see its `NOTICE.md`); the fork lives in `src/launchpad/`.

What changes against Pons:

| Pons V2 | Here | Why |
|---|---|---|
| quote = native ETH or owner-approved ERC-20 | quote = **any registered brand** of a reserve the owner has opened, no per-brand approval; native path deleted | curve float is brand float, so it earns yield for the brand's treasury while the curve trades, and the terms belong to the reserve rather than to each dollar |
| launch fee 0.0005 ETH | launch fee in the quote brand, per reserve | stablecoin-first product; no ETH plumbing |
| graduates into its own hook + permanent locker, LP fee tier 0 | graduates through `AssetMarketFactory.createLaunchMarket` into a normal asset market: `ProtocolFeeHook` skim (protocol), 0.5% LP tier, float yield to LPs | one market stack, one indexer, one router, one UI |
| creator revenue post-graduation = hook fee share | creator revenue post-graduation = the locked position's income, split on two rates: `creatorShareBps` of its LP fees (snapshotted per launch, ships at 10_000) and `graduatedCreatorYieldShareBps` of its float-yield rewards (read live, ships at 0), both pulled from `LaunchFeeEscrow` | zero hook changes; the locked seed liquidity is the largest LP and earns like any LP, but the float yield is the reserve's earning rather than the launch's |
| `PonsV2BuybackVault` (5-year vest of bought-back tokens) | deleted | conflicts with the yield-to-LPs decision (`2105f7d`); halves the fee-split surface |
| owner may retarget any creator's fee recipient after 3 days | deleted; only the current recipient can hand over (2-step) | centralization |
| non-upgradeable factory | factory is a UUPS proxy behind `ProtocolGuard` like every other singleton here; curves and tokens stay immutable | graduation is the step that broke on mainnet last time; a patchable orchestrator is worth the proxy |

Kept verbatim (renamed): curve math, curve accounting (tracked reserves, quote-leg fees,
creator tax, snipe tax, partial-fill refund), CREATE2 deployer with address prediction,
graduation guard, fee escrow (ERC-20 half), two-phase retryable graduation, 7-day rescue.

## 2. Files and ownership

```
src/launchpad/
  LaunchToken.sol              ← vendor PonsV2LauncherToken       (rename only)
  LaunchCurve.sol              ← vendor PonsV2BondingCurve        (strip native/buyback; policy from factory)
  LaunchFactory.sol            ← vendor PonsV2LaunchFactory       (UUPS; ERC-20 fee; brand quotes; phase 2 → LaunchGraduation)
  LaunchDeployer.sol           ← vendor PonsV2LaunchDeployer      (rename; drop buybackEnabled)
  LaunchGraduationGuard.sol    ← vendor PonsV2GraduationGuard     (rename only)
  LaunchFeeEscrow.sol          ← vendor PonsV2FeeEscrow           (ERC-20 half only)
  LaunchGraduation.sol         NEW (replaces PonsV2GraduationExecutor)
  LaunchLocker.sol             NEW (replaces PonsV2LaunchLocker)
  LaunchRouter.sol             ← vendor PonsV2LaunchAndBuy + reserve mint/swap/redeem legs
  interfaces/ILaunchpad.sol    ← vendor interfaces/ILaunchpadV2.sol (trimmed, §3)
  libraries/LaunchCurveMath.sol, libraries/LaunchGraduationMath.sol   (rename only)
src/markets/AssetMarketFactory.sol   + `launchpad` role, `createLaunchMarket` (§4)
src/upgrade/ProtocolStack.sol        + `deployLaunchpad`
script/DeployAssetMarkets.s.sol      + launchpad step, manifest fields
test/launchpad/*.t.sol               new suites (§7)
test/helpers/StackFixture.sol        + launchpad wiring helpers
web-stable/, backend/, services/market-data/   (§8, §9)
```

Every fork file keeps `// SPDX-License-Identifier: MIT` and gets a one-line header
`// Forked from Pons V2 (vendor/pons-v2/<file>), MIT.` Contract names are `Launch*`; the
`PonsV2` prefix must not survive in `src/`.

## 3. `src/launchpad/interfaces/ILaunchpad.sol` — normative

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Pull ledger for ERC-20 revenue. `creditToken` pulls `amount` from `msg.sender`.
interface ILaunchFeeEscrow {
    function creditToken(address recipient, address token, uint256 amount) external;
    function claimToken(address token) external returns (uint256 amount);
    function claimToken(address token, uint256 amount) external returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

/// Snapshotted into every curve at launch.
struct FeePolicySnapshot {
    address protocolFeeRecipient;
    uint16 protocolFeeShareBps;   // share of the curve fee that goes to the protocol
}

/// Implemented by LaunchFactory. The curve reads it at initialize and snapshots it.
interface ILaunchFeePolicy {
    function protocolFeeRecipient() external view returns (address);
    function protocolFeeShareBps() external view returns (uint256);
    function feeEscrow() external view returns (ILaunchFeeEscrow);
    function currentFeePolicy() external view returns (FeePolicySnapshot memory);
}

/// Implemented by LaunchFactory. Snapshotted into every curve at initialize.
interface ILaunchSnipeTax {
    function snipeTaxStartBps() external view returns (uint256);
    function snipeTaxSeconds() external view returns (uint256);
}

enum GraduationPhase { NotGraduated, Swept, Graduated, Rescued }

interface ILaunchFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;               // creator, for attribution and unit metadata admin
        address creatorFeeRecipient;
        address pairToken;              // the brand the curve is quoted in
        address reserve;                // SharedReservePool that brand belongs to
        uint256 graduationThreshold;    // in pairToken units
        uint24 poolFee;                 // LP tier of the graduated pool, snapshotted
        uint16 creatorTaxBps;
        uint16 creatorShareBps;         // creator's share of locked-position income post-graduation
        GraduationPhase phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        uint256 marketId;               // AssetMarketFactory market id once Graduated
        bool exists;
    }
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function creatorFeeRecipientOf(address token) external view returns (address); // live; the locker reads it at collect time
    function launchCount() external view returns (uint256);
    function launchAt(uint256 index) external view returns (address token);
    function graduate(address token) external;           // phase 1, permissionless
    function graduateToMarket(address token) external;   // phase 2, permissionless, retryable
}

interface ILaunchCurve {
    function token() external view returns (address);
    function pairToken() external view returns (address);
    function graduationThreshold() external view returns (uint256);
    function graduated() external view returns (bool);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function realQuoteReserve() external view returns (uint256);
    function sellableTokens() external view returns (uint256);
    function readyToGraduate() external view returns (bool);
    function currentSnipeTaxBps(address recipient) external view returns (uint256);
    function quoteBuy(uint256 quoteIn, address recipient) external view returns (uint256 tokensOut, uint256 fee, uint256 tax);
    function quoteSell(uint256 tokensIn) external view returns (uint256 quoteOut, uint256 fee, uint256 tax);
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);
    function sweepFees() external;
    function graduate(address recipient) external returns (uint256 quoteOut, uint256 tokenOut); // onlyFactory
}

/// The graduation executor. `LaunchFactory` transfers `quoteAmount` of `pairToken` and
/// `tokenAmount` of `token` to it, then calls `graduate`. All-or-nothing: any failure
/// reverts the whole phase-2 transaction and the factory keeps the swept reserves.
interface ILaunchGraduation {
    struct Seed {
        address token;
        address pairToken;
        address reserve;
        address creator;
        address creatorFeeRecipient;
        uint16 creatorShareBps;
        uint24 poolFee;
        uint256 quoteAmount;     // swept real quote, pairToken units
        uint256 tokenAmount;     // swept tokens (whole remaining supply)
        uint256 phantomQuote;    // to preserve the terminal price: seed tokens = tokenAmount·quote/(quote+phantom)
        string unitName;
        string unitSymbol;
    }
    struct Result {
        uint256 marketId;
        address unit;
        bytes32 poolId;
        uint256 positionId;
        uint256 unitSeeded;
        uint256 tokensSeeded;
        uint256 tokensLocked;    // everything sent to the locker: excess supply plus mint dust (§6 step 8)
    }
    function graduate(Seed calldata seed) external returns (Result memory);
}

interface ILaunchLocker {
    struct LockedPosition {
        uint256 tokenId;
        address distributor;         // LpRewardDistributor the NFT is staked in
        address unit;                // the market unit (reward token and one fee currency)
        address creatorFeeRecipient;
        uint16 creatorShareBps;
        bool exists;
    }
    /// onlyGraduation. The NFT must already be staked in `distributor` with this locker as
    /// the staker; this records the split. Never unstakes: there is no function for it.
    function recordPosition(address token, LockedPosition calldata position) external;
    /// onlyGraduation. Pulls `amount` of `token` from msg.sender and holds it forever.
    function lockTokenSupply(address token, uint256 amount) external;
    /// Permissionless. Collects the position's LP fees and float-yield rewards, splits
    /// creator/protocol and credits LaunchFeeEscrow.
    function collect(address token) external returns (uint256 unitOut, uint256 tokenOut);
    function lockedPosition(address token) external view returns (LockedPosition memory);
    function lockedSupply(address token) external view returns (uint256);
}
```

Events (exact shapes; indexers and the UI key off these):

```solidity
// LaunchFactory
event TokenLaunched(address indexed token, address indexed curve, address indexed deployer,
    address pairToken, address reserve, uint256 launchConfigId, uint256 graduationThreshold);
event LaunchSwept(address indexed token, uint256 quoteOut, uint256 tokenOut);
event PoolGraduated(address indexed token, uint256 indexed marketId, address unit, bytes32 poolId,
    uint256 positionId, uint256 unitSeeded, uint256 tokensSeeded, uint256 tokensLocked);
event GraduationRescued(address indexed token, address indexed to, uint256 quote, uint256 tokens);
event CreatorFeeRecipientUpdated(address indexed token, address indexed previous, address indexed current);
// LaunchCurve (Pons shapes, unchanged)
event CurveBuy(address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 tokensOut, uint256 fee, uint256 tax);
event CurveBuyRefunded(address indexed buyer, uint256 refund);
event CurveSell(address indexed seller, address indexed recipient, uint256 tokensIn, uint256 quoteOut, uint256 fee, uint256 tax);
event FeesSwept(uint256 protocolAmount, uint256 creatorAmount);
event SnipeTaxCharged(address indexed recipient, uint256 amount);
event CurveCompleted(address recipient, uint256 quoteOut, uint256 tokenOut);
// LaunchLocker
event PositionLocked(address indexed token, uint256 indexed tokenId, address distributor);
event SupplyLocked(address indexed token, uint256 amount);
event Collected(address indexed token, uint256 unitToCreator, uint256 unitToProtocol, uint256 tokenToCreator, uint256 tokenToProtocol);
```

## 4. `AssetMarketFactory` seam — normative

```solidity
/// @notice The launchpad's graduation module. The only address that may list an asset it
///         created without an owner approval. Zero disables the path.
address public launchpad;                       // appended before __gap; gap shrinks to 39
event LaunchpadUpdated(address launchpad);
error OnlyLaunchpad();

function setLaunchpad(address launchpad_) external onlyOwner;

/// @notice One-transaction market for a launchpad-created asset. Same validation as
///         `approveAsset` on `listing` (code, unit metadata, fee tier, price, cardinality),
///         same `_registerBrand` + `_openMarket` path as `createMarket`, except:
///         - no `approveAsset` gate (the caller IS the gate),
///         - `creator` (not msg.sender) is recorded as the market creator and receives the
///           unit's metadata admin,
///         - the asset is never `verified`.
///         Reverts `OnlyLaunchpad`, `AssetAlreadyHasMarket`, `ReserveNotApproved`.
function createLaunchMarket(address asset, address reserve, address creator, AssetListing calldata listing)
    external
    returns (uint256 marketId, address brandToken, address feeVault, address lpDistributor, bytes32 poolId);
```

`listing.approved` is ignored. `listing.assetPriceE18` is the price of ONE WHOLE token in
WHOLE unit units × 1e18, as documented on the struct. Nothing else in the factory changes;
`ProtocolFeeHook` keeps the factory as its single registrar.

## 5. `LaunchFactory` — normative surface

Storage/config (owner):

```solidity
struct LaunchConfig { uint256 supply; uint256 curveFeeBps; uint24 poolFee; bool enabled; }
struct ReserveEconomics {
    uint256 phantomQuote;        // reserve-asset units
    uint256 graduationThreshold; // reserve-asset units
    uint256 launchFee;           // reserve-asset units, may be 0
    uint8 decimals;              // == SharedReservePool(reserve).assetDecimals()
    bool approved;
}
uint256 public constant MAX_CURVE_FEE_BPS = 1_000;      // 10%
uint256 public constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // curve fee + creator tax
uint256 public constant GRADUATION_RESCUE_DELAY = 7 days;
uint256 public constant MIN_PAIR_TOKEN_DECIMALS = 6;

function initialize(address owner, address guard, AssetMarketFactory marketFactory, IPositionManagerV4 positionManager, ILaunchFeeEscrow feeEscrow) external initializer;
function setLaunchDeployer(LaunchDeployer d) external onlyOwner;        // one-shot
function setGraduation(ILaunchGraduation g) external onlyOwner;         // one-shot
function setLaunchForwarder(address router) external onlyOwner;
function setLaunchEnabled(bool) external onlyOwner;
function addLaunchConfig(LaunchConfig calldata) external onlyOwner returns (uint256 id);
function updateLaunchConfig(uint256 id, LaunchConfig calldata) external onlyOwner;
mapping(address reserve => ReserveEconomics economics) public reserveEconomics;
function launchEconomics(address pairToken) public view returns (address reserve, ReserveEconomics memory economics);
    // reverts: PairTokenNotRegistered (marketFactory.reserveOfBrand(pairToken) == 0),
    // ReserveNotApproved (that reserve is neither the market factory's default nor an
    // `approvedReservePool`), PairTokenFloatShareUnavailable (the brand's treasury does not
    // name the market factory). Private `_quoteReserve` holds those three; every launch,
    // preview and router quote goes through it.
function setReserveEconomics(address reserve, ReserveEconomics calldata e) external onlyOwner;
    // requires: reserve != 0; phantomQuote != 0 && graduationThreshold != 0;
    // e.decimals >= MIN_PAIR_TOKEN_DECIMALS; reserve is the market factory's default reserve
    // or an `approvedReservePool`; SharedReservePool(reserve).assetDecimals() == e.decimals;
    // `_requireQuotable` at MIN_LAUNCH_SUPPLY / MAX_CURVE_FEE_BPS. Names no brand.
function setReserveApproved(address reserve, bool) external onlyOwner;  // reverts ReserveEconomicsInvalid while phantomQuote == 0
function setProtocolFeeRecipient(address) external onlyOwner;
function setProtocolFeeShareBps(uint16) external onlyOwner;     // <= 5_000
function setMaxCreatorTaxBps(uint16) external onlyOwner;        // <= 1_000
function setSnipeTax(uint256 startBps, uint256 seconds_) external onlyOwner;
function setGraduatedCreatorShareBps(uint16) external onlyOwner; // <= 10_000, default 10_000, LP fees, snapshotted
function setGraduatedCreatorYieldShareBps(uint16) external onlyOwner; // <= 10_000, default 0, float yield, read live
```

**Launch collateral is keyed by reserve, not by brand.** Every brand is a costless 1:1 wrapper
of its reserve's asset, minted at `assetDecimals`, so one unit of any brand of a reserve is
worth the same and counts the same: a `phantomQuote` and `graduationThreshold` sized for one
brand are correct for all of them. Keying by brand made every new platform dollar wait on an
owner transaction that could only ever repeat the same five figures; keying by reserve means a
dollar issued tomorrow is launchable the moment the market factory registers it and its issuer
opts into float sharing. The two per-brand conditions are not dropped — they move to launch
time, into `_quoteReserve`, where they are re-read on every launch instead of once at approval.

The real cost is that **there is no per-brand kill switch.** The owner's only switch is
`setReserveApproved(reserve, false)`, which closes every brand of that reserve at once; a
specific dollar is refused only by the structural conditions — not registered through the
market factory, or no float-share opt-in — and neither of those is the launchpad owner's to
set. Refusing one brand of an otherwise-open reserve therefore needs the market factory's
brand registry or the issuer's own treasury, not this contract. Accepted deliberately: the
per-brand switch's only real use was withholding launchability from a dollar that met every
structural condition, which is exactly the rollout tax this change exists to remove. Existing
launches are unaffected by either switch — each curve holds its figures as constructor
immutables.

Launch:

```solidity
struct TokenParams {
    string name; string symbol; string logo; string description;
    LaunchToken.Socials socials;       // {twitter, telegram, discord, website, farcaster}
    address creatorFeeRecipient;
    uint16 creatorTaxBps;
    bytes32 expectedEconomics;         // 0 waives; else must equal previewLaunchEconomics(configId, pairToken)
    bytes32 salt;                      // CREATE2, namespaced by originalDeployer
}
function launchToken(TokenParams calldata p, uint256 launchConfigId, address pairToken, address[] calldata snipeTaxExemptions)
    external returns (address token, address curve);
function launchTokenFor(TokenParams calldata p, uint256 launchConfigId, address pairToken, address[] calldata snipeTaxExemptions, address originalDeployer)
    external returns (address token, address curve);   // msg.sender == launchForwarder
function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
function predictLaunchAddresses(TokenParams calldata p, uint256 launchConfigId, address pairToken, address originalDeployer) external view returns (address token, address curve);
```

`launchToken` pulls `economics.launchFee` of `pairToken` from `msg.sender` straight to
`protocolFeeRecipient` (`safeTransferFrom`), **last**, after the curve is initialised — the
same "fee last" ordering Pons uses so a failed launch never takes a fee. The full supply is
minted to the curve in `LaunchToken`'s constructor. `reservedTokens = supply·phantom/(phantom+threshold)`.

Graduation:

- `graduate(token)`: phase 1, permissionless, also attempted inside the crossing `buy` via
  try/catch (`AutoGraduationFailed` on failure). Calls `curve.graduate(address(this))`, which
  sweeps pending fees to the escrow itself before handing over the reserves (`curve.sweepFees()`
  is `nonReentrant` and so cannot be called from inside the crossing buy's guarded scope);
  records `sweptQuote/sweptTokens/sweptAt`; phase `Swept`. No seed preflight here: a launch
  that cannot seed still sweeps, so the 7-day rescue can reach its reserves.
- `graduateToMarket(token)`: phase 2, permissionless, retryable. Transfers `sweptQuote` of
  pairToken and `sweptTokens` of token to `graduation`, builds the `Seed` with
  `unitName = string.concat(symbol, " Market Dollar")`, `unitSymbol = string.concat(symbol, ".d")`,
  calls `graduation.graduate(seed)`, stores `marketId`, phase `Graduated`, emits
  `PoolGraduated`. Preflight with `LaunchGraduationGuard` before moving funds.
- `rescueSweptGraduation(token, to)`: owner, `whenNotPaused`, only after `sweptAt + 7 days` and
  still `Swept`; phase `Rescued`; emits `GraduationRescued`. The pause gate is load-bearing:
  the window is only legitimate because the permissionless retry stays available throughout
  it, so the rescue must be unavailable on exactly the condition that removes the retry.
  Otherwise a guardian pause — instant, untimelocked, and supposedly harmless — becomes the
  trigger for an owner-only transfer of traders' money.

`expectedEconomics` preimage, in order: `phantomQuote`, `graduationThreshold`, `supply`,
`curveFeeBps`, `poolFee`, `protocolFeeShareBps`, `launchFee`, `graduatedCreatorShareBps`,
`snipeTaxStartBps`, `snipeTaxSeconds`, `reserve`. The rule is that every owner-movable term
**frozen into the launch** is covered, because the creator cannot react to it once the curve
is live. `maxCreatorTaxBps` is excluded deliberately — it bounds a figure the creator supplies,
so a change makes the launch revert rather than silently reprice.

Two bounds keep terms that cannot graduate from ever launching. `_requireSeedableTerms`
rejects a seed V4 would refuse to mint. `_requireSeedPriceResolvable` rejects terms whose
`assetPriceE18` would fall below `1e4`: that price is what the graduated pool opens at, its
truncation strands that fraction of the seed, and `LaunchGraduation.MAX_DUST_BPS` enforces the
same bound from the other side at graduation. The brand's reserve is resolved and re-checked
against `marketFactory.approvedReservePool` on every launch rather than stored per brand — a
reserve retired underneath a live brand would otherwise strand every launch quoted in it.

Creator fee recipient: `proposeCreatorFeeRecipient(token, newRecipient)` by the current
recipient, `acceptCreatorFeeRecipient(token)` by the proposed one. Accepting updates the
factory record and, while the curve still trades, the curve; nothing is pushed to the locker:
`LaunchLocker.collect` reads `creatorFeeRecipientOf(token)` live (§6), so the factory record is
the single source of truth before and after graduation. No owner override.

`LaunchFactory` implements `ILaunchFeePolicy` and `ILaunchSnipeTax`; the curve reads
`ILaunchFeePolicy(factory)` at `initialize` and snapshots the policy. Deleted from the fork:
`buybackEnabled`, `buybackBurnBps`, `hookFeeBps`, `maxInternalPriceImpactBps`,
`feeSweepOperator`, the internal buyback swap, native-quote branches, the pending
creator-fee-recipient owner override, `IPonsV2BuybackVault`, the meme hook.

Bytecode budget: the factory must stay under EIP-170 with `via_ir`, 200 runs (check with
`forge build --sizes`). If it does not, move more of phase 2 into `LaunchGraduation`.

## 6. `LaunchGraduation` and `LaunchLocker` — normative behaviour

`LaunchGraduation.graduate(seed)` (onlyFactory, nonReentrant):

1. `tokensSeeded = seed.tokenAmount · seed.quoteAmount / (seed.quoteAmount + seed.phantomQuote)`;
   `tokensLocked = seed.tokenAmount − tokensSeeded` → `locker.lockTokenSupply` (approve + pull).
2. `assetPriceE18 = seed.quoteAmount · 10^(tokenDecimals) · 1e18 / (tokensSeeded · 10^(unitDecimals))`
   where `unitDecimals == IERC20Metadata(seed.pairToken).decimals()` (units share the reserve
   asset's decimals; brands of one reserve are all 6-decimal today). Revert `ZeroAmount` on zero.
3. `marketFactory.createLaunchMarket(seed.token, seed.reserve, seed.creator, AssetListing{approved: false, fee: seed.poolFee, assetPriceE18, observationCardinality: 0, unitName, unitSymbol})`
   → `(marketId, unit, , distributor, poolId)`.
4. `SharedReservePool(seed.reserve).swap(seed.pairToken, unit, seed.quoteAmount, address(this))` — 1:1.
5. Full-range mint through `IPositionManagerV4.modifyLiquidities` exactly as
   `MarketRouter._mintPosition` does (Permit2 approvals, `MINT_POSITION` + `SETTLE_PAIR`,
   `liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96 read from the pool, fullRange)`),
   owner of the NFT = `address(this)`. Ticks from `LpRewardDistributor(distributor).fullRange()`.
6. `IERC721(positionManager).approve(distributor, tokenId)`; `LpRewardDistributor(distributor).stake(tokenId, locker)`
   — the locker becomes the staker; the distributor custodies the NFT; the locker has no
   `unstake`, so the position is permanent.
7. `locker.recordPosition(seed.token, LockedPosition{tokenId, distributor, unit, seed.creatorFeeRecipient, seed.creatorShareBps, true})`.
8. Dust: any unit left → `protocolFeeRecipient` via `LaunchFeeEscrow.creditToken`; any token
   left → `locker.lockTokenSupply` and **counted in `Result.tokensLocked`**, so
   `tokensSeeded + tokensLocked == seed.tokenAmount` exactly and the unit side reconciles as
   `unitSeeded + escrow dust == seed.quoteAmount`. Balance-delta accounting throughout:
   `unitSeeded`/`tokensSeeded` are what the mint actually pulled, not what was asked for.
9. Return `Result`.

Failure semantics: everything reverts as one transaction; the factory still holds the swept
reserves and phase stays `Swept`. `createLaunchMarket` reverting with
`PoolAlreadyInitialised` (a front-run pool at the CREATE-predicted unit address) is handled by
retrying after any other brand registration moves the reserve's nonce; documented, not solved.

`LaunchLocker.collect(token)` (permissionless, nonReentrant): `distributor.collectFees(tokenId)`
then `distributor.claim(unit)` **only if `distributor.earned(locker) != 0`** (`claim` reverts
`ZeroAmount` on nothing earned, and swap fees must stay collectable while the float stream is
idle), measuring the `unit` balance **between the two pulls** — both legs arrive in the unit in
one call, so measuring in between is the only thing that separates them. The fee leg (unit
delta before the claim, plus the whole `token` delta) is split by the position's snapshotted
`creatorShareBps`; the yield leg (the unit delta across the claim) is split by the factory's
live `graduatedCreatorYieldShareBps`. `creditToken` pays one credit per recipient per asset
into `LaunchFeeEscrow` with exact, per-call allowances, and `Collected` reports the four legs
separately. Returns `(unitOut, tokenOut, yieldOut)`, where `unitOut` includes `yieldOut`. Both
recipients are read **live from the factory at collect time**: the creator from
`ILaunchFactory(factory).creatorFeeRecipientOf(token)`, the protocol
from `ILaunchFeePolicy(factory).protocolFeeRecipient()`, the escrow from
`ILaunchFeePolicy(factory).feeEscrow()`. Nothing is pushed to the locker on a recipient
handover; `LockedPosition.creatorFeeRecipient` is the recipient at graduation, kept for the
record only. A zero recipient from the factory reverts `ZeroAddress` rather than paying a
stale address. Locked supply is never movable: no function transfers it out, and the token
leg of `collect` pays only the balance delta of that call, so the locker's balance never drops
below `lockedSupply`. `recordPosition` requires `distributor.stakerOf(tokenId) == locker` and
is once per token; `lockTokenSupply` ledgers what arrives, not what was asked.

## 7. Tests (Foundry, `test/launchpad/`)

Offline suites run against `new PoolManager` and the stand-ins already in
`test/helpers/StackFixture.sol` / `test/markets/MarketRouter.t.sol` (`StandInPositionManager`,
`StandInPermit2`). Required coverage, each named for the behaviour it defends:

- `LaunchCurve.t.sol`: buy/sell round trip loses exactly fee+tax; price monotonic; partial
  fill refunds the excess at the threshold; sell cannot exceed real reserve; fees credited to
  escrow on sweep with the snapshotted split; snipe tax decays to zero and exemptions read 0;
  reentrant quote token cannot reenter; trading closed after graduation.
- `LaunchFactory.t.sol`: config/economics validation (fee caps, decimals, unregistered brand,
  unapproved reserve); launch fee pulled last and only on success; `expectedEconomics` pin;
  CREATE2 prediction matches; forwarder gate; creator recipient 2-step; auto-graduation on the
  crossing buy; `graduate` idempotence; rescue only after 7 days.
- `LaunchGraduation.t.sol`: end-to-end launch → threshold → `graduateToMarket` creates a real
  market (unit, pool, hook registration), pool price equals the curve's terminal price within
  rounding, seeded amounts and locked excess reconcile to the swept totals, distributor shows
  the locker as staker, second call reverts, revert path leaves phase `Swept` and balances
  untouched; MarketRouter can buy the graduated token with USDG.
- `LaunchLocker.t.sol`: `collect` after swaps and a vault `sweep` pays creator/protocol shares
  into the escrow; no path moves locked supply or the NFT.
- `LaunchRouter.t.sol`: launch-and-buy with USDG, with another brand, and with the pair token;
  sell to USDG; deadline and min-out enforcement; router holds nothing afterwards.
- `test/markets/AssetMarketFactory.t.sol`: `createLaunchMarket` gate, validation parity with
  `approveAsset`, creator attribution, `verified == false`.
- `test/launchpad/LaunchJourneyV4Fork.t.sol` (fork, RH mainnet): the whole journey against the
  real `PoolManager`/`PositionManager`.

Invariants worth a handler: curve `trackedQuote ≥ realQuoteReserve + fee balances`; sum of
escrow balances ≤ escrow token balance; locker-recorded positions are always staked.

## 8. Frontend (`web-stable/`)

- `packages/market-core`: launchpad ABIs via `scripts/sync-abis.mjs` `EXPORTS`
  (`LaunchFactory`, `LaunchCurve`, `LaunchRouter`, `LaunchLocker`, `LaunchFeeEscrow`),
  `launchpad-read.ts` (launch list, launched-token record, curve reserves/quotes, progress),
  `launchpad-math.ts` (client mirror of `LaunchCurveMath` for previews), write helpers built
  on the existing reviewed-transaction flow.
- Routes: `/launch` (feed + "Launch a token" wizard: name, symbol, logo, description, socials,
  quote brand, creator tax, optional first buy), `/launch/[token]` (curve trade widget with
  USDG/brand pay-in, graduation progress, trades, creator fee panel), graduated tokens deep-link
  to the existing market page. Deployment config gains the launchpad addresses; without them
  the pages show labelled examples like the rest of the app.
- Keep the app's conventions: `web-stable/AGENTS.md`, reviewed transactions, exact approvals,
  simulation, min-outs, receipt verification.

## 9. Indexers

- `backend/` (Postgres, serves the web): tables `launches`, `launch_trades`; consume
  `TokenLaunched`, `LaunchSwept`, `PoolGraduated`, `CurveBuy`, `CurveSell`, `SnipeTaxCharged`
  (curve address set = launches table, emitter-checked); endpoints
  `/v1/launches`, `/v1/launches/:token`, `/v1/launches/:token/trades`,
  `/v1/launches/:token/history`. `backend/market-reader` exposes the reads.
- `services/market-data/` (SQLite, mobile): same events, same routes.
- Both indexers still decode the pre-`2105f7d` 12-field `MarketCreated`; that is fixed on the
  main branch, not here — the launch tables must not depend on `MarketCreated`.

## 10. Deployment

- `ProtocolStack.deployLaunchpad`: `LaunchFeeEscrow`, `LaunchLocker`, `LaunchGraduation`,
  `LaunchDeployer`, `LaunchFactory` (UUPS proxy), `LaunchRouter`; wire one-shots; owner calls
  `marketFactory.setLaunchpad(graduation)`, `launchFactory.setLaunchForwarder(router)`,
  `addLaunchConfig({supply: 1e27, curveFeeBps: 100, poolFee: 5_000, enabled: true})`,
  `setReserveEconomics(reserve, {phantom: 3_236e6, threshold: 8_090e6, launchFee: 1e6, decimals: 6, approved: true})`
  — once per reserve, and nothing per brand: every dollar the market factory registers on that
  reserve whose issuer has called `PoolBrandTreasury.setFactory` is launchable without a
  further owner call.
- Defaults: `protocolFeeShareBps 3_000`, `maxCreatorTaxBps 1_000`, snipe tax `9_900 bps / 15 s`,
  `graduatedCreatorShareBps 10_000`, `graduatedCreatorYieldShareBps 0`. A trader's 1% on a
  graduated market therefore ends up half protocol (the hook's skim) and half creator (the
  pool's own fee tier), with the float yield the protocol's until the live knob is raised.
- Manifest (`deployments/*.json`) gains a `launchpad` block; `app-networks.json` follows.
- Order: testnet (46630) first with the existing testnet stack, then Base Sepolia, then mainnet
  only after the audit.

## 11. Waves

1. **Contracts core** (parallel): `CoreFork` (§2 fork files + `LaunchFactory`), `FactorySeam`
   (§4), `Graduation` (§6 + locker), each with its own tests.
2. `LaunchRouter`, `ProtocolStack`/deploy script/`StackFixture`, frontend, both indexers,
   `LaunchJourneyV4Fork`.
3. Security review pass, README/ASSET_MARKETS cross-references, format/lint/typecheck, full
   offline suite, fork suite.
