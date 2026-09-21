#!/usr/bin/env node
/**
 * One-shot stored LP-fee keeper with an optional independent Uniswap V3 TWAP.
 *
 * This is an independently specified reference-divergence policy. It does not implement or
 * claim to reproduce Fables' private keeper algorithm. The default mode only prints a plan.
 */
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const require = createRequire(new URL("../web-stable/package.json", import.meta.url));
const {
  createPublicClient,
  decodeEventLog,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  http,
  isAddress,
  keccak256,
  parseAbi,
} = require("viem");

export const DYNAMIC_FEE_FLAG = 0x800000n;
export const MIN_FEE_PIPS = 100n;
export const MAX_FEE_PIPS = 50000n;
const Q96 = 1n << 96n;
const Q128 = 1n << 128n;
const Q192 = 1n << 192n;
const UINT32_MODULUS = 1n << 32n;
const UINT256_MAX = (1n << 256n) - 1n;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const factoryAbi = parseAbi([
  "function market(uint256) view returns ((address asset,address brandToken,address treasury,address feeVault,address lpDistributor,bytes32 poolId,uint24 fee,int24 tickSpacing,address creator,bool verified,uint64 createdAt,address reservePool))",
  "function poolKeyOf(uint256) view returns ((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks))",
  "function feeHook() view returns (address)",
  "function poolManager() view returns (address)",
  "function reservePool() view returns (address)",
]);
const hookAbi = parseAbi([
  "function owner() view returns (address)",
  "function feeKeeper() view returns (address)",
  "function setPoolLpFee((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks),uint24)",
  "event PoolLpFeeUpdated(bytes32 indexed poolId,uint24 feePips)",
]);
const stateViewAbi = parseAbi([
  "function poolManager() view returns (address)",
  "function getSlot0(bytes32) view returns (uint160 sqrtPriceX96,int24 tick,uint24 protocolFee,uint24 lpFee)",
  "function getLiquidity(bytes32) view returns (uint128 liquidity)",
]);
const reserveAbi = parseAbi([
  "function asset() view returns (address)",
  "function brands(address) view returns (bool registered,address treasury,uint256 outstanding,uint256 indexCheckpoint,uint256 accruedYield)",
]);
const erc20Abi = parseAbi(["function decimals() view returns (uint8)"]);
const v3PoolAbi = parseAbi([
  "function factory() view returns (address)",
  "function fee() view returns (uint24)",
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function liquidity() view returns (uint128)",
  "function slot0() view returns (uint160 sqrtPriceX96,int24 tick,uint16 observationIndex,uint16 observationCardinality,uint16 observationCardinalityNext,uint8 feeProtocol,bool unlocked)",
  "function observations(uint256) view returns (uint32 blockTimestamp,int56 tickCumulative,uint160 secondsPerLiquidityCumulativeX128,bool initialized)",
  "function observe(uint32[]) view returns (int56[] tickCumulatives,uint160[] secondsPerLiquidityCumulativeX128s)",
]);
const v3FactoryAbi = parseAbi([
  "function getPool(address,address,uint24) view returns (address pool)",
]);

function fail(condition, message) {
  if (!condition) throw new Error(message);
}
function sameAddress(a, b) {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}
function tupleValue(value, name, index) {
  return value?.[name] ?? value?.[index];
}
function decimal(value, label, { min = 0n, max } = {}) {
  fail(
    typeof value === "string" && /^\d+$/.test(value),
    `${label} must be an unsigned decimal integer`,
  );
  const parsed = BigInt(value);
  fail(
    parsed >= min && (max === undefined || parsed <= max),
    `${label} is outside its allowed range`,
  );
  return parsed;
}
function address(value, label) {
  fail(typeof value === "string" && isAddress(value), `${label} must be an address`);
  fail(!sameAddress(value, ZERO_ADDRESS), `${label} cannot be zero`);
  return getAddress(value);
}
function json(value) {
  return JSON.stringify(value, (_, item) => (typeof item === "bigint" ? item.toString() : item), 2);
}
function max(a, b) {
  return a > b ? a : b;
}
function min(a, b) {
  return a < b ? a : b;
}

export function sqrtPriceAtTick(tickValue) {
  const tick = BigInt(tickValue);
  const absTick = tick < 0n ? -tick : tick;
  fail(absTick <= 887272n, "TWAP tick is outside Uniswap's supported range");
  const constants = [
    0xfffcb933bd6fad37aa2d162d1a594001n,
    0xfff97272373d413259a46990580e213an,
    0xfff2e50f5f656932ef12357cf3c7fdccn,
    0xffe5caca7e10e4e61c3624eaa0941cd0n,
    0xffcb9843d60f6159c9db58835c926644n,
    0xff973b41fa98c081472e6896dfb254c0n,
    0xff2ea16466c96a3843ec78b326b52861n,
    0xfe5dee046a99a2a811c461f1969c3053n,
    0xfcbe86c7900a88aedcffc83b479aa3a4n,
    0xf987a7253ac413176f2b074cf7815e54n,
    0xf3392b0822b70005940c7a398e4b70f3n,
    0xe7159475a2c29b7443b29c7fa6e889d9n,
    0xd097f3bdfd2022b8845ad8f792aa5825n,
    0xa9f746462d870fdf8a65dc1f90e061e5n,
    0x70d869a156d2a1b890bb3df62baf32f7n,
    0x31be135f97d08fd981231505542fcfa6n,
    0x9aa508b5b7a84e1c677de54f3e99bc9n,
    0x5d6af8dedb81196699c329225ee604n,
    0x2216e584f5fa1ea926041bedfe98n,
    0x48a170391f7dc42444e8fa2n,
  ];
  let ratio = Q128;
  for (let bit = 0; bit < constants.length; bit += 1) {
    if ((absTick & (1n << BigInt(bit))) !== 0n) ratio = (ratio * constants[bit]) >> 128n;
  }
  if (tick > 0n) ratio = UINT256_MAX / ratio;
  return (ratio + (1n << 32n) - 1n) >> 32n;
}

