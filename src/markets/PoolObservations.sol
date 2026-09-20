// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PoolObservations
/// @notice Uniswap V3's observation ring buffer, ported to solc 0.8.x so a Uniswap **v4** hook
///         can be its own oracle.
///
///         **Why this file exists.** V4 core deleted observations. A v4 pool has no `observe()`
///         and stores no history at all, because Uniswap decided an oracle is a hook's job and
///         shipped nothing in `v4-core` or `v4-periphery` to do it. Everything downstream of us
///         that priced off a TWAP — in this repo, `BuybackEngine`'s manipulation-resistant price
///         band — therefore has to get its history from the hook that already runs on every
///         swap. This library is that history.
///
///         **Ported from** Uniswap V3 `contracts/libraries/Oracle.sol` (v3-core @ 0.7.6):
///         `Observation`, `transform`, `initialize`, `write`, `grow`, `lte`, `binarySearch`,
///         `getSurroundingObservations`, `observeSingle`, `observe`. The algorithm, the ring
///         geometry and the wraparound conventions are unchanged; only the type-level noise
///         that 0.8 forces (explicit casts, explicit `unchecked`) differs.
///
///         **Deliberately left out: `secondsPerLiquidityCumulativeX128`.** V3 accumulates a
///         second series alongside the tick series, used by staking/incentive contracts to
///         weigh a position by liquidity-seconds. This repo used to weigh multi-leg splitter
///         payouts by pool liquidity-seconds and that weighting has since been deleted, so
///         nothing here reads it. Dropping it is not cosmetic: it halves the accumulator work
///         in `transform`, removes the `uint160`/`Q128` division that is the most expensive
///         arithmetic in the original, and shrinks `Observation` from three storage-packed
///         fields plus a `uint160` (two slots) to a single slot — which matters a lot when the
///         buffer is 65535 entries deep and a hook pays for it. `getSurroundingObservations`,
///         `binarySearch` and `lte` are untouched by the removal; they only ever compare
///         timestamps.
///
///         **Also left out:** `observeSingle`'s and `observe`'s liquidity arguments, and V3's
///         `snapshotCumulativesInside` (that lives in the pool, not the oracle library).
///
/// @dev    The `unchecked` blocks below are load-bearing, not decoration. V3 was written under
///         0.7.6, where all arithmetic wrapped silently, and several of its invariants *depend*
///         on wrapping. Under 0.8's default checked arithmetic those sites would revert instead
///         of wrapping, which would brick the buffer at a `block.timestamp` epoch boundary
///         rather than carrying it across. Each `unchecked` below names the specific overflow it
///         is preserving. Do not "clean these up".
library PoolObservations {
    /// @notice Minimum seconds between two stored observations.
    ///
    ///         This is what makes the ring's reach a property of the buffer rather than of how
    ///         often the pool happens to trade: `cardinality` slots reach back at least
    ///         `MIN_INTERVAL * (cardinality - 1)` seconds however busy the pool is. See `write`
    ///         for why a chain with sub-second blocks makes that necessary, and
    ///         `AssetMarketFactory.cardinalityForWindow` for the arithmetic that turns a TWAP
    ///         window into a slot count.
    ///
    ///         Fifteen seconds buys a 30-minute window for 122 slots instead of 1,802, and still
    ///         samples the 300-second floor twenty times.
    ///
    ///         **Consumers must read a window lagged by at least this much.** `observeSingle`
    ///         extends the newest stored observation to the requested instant at the LIVE tick,
    ///         so a window ending at `now` credits up to `MIN_INTERVAL` seconds to whatever the
    ///         pool says right now — which is exactly what a spike is. Asking instead for
    ///         `[window + MIN_INTERVAL, MIN_INTERVAL]` puts both endpoints on stored
    ///         observations, and costs `MIN_INTERVAL` seconds of staleness.
    ///
    ///         The stretch still open to the live tick is `max(0, now - newest - MIN_INTERVAL)`,
    ///         and a swap closes it: every swap writes an observation *before* it moves the price,
    ///         at the then-true tick, so a spike is recorded honestly and is worth nothing at the
    ///         instant it lands no matter how quiet the pool was. What remains is a manipulated
    ///         price held for longer than `MIN_INTERVAL` with nobody trading against it, which is
    ///         a TWAP charging for inventory risk rather than a hole in one.
    uint32 internal constant MIN_INTERVAL = 15;

    /// @notice The oracle has never been initialised for this pool — `cardinality` is zero, so
    ///         there is no observation to read and no sensible number to return.
    error NotInitialized();

    /// @notice The requested point in time is older than the oldest observation the ring buffer
    ///         still holds. V3 spells this `require(..., "OLD")`. Callers surface it as
    ///         "not enough history yet"; it must stay distinguishable from every other revert,
    ///         because it is the one a caller can fix by waiting or by growing the buffer.
    error TargetPredatesOldestObservation();

    /// @notice A single point in the buffer.
    /// @dev Packs into one 32-byte slot: 32 + 56 + 8 = 96 bits. In V3 this struct also carried
    ///      `secondsPerLiquidityCumulativeX128` (a `uint160`), which pushed it to two slots.
    struct Observation {
        /// @dev Block timestamp of the observation, truncated to 32 bits. Truncation is
        ///      intentional and the whole buffer is built to survive the resulting wraparound;
        ///      see `lte`.
        uint32 blockTimestamp;
        /// @dev Tick accumulator: the running sum of `tick * seconds_elapsed` since the pool was
        ///      first observed.
        int56 tickCumulative;
        /// @dev Whether this slot has ever been written. Used to tell "empty ring slot" apart
        ///      from "genuinely observed at timestamp 0".
        bool initialized;
    }

    /// @notice Advance an observation to a later timestamp, assuming `tick` held for the gap.
    /// @dev Two wrapping behaviours are preserved here, both of which 0.8 would otherwise turn
    ///      into reverts:
    ///
    ///      1. `blockTimestamp - last.blockTimestamp` is `uint32` subtraction. Once
    ///         `block.timestamp` passes 2^32 the truncated stamps wrap, and the *difference*
    ///         stays correct only because the subtraction wraps with them. Checked arithmetic
    ///         would revert on every call for the ~136 years after the epoch rolls over.
    ///      2. `tickCumulative + tick * delta` is allowed to overflow `int56`. V3 documents this
    ///         as desired: the accumulator is only ever read as a *difference* between two
    ///         observations, and a difference of two wrapped values is still the right number
    ///         provided both wrapped the same way. Checking it would revert the pool once the
    ///         accumulator saturated instead of quietly carrying on.
    function transform(Observation memory last, uint32 blockTimestamp, int24 tick)
        internal
        pure
        returns (Observation memory)
    {
        unchecked {
            uint32 delta = blockTimestamp - last.blockTimestamp;
            return Observation({
                blockTimestamp: blockTimestamp,
                tickCumulative: last.tickCumulative + int56(tick) * int56(uint56(delta)),
                initialized: true
            });
        }
    }

    /// @notice Write the first observation and open the ring at length one.
    /// @param self The stored buffer.
    /// @param time The current truncated timestamp.
    /// @return cardinality     The ring's populated length (1).
    /// @return cardinalityNext The ring's target length (1).
    function initialize(Observation[65535] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({blockTimestamp: time, tickCumulative: 0, initialized: true});
        return (1, 1);
    }

    /// @notice Append an observation for the current block, growing the ring if it is due.
    /// @dev At most one observation per block: a second call in the same block is a no-op, which
    ///      is what makes a same-block round trip unable to plant two entries. Growth happens
    ///      lazily, exactly when the write is about to wrap past the end of the populated
    ///      region, so `grow`'s prepaid slots become live in index order.
    /// @param self            The stored buffer.
    /// @param index           Index of the most recent observation.
    /// @param blockTimestamp  Current truncated timestamp.
    /// @param tick            The tick to accumulate over the elapsed interval.
    /// @param cardinality     Current populated length of the ring.
    /// @param cardinalityNext Target length, as set by `grow`.
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];

        // Too soon since the last entry. Uniswap's own oracle writes at most once per second
        // (`last.blockTimestamp == blockTimestamp`), which is ample when blocks are twelve
        // seconds apart because a ring of N then reaches back roughly 12N seconds.
        //
        // Robinhood Chain produces a block about every 0.1 seconds, so a busy pool writes every
        // single second and a ring of N reaches back exactly N seconds. That is what made a flat
        // 32-slot floor unable to serve an 1,800-second window: `observe` reverted
        // `TargetPredatesOldestObservation` on every read, `BuybackEngine.execute` could never
        // run on a market that actually traded, and one dust swap per second was enough to hold
        // any market there deliberately. Reaching the window at one entry per second would need
        // 1,802 slots.
        //
        // Throttling decouples reach from trade frequency. The cost is that the stretch between
        // the newest stored observation and `now` grows to `MIN_INTERVAL`, and `observeSingle`
        // credits that stretch to the live tick — so consumers must read a lagged window. See
        // `MIN_INTERVAL`.
        //
        // `unchecked` for the same reason `transform` is: uint32 timestamps wrap in 2106, and
        // wrapping subtraction is what gives the correct elapsed time across that boundary, where
        // a checked subtraction would revert and freeze every oracle on the chain.
        uint32 elapsed;
        unchecked {
            elapsed = blockTimestamp - last.blockTimestamp;
        }
        if (elapsed < MIN_INTERVAL) return (index, cardinality);

        // `cardinality >= 1` always once initialised, so `cardinality - 1` cannot underflow and
        // `index + 1` cannot exceed `uint16` (index < cardinality <= 65535, so index <= 65534).
        // These are the two places V3's implicit wrapping was never actually needed, so they
        // deliberately stay checked.
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            cardinalityUpdated = cardinality;
        }

        indexUpdated = (index + 1) % cardinalityUpdated;
        self[indexUpdated] = transform(last, blockTimestamp, tick);
    }

    /// @notice Prepare the ring to hold `next` observations.
    /// @dev The loop writes a non-zero `blockTimestamp` into every new slot purely to move the
    ///      cold-SSTORE cost onto whoever asked for the deeper buffer, rather than onto the
    ///      unlucky trader whose swap first wraps into it. `1` is a sentinel: `initialized`
    ///      stays false, so `binarySearch` still skips these slots.
    /// @return The new target length (unchanged if `next` is not an increase).
    function grow(Observation[65535] storage self, uint16 current, uint16 next)
        internal
        returns (uint16)
    {
        if (current == 0) revert NotInitialized();
        // The buffer never shrinks: a shorter target would silently discard history that
        // somebody is already relying on.
        if (next <= current) return current;
        for (uint16 i = current; i < next; i++) {
            self[i].blockTimestamp = 1;
        }
        return next;
    }

    /// @notice 32-bit-wraparound-safe `a <= b`, evaluated from the vantage point of `time`.
    /// @dev This is the single function that makes the ring survive a `block.timestamp`
    ///      overflow, and the one people drop when porting. Timestamps are stored truncated to
    ///      32 bits, so once the clock passes 2^32 a *newer* observation can hold a numerically
    ///      *smaller* stamp than an older one. Naive `a <= b` would then order the buffer
    ///      backwards and the binary search would return garbage. Lifting both operands into
    ///      `uint256` and adding a full 2^32 epoch to whichever ones have already wrapped past
    ///      `time` restores the true ordering.
    ///
    ///      The arithmetic itself is safe under 0.8 without `unchecked`: both operands are
    ///      widened to `uint256` before the addition, so `a + 2**32` cannot overflow.
    function lte(uint32 time, uint32 a, uint32 b) internal pure returns (bool) {
        // No overflow has happened yet, so the plain comparison is correct.
        if (a <= time && b <= time) return a <= b;

        uint256 aAdjusted = a > time ? a : uint256(a) + 2 ** 32;
        uint256 bAdjusted = b > time ? b : uint256(b) + 2 ** 32;

        return aAdjusted <= bAdjusted;
    }

    /// @notice Find the two observations that bracket `target`, by binary search over the ring.
    /// @dev The caller must already have established that `target` lies at or after the oldest
    ///      observation and at or before the newest; `getSurroundingObservations` does that.
    ///
    ///      `r = i - 1` is left checked on purpose. In V3 it wrapped, but only in a branch the
    ///      precondition above makes unreachable — the search cannot step left of the oldest
    ///      entry when the target is known to be at or after it. Under 0.8 an unreachable
    ///      underflow reverts instead of silently producing an enormous `r` and a nonsense
    ///      answer, which is strictly the better failure mode.
    function binarySearch(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        uint256 l = (uint256(index) + 1) % cardinality; // oldest observation
        uint256 r = l + cardinality - 1; // newest observation
        uint256 i;
        while (true) {
            i = (l + r) / 2;

            beforeOrAt = self[i % cardinality];

            // Slot prepaid by `grow` but never written; keep searching to the right.
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }

            atOrAfter = self[(i + 1) % cardinality];

            bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

            if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp)) break;

            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

    /// @notice Return the observations on either side of `target`, synthesising the right-hand
    ///         one when `target` is in the future relative to the newest stored observation.
    /// @dev Reverts `TargetPredatesOldestObservation` when the ring no longer reaches back that
    ///      far. That is the case a caller fixes by growing the buffer or by waiting.
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // Optimistically assume the newest observation is the left-hand bound.
        beforeOrAt = self[index];

        if (lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) {
                // `atOrAfter` is deliberately left zeroed; the caller short-circuits on the
                // exact-hit case and never reads it.
                return (beforeOrAt, atOrAfter);
            } else {
                // `target` is after everything stored, so extend the newest observation forward
                // at the current tick.
                return (beforeOrAt, transform(beforeOrAt, target, tick));
            }
        }

        // Otherwise start from the oldest observation.
        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        if (!lte(time, beforeOrAt.blockTimestamp, target)) {
            revert TargetPredatesOldestObservation();
        }

        return binarySearch(self, time, target, index, cardinality);
    }

    /// @notice The tick accumulator as of `secondsAgo` seconds before `time`.
    /// @dev Three wrapping sites, all `uint32` clock arithmetic that must wrap the way the
    ///      stored stamps do:
    ///
    ///      1. `time - secondsAgo` — the target stamp. Wraps back across the epoch boundary the
    ///         same way the stored stamps wrapped forward across it, which is exactly what makes
    ///         `lte` able to order them.
    ///      2. `atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp` — the gap between two
    ///         bracketing observations, which straddles the boundary whenever the buffer does.
    ///      3. `target - beforeOrAt.blockTimestamp` — the same, for the partial gap.
    ///
    ///      The `int56` interpolation is inside the same block because, like `transform`, it
    ///      operates on accumulators that are allowed to have wrapped; only the difference is
    ///      meaningful.
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative) {
        unchecked {
            if (secondsAgo == 0) {
                Observation memory last = self[index];
                if (last.blockTimestamp != time) last = transform(last, time, tick);
                return last.tickCumulative;
            }

            uint32 target = time - secondsAgo;

            (Observation memory beforeOrAt, Observation memory atOrAfter) =
                getSurroundingObservations(self, time, target, tick, index, cardinality);

            if (target == beforeOrAt.blockTimestamp) {
                // Landed exactly on the left-hand observation.
                return beforeOrAt.tickCumulative;
            } else if (target == atOrAfter.blockTimestamp) {
                // Landed exactly on the right-hand observation.
                return atOrAfter.tickCumulative;
            } else {
                // Strictly between the two: interpolate linearly, which is exact, because the
                // tick was constant across the whole interval by construction.
                uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
                uint32 targetDelta = target - beforeOrAt.blockTimestamp;
                return beforeOrAt.tickCumulative
                    + ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative)
                        / int56(uint56(observationTimeDelta))) * int56(uint56(targetDelta));
            }
        }
    }

    /// @notice Batch form of `observeSingle`, matching V3's `observe` minus the liquidity series.
    /// @param self        The stored buffer.
    /// @param time        The current truncated timestamp.
    /// @param secondsAgos How far back each requested point is, in seconds.
    /// @param tick        The pool's current tick, used to extend the newest observation to now.
    /// @param index       Index of the most recent observation.
    /// @param cardinality Populated length of the ring.
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (int56[] memory tickCumulatives) {
        if (cardinality == 0) revert NotInitialized();

        tickCumulatives = new int56[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = observeSingle(self, time, secondsAgos[i], tick, index, cardinality);
        }
    }
}
