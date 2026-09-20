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
    /// The creator's share of a locked position's float-yield rewards, in bps. Read live by
    /// the locker at collect time rather than snapshotted into the launch, which is the whole
    /// reason it is a second knob: the LP-fee split is a term the creator is sold and is
    /// therefore frozen per launch, while the yield on a market's float is the reserve's own
    /// and one change has to reach every locked position at once.
    function graduatedCreatorYieldShareBps() external view returns (uint16);
    /// The LP fund's share of BOTH post-graduation legs — the locked position's LP fees and
    /// its float yield — in bps. Read live by the locker for the same reason the yield share
    /// is: the fund's mandate is still being decided, so its cut has to stay tunable, and it
    /// is carved out of the PROTOCOL's remainder rather than the creator's frozen share so
    /// that tuning it can never reprice a term a creator was sold.
    function graduatedLpFundShareBps() external view returns (uint16);
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
        uint256 tokensLocked; // everything sent to the locker: excess supply plus mint dust
    }
    function graduate(Seed calldata seed) external returns (Result memory);
}

interface ILaunchLocker {
    struct LockedPosition {
        uint256 tokenId;
        address distributor; // LpRewardDistributor the NFT is staked in
        address unit; // the market unit (reward token and one fee currency)
        address creatorFeeRecipient;
        uint16 creatorShareBps; // of LP fees only; the yield share is read live from the factory
        bool exists;
    }
    /// onlyGraduation. The NFT must already be staked in `distributor` with this locker as
    /// the staker; this records the split. Never unstakes: there is no function for it.
    function recordPosition(address token, LockedPosition calldata position) external;
    /// onlyGraduation. Pulls `amount` of `token` from msg.sender and holds it forever.
    function lockTokenSupply(address token, uint256 amount) external;
    /// Permissionless. Collects the position's LP fees and its float-yield rewards and splits
    /// each three ways, on two separate creator rates: LP fees by the position's snapshotted
    /// `creatorShareBps`, float yield by the factory's live `graduatedCreatorYieldShareBps`.
    /// Both legs give the LP fund the factory's live `graduatedLpFundShareBps`, taken out of
    /// the protocol's remainder rather than the creator's share, and the protocol keeps what
    /// is left. Every leg credits LaunchFeeEscrow.
    /// `unitOut` is both unit legs added together; `yieldOut` is the yield leg alone.
    function collect(address token)
        external
        returns (uint256 unitOut, uint256 tokenOut, uint256 yieldOut);
    function lockedPosition(address token) external view returns (LockedPosition memory);
    function lockedSupply(address token) external view returns (uint256);
}
