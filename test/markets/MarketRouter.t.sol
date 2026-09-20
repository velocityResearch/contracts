// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

// Same note as in `MarketRouter`: this library sits outside the `v4-core/` remapping's root.
import {LiquidityAmounts} from "v4-core-test/utils/LiquidityAmounts.sol";

import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockAsset} from "./mocks/MockBuybackVenue.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev An asset that skims a share of every `transferFrom` and nothing off a plain `transfer`.
///      Stands in for the pull side of a badly-behaved token: the router asks for `assetIn` and
///      strictly less arrives, which is the case `_pullMeasured` exists for. Split from the
///      push-taxing variant on purpose — v4 is paid by transferring into the PoolManager
///      between `sync` and `settle`, so a token that taxes `transfer` cannot be settled at all
///      and no amount of measuring in this router would change that.
contract PullTaxedAsset is ERC20 {
    uint256 public constant TAX_BPS = 100; // 1%

    address public immutable sink;

    /// @dev Payers the tax is not charged to. Exists only so this market can be given depth at
    ///      all: a v4 position is settled with a `transferFrom` — Permit2's, under the real
    ///      PositionManager — so a token that taxes `transferFrom` under-delivers to the
    ///      PoolManager and the whole unlock reverts, exactly as `SendTaxedAsset` already
    ///      cannot be settled by the router's plain `transfer`. That is the correct failure,
    ///      not a case to work around, and it is asserted directly further down. What this
    ///      market exists to test is the *sell* leg's `_pullMeasured`, so the harness stocks
    ///      the pool tax-free and leaves the tax in place for every path under test.
    mapping(address => bool) public taxFree;

    constructor(address _sink) ERC20("Pull Taxed Asset", "PULLTAX") {
        sink = _sink;
    }

    function setTaxFree(address payer, bool on) external {
        taxFree[payer] = on;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        if (taxFree[from]) {
            _transfer(from, to, value);
            return true;
        }
        uint256 tax = value * TAX_BPS / 10_000;
        _transfer(from, sink, tax);
        _transfer(from, to, value - tax);
        return true;
    }
}

/// @dev The mirror image: a share is skimmed off every plain `transfer` and nothing off
///      `transferFrom`. This is what puts a tax on the last hop of a buy — the router handing
///      the asset to the trader — which is the hop `minAssetOut` has to be measured after.
contract SendTaxedAsset is ERC20 {
    uint256 public constant TAX_BPS = 100; // 1%

    address public immutable sink;

    constructor(address _sink) ERC20("Send Taxed Asset", "SENDTAX") {
        sink = _sink;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        uint256 tax = value * TAX_BPS / 10_000;
        _transfer(_msgSender(), sink, tax);
        _transfer(_msgSender(), to, value - tax);
        return true;
    }
}

/// @dev `MockYieldSource` with a switch that makes every withdrawal come back short.
///
///      This is not a contrivance: a real source's share↔asset floor division can leave the
///      reserve a wei or two below book value, `SharedReservePool.redeem` caps the payout at
///      what it actually holds rather than reverting, and it therefore returns less than it was
///      asked for. `shortBy` is set to 2 because `_recallIfNeeded` already pads its recall by
///      one — so two is the smallest number that survives the pad and reaches the payout.
contract ShortingYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    uint256 public index = 1e18;
    uint256 public shortBy;

    mapping(address => mapping(address => uint256)) public principalOf;
    mapping(address => uint256) public totalPrincipalOf;

    function setShortBy(uint256 amount) external {
        shortBy = amount;
    }

    function deposit(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 principal = amount * 1e18 / index;
        principalOf[asset][msg.sender] += principal;
        totalPrincipalOf[asset] += principal;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 principalNeeded = amount * 1e18 / index;
        uint256 userPrincipal = principalOf[asset][msg.sender];
        if (principalNeeded > userPrincipal) {
            principalNeeded = userPrincipal;
            amount = principalNeeded * index / 1e18;
        }

        principalOf[asset][msg.sender] -= principalNeeded;
        totalPrincipalOf[asset] -= principalNeeded;

        uint256 paid = amount > shortBy ? amount - shortBy : 0;
        IERC20(asset).safeTransfer(to, paid);
        return paid;
    }

    function balanceOf(address asset) external view returns (uint256) {
        return principalOf[asset][msg.sender] * index / 1e18;
    }

    function totalAssets(address asset) external view returns (uint256) {
        return totalPrincipalOf[asset] * index / 1e18;
    }

    function withdrawable(address asset, address consumer) external view returns (uint256) {
        uint256 owed = principalOf[asset][consumer] * index / 1e18;
        return owed > shortBy ? owed - shortBy : 0;
    }
}

/// @dev **A stand-in for Permit2, not Permit2.** Only the two calls this router's path touches:
///      `approve`, which is how the router grants the PositionManager a spending allowance, and
///      `transferFrom`, which is how the PositionManager then collects. Real Permit2 also does
///      signatures, nonces, batches and lockdowns; none of that is on this path.
///
///      The allowance is enforced the way the real one is — an amount and an expiry, with
///      `type(uint160).max` treated as unlimited — so an approval the router forgot to set, or
///      set for the wrong spender, still fails here.
contract StandInPermit2 {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => Allowance))) public allowance;

    error InsufficientAllowance();
    error AllowanceExpired();

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender] =
            Allowance({amount: amount, expiration: expiration, nonce: 0});
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = allowance[from][token][msg.sender];
        if (a.expiration < block.timestamp) revert AllowanceExpired();
        if (a.amount < amount) revert InsufficientAllowance();
        if (a.amount != type(uint160).max) a.amount -= amount;

        SafeERC20.safeTransferFrom(IERC20(token), from, to, amount);
    }
}

