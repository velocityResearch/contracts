// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/utils/math/Math.sol";

/// @notice One declared segment of a launch's bonding curve, in terms that are independent of
///         the quote asset it will trade against.
///
///         A `LaunchConfig` is reusable across every approved quote brand, and those brands
///         differ in scale by orders of magnitude, so a segment cannot name an absolute token
///         amount or an absolute phantom reserve. Both figures are therefore relative:
///
///         - `supplyShareBps` is this segment's share of the launch's *sellable* supply, the
///           allocation above `reservedTokens` that the curve actually dispenses. Shares must
///           sum to exactly `BASIS_POINTS`, which is what makes "the segments add up to the
///           whole supply" checkable when the config is written rather than when it is used.
///         - `kMultiplierBps` is this segment's constant product as a fraction of the first
///           segment's, `phantomQuote * launchSupply`. The first segment is pinned to
///           `BASIS_POINTS` so every launch opens at the price its brand's economics fix, and
///           the rest are non-decreasing, which is exactly the condition that makes the price
///           non-decreasing across every boundary: with the token reserve continuous at a
///           boundary, the price is `k / tokenReserve²`, so the price steps up if and only if
///           `k` does.
struct CurveSegmentConfig {
    uint16 supplyShareBps;
    uint32 kMultiplierBps;
}

/// @notice One segment resolved against a live launch, in absolute amounts.
///
/// @dev Only the quote side is segmented. The token reserve is the launch's single global
///      `trackedTokens` axis and is continuous across boundaries; a segment is the band of
///      that axis running from the previous segment's `tokenFloor` (or the whole supply, for
///      the first) down to its own. Within the band the curve is an ordinary constant product
///      over the reserves
///
///          quote = phantomQuote + (netQuoteRaised - quoteMark),  token = trackedTokens
///
///      so `quoteMark` — the net quote the curve has taken in by the time the band opens — is
///      what lets each band carry its own virtual reserve without the accumulated real quote
///      being counted twice.
struct CurveSegment {
    /// @notice Token reserve at which this segment ends and the next one begins. The last
    ///         segment's floor is the launch's reserved allocation.
    uint256 tokenFloor;
    /// @notice Virtual quote reserve this segment prices against at its own start.
    uint256 phantomQuote;
    /// @notice Net quote raised by the curve when this segment starts.
    uint256 quoteMark;
}

