// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20Upgradeable} from "oz-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";

/// @title PooledBrandToken
/// @notice A brand's 1:1-redeemable claim on a `SharedReservePool`. Unlike a yield-bearing
///         ERC-4626 share, this token never appreciates in price — it is always worth exactly 1 unit of the
///         pool's underlying asset, which is what makes free `swap()` between brands in the
///         same pool safe: burning X of one pooled brand token and minting X of another never
///         moves value, because neither side's par value ever moves.
///
///         Yield earned on the reserves backing this brand's outstanding supply still accrues
///         — see `SharedReservePool` — but as a claim owed to the brand's treasury, not as
///         appreciation of this token. Mint/burn is restricted to the pool, which is the only
///         contract that ever changes this token's supply and always does so 1:1 against real
///         backing moving in (mint), real backing paying out (redeem), or a same-amount
///         burn/mint on the other side of a swap.
///
///         **Upgradeable, behind a beacon shared by every brand.** One implementation backs all
///         of them, so a fix reaches every stablecoin at once rather than only the ones minted
///         after it. The beacon is owned by the protocol timelock.
///
///         **Transfers are deliberately never pausable.** Everything else in the protocol obeys
///         `ProtocolGuard`, and this does not, for the same reason redemption does not: a holder
///         must be able to leave during an incident, and leaving means moving the token to
///         wherever they redeem or trade it. A pausable stablecoin whose transfers stop is also
///         a stablecoin whose Uniswap pool stops quoting, which turns a contained incident into
///         a market-wide one. The supply-changing entry points are pool-only, and the pool's own
///         mint is guarded, so halting reaches minting without reaching holders.
contract PooledBrandToken is Initializable, ERC20Upgradeable {
    // ─── Metadata (on chain, Pons-compatible) ────────────────────────────

    /// @notice What a brand stablecoin carries besides name and symbol.
    /// @dev    Stored on chain rather than only in this app's own image store, so an indexer,
    ///         explorer or aggregator can render the coin without knowing about us. The
    ///         getters `description()`, `logo()` and `socials()` deliberately match the
    ///         selectors the Pons tokens on this chain expose — so tooling written for them
    ///         reads this unchanged.
    ///
    ///         Before this existed, a brand's logo lived only in an off-chain bucket keyed by
    ///         token address, which meant nothing on chain recorded it and anyone indexing the
    ///         token had no way to find the image. That is the gap this closes.
    struct Metadata {
        /// @dev Free text; the issuer's pitch.
        string description;
        /// @dev Image URL. Any scheme a reader can resolve: https://, ipfs://.
        string logo;
        /// @dev One or more URLs, space-separated. A single URL is the common case.
        string socials;
    }

    /// @notice Free-text description.
    string public description;

    /// @notice Image URL. This is the field an indexer reads to find the token's picture.
    string public logo;

    /// @notice Social / community links.
    string public socials;

    /// @notice The only address that may rewrite the three metadata strings.
    ///
    ///         Metadata is mutable where supply is not, on purpose: a logo is hosted content
    ///         that rots, and an issuer who has to redeploy their stablecoin to repoint an
    ///         image URL will simply not bother, which puts us back to having no on-chain
    ///         image at all. The authority reaches nothing but these three strings — it cannot
    ///         mint, cannot burn, cannot touch the treasury, and cannot change the peg.
    ///
    ///         Zero means the metadata is frozen as constructed and can never be changed.
    address public metadataAdmin;

    /// @notice The admin named at initialisation. It gets exactly one direct handover, spent
    ///         by `handOverMetadataAdmin`, and no authority of any kind after that.
    ///
    /// @dev    Storage rather than `immutable`: every brand shares one implementation behind the
    ///         beacon, and an immutable lives in that shared bytecode — so the first brand
    ///         deployed would silently set it for all of them. The same applies to `pool` and
    ///         `_decimals` below.
    address public initialMetadataAdmin;

    /// @notice Who has been offered the metadata authority but has not yet accepted it. Zero
    ///         when no transfer is outstanding.
    address public pendingMetadataAdmin;

    /// @dev Whether the one direct handover has been spent.
    bool private _handedOver;

    // ─── Supply control ──────────────────────────────────────────────────

    /// @notice The `SharedReservePool` that exclusively controls this token's supply.
    address public pool;

    uint8 private _decimals;

    /// @dev Room for later versions to add state without disturbing what a live brand already
    ///      holds. See the note on the beacon above.
    uint256[44] private __gap;

    event MetadataUpdated(string description, string logo, string socials);
    event MetadataAdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event MetadataAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error OnlyPool();
    error OnlyMetadataAdmin();
    error OnlyPendingMetadataAdmin();
    error HandoverAlreadySpent();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    modifier onlyMetadataAdmin() {
        if (msg.sender != metadataAdmin || metadataAdmin == address(0)) revert OnlyMetadataAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @param name_          Token name (e.g. "Stables USD")
    /// @param symbol_        Token symbol (e.g. "sphUSD")
    /// @param _pool          The SharedReservePool this token is pooled with
    /// @param decimals_      Decimals to match the pool's underlying asset, so 1 unit of this
    ///                       token always lines up with 1 unit of the asset it is redeemable
    ///                       for.
    /// @param _metadata      Description, logo URL and socials. Every field may be empty.
    /// @param _metadataAdmin Who may rewrite `_metadata` later. Zero freezes it forever.
    function initialize(
        string memory name_,
        string memory symbol_,
        address _pool,
        uint8 decimals_,
        Metadata memory _metadata,
        address _metadataAdmin
    ) external initializer {
        __ERC20_init(name_, symbol_);

        pool = _pool;
        _decimals = decimals_;

        description = _metadata.description;
        logo = _metadata.logo;
        socials = _metadata.socials;
        metadataAdmin = _metadataAdmin;
        initialMetadataAdmin = _metadataAdmin;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // ─── Metadata administration ─────────────────────────────────────────

    /// @notice Rewrite all three metadata strings. All-or-nothing rather than one setter per
    ///         field, so a partial update cannot leave the three describing different versions
    ///         of the brand.
    function setMetadata(Metadata calldata _metadata) external onlyMetadataAdmin {
        description = _metadata.description;
        logo = _metadata.logo;
        socials = _metadata.socials;

        emit MetadataUpdated(_metadata.description, _metadata.logo, _metadata.socials);
    }

    /// @notice Offer the metadata authority to `newAdmin`, who must accept it.
    ///
    ///         Two steps rather than one, and the reason is what this authority controls. A
    ///         logo is the first thing a user recognises a token by. Sending it to a mistyped
    ///         or unreachable address does not fail loudly: the token keeps working, keeps its
    ///         peg, keeps trading, and simply can never have its image corrected again. A
    ///         handover that only completes when the recipient proves they can transact makes
    ///         that outcome unreachable.
    ///
    ///         Passing `address(0)` cancels an outstanding offer. To freeze the strings
    ///         permanently, call `renounceMetadataAdmin` instead — freezing cannot be two-step,
    ///         because nobody is there to accept.
    function transferMetadataAdmin(address newAdmin) external onlyMetadataAdmin {
        pendingMetadataAdmin = newAdmin;
        emit MetadataAdminTransferStarted(metadataAdmin, newAdmin);
    }

    /// @notice Take up an offer made by `transferMetadataAdmin`.
    function acceptMetadataAdmin() external {
        if (msg.sender != pendingMetadataAdmin || pendingMetadataAdmin == address(0)) {
            revert OnlyPendingMetadataAdmin();
        }

        emit MetadataAdminTransferred(metadataAdmin, msg.sender);
        metadataAdmin = msg.sender;
        pendingMetadataAdmin = address(0);
    }

    /// @notice Give up the metadata authority for good, freezing all three strings.
    ///
    ///         Single-step by necessity — there is no recipient to accept — and irreversible.
    ///         An issuer who wants their metadata visibly immutable has no other way to say so.
    function renounceMetadataAdmin() external onlyMetadataAdmin {
        emit MetadataAdminTransferred(metadataAdmin, address(0));
        metadataAdmin = address(0);
        pendingMetadataAdmin = address(0);
    }

    /// @notice The one direct handover, reserved for the admin named at construction.
    ///
    ///         `AssetMarketFactory` registers each brand with ITSELF as the metadata admin, for
    ///         the length of one function call, purely so it can write a logo URL derived from
    ///         the token's own address — which nobody could have passed in, because the address
    ///         does not exist until the token does. It then hands the authority to the issuer
    ///         and never holds it again.
    ///
    ///         That handoff cannot be two-step without breaking the one-transaction launch: the
    ///         issuer would have to send a second transaction to accept, and until they did, the
    ///         factory would hold the pen over their logo. So it is single-step, spendable once,
    ///         and only by the constructor's admin. Every later transfer goes through
    ///         `transferMetadataAdmin` and must be accepted.
    function handOverMetadataAdmin(address newAdmin) external onlyMetadataAdmin {
        if (_handedOver || msg.sender != initialMetadataAdmin) revert HandoverAlreadySpent();

        _handedOver = true;
        emit MetadataAdminTransferred(metadataAdmin, newAdmin);
        metadataAdmin = newAdmin;
    }

    /// @notice All three strings in one call, so an indexer needs one `eth_call` per token
    ///         rather than three.
    function metadata() external view returns (Metadata memory) {
        return Metadata({description: description, logo: logo, socials: socials});
    }

    // ─── Supply ──────────────────────────────────────────────────────────

    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}