/// @dev **A stand-in for Uniswap's `PositionManager`, not the real one.** The real contract
///      cannot be compiled into this repo: `lib/v4-periphery` vendors its own v4-core and its
///      own OpenZeppelin, and `permit2` pins `solc =0.8.17` — pulling either in breaks the
///      build for the whole project. So the offline suite talks to this, and the real
///      integration is covered against the deployed contracts in
///      `test/markets/MarketRouterV4Fork.t.sol`, which is where "the seeder really can withdraw"
///      is actually proved.
///
///      What it does faithfully, because these are the parts the router's correctness depends
///      on:
///        - decodes exactly the calldata the real one decodes, from the same
///          `(bytes actions, bytes[] params)` envelope, and rejects anything but
///          `MINT_POSITION` + `SETTLE_PAIR` — so a mis-encoded mint fails here rather than
///          silently passing;
///        - enforces the deadline, and `amount0Max`/`amount1Max`;
///        - adds the liquidity to the **real** `PoolManager`, one position per token id (the
///          salt is the id), so the amounts actually charged, the dust left over, and the
///          pool's depth are Uniswap's own arithmetic and not this mock's opinion;
///        - pays for it by pulling from the caller through Permit2, so the router's two-step
///          approval is genuinely required;
///        - records ERC-721-style ownership of each id, and lets only that owner burn.
///
///      What it does not do: transfers, approvals, permits, subscribers, `tokenURI`, fee
///      collection, or any of the slippage machinery beyond the two maxima. Nothing on this
///      path uses them.
contract StandInPositionManager is IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint8 private constant MINT_POSITION = 0x02;
    uint8 private constant SETTLE_PAIR = 0x0d;
    uint8 private constant DECREASE_LIQUIDITY = 0x01;
    uint8 private constant TAKE_PAIR = 0x11;

    /// @dev v4-periphery's own mask: the packed `PositionInfo` keeps only the highest 200 bits
    ///      of the pool id.
    uint256 private constant MASK_UPPER_200_BITS =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000;

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    IPoolManager private immutable manager;
    StandInPermit2 private immutable permit2;

    /// @dev Starts at 1, exactly as the real one does: id 0 is never a position.
    uint256 public nextTokenId = 1;

    mapping(uint256 => Position) private _positions;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(address => uint256) public balanceOf;

    error DeadlinePassed();
    error UnexpectedActions();
    error MaximumAmountExceeded();
    error NotOwner();
    error OnlyPoolManager();
    error NotApproved();
    error MinimumAmountNotMet();

    constructor(IPoolManager _manager, StandInPermit2 _permit2) {
        manager = _manager;
        permit2 = _permit2;
    }

    function poolManager() external view returns (address) {
        return address(manager);
    }

    function positionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    /// @notice ERC-721 approval, enough of it for the one caller that needs it: a staking
    ///         contract that pulls a position with `transferFrom`.
    function approve(address to, uint256 tokenId) external {
        if (ownerOf[tokenId] != msg.sender) revert NotOwner();
        getApproved[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    /// @notice Move a position. The real one is `onlyIfApproved` and drops any subscriber on the
    ///         way through; there are no subscribers here, so this is the authorisation half.
    function transferFrom(address from, address to, uint256 tokenId) external {
        address owner_ = ownerOf[tokenId];
        if (owner_ != from) revert NotOwner();
        if (
            msg.sender != owner_ && msg.sender != getApproved[tokenId]
                && !isApprovedForAll[owner_][msg.sender]
        ) revert NotApproved();

        delete getApproved[tokenId];
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
        ownerOf[tokenId] = to;
    }

    /// @notice The pool a position is in, and its range packed the way v4-periphery packs it:
    ///         `200 bits truncated poolId | 24 bits tickUpper | 24 bits tickLower | 8 bits
    ///         hasSubscriber`. Packed faithfully, truncation included, because a consumer that
    ///         compares the packed id against a v4-core `PoolId` must fail here too.
    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory, uint256)
    {
        Position memory p = _positions[tokenId];
        uint256 info = uint256(PoolId.unwrap(p.key.toId())) & MASK_UPPER_200_BITS;
        info |= uint256(uint24(p.tickUpper)) << 32;
        info |= uint256(uint24(p.tickLower)) << 8;
        return (p.key, info);
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        if (block.timestamp > deadline) revert DeadlinePassed();

        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        if (actions.length != 2 || params.length != 2) revert UnexpectedActions();

        if (uint8(actions[0]) == MINT_POSITION && uint8(actions[1]) == SETTLE_PAIR) {
            _mint(params);
        } else if (uint8(actions[0]) == DECREASE_LIQUIDITY && uint8(actions[1]) == TAKE_PAIR) {
            _decrease(params);
        } else {
            revert UnexpectedActions();
        }
    }

    function _mint(bytes[] memory params) private {
        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner_,
        ) = abi.decode(
            params[0], (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes)
        );

        // `SETTLE_PAIR`'s operands must name this pool's own two currencies, or the real one
        // would settle the wrong deltas. Checked rather than ignored.
        (Currency c0, Currency c1) = abi.decode(params[1], (Currency, Currency));
        if (
            Currency.unwrap(c0) != Currency.unwrap(key.currency0)
                || Currency.unwrap(c1) != Currency.unwrap(key.currency1)
        ) {
            revert UnexpectedActions();
        }

        uint256 tokenId = nextTokenId++;
        _positions[tokenId] = Position({
            key: key, tickLower: tickLower, tickUpper: tickUpper, liquidity: uint128(liquidity)
        });
        ownerOf[tokenId] = owner_;
        balanceOf[owner_] += 1;

        (uint256 paid0, uint256 paid1) =
            _modify(key, tickLower, tickUpper, int256(liquidity), tokenId, msg.sender, address(0));

        if (paid0 > amount0Max || paid1 > amount1Max) revert MaximumAmountExceeded();
    }

    /// @dev `DECREASE_LIQUIDITY` + `TAKE_PAIR`. A decrease of zero is how v4 settles a
    ///      position's accrued fees without touching its liquidity, and the amounts taken are
    ///      the real `PoolManager`'s arithmetic, not this mock's opinion of it.
    function _decrease(bytes[] memory params) private {
        (uint256 tokenId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min,) =
            abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
        (Currency c0, Currency c1, address recipient) =
            abi.decode(params[1], (Currency, Currency, address));

        Position memory p = _positions[tokenId];
        if (
            Currency.unwrap(c0) != Currency.unwrap(p.key.currency0)
                || Currency.unwrap(c1) != Currency.unwrap(p.key.currency1)
        ) {
            revert UnexpectedActions();
        }
        // The real one is `onlyIfApproved(msgSender(), tokenId)`.
        if (
            msg.sender != ownerOf[tokenId] && msg.sender != getApproved[tokenId]
                && !isApprovedForAll[ownerOf[tokenId]][msg.sender]
        ) revert NotApproved();

        _positions[tokenId].liquidity = uint128(uint256(p.liquidity) - liquidity);

        (uint256 taken0, uint256 taken1) = _modify(
            p.key, p.tickLower, p.tickUpper, -int256(liquidity), tokenId, address(0), recipient
        );

        if (taken0 < amount0Min || taken1 < amount1Min) revert MinimumAmountNotMet();
    }

    /// @notice Close a position and send both sides to `recipient`. The real contract spells
    ///         this `BURN_POSITION` + `TAKE_PAIR`; the offline suite only needs the effect.
    function burn(uint256 tokenId, address recipient) external {
        if (ownerOf[tokenId] != msg.sender) revert NotOwner();

        Position memory p = _positions[tokenId];
        _positions[tokenId].liquidity = 0;
        balanceOf[msg.sender] -= 1;
        ownerOf[tokenId] = address(0);

        _modify(
            p.key,
            p.tickLower,
            p.tickUpper,
            -int256(uint256(p.liquidity)),
            tokenId,
            address(0),
            recipient
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyPoolManager();

        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            int256 liquidityDelta,
            uint256 tokenId,
            address payer,
            address recipient
        ) = abi.decode(data, (PoolKey, int24, int24, int256, uint256, address, address));

        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(tokenId)
            }),
            ""
        );

        uint256 paid0 = _resolve(key.currency0, delta.amount0(), payer, recipient);
        uint256 paid1 = _resolve(key.currency1, delta.amount1(), payer, recipient);
        return abi.encode(paid0, paid1);
    }

    function _modify(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        uint256 tokenId,
        address payer,
        address recipient
    ) private returns (uint256 paid0, uint256 paid1) {
        bytes memory out = manager.unlock(
            abi.encode(key, tickLower, tickUpper, liquidityDelta, tokenId, payer, recipient)
        );
        (paid0, paid1) = abi.decode(out, (uint256, uint256));
    }

    /// @dev A debt is paid by pulling from `payer` **through Permit2** — the whole reason the
    ///      router has to approve twice. A credit is taken out to `recipient`.
    function _resolve(Currency currency, int128 amount, address payer, address recipient)
        private
        returns (uint256 moved)
    {
        if (amount < 0) {
            moved = uint256(uint128(-amount));
            manager.sync(currency);
            permit2.transferFrom(payer, address(manager), uint160(moved), Currency.unwrap(currency));
            manager.settle();
        } else if (amount > 0) {
            moved = uint256(uint128(amount));
            manager.take(currency, recipient, moved);
        }
    }
}