export function arithmeticMeanTick(tickCumulatives, window) {
  const duration = BigInt(window);
  fail(duration > 0n, "TWAP window must be positive");
  fail(
    Array.isArray(tickCumulatives) && tickCumulatives.length === 2,
    "two TWAP cumulatives required",
  );
  const delta = BigInt(tickCumulatives[1]) - BigInt(tickCumulatives[0]);
  let result = delta / duration;
  if (delta < 0n && delta % duration !== 0n) result -= 1n;
  fail(result >= -887272n && result <= 887272n, "mean TWAP tick is outside Uniswap's range");
  return result;
}

/** Exact rational price of one whole base token in whole quote tokens. */
export function priceOfBaseInQuote(sqrtPriceX96, baseIsToken0, baseDecimals, quoteDecimals) {
  const sqrt = BigInt(sqrtPriceX96);
  const baseUnit = 10n ** BigInt(baseDecimals);
  const quoteUnit = 10n ** BigInt(quoteDecimals);
  fail(sqrt > 0n, "pool price is uninitialized");
  const square = sqrt * sqrt;
  return baseIsToken0
    ? { numerator: square * baseUnit, denominator: Q192 * quoteUnit }
    : { numerator: Q192 * baseUnit, denominator: square * quoteUnit };
}

/** Relative absolute distance |a-b|/b in parts per million, rounded down. */
export function relativePpm(a, b) {
  const left = a.numerator * b.denominator;
  const right = b.numerator * a.denominator;
  const difference = left > right ? left - right : right - left;
  return (difference * 1_000_000n) / (a.denominator * b.numerator);
}

function validateFeeBounds(floorPips, capPips, baselinePips) {
  fail(
    floorPips >= MIN_FEE_PIPS && capPips <= MAX_FEE_PIPS && floorPips <= capPips,
    "fee bounds must satisfy 100 <= floor <= cap <= 50000 pips",
  );
  fail(baselinePips >= floorPips && baselinePips <= capPips, "baseline is outside fee bounds");
}

export function computeStoredFee({
  fairPrice,
  poolPrice,
  baselinePips,
  floorPips,
  capPips,
  thresholdBps,
  maxDivergenceBps,
  premiumPipsPerBps,
  maxPremiumPips,
}) {
  validateFeeBounds(floorPips, capPips, baselinePips);
  const divergencePpm = relativePpm(fairPrice, poolPrice);
  fail(
    divergencePpm <= maxDivergenceBps * 100n,
    "market/reference divergence exceeds circuit breaker",
  );
  const excessPpm = max(0n, divergencePpm - thresholdBps * 100n);
  const premiumPips = min(maxPremiumPips, (excessPpm * premiumPipsPerBps) / 100n);
  return {
    divergencePpm,
    divergenceBpsFloor: divergencePpm / 100n,
    premiumPips,
    feePips: min(capPips, baselinePips + premiumPips),
  };
}

const newYorkTime = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  weekday: "short",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

/** Piecewise-constant session fees; boundaries use pinned-block New York time. */
export function baselineForTimestamp(timestamp, settings) {
  if (settings.model === "flat") return { session: "flat", feePips: settings.basePips };
  fail(settings.model === "equity", "model must be flat or equity");
  const date = new Date(Number(timestamp) * 1000);
  fail(Number.isFinite(date.getTime()), "block timestamp is outside the calendar range");
  const parts = Object.fromEntries(
    newYorkTime.formatToParts(date).map(({ type, value }) => [type, value]),
  );
  const localDate = `${parts.year}-${parts.month}-${parts.day}`;
  const seconds = BigInt(
    Number(parts.hour) * 3600 + Number(parts.minute) * 60 + Number(parts.second),
  );
  const open = 570n * 60n;
  const close = (settings.earlyCloses[localDate] ?? 960n) * 60n;
  let session;
  let feePips;
  if (parts.weekday === "Sat" || parts.weekday === "Sun" || settings.holidays.includes(localDate)) {
    session = "closed";
    feePips = settings.closedPips;
  } else if (seconds < open || seconds >= close) {
    session = "overnight";
    feePips = settings.overnightPips;
  } else if (seconds < open + settings.openWindowMinutes * 60n) {
    session = "open";
    feePips = settings.openPips;
  } else if (seconds >= close - settings.closeWindowMinutes * 60n) {
    session = "close";
    feePips = settings.closePips;
  } else {
    session = "regular";
    feePips = settings.basePips;
  }
  return { session, localDate, timeZone: "America/New_York", feePips };
}

