// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

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
///         **A shared quote dollar splits its yield.** A dollar that quotes markets it does not
///         belong to — AIUSD quoting a graduated launch, say — is backing float that sits in
///         those markets' pools, and the yield on that float is theirs rather than the issuer's.
///         `registerFloat` records how much each market locked, `pull` divides every claim
///         between the markets and the issuer in proportion to `outstanding`, and
///         `claimFloatShare` pays a market's vault. The issuer opts in by naming the market
///         factory through `setFactory`; until they do, `totalFloat` is zero and `claim`
///         behaves exactly as it always has. That naming is one-way — withdrawable and
///         restorable, but never transferable to a second address — because `factory` is the
///         only gate on `registerFloat` and a market that seeded this dollar can never
///         withdraw the liquidity it seeded.
///
///         The split is an index rather than a loop, the same shape
///         `SharedReservePool.cumulativeYieldPerToken` uses, so a dollar quoting a thousand
///         markets costs the same to claim as one quoting none.
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

    /// @dev `claimed` is what the pool paid this treasury on this call; `amount` is what was
    ///      forwarded to `receiver`. They differ by the markets' withheld share and by any
    ///      balance that reached this address outside a claim — see `claim`.
    event Claimed(uint256 claimed, uint256 amount, address indexed receiver);
    event Distributed(address indexed token, address indexed to, uint256 amount);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event FactoryUpdated(address indexed factory);
    event FloatRegistered(address indexed vault, uint256 previous, uint256 current);
    event FloatSharePulled(uint256 claimed, uint256 toMarkets);
    event FloatShareClaimed(address indexed vault, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────

    error OnlyAdmin();
    error OnlyFactory();
    error ZeroAmount();
    error ZeroAddress();
    error NoFloat();
    error FactoryAlreadyNamed();

    /// @notice The `AssetMarketFactory` allowed to register market float against this brand.
    ///         Zero until the admin names one, which is how an issuer opts into sharing.
    /// @dev    A setter rather than an `initialize` argument on purpose: the pool deploys these
    ///         treasuries (`SharedReservePool._registerBrand`), so a new argument would mean a
    ///         reserve upgrade to hand over an address only shared quote dollars ever use.
    address public factory;

    /// @notice What a market's fee vault has locked of this brand, in brand units. Recorded at
    ///         graduation and never re-measured: a pool's live balance is not readable, because
    ///         Uniswap v4 holds every pool's tokens in one singleton.
    mapping(address vault => uint256 float) public floatOf;

    /// @notice The sum of every `floatOf`.
    uint256 public totalFloat;

    /// @notice Underlying accrued per unit of float, scaled by `WAD`.
    uint256 public cumulativePerFloat;

    /// @notice Where each vault last settled against `cumulativePerFloat`.
    mapping(address vault => uint256 checkpoint) public checkpointOf;

    /// @notice Underlying held here that belongs to market vaults and has not been paid out.
    ///         Held back from `claim`, which is the whole of how the issuer cannot take it.
    ///
    ///         Only ever credited with what `cumulativePerFloat` actually promised — see the
    ///         conservation note on `_pull` — so the vaults between them can reach it to the
    ///         wei rather than leaving a remainder nobody can spend.
    uint256 public marketReserve;

    /// @notice The one factory address this brand has ever consented to, remembered so that
    ///         consent can be withdrawn and restored but never transferred. Zero until the
    ///         admin first names a factory, and never cleared afterwards. See `setFactory`.
    address public namedFactory;

    uint256 private constant WAD = 1e18;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
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

    /// @notice Claim this brand's accrued reserve yield and pay the issuer's part of it to
    ///         `receiver`. Admin only, explicit receiver — see the contract-level note on why
    ///         this differs from VaultTreasury.
    ///
    ///         The pool now pays this contract rather than `receiver` directly, because the
    ///         claim has to be divided before it can be paid: `marketReserve` is what belongs
    ///         to market vaults and is held back here. On a brand with no registered float the
    ///         two are identical and the issuer receives the whole claim, as before.
    ///
    ///         **The two numbers are not the same number, so the event carries both.** What
    ///         the pool paid this treasury is `claimed`; what left for `receiver` is `amount`,
    ///         which is the whole unreserved balance — the fresh claim, less the markets'
    ///         share, plus anything that reached this address by another route (a donation, a
    ///         manual top-up, dust the index rounded onto the issuer's side). They coincide
    ///         only on a brand with no float and no stray balance. Two further consequences of
    ///         the pool paying this contract, for anyone reading the chain: `totalYieldClaimed`
    ///         tracks `claimed` and not `amount`, and `SharedReservePool.YieldClaimed.receiver`
    ///         is now this treasury rather than the issuer's address, so yield must be
    ///         attributed from `Claimed` here rather than from the pool's event.
    /// @param receiver Address to receive the issuer's share of the claimed underlying
    /// @return amount  The amount paid to `receiver`
    function claim(address receiver) external onlyAdmin whenNotPaused returns (uint256 amount) {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 claimed = _pull();

        IERC20 underlying = IERC20(address(pool.asset()));
        uint256 held = underlying.balanceOf(address(this));
        uint256 reserved = marketReserve;
        amount = held > reserved ? held - reserved : 0;
        if (amount == 0) return 0;

        underlying.safeTransfer(receiver, amount);
        emit Claimed(claimed, amount, receiver);
    }

    /// @notice Name the `AssetMarketFactory` that may register market float here, or zero to
    ///         stop it. This is how a dollar's issuer consents to sharing its yield with the
    ///         markets that quote it; without it `totalFloat` stays zero and nothing changes.
    ///
    ///         **Consent is one-way: withdrawable, restorable, never transferable.** The first
    ///         non-zero address named is recorded in `namedFactory` and is the only non-zero
    ///         address this function will ever accept again; any other reverts
    ///         `FactoryAlreadyNamed`. `address(0)` is always accepted and always re-openable
    ///         back to `namedFactory`, so an issuer keeps a switch and a deferred graduation
    ///         keeps a way home.
    ///
    ///         The shape exists because `factory` is the sole gate on `registerFloat`, and
    ///         `registerFloat(vault, 0)` deregisters. A freely re-pointable `factory` would
    ///         therefore let this contract's own admin appoint an address it controls and end
    ///         a graduated market's yield share — or register a vault of its own with a huge
    ///         float and take nearly all of the split through the `min(totalFloat,
    ///         outstanding)` weight. That market's consideration for seeding this dollar is
    ///         liquidity it locked forever and cannot withdraw, and `LaunchFactory` gates every
    ///         launch quoted in this dollar on the guarantee — `_quoteReserve` reads this
    ///         `factory` at launch time and reverts `PairTokenFloatShareUnavailable` when it is
    ///         not the market factory — so the guarantee has to be enforced here rather than
    ///         promised here.
    ///
    ///         Revoking does not confiscate, and now the code says so: setting zero touches
    ///         neither `floatOf`, nor `totalFloat`, nor `marketReserve`, nor the index. Float
    ///         already registered keeps earning its share of every later pull and stays
    ///         claimable through `claimFloatShare`, which is not gated on `factory` at all.
    ///         Revoking only stops new markets being added — and stops
    ///         `AssetMarketFactory.retireMarket` deregistering one, which is why revocation is
    ///         reversible.
    function setFactory(address newFactory) external onlyAdmin {
        if (newFactory != address(0)) {
            address named = namedFactory;
            if (named == address(0)) {
                namedFactory = newFactory;
            } else if (named != newFactory) {
                revert FactoryAlreadyNamed();
            }
        }
        factory = newFactory;
        emit FactoryUpdated(newFactory);
    }

    // ─── Float share ─────────────────────────────────────────────────────

    /// @notice Record what `vault`'s market has locked of this brand. Only the factory named
    ///         by `setFactory` may call it; `0` deregisters a market.
    ///
    /// @dev    Order is load-bearing. `_pull` runs first so every wei earned under the OLD
    ///         weights is credited at those weights, and the vault is settled and paid before
    ///         its own weight moves, so a changed float never reprices what it already earned.
    function registerFloat(address vault, uint256 amount) external onlyFactory {
        if (vault == address(0)) revert ZeroAddress();

        _pull();
        _settleAndPay(vault);

        uint256 previous = floatOf[vault];
        if (previous != amount) {
            totalFloat = totalFloat - previous + amount;
            floatOf[vault] = amount;
        }
        emit FloatRegistered(vault, previous, amount);
    }

    /// @notice Pay the caller its share of this brand's yield. Called by a market's
    ///         `BrandFeeVault`, which forwards it to that market's liquidity providers.
    ///
    ///         A caller with no registered float is a no-op rather than a revert, so a vault
    ///         may harvest unconditionally without knowing whether its market was seeded here.
    function claimFloatShare() external whenNotPaused returns (uint256 amount) {
        if (floatOf[msg.sender] == 0) return 0;
        _pull();
        amount = _settleAndPay(msg.sender);
    }

    /// @notice Draw this brand's accrued yield out of the reserve and divide it.
    ///
    ///         The markets' part is `totalFloat / outstanding` of the claim — the share of the
    ///         brand's supply that is sitting in their pools — and it is credited to an index
    ///         rather than to each vault in turn, so the cost does not grow with the number of
    ///         markets. `totalFloat` is capped at `outstanding` so the markets can never be
    ///         owed more than the whole claim, which is otherwise reachable if holders redeem
    ///         the brand down below what the pools hold.
    ///
    /// @dev    **`marketReserve` is credited with what the index promised, not with the
    ///         markets' share.** `share` is what the split says the markets get; `delta` is
    ///         what an index scaled by `WAD` can actually express of it; `booked` is `delta`
    ///         read back out. Crediting the reserve with `share` while the index only ever
    ///         pays out `booked` would withhold `share - booked` from the issuer on every
    ///         pull without promising it to any vault, and both `claim` and `distribute`
    ///         subtract `marketReserve` in full, so that difference would be unspendable by
    ///         anyone for the life of the brand. `delta == 0` — reachable whenever
    ///         `float > share * WAD`, i.e. a small pull against a large 18-decimal float —
    ///         is the extreme of the same error: it would freeze the entire `share`. Booking
    ///         `booked` instead leaves the remainder on the issuer's side of the balance,
    ///         where `claim` can still reach it, and costs the markets at most one wei of
    ///         index resolution per pull.
    ///
    ///         **Conservation.** `delta = floor(share * WAD / float)` gives
    ///         `delta * float <= share * WAD`, so `booked = floor(delta * float / WAD)
    ///         <= share <= got`: the reserve is never credited more than was claimed. In the
    ///         other direction, a vault is paid `floor(f_v * delta / WAD)` for this pull, and
    ///         `sum_v f_v == float` over the vaults registered while `delta` was credited, so
    ///         `sum_v floor(f_v * delta / WAD) <= floor(float * delta / WAD) == booked` — the
    ///         sum of floors never exceeds the floor of the sum. Summing over pulls,
    ///         everything the vaults can ever withdraw is `<=` everything ever credited, so
    ///         `marketReserve` cannot underflow and the `min(amount, marketReserve)` cap in
    ///         `_settleAndPay` stays unreachable defence rather than live arithmetic. The
    ///         residual it leaves behind is now only the per-vault flooring — under one wei
    ///         per registered vault per pull, and exactly zero for a single vault, since it
    ///         is then the same floor computed twice.
    function _pull() private returns (uint256 got) {
        got = pool.claimYield(brandToken, address(this));
        if (got == 0) return 0;
        totalYieldClaimed += got;

        uint256 float = totalFloat;
        uint256 booked;
        if (float != 0) {
            uint256 outstanding = pool.outstandingOf(brandToken);
            if (outstanding != 0) {
                uint256 weight = float < outstanding ? float : outstanding;
                uint256 share = Math.mulDiv(got, weight, outstanding);
                uint256 delta = Math.mulDiv(share, WAD, float);
                if (delta != 0) {
                    cumulativePerFloat += delta;
                    booked = Math.mulDiv(delta, float, WAD);
                    marketReserve += booked;
                }
            }
        }
        emit FloatSharePulled(got, booked);
    }

    /// @dev Settle `vault` against the index and pay what it is owed. Capped at
    ///      `marketReserve`, which after the booking change in `_pull` is defence rather than
    ///      live arithmetic — see the conservation note there.
    function _settleAndPay(address vault) private returns (uint256 amount) {
        amount = Math.mulDiv(floatOf[vault], cumulativePerFloat - checkpointOf[vault], WAD);
        checkpointOf[vault] = cumulativePerFloat;
        if (amount == 0) return 0;

        uint256 reserved = marketReserve;
        if (amount > reserved) amount = reserved;
        marketReserve = reserved - amount;

        IERC20(address(pool.asset())).safeTransfer(vault, amount);
        emit FloatShareClaimed(vault, amount);
    }

    /// @notice Transfer any token held by this treasury out to a recipient. Admin only.
    ///
    ///         The reserve asset is capped at what is not `marketReserve`: without that, this
    ///         function would be a way around the split that `claim` enforces.
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
        if (token == address(pool.asset())) {
            uint256 held = IERC20(token).balanceOf(address(this));
            uint256 reserved = marketReserve;
            if (amount > (held > reserved ? held - reserved : 0)) revert ZeroAmount();
        }
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

    /// @dev Room for later versions to add state. Cut from forty-five: seven slots are spent
    ///      on the float share — `factory`, `floatOf`, `totalFloat`, `cumulativePerFloat`,
    ///      `checkpointOf`, `marketReserve` and `namedFactory`. New state is appended below
    ///      them, never above.
    uint256[38] private __gap;

    /// @notice This brand's pending (unclaimed) yield, including yield earned since the
    ///         pool's last on-chain settle.
    function pendingYield() external view returns (uint256) {
        return pool.pendingYield(brandToken);
    }

    /// @notice What `vault` would be paid by `claimFloatShare` right now, ignoring yield the
    ///         reserve has accrued but this treasury has not pulled yet.
    function pendingFloatShare(address vault) external view returns (uint256) {
        return Math.mulDiv(floatOf[vault], cumulativePerFloat - checkpointOf[vault], WAD);
    }
}
