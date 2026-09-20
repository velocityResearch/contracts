// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IYieldSource
/// @notice Uniform interface for yield sources (Aave, Compound, Morpho, etc.)
/// @dev The vault calls these to deposit/withdraw USDC and check balances.
interface IYieldSource {
    /// @notice Deposit `amount` of `asset` into the yield source on behalf of this vault
    /// @param asset The token to deposit (e.g. USDC)
    /// @param amount The amount to deposit (in asset's decimals)
    function deposit(address asset, uint256 amount) external;

    /// @notice Withdraw `amount` of `asset` from the yield source to `to`
    /// @param asset The token to withdraw
    /// @param amount The amount to withdraw (in asset's decimals)
    /// @param to The recipient of the withdrawn tokens
    /// @return actualAmount The actual amount withdrawn (may be less if source is depleted)
    function withdraw(address asset, uint256 amount, address to)
        external
        returns (uint256 actualAmount);

    /// @notice The total balance of `asset` held in the yield source on behalf of this vault
    /// @param asset The token to check
    /// @return The balance in asset's decimals (includes accrued yield)
    function balanceOf(address asset) external view returns (uint256);

    /// @notice The total amount of `asset` managed by the yield source (for utilization checks)
    /// @param asset The token to check
    /// @return The total in asset's decimals
    function totalAssets(address asset) external view returns (uint256);

    /// @notice How much of `asset` `consumer` could withdraw right now, if it asked for
    ///         everything. This is the liquidity question, not the accounting one: `balanceOf`
    ///         is what the consumer is owed, and this is the part of it the source can hand
    ///         over in this block — the buffer on this chain, a lending market's unborrowed
    ///         supply, a vault's withdrawable share of its assets. Never more than `balanceOf`.
    ///
    ///         Takes the consumer explicitly rather than reading `msg.sender`, because the
    ///         callers that need it are quoters and aggregators sizing a redemption on the
    ///         pool's behalf, not the pool itself.
    /// @param asset    The token
    /// @param consumer The depositor whose position is being sized (the vault or pool)
    /// @return The amount `withdraw` would actually deliver for a full-position request
    function withdrawable(address asset, address consumer) external view returns (uint256);
}