function validateSettings(settings) {
  fail(settings.model === "flat" || settings.model === "equity", "model must be flat or equity");
  validateFeeBounds(settings.floorPips, settings.capPips, settings.basePips);
  fail(
    settings.thresholdBps >= 0n &&
      settings.thresholdBps < settings.maxDivergenceBps &&
      settings.maxDivergenceBps <= 10000n,
    "divergence threshold must be below circuit breaker (at most 10000 bps)",
  );
  fail(
    settings.premiumPipsPerBps >= 0n &&
      settings.premiumPipsPerBps <= MAX_FEE_PIPS &&
      settings.maxPremiumPips >= 0n &&
      settings.maxPremiumPips <= MAX_FEE_PIPS,
    "premium parameters must be between 0 and 50000",
  );
  if (settings.model === "equity") {
    for (const fee of [
      settings.overnightPips,
      settings.closedPips,
      settings.openPips,
      settings.closePips,
    ]) {
      validateFeeBounds(settings.floorPips, settings.capPips, fee);
    }
    fail(
      settings.openWindowMinutes >= 0n && settings.closeWindowMinutes >= 0n,
      "session windows cannot be negative",
    );
    for (const close of [960n, ...Object.values(settings.earlyCloses)]) {
      fail(
        close > 570n && close <= 960n,
        "early close must be after 09:30 and no later than 16:00",
      );
      fail(
        settings.openWindowMinutes + settings.closeWindowMinutes <= close - 570n,
        "open and close windows overlap",
      );
    }
  }
}

function normalizeMarket(value) {
  return {
    asset: tupleValue(value, "asset", 0),
    brandToken: tupleValue(value, "brandToken", 1),
    poolId: tupleValue(value, "poolId", 5),
    fee: BigInt(tupleValue(value, "fee", 6)),
    tickSpacing: BigInt(tupleValue(value, "tickSpacing", 7)),
    reservePool: tupleValue(value, "reservePool", 11),
  };
}
function normalizePoolKey(value) {
  return {
    currency0: tupleValue(value, "currency0", 0),
    currency1: tupleValue(value, "currency1", 1),
    fee: BigInt(tupleValue(value, "fee", 2)),
    tickSpacing: BigInt(tupleValue(value, "tickSpacing", 3)),
    hooks: tupleValue(value, "hooks", 4),
  };
}

export function poolIdOf(key) {
  const encoded = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
    ],
    [{ ...key, fee: key.fee, tickSpacing: key.tickSpacing }],
  );
  return keccak256(encoded);
}

function uint32Age(now, then) {
  return ((BigInt(now) & (UINT32_MODULUS - 1n)) - BigInt(then) + UINT32_MODULUS) % UINT32_MODULUS;
}

