// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @title IStakedUSDai
/// @notice The slice of USD.AI's `StakedUSDai` (sUSDai) this repo reads and calls. Canonical
///         on Arbitrum at `0x0B2b2B2076d95dda7817e785989fE353fe955ef9` (18 decimals, asset =
///         USDai `0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF`). Verified against the deployed
///         v1.12 implementation's ABI on 2026-09-13.
///
///         Two NAVs. `depositSharePrice()` is the optimistic mark used by `convertToAssets`
///         and by the Curve pool's oracle rate; `redemptionSharePrice()` is the conservative
///         mark a native redemption is serviced at. The gap was ~44 bps at the time of
///         writing. This repo values holdings at the conservative one.
///
///         Exits are ERC-7540: `requestRedeem` burns the shares immediately and queues them
///         for role-gated servicing; `redeem` claims serviced USDai later. That path is not
///         used by `SUSDaiHub` yet — the hub exits through Curve — but the surface is kept
///         here because it is the liquidity fallback the design document names.
interface IStakedUSDai is IERC20 {
    function asset() external view returns (address);

    function depositSharePrice() external view returns (uint256);

    function redemptionSharePrice() external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function totalShares() external view returns (uint256);

    function paused() external view returns (bool);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function requestRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);

    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);

    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets);

    function maxWithdraw(address controller) external view returns (uint256);
}
