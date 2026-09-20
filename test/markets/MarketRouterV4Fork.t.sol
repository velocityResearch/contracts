// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {MorphoBlueYieldSource} from "../../src/yield/MorphoBlueYieldSource.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3.sol";
import {MainnetAddresses} from "../../script/MainnetAddresses.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @dev The ERC-721 half of the deployed PositionManager, which `IPositionManagerV4` does not
///      declare because the router never needs it. Only used to prove the thing the router
///      hands back really is Uniswap's LP NFT and not a receipt of our own invention.
interface IPositionsNftLike {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function balanceOf(address owner) external view returns (uint256);
    function permit2() external view returns (address);
}

/// @title MarketRouterV4ForkTest
/// @notice `MarketRouter.seedLiquidity` run against **Uniswap's own deployed v4 periphery** on
///         Robinhood Chain: the real `PositionManager` at `V4_POSITION_MANAGER`, the canonical
///         Permit2, and the real `PoolManager` singleton they are both bound to.
///
///         This is the suite that proves the point of the rewrite. The offline suite in
///         `MarketRouter.t.sol` mints through a stand-in written in that file, which can only
///         ever confirm that the router encodes what *we* think `MINT_POSITION` +
///         `SETTLE_PAIR` mean, and that the refunds and minimums around it hold. Whether
///         Uniswap's own contract agrees with that encoding — and whether the seeder can
///         actually get their money back out of it afterwards — can only be answered here.
///
///         The real periphery cannot be compiled into this repo at all: `lib/v4-periphery`
///         vendors its own v4-core and its own OpenZeppelin, and `permit2` pins
///         `solc =0.8.17`, so importing either breaks the build for the whole project. On a
///         fork none of that matters, because both contracts are already deployed — all that is
///         needed is the local `IPositionManagerV4` interface and hand-rolled action calldata.
///
///         **Real:** the PoolManager, the PositionManager, Permit2, USDG, Morpho Blue, SPCX and
///         the live V3 SPCX/USDG pool (read for a starting price, pranked as a source of SPCX).
///         **Ours, deployed into the fork:** the reserve stack, the hook, the factory and the
///         router. Nothing is mocked.
///
///         **Pin the block, but pin it near the head.** This chain's public RPC is not an
///         archive node: state more than a few hundred blocks back comes back as
///         `-32000: metadata is not found`, and every test then fails inside `setUp` with an
///         account-fetch error that says nothing about our contracts. Take the block from the
///         chain, not from this comment:
///
///         BN=$(cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com); forge test --match-path "test/markets/MarketRouterV4Fork.t.sol" --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number $((BN-80)) -vv
contract MarketRouterV4ForkTest is Test, StackFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── The live venue ──────────────────────────────────────────────────

    IPoolManager constant MANAGER = IPoolManager(MainnetAddresses.POOL_MANAGER);
    IPositionManagerV4 constant POSM = IPositionManagerV4(MainnetAddresses.V4_POSITION_MANAGER);
    IPermit2 constant PERMIT2 = IPermit2(MainnetAddresses.PERMIT2);

    address constant USDG = MainnetAddresses.USDG;
    address constant MORPHO_BLUE = MainnetAddresses.MORPHO_BLUE;
    address constant SPCX = MainnetAddresses.REFERENCE_EQUITY;
    bytes32 constant USDE_MARKET_ID = MainnetAddresses.USDE_MARKET_ID;

    /// @notice The live SPCX/USDG 0.05% V3 pool. Read for a price, pranked for SPCX, never
    ///         traded against.
    address constant LIVE_SPCX_USDG_POOL = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029;

    /// @dev v4-periphery action ids, the same two constants the router encodes plus the two
    ///      that undo them. Written out rather than imported for the reason in the header.
    uint8 constant BURN_POSITION = 0x03;
    uint8 constant TAKE_PAIR = 0x11;

    // ─── Market configuration ────────────────────────────────────────────

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint24 constant PROTOCOL_FEE_PIPS = 1_000; // 0.10%

    uint256 constant SEED_USDG = 20_000e6;
    uint256 constant SEED_SPCX = 100e18;

    // ─── Our stack, deployed into the fork ───────────────────────────────

    SharedReservePool reservePool;
    MorphoBlueYieldSource yieldSource;
    ProtocolFeeHook feeHook;
    AssetMarketFactory factory;
    MarketRouter router;

    address owner = address(0x0AD01);
    address operator = address(0x0FE);
    address protocolTreasury = address(0xF33);
    address seeder = address(0x11B0);
    address otherSeeder = address(0x57A);

    uint256 marketId;
    address brandToken;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        _deployUpgradeBase();
        // Skip cleanly when run without --fork-url, so an offline `forge test` still passes.
        // `vm.skip` only marks the result, it does not abort the body, so the early return is
        // what keeps the rest of this from reverting against an empty chain.
        vm.skip(block.chainid != MainnetAddresses.CHAIN_ID);
        if (block.chainid != MainnetAddresses.CHAIN_ID) return;

        yieldSource = _deployYieldSource(MORPHO_BLUE, USDE_MARKET_ID, owner);
        reservePool = _deployReservePool(USDG, address(yieldSource), owner);

        feeHook = _deployHook();

        factory =
            _deployFactory(reservePool, MANAGER, feeHook, POSM, protocolTreasury, SPCX, 0, owner);

        vm.startPrank(owner);
        feeHook.setRegistrar(address(factory));
        factory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        // The whole point: the deployed periphery, not a local deployment of it.
        router = _deployRouter(reservePool, factory, POSM, PERMIT2, owner);

        _createMarket();

        _fundUsdg(seeder, 100_000e6);
        _fundSpcx(seeder, 500e18);
        _fundUsdg(otherSeeder, 100_000e6);
        _fundSpcx(otherSeeder, 500e18);
    }

    // ─── The claim ───────────────────────────────────────────────────────

    /// @notice The router is wired to Uniswap's own periphery, and that periphery is bound to
    ///         the singleton our markets live in. Cheap, but it is the assumption every other
    ///         assertion in this file rests on, and the constructor's own check would have
    ///         reverted the deployment in `setUp` if it did not hold.
    function test_theDeployedPeripheryIsTheOneOurMarketsPoolManagerBelongsTo() public view {
        assertEq(POSM.poolManager(), address(MANAGER), "PositionManager is on our singleton");
        assertEq(
            IPositionsNftLike(address(POSM)).permit2(),
            address(PERMIT2),
            "and pulls through the canonical Permit2"
        );
        assertEq(address(router.positionManager()), address(POSM));
        assertEq(address(router.permit2()), address(PERMIT2));
    }

    /// @notice Seeding mints a genuine `UNI-V4-POSM` position, owned by the caller.
    function test_seedingMintsARealUniswapLpNftOwnedByTheSeeder() public {
        uint256 expectedId = POSM.nextTokenId();
        uint256 heldBefore = IPositionsNftLike(address(POSM)).balanceOf(seeder);

        (uint256 tokenId, uint128 liquidity,,) = _seedAs(seeder, SEED_USDG, SEED_SPCX);

        assertEq(tokenId, expectedId, "the id the router reported is the id that was minted");
        assertGt(liquidity, 0, "and it carries liquidity");

        assertEq(POSM.ownerOf(tokenId), seeder, "the seeder owns it");
        assertEq(POSM.ownerOf(tokenId) == address(router), false, "the router does not");
        assertEq(
            IPositionsNftLike(address(POSM)).balanceOf(seeder),
            heldBefore + 1,
            "as an ERC-721 in their own wallet"
        );

        // Uniswap's, not ours. This is the assertion the offline suite cannot make.
        assertEq(IPositionsNftLike(address(POSM)).name(), "Uniswap v4 Positions NFT");
        assertEq(IPositionsNftLike(address(POSM)).symbol(), "UNI-V4-POSM");

        assertGt(MANAGER.getLiquidity(poolId), 0, "and the market has depth");
    }

    /// @notice **The reason for the whole change.** A seeder puts both sides in through our
    ///         router, then goes to Uniswap's `PositionManager` with no help from this repo at
    ///         all and gets their money back. Under the previous design the router owned the
    ///         position and this test could not have been written.
    function test_theSeederCanWithdrawThroughTheRealPositionManagerAndGetTokensBack() public {
        (uint256 tokenId,, uint256 brandUsed, uint256 assetUsed) =
            _seedAs(seeder, SEED_USDG, SEED_SPCX);

        uint128 depth = MANAGER.getLiquidity(poolId);
        assertGt(depth, 0, "there is something to pull back out");

        // Baselines after the seed, so the refund of the unused side is not counted as an exit.
        uint256 brandBefore = IERC20(brandToken).balanceOf(seeder);
        uint256 spcxBefore = IERC20(SPCX).balanceOf(seeder);

        _burnPositionAs(seeder, tokenId);

        uint256 brandBack = IERC20(brandToken).balanceOf(seeder) - brandBefore;
        uint256 spcxBack = IERC20(SPCX).balanceOf(seeder) - spcxBefore;

        assertGt(brandBack, 0, "the stable side came home");
        assertGt(spcxBack, 0, "and so did the asset side");

        // Essentially everything that went in — v4 rounds a position in the pool's favour on
        // the way in and again on the way out, but no swap has touched this pool, so the gap
        // is dust rather than a haircut.
        assertApproxEqRel(brandBack, brandUsed, 1e12, "essentially the whole stable side");
        assertApproxEqRel(spcxBack, assetUsed, 1e12, "and essentially the whole asset side");

        assertEq(MANAGER.getLiquidity(poolId), 0, "the position is closed");

        // The stable side comes back as brandUSD, because brandUSD is what was deposited. It
        // redeems 1:1 at the reserve, which is what makes the round trip whole in USDG.
        uint256 usdgBefore = IERC20(USDG).balanceOf(seeder);
        vm.prank(seeder);
        uint256 usdgBack = reservePool.redeem(brandToken, brandBack, seeder);
        assertEq(IERC20(USDG).balanceOf(seeder) - usdgBefore, usdgBack, "and back to USDG");
        assertApproxEqAbs(usdgBack, brandBack, 1, "1:1, less at most the reserve's own rounding");
    }

    /// @notice Two seeders get two positions, and one leaving does not touch the other's. This
    ///         is the property the old shared-position design could not offer, which is why it
    ///         had no withdrawal function at all.
    function test_twoSeedersGetTwoIndependentPositionsOnTheRealPositionManager() public {
        (uint256 firstId, uint128 firstLiquidity,,) = _seedAs(seeder, SEED_USDG, SEED_SPCX);
        (uint256 secondId, uint128 secondLiquidity,,) =
            _seedAs(otherSeeder, SEED_USDG / 4, SEED_SPCX / 4);

        assertTrue(firstId != secondId, "two distinct positions, not one shared pot");
        assertEq(POSM.ownerOf(firstId), seeder, "each owned by whoever paid for it");
        assertEq(POSM.ownerOf(secondId), otherSeeder);
        assertGt(firstLiquidity, secondLiquidity, "and sized independently");

        assertEq(
            MANAGER.getLiquidity(poolId),
            uint256(firstLiquidity) + uint256(secondLiquidity),
            "the pool sees the sum"
        );

        uint256 firstAssetBefore = IERC20(SPCX).balanceOf(seeder);
        uint256 secondAssetBefore = IERC20(SPCX).balanceOf(otherSeeder);

        _burnPositionAs(otherSeeder, secondId);

        assertEq(MANAGER.getLiquidity(poolId), firstLiquidity, "only their own share left");
        assertEq(POSM.ownerOf(firstId), seeder, "the other seeder still holds theirs");
        assertGt(
            IERC20(SPCX).balanceOf(otherSeeder) - secondAssetBefore, 0, "they got their asset back"
        );
        assertEq(
            IERC20(SPCX).balanceOf(seeder), firstAssetBefore, "and not a wei of the other seeder's"
        );
    }

    /// @notice Nobody but the owner can close a seeded position — not the router that minted
    ///         it, and not the market's operator.
    function test_nobodyButTheOwnerCanCloseASeededPosition() public {
        (uint256 tokenId,,,) = _seedAs(seeder, SEED_USDG, SEED_SPCX);

        vm.expectRevert();
        _burnPositionAs(operator, tokenId);

        vm.expectRevert();
        _burnPositionAs(address(router), tokenId);

        assertEq(POSM.ownerOf(tokenId), seeder, "still theirs");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev A v4 hook's permission bits are the low 14 bits of its own address, so `deployCodeTo`
    ///      puts it where we want it while still running the constructor — and therefore still
    ///      running `Hooks.validateHookPermissions`. The `0x00DD` prefix keeps this suite's hook
    ///      at an address no other suite uses; the `require` checks the live chain has nothing
    ///      there rather than assuming it.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x00DD << 144)
        );
        require(flags.code.length == 0, "hook address is occupied on the live chain");
        return _deployHookAt(flags, MANAGER, owner);
    }

    /// @dev Morpho Blue custodies tens of millions of USDG on this chain.
    function _fundUsdg(address to, uint256 amount) internal {
        vm.prank(MORPHO_BLUE);
        IERC20(USDG).transfer(to, amount);
    }

    /// @dev SPCX is an issuer-controlled beacon proxy, so `deal` cannot be trusted to find the
    ///      balance slot. The live V3 pool is a real holder, so real tokens are moved instead.
    function _fundSpcx(address to, uint256 amount) internal {
        vm.prank(LIVE_SPCX_USDG_POOL);
        IERC20(SPCX).transfer(to, amount);
    }

    /// @dev The live mid price of one whole SPCX in whole USDG, read off the real V3 pool so
    ///      this suite does not rot as the price moves.
    function _livePriceE18() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolLike(LIVE_SPCX_USDG_POOL).slot0();
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return Math.mulDiv(ratioX192, 1e18 * 1e12, 1 << 192);
    }

    function _createMarket() internal {
        _approveAsset(factory, SPCX, FEE, _livePriceE18(), 64, "Starbase Dollar", "starUSD");

        bytes32 rawPoolId;
        (marketId, brandToken,,, rawPoolId) = factory.createMarket(SPCX, address(0));

        poolKey = factory.poolKeyOf(marketId);
        poolId = PoolId.wrap(rawPoolId);
    }

    function _seedAs(address who, uint256 usdgIn, uint256 assetIn)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 brandUsed, uint256 assetUsed)
    {
        vm.startPrank(who);
        // The stable side the router takes is the market's own brandUSD. Minting it from USDG
        // is the seeder's own 1:1 call at the reserve, made before the approval below.
        IERC20(USDG).approve(address(reservePool), usdgIn);
        reservePool.mint(brandToken, usdgIn, who);
        IERC20(brandToken).approve(address(router), usdgIn);
        IERC20(SPCX).approve(address(router), assetIn);
        (tokenId, liquidity, brandUsed, assetUsed) =
            router.seedLiquidity(marketId, usdgIn, assetIn, 0, 0, vm.getBlockTimestamp() + 1 hours);
        vm.stopPrank();
    }

    /// @dev Close a position the way its owner would, straight to Uniswap's PositionManager:
    ///      `BURN_POSITION` (which decreases to zero first) then `TAKE_PAIR` to collect both
    ///      sides. No call to anything in this repo appears anywhere in here — that is the
    ///      claim. Minimums are zero because the pool has not been traded; the point is the
    ///      exit path existing at all, not its slippage bounds, which are Uniswap's.
    function _burnPositionAs(address who, uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(BURN_POSITION, TAKE_PAIR);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, who);

        vm.prank(who);
        POSM.modifyLiquidities(abi.encode(actions, params), vm.getBlockTimestamp() + 1 hours);
    }
}