export function buildPlan(snapshot, settings) {
  validateSettings(settings);
  fail(
    BigInt(snapshot.chainId) === BigInt(settings.chainId),
    "RPC chain does not match --chain-id",
  );
  const { market, pool } = snapshot;
  fail(
    sameAddress(snapshot.hookAddress, market.poolKey.hooks),
    "market PoolKey uses a foreign hook",
  );
  fail(market.poolKey.fee === DYNAMIC_FEE_FLAG, "market is not a dynamic-fee pool");
  fail(market.fee === DYNAMIC_FEE_FLAG, "market record is not dynamic-fee enabled");
  fail(
    market.poolKey.tickSpacing === 50n && market.tickSpacing === 50n,
    "market PoolKey tick spacing mismatch",
  );
  fail(
    sameAddress(market.poolId, poolIdOf(market.poolKey)),
    "market PoolId does not match its PoolKey",
  );
  const assetIsCurrency0 = sameAddress(market.asset, market.poolKey.currency0);
  fail(
    (assetIsCurrency0 && sameAddress(market.brandToken, market.poolKey.currency1)) ||
      (sameAddress(market.asset, market.poolKey.currency1) &&
        sameAddress(market.brandToken, market.poolKey.currency0)),
    "market PoolKey does not contain exactly the asset and unit",
  );
  fail(market.brandRegistered, "market unit is not registered in its reserve");
  fail(
    market.brandDecimals === market.reserveDecimals,
    "market unit does not map 1:1 to reserve-asset units",
  );
  fail(pool.sqrtPriceX96 > 0n, "market pool is uninitialized");
  fail(pool.liquidity > 0n, "market pool has no active liquidity");
  fail(pool.lpFee >= 0n && pool.lpFee <= 1_000_000n, "invalid stored LP fee");
  const baseline = baselineForTimestamp(snapshot.blockTimestamp, settings);
  const poolPrice = priceOfBaseInQuote(
    pool.sqrtPriceX96,
    assetIsCurrency0,
    market.assetDecimals,
    market.brandDecimals,
  );
  fail(
    Boolean(settings.referencePool) === Boolean(settings.referenceFactory),
    "reference pool and factory must be supplied together",
  );
  fail(!settings.referencePool || snapshot.reference, "configured reference is unavailable");
  const reference = settings.referencePool ? referencePlan(snapshot, settings) : null;
  const result = reference
    ? computeStoredFee({
        ...settings,
        baselinePips: baseline.feePips,
        fairPrice: reference.fairPriceRational,
        poolPrice,
      })
    : { divergencePpm: null, divergenceBpsFloor: null, premiumPips: 0n, feePips: baseline.feePips };
  const shouldWrite = result.feePips !== pool.lpFee;
  return {
    mode: settings.execute ? "execute" : "plan",
    pinnedBlock: {
      number: snapshot.blockNumber,
      hash: snapshot.blockHash,
      timestamp: snapshot.blockTimestamp,
    },
    chainId: snapshot.chainId,
    factory: settings.factory,
    marketId: settings.marketId,
    poolId: market.poolId,
    hook: snapshot.hookAddress,
    market: {
      asset: market.asset,
      quoteUnit: market.brandToken,
      reservePool: market.reservePool,
      reserveUnderlying: market.reserveAsset,
      assetDecimals: market.assetDecimals,
      quoteDecimals: market.brandDecimals,
      poolLiquidity: pool.liquidity,
    },
    decision: shouldWrite ? "set-pool-lp-fee" : "no-write",
    reason: shouldWrite
      ? reference
        ? "reference-divergence-update"
        : "baseline-update"
      : "stored-fee-already-matches",
    baseline,
    reference,
    marketPoolPriceRational: poolPrice,
    calibration: {
      model: settings.model,
      floorPips: settings.floorPips,
      capPips: settings.capPips,
      divergenceThresholdBps: settings.thresholdBps,
      circuitBreakerBps: settings.maxDivergenceBps,
      premiumPipsPerDivergenceBps: settings.premiumPipsPerBps,
      maxPremiumPips: settings.maxPremiumPips,
    },
    storedLpFee: pool.lpFee,
    result,
    action: shouldWrite
      ? {
          to: snapshot.hookAddress,
          value: 0n,
          calldata: encodeFunctionData({
            abi: hookAbi,
            functionName: "setPoolLpFee",
            args: [market.poolKey, result.feePips],
          }),
        }
      : null,
  };
}

function referencePlan(snapshot, settings) {
  const reference = snapshot.reference;
  fail(
    sameAddress(reference.factory, settings.referenceFactory),
    "reference pool reports a foreign V3 factory",
  );
  fail(
    sameAddress(reference.canonicalPool, settings.referencePool),
    "reference factory does not recognize the configured pool",
  );
  const token0IsAsset = sameAddress(reference.token0, snapshot.market.asset);
  const token1IsAsset = sameAddress(reference.token1, snapshot.market.asset);
  const token0IsReserve = sameAddress(reference.token0, snapshot.market.reserveAsset);
  const token1IsReserve = sameAddress(reference.token1, snapshot.market.reserveAsset);
  fail(
    (token0IsAsset && token1IsReserve) || (token1IsAsset && token0IsReserve),
    "reference pool must pair the exact market asset with the reserve underlying",
  );
  fail(
    reference.assetDecimals === snapshot.market.assetDecimals,
    "reference asset decimals mismatch",
  );
  fail(
    reference.quoteDecimals === snapshot.market.reserveDecimals,
    "reference quote decimals mismatch",
  );
  fail(reference.unlocked, "reference V3 pool is locked");
  fail(
    reference.observationCardinality >= 2n,
    "reference pool observation ring is not initialized for TWAP",
  );
  fail(
    reference.latestObservationInitialized,
    "reference pool latest observation is uninitialized",
  );
  const observationAge = uint32Age(snapshot.blockTimestamp, reference.latestObservationTimestamp);
  fail(observationAge <= settings.maxObservationAge, "reference pool latest observation is stale");
  fail(
    reference.currentLiquidity >= settings.minReferenceLiquidity,
    "reference pool current liquidity is below the configured floor",
  );
  const splDelta =
    reference.secondsPerLiquidityCumulatives[1] - reference.secondsPerLiquidityCumulatives[0];
  fail(splDelta > 0n, "reference TWAP has no measurable seconds-per-liquidity history");
  const harmonicLiquidity = (settings.twapWindow * Q128) / splDelta;
  fail(
    harmonicLiquidity >= settings.minReferenceLiquidity,
    "reference pool harmonic TWAP liquidity is below the configured floor",
  );

  const meanTick = arithmeticMeanTick(reference.tickCumulatives, settings.twapWindow);
  const twapSqrtPriceX96 = sqrtPriceAtTick(meanTick);
  const fairPrice = priceOfBaseInQuote(
    twapSqrtPriceX96,
    token0IsAsset,
    snapshot.market.assetDecimals,
    snapshot.market.reserveDecimals,
  );
  const referenceSpotPrice = priceOfBaseInQuote(
    reference.sqrtPriceX96,
    token0IsAsset,
    snapshot.market.assetDecimals,
    snapshot.market.reserveDecimals,
  );
  const referenceSpotDeviationPpm = relativePpm(referenceSpotPrice, fairPrice);
  fail(
    referenceSpotDeviationPpm <= settings.maxReferenceSpotDeviationBps * 100n,
    "reference spot is too far from its TWAP",
  );

  return {
    pool: settings.referencePool,
    factory: settings.referenceFactory,
    token0: reference.token0,
    token1: reference.token1,
    fee: reference.fee,
    twapWindowSeconds: settings.twapWindow,
    latestObservationAgeSeconds: observationAge,
    currentLiquidity: reference.currentLiquidity,
    harmonicMeanLiquidity: harmonicLiquidity,
    arithmeticMeanTick: meanTick,
    twapSqrtPriceX96,
    spotVsTwapPpm: referenceSpotDeviationPpm,
    fairPriceRational: fairPrice,
  };
}

