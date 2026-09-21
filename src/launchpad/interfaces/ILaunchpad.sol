// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Pull ledger for ERC-20 revenue. `creditToken` pulls `amount` from `msg.sender`.
interface ILaunchFeeEscrow {
    function creditToken(address recipient, address token, uint256 amount) external;
    function claimToken(address token) external returns (uint256 amount);
    function claimToken(address token, uint256 amount) external returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

/// Snapshotted into every curve at launch. The creator's share is not stored: it is the
/// remainder after the protocol's and the LP fund's, so the three always sum to the whole
/// fee and the rounding dust falls to the creator.
struct FeePolicySnapshot {
    address protocolFeeRecipient;
    uint16 protocolFeeShareBps; // share of the curve fee that goes to the protocol
    address lpFundRecipient;
    uint16 lpFundShareBps; // share of the curve fee that goes to the LP fund
}

/// Implemented by LaunchFactory. The curve reads it at initialize and snapshots it.
interface ILaunchFeePolicy {
    function protocolFeeRecipient() external view returns (address);
    function protocolFeeShareBps() external view returns (uint256);
    /// Where the LP fund's share of launchpad revenue is credited. Zero only while both LP
    /// fund share knobs are zero, which is the configuration that disables the leg entirely.
    function lpFundRecipient() external view returns (address);
    function lpFundShareBps() external view returns (uint16);
    function feeEscrow() external view returns (ILaunchFeeEscrow);
    function currentFeePolicy() external view returns (FeePolicySnapshot memory);
}

/// Implemented by LaunchFactory. Snapshotted into every curve at initialize.
interface ILaunchSnipeTax {
    function snipeTaxStartBps() external view returns (uint256);
    function snipeTaxSeconds() external view returns (uint256);
}

enum GraduationPhase {
    NotGraduated,
    Swept,
    Graduated,
    Rescued
}

interface ILaunchFactory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer; // creator, for attribution and unit metadata admin
        address creatorFeeRecipient;
        address pairToken; // the brand the curve is quoted in
        address reserve; // SharedReservePool that brand belongs to
        uint256 graduationThreshold; // in pairToken units
        uint24 poolFee; // LP tier of the graduated pool, snapshotted
        uint16 creatorTaxBps;
        uint16 creatorShareBps; // creator's share of the position's LP FEES post-graduation
        GraduationPhase phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        uint256 marketId; // AssetMarketFactory market id once Graduated
        bool exists;
    }
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    /// The live creator fee recipient. Post-graduation payers (the locker) read this at
    /// collect time rather than holding a copy, so the 2-step handover has one record.
    function creatorFeeRecipientOf(address token) external view returns (address);
    /// The LP fund's share of a locked position's LP fees, in bps. Read live by the locker
    /// rather than snapshotted, because the fund's mandate is still being decided, so its cut
    /// has to stay tunable — and it is carved out of the PROTOCOL's remainder rather than the
    /// creator's frozen share, so that tuning it can never reprice a term a creator was sold.
    ///
    /// There is no yield knob beside it any more. A position the CURRENT locker records
    /// renounces its reward stream at `recordPosition`, so float yield never reaches that
    /// locker and has nothing to split: every wei of it belongs to the liquidity providers
    /// who took risk for it.
    function graduatedLpFundShareBps() external view returns (uint16);
    /// The creator's share of a locked position's FLOAT YIELD, in bps. Kept solely for the
    /// `LaunchLocker` deployed before the shared-quote change, which reads it unconditionally
    /// in `collect()` for the positions it already custodies. Not settable, and never read by
    /// the current locker.
    function graduatedCreatorYieldShareBps() external view returns (uint16);
    function launchCount() external view returns (uint256);
    function launchAt(uint256 index) external view returns (address token);
    function graduate(address token) external; // phase 1, permissionless
    function graduateToMarket(address token) external; // phase 2, permissionless, retryable
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
    function quoteBuy(uint256 quoteIn, address recipient)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 tax);
    function quoteSell(uint256 tokensIn)
        external
        view
        returns (uint256 quoteOut, uint256 fee, uint256 tax);
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        returns (uint256 quoteOut);
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
        uint256 quoteAmount; // swept real quote, pairToken units
        uint256 tokenAmount; // swept tokens (whole remaining supply)
        uint256 phantomQuote; // to preserve the terminal price: seed tokens = tokenAmount·quote/(quote+phantom)
    }

    struct Result {
        uint256 marketId;
        address unit; // the market's quote brand, which is the launch's own `pairToken`
        bytes32 poolId;
        uint256 positionId;
        uint256 unitSeeded;
        uint256 tokensSeeded;
        uint256 tokensLocked; // everything sent to the locker: excess supply plus mint dust
    }
    function graduate(Seed calldata seed) external returns (Result memory);
}

interface ILaunchLocker {
    struct LockedPosition {
        uint256 tokenId;
        address distributor; // LpRewardDistributor the NFT is staked in
        address unit; // the market's quote brand, one of the two fee currencies
        address creatorFeeRecipient;
        uint16 creatorShareBps; // of the position's LP fees; there is no yield leg to split
        bool exists;
    }
    /// onlyGraduation. The NFT must already be staked in `distributor` with this locker as
    /// the staker; this records the split. Never unstakes: there is no function for it.
    function recordPosition(address token, LockedPosition calldata position) external;
    /// onlyGraduation. Pulls `amount` of `token` from msg.sender and holds it forever.
    function lockTokenSupply(address token, uint256 amount) external;
    /// Permissionless. Collects the position's LP fees — in the quote brand and in the launch
    /// token — and splits each three ways: the position's snapshotted `creatorShareBps` to the
    /// creator, the factory's live `graduatedLpFundShareBps` to the LP fund, and the remainder
    /// to the protocol. Every leg credits LaunchFeeEscrow.
    ///
    /// Float yield is deliberately absent. The position renounced its reward stream when it
    /// was recorded, so the whole stream stays with the market's other liquidity providers.
    function collect(address token) external returns (uint256 unitOut, uint256 tokenOut);
    function lockedPosition(address token) external view returns (LockedPosition memory);
    function lockedSupply(address token) external view returns (uint256);
}