/// @title MarketRouterTest
/// @notice The three trading paths, the permanent full-range position, and the properties that
///         survived the move off Uniswap V3.
///
///         **The venue is a real `PoolManager` behind the real `ProtocolFeeHook`.** Price
///         impact, the LP fee and the hook's skim off the output are Uniswap's own arithmetic
///         here, not a mock's opinion of it — which is the only way "the slippage bound is
///         what protects the trader from the skim" is actually being tested rather than
///         asserted.
///
///         **Markets come from the real `AssetMarketFactory`.** The router reads a market's
///         `PoolKey` from it on every call, so a fixture that invented its own keys would test
///         the router against a pool the rest of the system does not believe in.
///
/// @dev    Time is always read with `vm.getBlockTimestamp()`, never cached from
///         `block.timestamp`. This project builds with `via_ir`, which treats TIMESTAMP as pure
///         and re-reads it, so a local captured before a `vm.warp` is not the snapshot it looks
///         like.
contract MarketRouterTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Venue ───────────────────────────────────────────────────────────

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    /// @dev Non-zero on purpose: every swap in this suite pays the hook's skim, exactly as a
    ///      live market would. Every trade the router makes is exact-input, so that skim comes
    ///      off the OUTPUT currency — the unspecified leg — and is charged in `afterSwap` on
    ///      what the pool actually filled.
    uint24 constant PROTOCOL_FEE_PIPS = 1000; // 0.10%

    PoolManager manager;
    ProtocolFeeHook hook;
    PoolModifyLiquidityTest lpRouter;

    /// @dev Stand-ins, deliberately — see the notes on the two contracts above, and
    ///      `test/markets/MarketRouterV4Fork.t.sol` for the same path run against the real
    ///      `PositionManager` and the real Permit2 deployed on Robinhood Chain. What is proved
    ///      here is the calldata this router builds, the minimums and refunds it enforces, and
    ///      who it names as the NFT's owner; what is proved there is that Uniswap's own
    ///      contracts agree.
    StandInPermit2 permit2;
    StandInPositionManager posm;

    // ─── The stack under test ────────────────────────────────────────────

    MockUSDC usdg;
    ShortingYieldSource yieldSource;
    SharedReservePool reserve;
    AssetMarketFactory factory;
    MarketRouter router;

    MockAsset asset;
    MockAsset otherAsset;
    PullTaxedAsset pullTaxed;
    SendTaxedAsset sendTaxed;

    uint256 marketId;
    uint256 otherMarketId;
    uint256 pullTaxedMarketId;
    uint256 sendTaxedMarketId;

    address owner = address(0x0AD01);
    address protocolTreasury = address(0xF33);
    address creator = address(0x0FE);
    address lp = address(0x11B0);
    address trader = address(0x7AAD);
    address stranger = address(0x57A);
    address taxSink = address(0x7A5);

    /// @dev One whole asset costs one whole brand unit. The two sides have different decimals
    ///      (6 and 18), which the factory's own price derivation is responsible for; keeping the
    ///      human price at 1 makes every expectation below readable.
    uint256 constant PRICE_E18 = 1e18;

    uint256 constant SEED_USDG = 500_000e6;
    uint256 constant SEED_ASSET = 500_000e18;

    function setUp() public {
        _deployUpgradeBase();
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        hook = _deployHook();

        usdg = new MockUSDC();
        yieldSource = new ShortingYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), owner);

        // The periphery pair is built before the factory, which is new: the factory takes the
        // `PositionManager` it hands to every market's reward distributor, and rejects one
        // bound to a different `PoolManager` than its own.
        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        factory = _deployFactory(
            reserve,
            IPoolManager(address(manager)),
            hook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(0), // verification disabled; nothing here turns on it
            0, // the whole protocol cut of yield stays with the market
            owner
        );

        vm.startPrank(owner);
        hook.setRegistrar(address(factory));
        factory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        router = _deployRouter(
            reserve, factory, IPositionManagerV4(address(posm)), IPermit2(address(permit2)), owner
        );

        asset = new MockAsset();
        otherAsset = new MockAsset();
        pullTaxed = new PullTaxedAsset(taxSink);
        sendTaxed = new SendTaxedAsset(taxSink);

        marketId = _createMarket("Cashcat Dollar", "catUSD", address(asset));
        otherMarketId = _createMarket("Dogpark Dollar", "dogUSD", address(otherAsset));
        pullTaxedMarketId = _createMarket("Pulltax Dollar", "pulUSD", address(pullTaxed));
        sendTaxedMarketId = _createMarket("Sendtax Dollar", "senUSD", address(sendTaxed));

        _seedThroughRouter(marketId, SEED_USDG, SEED_ASSET);
        _seedThroughRouter(otherMarketId, SEED_USDG, SEED_ASSET);

        // Neither taxing asset can be seeded through the router, and for the same reason:
        // a v4 position is paid for by moving tokens into the PoolManager between `sync` and
        // `settle`, and a token that skims either kind of transfer leaves the manager short, so
        // `settle` reverts the whole unlock. `SendTaxedAsset` always failed that way. The
        // *pull*-taxing one now fails it too, which is new: the router used to settle with a
        // plain `transfer` of its own, and settlement is now Permit2's `transferFrom` on the
        // PositionManager's behalf. That is the correct failure rather than something to route
        // around — it is asserted directly in
        // `test_aPullTaxingAssetCannotBeSeededBecausePermit2SettlesWithTransferFrom` — so both
        // markets are stocked here through a path that does not tax the harness. What they
        // exist to test is the sell leg's `_pullMeasured` and the buy leg's last hop, not how
        // their depth got there.
        pullTaxed.setTaxFree(address(this), true);
        _seedDirect(pullTaxedMarketId, SEED_USDG, SEED_ASSET);
        _seedDirect(sendTaxedMarketId, SEED_USDG, SEED_ASSET);
    }

    // ─── Fixtures ────────────────────────────────────────────────────────

    /// @dev A v4 hook's permission bits live in the low 14 bits of its own address, so the
    ///      address is not a free choice. `deployCodeTo` writes the contract where we want it
    ///      and still runs the constructor, so `Hooks.validateHookPermissions` still executes —
    ///      the standard way to skip salt mining without skipping the check mining satisfies.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x7777 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(manager)), owner);
    }

    /// @dev Two steps, and only the first is privileged: the owner lists the asset with the
    ///      terms every market on it gets, and then anyone may open the market. The prank
    ///      fixes who this suite's markets record as their `creator`.
    function _createMarket(string memory name, string memory symbol, address assetToken)
        internal
        returns (uint256 id)
    {
        _approveAsset(
            factory, assetToken, FEE, PRICE_E18, FIXTURE_MIN_OBSERVATION_CARDINALITY, name, symbol
        );
        vm.prank(creator);
        (id,,,,) = factory.createMarket(assetToken, address(0));
    }

    function _mintAsset(address token, address to, uint256 amount) internal {
        MockAsset(token).mint(to, amount);
    }

    function _seedThroughRouter(uint256 id, uint256 usdgAmount, uint256 assetAmount)
        internal
        returns (uint256 tokenId, uint128 liquidityAdded)
    {
        return _seedThroughRouterAs(lp, id, usdgAmount, assetAmount);
    }

    function _seedThroughRouterAs(
        address seeder,
        uint256 id,
        uint256 usdgAmount,
        uint256 assetAmount
    ) internal returns (uint256 tokenId, uint128 liquidityAdded) {
        AssetMarketFactory.Market memory m = factory.market(id);
        usdg.mint(seeder, usdgAmount);
        _mintAsset(m.asset, seeder, assetAmount);

        vm.startPrank(seeder);
        // `seedLiquidity` takes the pool's own stable side now, so the seeder mints brandUSD
        // first — 1:1 and free at the reserve — exactly as a person would before providing.
        usdg.approve(address(reserve), usdgAmount);
        uint256 brandAmount = reserve.mint(m.brandToken, usdgAmount, seeder);
        IERC20(m.brandToken).approve(address(router), brandAmount);
        IERC20(m.asset).approve(address(router), assetAmount);
        (tokenId, liquidityAdded,,) =
            router.seedLiquidity(id, brandAmount, assetAmount, 0, 0, _deadline());
        vm.stopPrank();
    }

    /// @dev Close a position the way its owner would once the router is out of the picture:
    ///      straight to the PositionManager, with no router call anywhere in here. That is the
    ///      claim being tested — the router is not on the exit path at all.
    function _burnPositionAs(address owner_, uint256 tokenId) internal {
        vm.prank(owner_);
        posm.burn(tokenId, owner_);
    }

    /// @dev Full-range liquidity added through v4's own test router, for the one market the
    ///      production router cannot settle into.
    function _seedDirect(uint256 id, uint256 usdgAmount, uint256 assetAmount) internal {
        AssetMarketFactory.Market memory m = factory.market(id);
        PoolKey memory key = factory.poolKeyOf(id);

        usdg.mint(address(this), usdgAmount);
        usdg.approve(address(reserve), usdgAmount);
        reserve.mint(m.brandToken, usdgAmount, address(this));
        _mintAsset(m.asset, address(this), assetAmount);

        IERC20(m.brandToken).approve(address(lpRouter), type(uint256).max);
        IERC20(m.asset).approve(address(lpRouter), type(uint256).max);

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (uint256 amount0, uint256 amount1) =
            m.brandToken < m.asset ? (usdgAmount, assetAmount) : (assetAmount, usdgAmount);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _deadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 1 hours;
    }

    function _fundTraderUsdg(uint256 amount) internal {
        usdg.mint(trader, amount);
        vm.prank(trader);
        usdg.approve(address(router), amount);
    }

    function _fundTraderAsset(address token, uint256 amount) internal {
        _mintAsset(token, trader, amount);
        vm.prank(trader);
        IERC20(token).approve(address(router), amount);
    }

    function _brandOf(uint256 id) internal view returns (address) {
        return factory.market(id).brandToken;
    }

    // ─── The buy paths ───────────────────────────────────────────────────

    function test_buyWithUsdgMintsBrandFloatAndDeliversTheAssetThroughTheV4Pool() public {
        uint256 usdgIn = 1_000e6;
        _fundTraderUsdg(usdgIn);

        PoolKey memory key = factory.poolKeyOf(marketId);
        uint256 poolBrandBefore = IERC20(_brandOf(marketId)).balanceOf(address(manager));

        vm.prank(trader);
        uint256 assetOut = router.buyWithUsdg(marketId, usdgIn, 0, trader, _deadline());

        assertGt(assetOut, 0, "the trade filled");
        assertEq(asset.balanceOf(trader), assetOut, "the trader holds exactly what was reported");
        assertEq(usdg.balanceOf(trader), 0, "and paid the whole input");

        // Below the 1:1 curve price, because the LPs took their fee on the way through and the
        // hook took its pips out of what came back. This is the gap `minAssetOut` bounds.
        assertLt(assetOut, 1_000e18, "output sits under the pure curve");
        assertGt(assetOut, 990e18, "but only by fees and impact");

        // The USDG never reaches the pool: it is minted into the brand first, so the stable
        // side of the market is float earning in the reserve.
        assertEq(usdg.balanceOf(address(manager)), 0, "no USDG in the pool");
        assertGt(
            IERC20(_brandOf(marketId)).balanceOf(address(manager)),
            poolBrandBefore,
            "the pool's stable side grew in brandUSD"
        );

        // Nothing is left behind in the router on a clean full fill.
        assertEq(IERC20(_brandOf(marketId)).balanceOf(address(router)), 0, "no brand dust");
        assertEq(asset.balanceOf(address(router)), 0, "no asset dust");

        // The hook took its cut out of the ASSET — the unspecified leg of this exact-input
        // swap — which is why the trader's output is short of the curve. It is booked to this
        // market's own fee vault, not netted out of the trade. The equality is what pins the
        // rate a trader actually pays: exactly the hook's pips of what the pool produced, and
        // nothing off the brand going in.
        uint256 protocolFee = hook.pendingFees(key.toId(), Currency.wrap(address(asset)));
        assertEq(
            hook.pendingFees(key.toId(), Currency.wrap(_brandOf(marketId))),
            0,
            "nothing is skimmed off the input leg any more"
        );
        assertEq(
            protocolFee,
            ((assetOut + protocolFee) * PROTOCOL_FEE_PIPS) / 1_000_000,
            "the protocol took exactly its pips of the filled output"
        );
    }

    function test_buyWithBrandCrossesAnotherMarketsBrandOneForOneBeforeSwapping() public {
        address foreignBrand = _brandOf(otherMarketId);
        uint256 amountIn = 1_000e6;

        usdg.mint(trader, amountIn);
        vm.startPrank(trader);
        usdg.approve(address(reserve), amountIn);
        reserve.mint(foreignBrand, amountIn, trader);
        IERC20(foreignBrand).approve(address(router), amountIn);
        uint256 assetOut =
            router.buyWithBrand(marketId, foreignBrand, amountIn, 0, trader, _deadline());
        vm.stopPrank();

        assertGt(assetOut, 0, "a foreign brand reached this market's pool");
        assertEq(asset.balanceOf(trader), assetOut, "and the asset landed with the trader");
        assertEq(IERC20(foreignBrand).balanceOf(trader), 0, "the whole foreign balance crossed");

        // The cross itself is free: the input that reached the pool is the full 1_000e6, so the
        // only value lost between the two brands is the pool's own fees.
        assertGt(assetOut, 990e18, "crossing brands cost nothing but the swap");
    }

    function test_buyWithBrandRejectsATokenTheReserveDoesNotKnow() public {
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketRouter.BrandNotInMarketReserve.selector, address(asset), address(reserve)
            )
        );
        router.buyWithBrand(marketId, address(asset), 1e6, 0, trader, _deadline());
    }

    // ─── The sell path ───────────────────────────────────────────────────

    function test_sellForBrandSwapsBackAndPaysOutInTheMarketsOwnBrand() public {
        uint256 assetIn = 1_000e18;
        _fundTraderAsset(address(asset), assetIn);
        IERC20 brand = IERC20(_brandOf(marketId));

        vm.prank(trader);
        uint256 brandOut = router.sellForBrand(marketId, assetIn, 0, trader, _deadline());

        assertGt(brandOut, 0, "the sale filled");
        assertEq(brand.balanceOf(trader), brandOut, "and paid out in the brand");
        assertEq(usdg.balanceOf(trader), 0, "no leg redeemed to USDG on the trader's behalf");
        assertLt(brandOut, 1_000e6, "under the curve by fees and impact");
        assertGt(brandOut, 990e6, "but only by that");

        assertEq(brand.balanceOf(address(router)), 0, "no brand dust");
        assertEq(asset.balanceOf(address(router)), 0, "no asset dust");
    }

    /// @notice The half of the old round trip that moved out of the router: a seller who wants
    ///         the reserve asset redeems the brand themselves, 1:1 and without asking anyone.
    function test_aSellerCanRedeemTheBrandTheySoldIntoForUsdgOneToOne() public {
        uint256 assetIn = 1_000e18;
        _fundTraderAsset(address(asset), assetIn);
        address brand = _brandOf(marketId);

        vm.startPrank(trader);
        uint256 brandOut = router.sellForBrand(marketId, assetIn, 0, trader, _deadline());
        uint256 usdgOut = reserve.redeem(brand, brandOut, trader);
        vm.stopPrank();

        assertEq(usdgOut, brandOut, "par, with no fee and no slippage");
        assertEq(usdg.balanceOf(trader), usdgOut, "and it landed");
        assertEq(IERC20(brand).balanceOf(trader), 0, "the brand was spent doing it");
    }

    /// @notice The one-call version of the round trip above, for a caller who has priced the
    ///         exit: swap, then redeem, with the reserve's fee paid and the minimum checked on
    ///         what actually lands.
    function test_sellForUsdgSwapsAndRedeemsInOneCallNetOfTheRedemptionFee() public {
        vm.prank(owner);
        reserve.setRedemptionFee(20);
        // Announced, not applied. Serve the hour before anything is quoted so the exit the
        // caller prices and the exit they get are the same fee.
        vm.warp(reserve.redemptionFeeEffectiveAt());
        reserve.commitRedemptionFee();

        uint256 assetIn = 1_000e18;
        _fundTraderAsset(address(asset), assetIn);
        IERC20 brand = IERC20(_brandOf(marketId));

        // The brand leg, quoted the way the caller would: the same sale, stopped one leg short.
        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        uint256 brandOut = router.sellForBrand(marketId, assetIn, 0, trader, _deadline());
        vm.revertToState(snap);
        uint256 expected = reserve.previewRedeem(brandOut);

        vm.prank(trader);
        uint256 usdgOut = router.sellForUsdg(marketId, assetIn, expected, trader, _deadline());

        assertEq(usdgOut, expected, "par less the reserve's fee");
        assertLt(usdgOut, brandOut, "the fee was actually charged");
        assertEq(usdg.balanceOf(trader), usdgOut, "and it landed with the receiver");
        assertEq(brand.balanceOf(trader), 0, "no brand reached the seller");
        assertEq(brand.balanceOf(address(router)), 0, "no brand dust");
        assertEq(asset.balanceOf(address(router)), 0, "no asset dust");
    }

    /// @notice A reserve that cannot pay the minimum must refuse **before** the brand is gone.
    ///         `SharedReservePool._redeem` burns first and then pays what it can, so a router
    ///         that only checked the receiver's balance afterwards would have let the seller
    ///         accept a payout for brand that no longer exists. `sellForUsdg` hands the bound
    ///         down instead, and the pool's own `InsufficientPayout` unwinds the burn with the
    ///         transaction.
    function test_sellForUsdgUnwindsTheBurnWhenTheReserveCannotPayTheMinimum() public {
        uint256 assetIn = 1_000e18;
        _fundTraderAsset(address(asset), assetIn);
        address brand = _brandOf(marketId);

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        uint256 par = router.sellForUsdg(marketId, assetIn, 0, trader, _deadline());
        vm.revertToState(snap);

        // The adapter comes back two short of what was asked; the pool's `+1` recall pad
        // absorbs one, so the payout lands a unit under par.
        yieldSource.setShortBy(2);
        uint256 supplyBefore = IERC20(brand).totalSupply();

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(SharedReservePool.InsufficientPayout.selector, par - 1, par)
        );
        router.sellForUsdg(marketId, assetIn, par, trader, _deadline());

        assertEq(IERC20(brand).totalSupply(), supplyBefore, "no brand was retired");
        assertEq(asset.balanceOf(trader), assetIn, "and the seller still holds their asset");
        assertEq(usdg.balanceOf(trader), 0, "having received nothing");
    }

    /// @notice The same call with no minimum is the caller saying they will take whatever the
    ///         reserve can raise. It is the one way to reach the short payout, and it is a
    ///         choice rather than a surprise.
    function test_sellForUsdgAcceptsAShortPayoutOnlyWhenTheCallerAsksForNoMinimum() public {
        uint256 assetIn = 1_000e18;
        _fundTraderAsset(address(asset), assetIn);

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        uint256 par = router.sellForUsdg(marketId, assetIn, 0, trader, _deadline());
        vm.revertToState(snap);

        yieldSource.setShortBy(2);
        vm.prank(trader);
        assertEq(
            router.sellForUsdg(marketId, assetIn, 0, trader, _deadline()),
            par - 1,
            "a unit under par, taken knowingly"
        );
    }

    // ─── Slippage and deadlines ──────────────────────────────────────────

    /// @notice A trader who quotes off the pure curve and ignores the hook's skim asks for more
    ///         than the pool can ever give and is refused. That is the protection working, not
    ///         a mispriced quote: the skim is never netted out inside the router.
    function test_buyRevertsWhenTheCurvePriceIsDemandedWithoutTheSkim() public {
        uint256 usdgIn = 1_000e6;
        _fundTraderUsdg(usdgIn);

        vm.prank(trader);
        vm.expectPartialRevert(MarketRouter.InsufficientOutput.selector);
        router.buyWithUsdg(marketId, usdgIn, 1_000e18, trader, _deadline());
    }

    function test_buyRevertsWithTheReceivedAmountWhenTheBoundIsMissed() public {
        uint256 usdgIn = 1_000e6;
        _fundTraderUsdg(usdgIn);

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        uint256 achievable = router.buyWithUsdg(marketId, usdgIn, 0, trader, _deadline());
        vm.revertToState(snap);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketRouter.InsufficientOutput.selector, achievable, achievable + 1
            )
        );
        router.buyWithUsdg(marketId, usdgIn, achievable + 1, trader, _deadline());
    }

    function test_sellRevertsWhenTheFillMissesTheSlippageBound() public {
        uint256 assetIn = 1_000e18;
        _fundTraderAsset(address(asset), assetIn);

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        uint256 achievable = router.sellForBrand(marketId, assetIn, 0, trader, _deadline());
        vm.revertToState(snap);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketRouter.InsufficientOutput.selector, achievable, achievable + 1
            )
        );
        router.sellForBrand(marketId, assetIn, achievable + 1, trader, _deadline());
    }

    function test_everyEntryPointRejectsAnExpiredDeadline() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 stale = vm.getBlockTimestamp() - 1;

        _fundTraderUsdg(10e6);
        _fundTraderAsset(address(asset), 10e18);

        // Resolved up front: `expectRevert` arms the very next call, and a view read buried in
        // an argument list would be the call it caught.
        address foreignBrand = _brandOf(otherMarketId);

        vm.startPrank(trader);
        vm.expectRevert(MarketRouter.DeadlineExpired.selector);
        router.buyWithUsdg(marketId, 10e6, 0, trader, stale);

        vm.expectRevert(MarketRouter.DeadlineExpired.selector);
        router.buyWithBrand(marketId, foreignBrand, 10e6, 0, trader, stale);

        vm.expectRevert(MarketRouter.DeadlineExpired.selector);
        router.sellForBrand(marketId, 10e18, 0, trader, stale);

        vm.expectRevert(MarketRouter.DeadlineExpired.selector);
        router.seedLiquidity(marketId, 10e6, 10e18, 0, 0, stale);
        vm.stopPrank();
    }

    // ─── Measured amounts, not assumed ones ──────────────────────────────

    function test_sellMeasuresWhatActuallyArrivedFromAnAssetThatTaxesTransferFrom() public {
        uint256 assetIn = 1_000e18;
        uint256 expectedArrival = assetIn - assetIn * pullTaxed.TAX_BPS() / 10_000;

        _fundTraderAsset(address(pullTaxed), assetIn);
        uint256 sinkBefore = pullTaxed.balanceOf(taxSink);

        vm.prank(trader);
        uint256 brandOut = router.sellForBrand(pullTaxedMarketId, assetIn, 0, trader, _deadline());

        assertEq(
            pullTaxed.balanceOf(taxSink) - sinkBefore,
            assetIn - expectedArrival,
            "the tax was taken"
        );
        assertEq(pullTaxed.balanceOf(address(router)), 0, "the router kept none of it");

        // The proceeds correspond to the 990 that arrived, not the 1000 that was asked for. A
        // router that had trusted `assetIn` would have tried to swap ten it never held.
        assertLt(brandOut, expectedArrival / 1e12, "priced off what arrived");
        assertGt(brandOut, 980e6, "and not off some smaller number still");
    }

    function test_buySlippageIsCheckedAgainstWhatTheReceiverActuallyHolds() public {
        uint256 usdgIn = 1_000e6;
        _fundTraderUsdg(usdgIn);

        uint256 snap = vm.snapshotState();
        vm.prank(trader);
        uint256 delivered = router.buyWithUsdg(sendTaxedMarketId, usdgIn, 0, trader, _deadline());

        assertEq(
            sendTaxed.balanceOf(trader), delivered, "the reported output is the trader's balance"
        );
        assertGt(sendTaxed.balanceOf(taxSink), 0, "the asset taxed the hops it charges for");
        vm.revertToState(snap);

        // One wei above what the trader can actually end up holding, after both the pool's fees
        // and the token's own transfer tax. The bound is enforced on the far side of the tax.
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketRouter.InsufficientOutput.selector, delivered, delivered + 1
            )
        );
        router.buyWithUsdg(sendTaxedMarketId, usdgIn, delivered + 1, trader, _deadline());
    }

    // ─── Liquidity ───────────────────────────────────────────────────────

    function test_seedLiquidityAddsFullRangeDepthAndMarketLiquidityReportsIt() public {
        uint256 fresh = _createMarket("Fresh Dollar", "frsUSD", address(new MockAsset()));
        assertEq(router.marketLiquidity(fresh), 0, "a market starts with no depth");

        (, uint128 added) = _seedThroughRouter(fresh, 10_000e6, 10_000e18);

        assertGt(added, 0, "liquidity was minted");
        assertEq(router.marketLiquidity(fresh), added, "and the view reports the pool's depth");

        // Full range, so the seeded position is the pool's whole active liquidity.
        PoolKey memory key = factory.poolKeyOf(fresh);
        assertEq(
            IPoolManager(address(manager)).getLiquidity(key.toId()),
            added,
            "the position is in range at the pool's own price"
        );
    }

    /// @notice The header claim of the whole change: the seeder walks away holding the LP NFT.
    ///         Not the router, not the factory, not the market's creator — `msg.sender`.
    function test_seedLiquidityMintsTheLpNftToTheCallerAndNotToTheRouter() public {
        uint256 fresh = _createMarket("Owned Dollar", "ownUSD", address(new MockAsset()));

        uint256 expectedId = posm.nextTokenId();
        uint256 heldBefore = posm.balanceOf(lp);
        (uint256 tokenId, uint128 added) = _seedThroughRouter(fresh, 10_000e6, 10_000e18);

        assertEq(tokenId, expectedId, "the id returned is the id that was minted");
        assertGt(added, 0, "and it carries liquidity");

        assertEq(posm.ownerOf(tokenId), lp, "the seeder owns the position");
        assertEq(
            posm.balanceOf(lp),
            heldBefore + 1,
            "as an ERC-721 they hold, transferable like any other"
        );
        assertEq(posm.balanceOf(address(router)), 0, "the router holds nothing at all");

        // That it is a *genuine* `UNI-V4-POSM` token, and not just something this stand-in
        // minted, is what the fork suite asserts against the deployed PositionManager.
    }

    /// @notice The reason the change was made. A seeder puts both sides in, gets an NFT, goes to
    ///         `PositionManager` with no help from this repo at all, and gets their money back.
    ///         Under the old design this test could not have been written: the router was the
    ///         position's owner and nothing could withdraw.
    function test_theSeederCanWithdrawThroughPositionManagerWithoutTheRouter() public {
        uint256 fresh = _createMarket("Exit Dollar", "extUSD", address(new MockAsset()));
        AssetMarketFactory.Market memory m = factory.market(fresh);

        (uint256 tokenId,, uint256 brandUsed, uint256 assetUsed) = _seedAndReport(fresh, lp);
        uint128 seeded = router.marketLiquidity(fresh);
        assertGt(seeded, 0, "there is depth to pull back out");

        // Baselines taken after the seed, so the refund of the unused side is not mistaken for
        // a withdrawal. What follows is measured purely across the burn.
        uint256 brandBefore = IERC20(m.brandToken).balanceOf(lp);
        uint256 assetBefore = IERC20(m.asset).balanceOf(lp);
        assertEq(brandBefore, 0, "the brand side is entirely in the pool, none held back");

        _burnPositionAs(lp, tokenId);

        // Both sides came back. The stable side comes back as brandUSD rather than USDG,
        // because brandUSD is what was deposited — `SharedReservePool.redeem` turns it back
        // into USDG 1:1 whenever the owner wants, which is exercised just below.
        uint256 brandBack = IERC20(m.brandToken).balanceOf(lp) - brandBefore;
        uint256 assetBack = IERC20(m.asset).balanceOf(lp) - assetBefore;
        assertGt(brandBack, 0, "the brand side came home");
        assertGt(assetBack, 0, "and so did the asset side");

        // Essentially everything that went in. It is never exactly equal — v4 rounds a position
        // in the pool's favour on the way in and on the way out — but no fee was ever charged
        // on this pool, so the gap is dust rather than a haircut.
        assertApproxEqRel(brandBack, brandUsed, 1e12, "essentially the whole stable side");
        assertApproxEqRel(assetBack, assetUsed, 1e12, "and essentially the whole asset side");

        assertEq(router.marketLiquidity(fresh), 0, "the pool is empty again");

        uint256 usdgBefore = usdg.balanceOf(lp);
        vm.prank(lp);
        uint256 usdgBack = reserve.redeem(m.brandToken, brandBack, lp);
        assertEq(usdgBack, brandBack, "and brandUSD redeems 1:1 back to the reserve asset");
        assertEq(usdg.balanceOf(lp) - usdgBefore, usdgBack, "so the seeder is whole in USDG");
    }

    /// @dev A seed that also reports what the router said it consumed, for tests that compare
    ///      what came back out against what actually went in.
    function _seedAndReport(uint256 id, address seeder)
        internal
        returns (uint256 tokenId, uint128 liquidityAdded, uint256 brandUsed, uint256 assetUsed)
    {
        AssetMarketFactory.Market memory m = factory.market(id);
        usdg.mint(seeder, 10_000e6);
        _mintAsset(m.asset, seeder, 10_000e18);

        vm.startPrank(seeder);
        usdg.approve(address(reserve), 10_000e6);
        uint256 brandAmount = reserve.mint(m.brandToken, 10_000e6, seeder);
        IERC20(m.brandToken).approve(address(router), brandAmount);
        IERC20(m.asset).approve(address(router), 10_000e18);
        (tokenId, liquidityAdded, brandUsed, assetUsed) =
            router.seedLiquidity(id, brandAmount, 10_000e18, 0, 0, _deadline());
        vm.stopPrank();
    }

    /// @notice Two seeders, two positions — not one shared pot. This is the property that made
    ///         a withdrawal function impossible before: the router could not tell whose
    ///         liquidity was whose, because there was only ever one position per market.
    function test_twoSeedersGetTwoSeparatePositionsRatherThanSharingOne() public {
        uint256 fresh = _createMarket("Split Dollar", "splUSD", address(new MockAsset()));
        AssetMarketFactory.Market memory m = factory.market(fresh);

        (uint256 lpToken, uint128 lpLiquidity) =
            _seedThroughRouterAs(lp, fresh, 10_000e6, 10_000e18);
        (uint256 strangerToken, uint128 strangerLiquidity) =
            _seedThroughRouterAs(stranger, fresh, 4_000e6, 4_000e18);

        assertTrue(lpToken != strangerToken, "two distinct positions");
        assertEq(posm.ownerOf(lpToken), lp, "each owned by whoever paid for it");
        assertEq(posm.ownerOf(strangerToken), stranger);
        assertGt(lpLiquidity, strangerLiquidity, "and sized independently");

        // The pool's depth is the sum, but the claims on it are separate.
        assertEq(
            router.marketLiquidity(fresh),
            lpLiquidity + strangerLiquidity,
            "the pool sees one number"
        );

        // The stranger leaves. The LP's position is untouched by that, which is the whole
        // difference from the shared-position design. Baselines are taken after both seeds, so
        // the dust each seed refunded is not mistaken for a withdrawal.
        uint256 strangerBefore = IERC20(m.asset).balanceOf(stranger);
        uint256 lpBefore = IERC20(m.asset).balanceOf(lp);

        _burnPositionAs(stranger, strangerToken);

        assertEq(
            router.marketLiquidity(fresh), lpLiquidity, "only the stranger's share was removed"
        );
        assertEq(posm.ownerOf(lpToken), lp, "the LP still holds theirs");
        assertGt(
            IERC20(m.asset).balanceOf(stranger) - strangerBefore,
            0,
            "and the stranger got their asset back"
        );
        assertEq(
            IERC20(m.asset).balanceOf(lp),
            lpBefore,
            "out of their own position, not a wei of the LP's"
        );
    }

    function test_seedLiquidityIsPermissionlessAndEachSeedIsItsOwnPosition() public {
        uint128 before = router.marketLiquidity(marketId);

        // A stranger with no relationship to this market. They are not donating any more —
        // they get a position — so there is even less reason to stop them.
        (uint256 tokenId, uint128 added) =
            _seedThroughRouterAs(stranger, marketId, 10_000e6, 10_000e18);

        assertGt(added, 0, "the seed landed");
        assertEq(posm.ownerOf(tokenId), stranger, "and it is theirs");
        assertEq(router.marketLiquidity(marketId), before + added, "on top of the existing depth");
    }

    function test_seedLiquidityPutsBrandFloatOnTheStableSideNeverUsdg() public {
        uint256 fresh = _createMarket("Float Dollar", "fltUSD", address(new MockAsset()));
        address brand = _brandOf(fresh);

        _seedThroughRouter(fresh, 10_000e6, 10_000e18);

        assertEq(usdg.balanceOf(address(manager)), 0, "the pool holds no USDG");
        assertGt(IERC20(brand).balanceOf(address(manager)), 0, "it holds brandUSD");

        // Which is the entire point: that balance is outstanding brand supply, so the reserve
        // is earning on it for this market rather than it sitting inert in a pool.
        assertGt(reserve.totalPooledSupply(), 0, "and the reserve is earning against it");
    }

    function test_seedLiquidityRefundsTheUnusedSideInTheTokenItWasGiven() public {
        uint256 fresh = _createMarket("Lopsided Dollar", "lopUSD", address(new MockAsset()));
        AssetMarketFactory.Market memory m = factory.market(fresh);

        // Far more stable than the price ratio can absorb, so most of the brand side comes
        // straight back — and comes back as brandUSD, which is what the caller arrived with.
        // It is deliberately not redeemed to USDG on the way out: the caller chose to hold
        // brandUSD, and undoing that for them would be a conversion they never asked for.
        uint256 usdgIn = 100_000e6;
        uint256 assetIn = 1_000e18;

        usdg.mint(lp, usdgIn);
        _mintAsset(m.asset, lp, assetIn);
        uint256 usdgBefore = usdg.balanceOf(lp) - usdgIn;

        vm.startPrank(lp);
        usdg.approve(address(reserve), usdgIn);
        uint256 brandIn = reserve.mint(m.brandToken, usdgIn, lp);
        IERC20(m.brandToken).approve(address(router), brandIn);
        IERC20(m.asset).approve(address(router), assetIn);
        (,, uint256 brandUsed, uint256 assetUsed) =
            router.seedLiquidity(fresh, brandIn, assetIn, 0, 0, _deadline());
        vm.stopPrank();

        assertLt(brandUsed, brandIn / 2, "the pool could not take the whole stable side");

        // Not all of the short side either, quite: v4 charges what the requested liquidity is
        // worth and that rounds down, so a few units are always left over. They are refunded
        // like everything else rather than kept.
        assertApproxEqAbs(assetUsed, assetIn, 1e9, "the short side went in almost entirely");

        assertEq(
            IERC20(m.brandToken).balanceOf(lp),
            brandIn - brandUsed,
            "the remainder came back as brandUSD"
        );
        assertEq(IERC20(m.asset).balanceOf(lp), assetIn - assetUsed, "and the asset dust too");
        assertEq(usdg.balanceOf(lp), usdgBefore, "never as USDG, which the router was not given");
        assertEq(IERC20(m.brandToken).balanceOf(address(router)), 0, "and none stuck in the router");
        assertEq(IERC20(m.asset).balanceOf(address(router)), 0, "on either side");
    }

    /// @notice Both bounds, each proved by the lopsided side that actually misses it. A seed
    ///         heavy in USDG cannot spend all its stable side, and a seed heavy in the asset
    ///         cannot spend all of that — so each minimum gets a case where it is the one doing
    ///         the work, rather than one case standing in for two.
    function test_seedLiquidityHonoursBothOfItsMinimums() public {
        uint256 fresh = _createMarket("Bound Dollar", "bndUSD", address(new MockAsset()));
        AssetMarketFactory.Market memory m = factory.market(fresh);
        uint256 heldBefore = posm.balanceOf(lp);

        uint256 usdgIn = 100_000e6;
        uint256 assetIn = 1_000e18;

        usdg.mint(lp, usdgIn);
        _mintAsset(m.asset, lp, assetIn);

        vm.startPrank(lp);
        usdg.approve(address(reserve), usdgIn);
        uint256 brandIn = reserve.mint(m.brandToken, usdgIn, lp);
        IERC20(m.brandToken).approve(address(router), brandIn);
        IERC20(m.asset).approve(address(router), assetIn);
        vm.expectPartialRevert(MarketRouter.InsufficientAmountUsed.selector);
        router.seedLiquidity(fresh, brandIn, assetIn, brandIn, 0, _deadline());
        vm.stopPrank();

        // The mirror image: far more asset than the stable side can pair with, so the asset
        // minimum is the one that cannot be met.
        uint256 other = _createMarket("Bound Two", "bn2USD", address(new MockAsset()));
        AssetMarketFactory.Market memory m2 = factory.market(other);

        uint256 usdgIn2 = 1_000e6;
        uint256 assetIn2 = 100_000e18;

        usdg.mint(lp, usdgIn2);
        _mintAsset(m2.asset, lp, assetIn2);

        vm.startPrank(lp);
        usdg.approve(address(reserve), usdgIn2);
        uint256 brandIn2 = reserve.mint(m2.brandToken, usdgIn2, lp);
        IERC20(m2.brandToken).approve(address(router), brandIn2);
        IERC20(m2.asset).approve(address(router), assetIn2);
        vm.expectPartialRevert(MarketRouter.InsufficientAmountUsed.selector);
        router.seedLiquidity(other, brandIn2, assetIn2, 0, assetIn2, _deadline());
        vm.stopPrank();

        // Nothing was minted on either attempt: a reverted seed leaves no position behind.
        assertEq(posm.balanceOf(lp), heldBefore, "no NFT survives a bound that was missed");
    }

    /// @notice A consequence of minting through `PositionManager` worth pinning down: the pool
    ///         is now paid by Permit2's `transferFrom`, not by a `transfer` the router makes
    ///         itself, so an asset that skims `transferFrom` under-delivers and v4 rejects the
    ///         whole unlock. The seed reverts rather than half-landing, which is the failure we
    ///         want; a market in such an asset simply cannot be seeded, and finding that out at
    ///         seed time is better than finding it out later.
    function test_aPullTaxingAssetCannotBeSeededBecausePermit2SettlesWithTransferFrom() public {
        uint256 fresh =
            _createMarket("Taxed Dollar", "taxUSD", address(new PullTaxedAsset(taxSink)));
        AssetMarketFactory.Market memory m = factory.market(fresh);

        usdg.mint(lp, 10_000e6);
        PullTaxedAsset(m.asset).mint(lp, 10_000e18);

        vm.startPrank(lp);
        usdg.approve(address(reserve), 10_000e6);
        uint256 brandIn = reserve.mint(m.brandToken, 10_000e6, lp);
        IERC20(m.brandToken).approve(address(router), brandIn);
        IERC20(m.asset).approve(address(router), 10_000e18);
        vm.expectRevert(); // v4's `CurrencyNotSettled`, raised inside the PoolManager's unlock
        router.seedLiquidity(fresh, brandIn, 10_000e18, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(router.marketLiquidity(fresh), 0, "and nothing was left half-added");
    }

    function test_seedLiquidityRefusesAnAmountTooSmallToBecomeLiquidity() public {
        uint256 fresh = _createMarket("Dust Dollar", "dstUSD", address(new MockAsset()));
        AssetMarketFactory.Market memory m = factory.market(fresh);

        usdg.mint(lp, 1);
        _mintAsset(m.asset, lp, 1);

        vm.startPrank(lp);
        usdg.approve(address(reserve), 1);
        uint256 brandIn = reserve.mint(m.brandToken, 1, lp);
        IERC20(m.brandToken).approve(address(router), brandIn);
        IERC20(m.asset).approve(address(router), 1);
        vm.expectRevert(MarketRouter.NoLiquidity.selector);
        router.seedLiquidity(fresh, brandIn, 1, 0, 0, _deadline());
        vm.stopPrank();
    }

    // ─── Trading never touches anyone's position ─────────────────────────

    /// @notice Nothing anyone can call on this router makes a market shallower. The router is
    ///         no longer an LP at all, so this is not the "liquidity is locked" claim it used
    ///         to be — it is the narrower and still necessary one that the trading paths only
    ///         ever move along the curve, and that seeding only ever adds. Every external entry
    ///         point is exercised here, by the parties most likely to be assumed privileged
    ///         (the market's creator, the LP who seeded it, and a stranger); none of them is.
    function test_noEntryPointEverReducesAMarketsDepth() public {
        uint128 seeded = router.marketLiquidity(marketId);
        assertGt(seeded, 0, "there is something to try to take");

        _fundTraderUsdg(5_000e6);
        vm.prank(trader);
        router.buyWithUsdg(marketId, 5_000e6, 0, trader, _deadline());
        assertGe(router.marketLiquidity(marketId), seeded, "a buy did not touch it");

        _fundTraderAsset(address(asset), 5_000e18);
        vm.prank(trader);
        router.sellForBrand(marketId, 5_000e18, 0, trader, _deadline());
        assertGe(router.marketLiquidity(marketId), seeded, "nor did a sell");

        address foreignBrand = _brandOf(otherMarketId);
        usdg.mint(creator, 1_000e6);
        vm.startPrank(creator);
        usdg.approve(address(reserve), 1_000e6);
        reserve.mint(foreignBrand, 1_000e6, creator);
        IERC20(foreignBrand).approve(address(router), 1_000e6);
        router.buyWithBrand(marketId, foreignBrand, 1_000e6, 0, creator, _deadline());
        vm.stopPrank();
        assertGe(router.marketLiquidity(marketId), seeded, "nor a cross-brand buy");

        // And whoever opened the market has no liquidity verb but `seedLiquidity`, which adds —
        // and hands them their own NFT rather than any claim on the LP's.
        (uint256 tokenId,) = _seedThroughRouterAs(creator, marketId, 1_000e6, 1_000e18);
        assertGt(router.marketLiquidity(marketId), seeded, "the only verb adds");
        assertEq(posm.ownerOf(tokenId), creator, "and gives them only what they paid for");
    }

    /// @notice The unlock callback is swap-only now — `modifyLiquidity` is not reachable from
    ///         this contract at all — and it is still closed to everyone but the PoolManager, so
    ///         no crafted payload gets a swap out of the router's balance either.
    function test_unlockCallbackRejectsEveryCallerButThePoolManager() public {
        bytes memory payload = abi.encode(factory.poolKeyOf(marketId), true, uint256(1));

        vm.prank(stranger);
        vm.expectRevert(MarketRouter.OnlyPoolManager.selector);
        router.unlockCallback(payload);

        vm.prank(creator);
        vm.expectRevert(MarketRouter.OnlyPoolManager.selector);
        router.unlockCallback(payload);

        vm.prank(lp);
        vm.expectRevert(MarketRouter.OnlyPoolManager.selector);
        router.unlockCallback(payload);
    }

    // ─── Wiring ──────────────────────────────────────────────────────────

    function test_theRouterTakesItsPoolManagerFromTheFactoryItServes() public view {
        assertEq(
            address(router.poolManager()),
            address(factory.poolManager()),
            "no second address to keep in sync"
        );
        assertEq(address(router.asset()), address(usdg), "and quotes in the reserve's asset");
        assertEq(address(router.positionManager()), address(posm), "and mints through periphery");
        assertEq(address(router.permit2()), address(permit2), "which pulls through Permit2");
    }

    function test_constructionRejectsZeroWiring() public {
        IPositionManagerV4 posmI = IPositionManagerV4(address(posm));
        IPermit2 permit2I = IPermit2(address(permit2));

        vm.expectRevert(MarketRouter.ZeroAddress.selector);
        _deployRouter(SharedReservePool(address(0)), factory, posmI, permit2I, owner);

        vm.expectRevert(MarketRouter.ZeroAddress.selector);
        _deployRouter(reserve, AssetMarketFactory(address(0)), posmI, permit2I, owner);

        vm.expectRevert(MarketRouter.ZeroAddress.selector);
        _deployRouter(reserve, factory, IPositionManagerV4(address(0)), permit2I, owner);

        vm.expectRevert(MarketRouter.ZeroAddress.selector);
        _deployRouter(reserve, factory, posmI, IPermit2(address(0)), owner);
    }

    /// @notice A `PositionManager` bound to some other PoolManager would mint into pools this
    ///         router's markets are not, so the pairing is refused at construction rather than
    ///         discovered on the first seed. Same discipline as deriving the singleton from the
    ///         factory: make the mismatch unrepresentable rather than detectable.
    function test_constructionRejectsAPositionManagerOnADifferentPoolManager() public {
        PoolManager otherManager = new PoolManager(address(this));
        StandInPositionManager strayPosm =
            new StandInPositionManager(IPoolManager(address(otherManager)), permit2);

        vm.expectRevert(
            abi.encodeWithSelector(
                MarketRouter.PoolManagerMismatch.selector, address(otherManager), address(manager)
            )
        );
        _deployRouter(
            reserve,
            factory,
            IPositionManagerV4(address(strayPosm)),
            IPermit2(address(permit2)),
            owner
        );
    }

    /// @notice The Permit2 double-approval is set once per token and then reused. Cheap to
    ///         assert, and it is the mechanism the whole mint depends on: without both legs
    ///         `PositionManager` cannot pull a thing and every seed reverts.
    function test_permit2ApprovalsAreSetOncePerTokenAndThenReused() public {
        uint256 fresh = _createMarket("Approve Dollar", "aprUSD", address(new MockAsset()));
        AssetMarketFactory.Market memory m = factory.market(fresh);

        assertFalse(router.approvedThroughPermit2(m.brandToken), "nothing approved up front");
        assertFalse(router.approvedThroughPermit2(m.asset));

        _seedThroughRouter(fresh, 10_000e6, 10_000e18);

        assertTrue(router.approvedThroughPermit2(m.brandToken), "the brand side is approved");
        assertTrue(router.approvedThroughPermit2(m.asset), "and so is the asset side");

        assertEq(
            IERC20(m.asset).allowance(address(router), address(permit2)),
            type(uint256).max,
            "token to Permit2, unlimited"
        );
        (uint160 amount, uint48 expiration,) =
            permit2.allowance(address(router), m.asset, address(posm));
        assertEq(amount, type(uint160).max, "Permit2 to PositionManager, unlimited");
        assertEq(expiration, type(uint48).max, "and never expiring");

        // A second seed of the same market reuses them rather than re-approving.
        (uint256 tokenId,) = _seedThroughRouter(fresh, 1_000e6, 1_000e18);
        assertEq(posm.ownerOf(tokenId), lp, "and mints just the same");
    }
}