async function readSnapshot(client, settings) {
  const chainId = await client.getChainId();
  fail(
    BigInt(chainId) === settings.chainId,
    `RPC reports chain ${chainId}, expected ${settings.chainId}`,
  );
  const blockNumber = await client.getBlockNumber();
  const block = await client.getBlock({ blockNumber });
  const at = (request) => client.readContract({ ...request, blockNumber });
  const [marketRaw, keyRaw, hookAddress, poolManager, defaultReserve] = await Promise.all([
    at({
      address: settings.factory,
      abi: factoryAbi,
      functionName: "market",
      args: [settings.marketId],
    }),
    at({
      address: settings.factory,
      abi: factoryAbi,
      functionName: "poolKeyOf",
      args: [settings.marketId],
    }),
    at({ address: settings.factory, abi: factoryAbi, functionName: "feeHook" }),
    at({ address: settings.factory, abi: factoryAbi, functionName: "poolManager" }),
    at({ address: settings.factory, abi: factoryAbi, functionName: "reservePool" }),
  ]);
  const market = normalizeMarket(marketRaw);
  market.poolKey = normalizePoolKey(keyRaw);
  market.reservePool = sameAddress(market.reservePool, ZERO_ADDRESS)
    ? defaultReserve
    : market.reservePool;
  fail(
    sameAddress(market.poolId, poolIdOf(market.poolKey)),
    "factory market PoolId/PoolKey mismatch",
  );
  const [
    reserveAsset,
    brandState,
    assetDecimals,
    brandDecimals,
    stateViewManager,
    slot0,
    poolLiquidity,
  ] = await Promise.all([
    at({ address: market.reservePool, abi: reserveAbi, functionName: "asset" }),
    at({
      address: market.reservePool,
      abi: reserveAbi,
      functionName: "brands",
      args: [market.brandToken],
    }),
    at({ address: market.asset, abi: erc20Abi, functionName: "decimals" }),
    at({ address: market.brandToken, abi: erc20Abi, functionName: "decimals" }),
    at({ address: settings.stateView, abi: stateViewAbi, functionName: "poolManager" }),
    at({
      address: settings.stateView,
      abi: stateViewAbi,
      functionName: "getSlot0",
      args: [market.poolId],
    }),
    at({
      address: settings.stateView,
      abi: stateViewAbi,
      functionName: "getLiquidity",
      args: [market.poolId],
    }),
  ]);
  fail(sameAddress(stateViewManager, poolManager), "StateView is bound to a foreign PoolManager");
  const reserveDecimals = await at({
    address: reserveAsset,
    abi: erc20Abi,
    functionName: "decimals",
  });

  let signer = null;
  if (settings.sender) {
    const [owner, keeper] = await Promise.all([
      at({ address: hookAddress, abi: hookAbi, functionName: "owner" }),
      at({ address: hookAddress, abi: hookAbi, functionName: "feeKeeper" }),
    ]);
    signer = { owner, keeper };
  }

  let reference = null;
  if (settings.referencePool) {
    const [referenceFactory, fee, token0, token1, currentLiquidity, referenceSlot0] =
      await Promise.all([
        at({ address: settings.referencePool, abi: v3PoolAbi, functionName: "factory" }),
        at({ address: settings.referencePool, abi: v3PoolAbi, functionName: "fee" }),
        at({ address: settings.referencePool, abi: v3PoolAbi, functionName: "token0" }),
        at({ address: settings.referencePool, abi: v3PoolAbi, functionName: "token1" }),
        at({ address: settings.referencePool, abi: v3PoolAbi, functionName: "liquidity" }),
        at({ address: settings.referencePool, abi: v3PoolAbi, functionName: "slot0" }),
      ]);
    const canonicalPool = await at({
      address: settings.referenceFactory,
      abi: v3FactoryAbi,
      functionName: "getPool",
      args: [token0, token1, fee],
    });
    const observationIndex = BigInt(referenceSlot0[2]);
    const [latestObservation, observed, token0Decimals, token1Decimals] = await Promise.all([
      at({
        address: settings.referencePool,
        abi: v3PoolAbi,
        functionName: "observations",
        args: [observationIndex],
      }),
      at({
        address: settings.referencePool,
        abi: v3PoolAbi,
        functionName: "observe",
        args: [[settings.twapWindow, 0n]],
      }),
      at({ address: token0, abi: erc20Abi, functionName: "decimals" }),
      at({ address: token1, abi: erc20Abi, functionName: "decimals" }),
    ]);
    const assetIsToken0 = sameAddress(token0, market.asset);
    reference = {
      factory: referenceFactory,
      canonicalPool,
      fee: BigInt(fee),
      token0,
      token1,
      assetDecimals: BigInt(assetIsToken0 ? token0Decimals : token1Decimals),
      quoteDecimals: BigInt(assetIsToken0 ? token1Decimals : token0Decimals),
      sqrtPriceX96: BigInt(referenceSlot0[0]),
      observationCardinality: BigInt(referenceSlot0[3]),
      unlocked: Boolean(referenceSlot0[6]),
      currentLiquidity: BigInt(currentLiquidity),
      latestObservationTimestamp: BigInt(latestObservation[0]),
      latestObservationInitialized: Boolean(latestObservation[3]),
      tickCumulatives: observed[0].map(BigInt),
      secondsPerLiquidityCumulatives: observed[1].map(BigInt),
    };
  }

  const confirmedBlock = await client.getBlock({ blockNumber });
  fail(confirmedBlock.hash === block.hash, "pinned block changed during reads");

  return {
    chainId: BigInt(chainId),
    blockNumber,
    blockHash: block.hash,
    blockTimestamp: BigInt(block.timestamp),
    hookAddress,
    signer,
    pool: {
      sqrtPriceX96: BigInt(slot0[0]),
      liquidity: BigInt(poolLiquidity),
      lpFee: BigInt(slot0[3]),
    },
    market: {
      ...market,
      reserveAsset,
      assetDecimals: BigInt(assetDecimals),
      brandDecimals: BigInt(brandDecimals),
      reserveDecimals: BigInt(reserveDecimals),
      brandRegistered: Boolean(brandState[0]),
    },
    reference,
  };
}