/// @title LaunchCurveSegments
/// @notice Shape validation and resolution for segmented launch curves, shared by
///         `LaunchCurve` (which prices against the resolved table) and `LaunchFactory` (which
///         stores the declared shape and preflights the graduation seed it implies).
///
///         An empty declaration resolves to the single segment that reproduces the
///         unsegmented curve exactly: phantom reserve equal to the brand's own, no quote mark,
///         and a floor at the reserved allocation. That is the identity every existing launch
///         relies on, so it is produced by the same code path rather than by a special case
///         somewhere else.
library LaunchCurveSegments {
    uint256 internal constant BASIS_POINTS = 10_000;
    /// @notice Most segments one launch may declare. Each one a trade crosses costs a storage
    ///         read and a pair of divisions, and four bands are already enough to express a
    ///         flat opening, a steepening middle and a hard tail.
    uint256 internal constant MAX_SEGMENTS = 4;
    /// @notice Steepest a later segment may be relative to the first: a hundredfold constant
    ///         product, which is a tenfold price step at the same token reserve. A ceiling at
    ///         all is what stops a config from pricing its tail so far above its opening that
    ///         the launch is only nominally the same curve.
    uint256 internal constant MAX_K_MULTIPLIER_BPS = 1_000_000;

    error InvalidSegmentCount();
    error InvalidSegmentShare();
    error InvalidSegmentSteepness();

    /// @notice Validates everything about a declared shape that does not depend on the quote
    ///         asset: count, per-segment share, that the shares cover the sellable supply
    ///         exactly, and that the curve never gets cheaper as it sells through.
    /// @dev An empty declaration is the unsegmented default and always valid.
    function validateShape(CurveSegmentConfig[] memory segments) internal pure {
        uint256 count = segments.length;
        if (count == 0) return;
        if (count > MAX_SEGMENTS) revert InvalidSegmentCount();

        uint256 shares;
        uint256 previousK;
        for (uint256 i = 0; i < count; ++i) {
            uint256 share = segments[i].supplyShareBps;
            uint256 k = segments[i].kMultiplierBps;
            if (share == 0) revert InvalidSegmentShare();
            shares += share;
            if (i == 0) {
                // Pinned rather than merely bounded: the opening price is what the brand's
                // economics, the quotability check and the creator's own quote were all
                // computed against.
                if (k != BASIS_POINTS) revert InvalidSegmentSteepness();
            } else if (k < previousK || k > MAX_K_MULTIPLIER_BPS) {
                revert InvalidSegmentSteepness();
            }
            previousK = k;
        }
        if (shares != BASIS_POINTS) revert InvalidSegmentShare();
    }

    /// @notice Resolves a declared shape against one launch's absolute figures.
    /// @param segments Declared shape; empty resolves to the single unsegmented segment.
    /// @param supply Total supply the launch minted, which is the curve's opening token
    ///        reserve.
    /// @param reserved Allocation the curve never sells below, and therefore the last
    ///        segment's floor. Must be non-zero and below `supply`; callers establish that
    ///        before calling.
    /// @param basePhantomQuote Virtual quote reserve the launch's brand economics fix, which
    ///        is the first segment's own.
    /// @return table Resolved segments, in the order they are sold through.
    /// @return quoteAtGraduation Net quote the curve holds once the whole sellable allocation
    ///         has been bought. Equal to the brand's graduation threshold (up to the same
    ///         rounding the reserved allocation already carries) for an unsegmented curve, and
    ///         strictly above it for a steepened one.
    /// @return graduationPhantomQuote Virtual quote reserve that reproduces the curve's
    ///         terminal price against `quoteAtGraduation`, i.e. the last segment's phantom
    ///         reserve net of its quote mark. Graduation splits the reserved allocation
    ///         between pool and locker with this rather than with `basePhantomQuote`, which is
    ///         what keeps the graduated pool opening at the price the curve closed at.
    function build(
        CurveSegmentConfig[] memory segments,
        uint256 supply,
        uint256 reserved,
        uint256 basePhantomQuote
    )
        internal
        pure
        returns (
            CurveSegment[] memory table,
            uint256 quoteAtGraduation,
            uint256 graduationPhantomQuote
        )
    {
        validateShape(segments);

        uint256 count = segments.length == 0 ? 1 : segments.length;
        uint256 sellable = supply - reserved;
        // One base unit per segment is the floor at which every band can dispense something.
        if (sellable < count) revert InvalidSegmentCount();

        table = new CurveSegment[](count);
        uint256 ceiling = supply;
        uint256 assigned;
        uint256 mark;
        for (uint256 i = 0; i < count; ++i) {
            // The last band takes the remainder rather than its own rounded share, so the
            // floors land on `reserved` exactly and no token is stranded between the curve's
            // last segment and its reserved allocation.
            uint256 allocated = i + 1 == count
                ? sellable - assigned
                : Math.mulDiv(sellable, segments[i].supplyShareBps, BASIS_POINTS);
            if (allocated == 0) revert InvalidSegmentShare();
            assigned += allocated;
            uint256 floor_ = ceiling - allocated;

            uint256 phantom;
            if (i == 0) {
                // Exactly the brand's own reserve, not a rounded derivation of it: this is the
                // identity that makes a single-segment launch price identically to an
                // unsegmented one.
                phantom = basePhantomQuote;
            } else {
                // k_i / T_i, rounded up, and never below the reserve the previous band closed
                // at. The max is what absorbs the wei of drift the two roundings can leave
                // between bands of equal steepness, so the price is non-decreasing at every
                // boundary by construction rather than by an argument about rounding.
                phantom = Math.max(
                    Math.mulDiv(
                        basePhantomQuote * segments[i].kMultiplierBps,
                        supply,
                        ceiling * BASIS_POINTS,
                        Math.Rounding.Ceil
                    ),
                    mark + graduationPhantomQuote
                );
            }

            table[i] = CurveSegment({tokenFloor: floor_, phantomQuote: phantom, quoteMark: mark});
            // Held as the running effective phantom so the max above stays monotone, and
            // returned as the terminal one once the loop ends.
            graduationPhantomQuote = phantom - mark;
            // Quote this band takes in when it is bought out whole, floored: the resolved
            // mark must never sit above the real quote the curve will actually be holding
            // when the next band opens.
            mark += Math.mulDiv(phantom, allocated, floor_);
            ceiling = floor_;
        }
        quoteAtGraduation = mark;
    }
}
