// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";

import {SharedReservePool} from "./SharedReservePool.sol";
import {GuardedUpgradeable} from "../upgrade/GuardedUpgradeable.sol";

/// @title PoolBrandTreasury
/// @notice Per-brand treasury for a `SharedReservePool` brand: the only address the pool will
///         ever pay that brand's accrued reserve yield to, and the admin-controlled point for
///         distributing it onward. Plays the same role `VaultTreasury` plays for a
///         `BrandedVault`, adapted to the pool's yield-claim ledger instead of an ERC-4626
///         redeem.
///
///         `claim` is admin-only with an explicit receiver, for the same reason
///         `VaultTreasury.redeem`/`redeemAll` are: a payout function that takes an arbitrary
///         receiver is redirectable by whoever calls it, so leaving it open would let a
///         passer-by send a brand's accrued yield to themselves. Owning the shares is not
///         enough — the destination has to be gated too.
///
///         **Upgradeable behind a shared beacon, and halted by `ProtocolGuard`.** Both payout
///         paths stop when the protocol is paused. Neither is an exit route for a holder — a
///         holder's exit is `SharedReservePool.redeem`, which is never pausable — so halting
///         them costs a brand operator a delay and costs a holder nothing.
contract PoolBrandTreasury is Initializable, GuardedUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The pool this treasury claims yield from.
    /// @dev    Storage, not `immutable`: one implementation backs every brand's treasury behind
    ///         the beacon, so an immutable would be shared by all of them.
    SharedReservePool public pool;

    /// @notice The PooledBrandToken this treasury represents.
    address public brandToken;

    /// @notice The admin address (typically the brand EOA or multisig)
    address public admin;

    /// @notice Cumulative underlying claimed from the pool by this treasury.
    uint256 public totalYieldClaimed;

    // ─── Events ──────────────────────────────────────────────────────────

    event Claimed(uint256 amount, address indexed receiver);
    event Distributed(address indexed token, address indexed to, uint256 amount);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyAdmin();
    error ZeroAmount();
    error ZeroAddress();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        SharedReservePool _pool,
        address _brandToken,
        address _admin,
        address _guard
    ) external initializer {
        if (address(_pool) == address(0) || _brandToken == address(0) || _admin == address(0)) {
            revert ZeroAddress();
        }
        __Guarded_init(_guard);

        pool = _pool;
        brandToken = _brandToken;
        admin = _admin;
    }

    // ─── Admin functions ─────────────────────────────────────────────────

    /// @notice Claim this brand's accrued reserve yield from the pool. Admin only, explicit
    ///         receiver — see the contract-level note on why this differs from VaultTreasury.
    /// @param receiver Address to receive the claimed underlying
    /// @return amount  The amount claimed
    function claim(address receiver) external onlyAdmin whenNotPaused returns (uint256 amount) {
        if (receiver == address(0)) revert ZeroAddress();
        amount = pool.claimYield(brandToken, receiver);
        totalYieldClaimed += amount;
        emit Claimed(amount, receiver);
    }

    /// @notice Transfer any token held by this treasury out to a recipient. Admin only.
    /// @param token  The ERC20 token to transfer
    /// @param to     The recipient
    /// @param amount The amount to transfer
    function distribute(address token, address to, uint256 amount)
        external
        onlyAdmin
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Distributed(token, to, amount);
    }

    /// @notice Transfer admin rights to a new address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        address old = admin;
        admin = newAdmin;
        emit AdminUpdated(old, newAdmin);
    }

    // ─── View functions ──────────────────────────────────────────────────

    /// @dev Room for later versions to add state.
    uint256[45] private __gap;

    /// @notice This brand's pending (unclaimed) yield, including yield earned since the
    ///         pool's last on-chain settle.
    function pendingYield() external view returns (uint256) {
        return pool.pendingYield(brandToken);
    }
}