function castExecutor({ account, sender, rpcUrl, chainId, to, calldata }) {
  fail(
    /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(account) && !/^(0x)?[0-9a-fA-F]{64}$/.test(account),
    "--account must be a Foundry account name, not a path, flag, or secret",
  );
  const result = spawnSync(
    "cast",
    [
      "send",
      to,
      calldata,
      "--rpc-url",
      rpcUrl,
      "--chain",
      String(chainId),
      "--account",
      account,
      "--from",
      sender,
      "--json",
    ],
    { encoding: "utf8", stdio: ["inherit", "pipe", "inherit"] },
  );
  fail(!result.error, "failed to start cast");
  fail(result.status === 0, `cast send exited with status ${result.status}`);
  let output;
  try {
    output = JSON.parse(result.stdout);
  } catch {
    throw new Error("cast send did not return a JSON receipt");
  }
  const hash = output.transactionHash ?? output.hash;
  fail(
    typeof hash === "string" && /^0x[0-9a-fA-F]{64}$/.test(hash),
    "cast send did not return a transaction hash",
  );
  return hash;
}

async function verifyExecution(client, settings, plan, hash) {
  const receipt = await client.waitForTransactionReceipt({ hash, confirmations: 1 });
  fail(receipt.status === "success", "LP fee transaction reverted");
  const matchingEvent = receipt.logs.some((log) => {
    if (!sameAddress(log.address, plan.hook)) return false;
    try {
      const decoded = decodeEventLog({
        abi: hookAbi,
        data: log.data,
        topics: log.topics,
        strict: true,
      });
      return (
        decoded.eventName === "PoolLpFeeUpdated" &&
        sameAddress(decoded.args.poolId, plan.poolId) &&
        BigInt(decoded.args.feePips) === plan.result.feePips
      );
    } catch {
      return false;
    }
  });
  fail(matchingEvent, "receipt is missing the exact PoolLpFeeUpdated event");
  const slot0 = await client.readContract({
    address: settings.stateView,
    abi: stateViewAbi,
    functionName: "getSlot0",
    args: [plan.poolId],
    blockNumber: receipt.blockNumber,
  });
  const verifiedLpFee = BigInt(tupleValue(slot0, "lpFee", 3));
  fail(verifiedLpFee === plan.result.feePips, "post-transaction stored LP fee does not match plan");
  return { transactionHash: hash, blockNumber: receipt.blockNumber, verifiedLpFee };
}

export async function runKeeper(settings, dependencies = {}) {
  const client = dependencies.client ?? createPublicClient({ transport: http(settings.rpcUrl) });
  const load = dependencies.loadSnapshot ?? (() => readSnapshot(client, settings));
  const firstSnapshot = await load();
  const initialPlan = buildPlan(firstSnapshot, settings);
  if (!settings.execute || !initialPlan.action) return initialPlan;
  fail(settings.account, "--execute requires an explicit --account Foundry keystore name");
  fail(settings.sender, "--execute requires the account's explicit public --sender address");

  const checkedSnapshot = await load();
  const checkedPlan = buildPlan(checkedSnapshot, settings);
  if (!checkedPlan.action) return { ...checkedPlan, execution: { skippedAfterRecheck: true } };
  fail(
    checkedSnapshot.signer,
    "execute mode requires signer authorization to be read at the pinned block",
  );
  fail(
    (!sameAddress(checkedSnapshot.signer.keeper, ZERO_ADDRESS) &&
      sameAddress(checkedSnapshot.signer.keeper, settings.sender)) ||
      sameAddress(checkedSnapshot.signer.owner, settings.sender),
    "sender is neither hook owner nor authorized keeper",
  );
  fail(client, "execute mode requires an RPC client");
  await client.call({
    account: settings.sender,
    to: checkedPlan.action.to,
    data: checkedPlan.action.calldata,
    blockNumber: checkedSnapshot.blockNumber,
  });
  const execute = dependencies.executor ?? castExecutor;
  const hash = await execute({
    account: settings.account,
    sender: settings.sender,
    rpcUrl: settings.rpcUrl,
    chainId: settings.chainId,
    to: checkedPlan.action.to,
    calldata: checkedPlan.action.calldata,
  });
  const execution = dependencies.verifyExecution
    ? await dependencies.verifyExecution(client, settings, checkedPlan, hash)
    : await verifyExecution(client, settings, checkedPlan, hash);
  return { ...checkedPlan, execution };
}

const usage = `Usage: node script/dynamic-fee-keeper.mjs [options]

Required:
  --rpc-url URL                JSON-RPC endpoint (explicit; no env-file reads)
  --chain-id ID                Expected chain id, also bound into cast signing
  --factory ADDRESS           AssetMarketFactory
  --market-id ID              1-indexed market id
  --state-view ADDRESS        Uniswap V4 StateView bound to factory PoolManager
  --model flat|equity         Offchain baseline model
  --base-pips N               Flat fee or regular-session fee, in pips

Fee bounds (all baseline fees must lie within these bounds):
  --floor-pips 100
  --cap-pips 50000             Hard maximum 5%; 10000 pips = 1%

Equity model (America/New_York; regular session 09:30 inclusive to 16:00 exclusive):
  --overnight-pips N          Required; weekdays outside session
  --closed-pips N             Required; weekends and explicit holidays
  --open-pips N               Required; first open-window minutes of session
  --close-pips N              Required; final close-window minutes of session
  --open-window-minutes 30    Zero disables the open window
  --close-window-minutes 30   Zero disables the close window; windows cannot overlap
  --holidays YYYY-MM-DD,...   Optional explicit full-day closures, no built-in holiday feed
  --early-closes YYYY-MM-DD@HH:MM,...  Optional New York close times after 09:30, up to 16:00

Optional independent reference (omit to update baseline without a reference):
  --reference-pool ADDRESS    Uniswap V3 asset/reserve-underlying pool
  --reference-factory ADDRESS Expected V3 factory; required with reference pool
  --min-reference-liquidity N Required with reference; current and harmonic uint128 floor
  Configured but invalid/unavailable references abort without writing.

Reference calibration defaults:
  --twap-window 1800
  --max-observation-age 900
  --max-reference-spot-deviation-bps 500
  --divergence-threshold-bps 25
  --max-divergence-bps 1000
  --premium-pips-per-bps 20
  --max-premium-pips 10000
  Target = min(cap, baseline + min(max-premium, excess-divergence-bps * premium-rate)).
  The same stored fee applies in both swap directions and persists until changed.

Execution (plan-only by default; matching stored fee never sends):
  --execute
  --account NAME              Encrypted Foundry cast account name; never a key or path
  --sender ADDRESS            Public address belonging to that account
`;

export function parseCli(argv) {
  const values = new Map();
  let execute = false;
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (item === "--help" || item === "-h") return { help: true };
    if (item === "--execute") {
      execute = true;
      continue;
    }
    fail(item.startsWith("--"), `unexpected argument: ${item}`);
    const name = item.slice(2);
    fail(index + 1 < argv.length && !argv[index + 1].startsWith("--"), `missing value for ${item}`);
    fail(!values.has(name), `duplicate option: ${item}`);
    values.set(name, argv[++index]);
  }
  const required = (name) => {
    fail(values.has(name), `missing --${name}`);
    return values.get(name);
  };
  const referencePool = values.has("reference-pool")
    ? address(values.get("reference-pool"), "--reference-pool")
    : null;
  const referenceFactory = values.has("reference-factory")
    ? address(values.get("reference-factory"), "--reference-factory")
    : null;
  fail(
    Boolean(referencePool) === Boolean(referenceFactory),
    "--reference-pool and --reference-factory must be supplied together",
  );
  fail(
    !referencePool || values.has("min-reference-liquidity"),
    "a reference pool requires explicit --min-reference-liquidity",
  );
  const known = new Set([
    "rpc-url",
    "chain-id",
    "factory",
    "market-id",
    "model",
    "base-pips",
    "floor-pips",
    "cap-pips",
    "overnight-pips",
    "closed-pips",
    "open-pips",
    "close-pips",
    "open-window-minutes",
    "close-window-minutes",
    "holidays",
    "early-closes",
    "state-view",
    "reference-pool",
    "reference-factory",
    "min-reference-liquidity",
    "twap-window",
    "max-observation-age",
    "max-reference-spot-deviation-bps",
    "divergence-threshold-bps",
    "max-divergence-bps",
    "premium-pips-per-bps",
    "max-premium-pips",
    "account",
    "sender",
  ]);
  for (const name of values.keys()) fail(known.has(name), `unknown option: --${name}`);
  const option = (name, fallback, bounds) =>
    decimal(values.get(name) ?? fallback, `--${name}`, bounds);
  const result = {
    execute,
    rpcUrl: required("rpc-url"),
    chainId: decimal(required("chain-id"), "--chain-id", { min: 1n }),
    factory: address(required("factory"), "--factory"),
    marketId: decimal(required("market-id"), "--market-id", { min: 1n }),
    model: required("model"),
    basePips: decimal(required("base-pips"), "--base-pips", {
      min: MIN_FEE_PIPS,
      max: MAX_FEE_PIPS,
    }),
    floorPips: option("floor-pips", "100", { min: MIN_FEE_PIPS, max: MAX_FEE_PIPS }),
    capPips: option("cap-pips", "50000", { min: MIN_FEE_PIPS, max: MAX_FEE_PIPS }),
    stateView: address(required("state-view"), "--state-view"),
    referencePool,
    referenceFactory,
    minReferenceLiquidity: referencePool
      ? option("min-reference-liquidity", null, { min: 1n, max: (1n << 128n) - 1n })
      : 0n,
    twapWindow: option("twap-window", "1800", { min: 60n, max: 86400n }),
    maxObservationAge: option("max-observation-age", "900", { min: 1n, max: 86400n }),
    maxReferenceSpotDeviationBps: option("max-reference-spot-deviation-bps", "500", {
      min: 1n,
      max: 10000n,
    }),
    thresholdBps: option("divergence-threshold-bps", "25", { max: 10000n }),
    maxDivergenceBps: option("max-divergence-bps", "1000", { min: 1n, max: 10000n }),
    premiumPipsPerBps: option("premium-pips-per-bps", "20", { max: MAX_FEE_PIPS }),
    maxPremiumPips: option("max-premium-pips", "10000", { max: MAX_FEE_PIPS }),
    account: values.get("account") ?? null,
    sender: values.has("sender") ? address(values.get("sender"), "--sender") : null,
  };
  const calendarOptions = [
    "overnight-pips",
    "closed-pips",
    "open-pips",
    "close-pips",
    "open-window-minutes",
    "close-window-minutes",
    "holidays",
    "early-closes",
  ];
  if (result.model === "equity") {
    for (const [name, field] of [
      ["overnight-pips", "overnightPips"],
      ["closed-pips", "closedPips"],
      ["open-pips", "openPips"],
      ["close-pips", "closePips"],
    ]) {
      result[field] = decimal(required(name), `--${name}`, {
        min: MIN_FEE_PIPS,
        max: MAX_FEE_PIPS,
      });
    }
    result.openWindowMinutes = option("open-window-minutes", "30", { max: 390n });
    result.closeWindowMinutes = option("close-window-minutes", "30", { max: 390n });
    result.holidays = values.has("holidays") ? values.get("holidays").split(",") : [];
    result.earlyCloses = {};
    for (const date of result.holidays) validateCalendarDate(date);
    fail(new Set(result.holidays).size === result.holidays.length, "duplicate holiday date");
    for (const entry of values.has("early-closes") ? values.get("early-closes").split(",") : []) {
      const match = /^(\d{4}-\d{2}-\d{2})@([01]\d|2[0-3]):([0-5]\d)$/.exec(entry);
      fail(match, "early closes must use YYYY-MM-DD@HH:MM");
      const [, date, hours, minutes] = match;
      validateCalendarDate(date);
      fail(
        !(date in result.earlyCloses) && !result.holidays.includes(date),
        "duplicate or conflicting calendar date",
      );
      result.earlyCloses[date] = BigInt(Number(hours) * 60 + Number(minutes));
    }
  } else {
    fail(
      !calendarOptions.some((name) => values.has(name)),
      "calendar options require --model equity",
    );
  }
  validateSettings(result);
  if (result.account) {
    fail(
      /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(result.account) &&
        !/^(0x)?[0-9a-fA-F]{64}$/.test(result.account),
      "--account must be a Foundry account name, not a path, flag, or secret",
    );
  }
  if (execute) {
    fail(result.account, "--execute requires --account");
    fail(result.sender, "--execute requires --sender");
  }
  return result;
}

function validateCalendarDate(value) {
  fail(/^\d{4}-\d{2}-\d{2}$/.test(value), "calendar date must use YYYY-MM-DD");
  const parsed = new Date(`${value}T00:00:00Z`);
  fail(
    Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value,
    "calendar date does not exist",
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let settings;
  try {
    settings = parseCli(process.argv.slice(2));
    if (settings.help) console.log(usage);
    else console.log(json(await runKeeper(settings)));
  } catch (error) {
    const unsafe =
      typeof error?.shortMessage === "string"
        ? error.shortMessage
        : error instanceof Error
          ? error.message
          : String(error);
    const message = settings?.rpcUrl ? unsafe.split(settings.rpcUrl).join("[rpc-url]") : unsafe;
    console.error(json({ ok: false, error: message }));
    process.exitCode = 1;
  }
}
