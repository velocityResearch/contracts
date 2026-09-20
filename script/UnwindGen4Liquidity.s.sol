// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPositionManagerV4} from "../src/interfaces/IPositionManagerV4.sol";

/// @dev The slice of the gen-4 `SharedReservePool` this script drives, declared here rather
///      than imported so the script keeps compiling against the deployed (older) ABI even as
///      `src/pool/SharedReservePool.sol` moves on. Both redeem selectors were confirmed present
///      in the deployed implementation `0x41996e59…` by reading its runtime bytecode.
interface IUnwindReserve {
    function isRegistered(address token) external view returns (bool);
    function redeem(address token, uint256 amount, address receiver) external returns (uint256);
    function totalPooledSupply() external view returns (uint256);
    function asset() external view returns (address);
}

interface IUnwindToken {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title UnwindGen4Liquidity
/// @notice Retires the gen-4 market stack by pulling the deployer's 5 LP positions out of
///         Uniswap v4 and redeeming every pooled brand token back to USDG 1:1.
///
///         This is step 2 of `docs/MAINNET_RUNBOOK_2026-09-16.md`, and it needs nobody's
///         permission: the positions are ordinary `UNI-V4-POSM` NFTs the deployer owns, and
///         `SharedReservePool.redeem` carries no `whenNotPaused` by design, so holders can
///         always exit 1:1. The exit path is the one covered by
///         `test/markets/MarketRouter.t.sol:test_theSeederCanWithdrawThroughPositionManagerWithoutTheRouter`
///         and `MarketRouterV4Fork.t.sol:_burnPositionAs` — `BURN_POSITION` + `TAKE_PAIR`
///         straight to the PositionManager, no router, no factory.
///
///         For each position: burn it (which decreases liquidity to zero first) and take both
///         sides home. Then redeem the deployer's ENTIRE balance of each distinct brand back
///         into USDG — the whole balance, not just what the burn returned, so any brand the
///         wallet already held is swept too and the gen-4 `totalPooledSupply` trends to zero.
///
///         The 5 positions span 3 markets (1, 2, 3) and 3 distinct pooled brands. Market 2 was
///         seeded three times, so it contributes three NFTs against one brand.
///
///         Slippage bounds on the burn are zero, matching the covered exit path. These are the
///         deployer's own pools being retired, total value is ~$362, and the fork dry-run
///         prints the exact amounts that came out so they can be eyeballed before a real run.
///
///         Usage:
///           # dry-run against a mainnet fork — prints deltas, sends nothing
///           PRIVATE_KEY=0x… forge script script/UnwindGen4Liquidity.s.sol:UnwindGen4Liquidity \
///               --rpc-url robinhood
///
///           # real unwind (the Sourcify short-circuit keeps forge from hanging on label fetches)
///           export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=rpc.mainnet.chain.robinhood.com
///           PRIVATE_KEY=0x… forge script script/UnwindGen4Liquidity.s.sol:UnwindGen4Liquidity \
///               --rpc-url robinhood --broadcast --slow
contract UnwindGen4Liquidity is Script {
    /// @notice Robinhood Chain mainnet. Gen-1, gen-4, gen-5 and gen-6 are all on this chain,
    ///         so the chain guard alone is not enough — the addresses below pin gen-4 exactly.
    uint256 internal constant CHAIN_ID = 4663;

    /// @notice The gen-4 reserve `0x076e…2338`. NOT the gen-5/gen-6 pool. Verified:
    ///         `asset() == USDG`, `paused() == false`, `totalAssets() == 362.224239 USDG`.
    address internal constant RESERVE = 0x076e361b535B236471BEA7f444D5E70971172338;

    /// @notice The Uniswap v4 PositionManager holding the 5 NFTs — `MainnetAddresses
    ///         .V4_POSITION_MANAGER`, confirmed `poolManager() == 0x8366…0951`.
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    /// @dev v4-periphery action ids, from `lib/v4-periphery/src/libraries/Actions.sol`.
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant TAKE_PAIR = 0x11;

    /// @notice The deployer's 5 LP positions, read off chain 4663 by walking every
    ///         PositionManager `Transfer` to `0xeA6A…12A9` across the gen-4 life. All five are
    ///         owned by the deployer with nonzero liquidity as of block 64,889,008.
    uint256[5] internal TOKEN_IDS = [
        uint256(2356098), // market 1
        uint256(2357056), // market 2
        uint256(2357544), // market 3
        uint256(2428284), // market 2
        uint256(2546931) // market 2
    ];

    function run() external {
        require(block.chainid == CHAIN_ID, "not Robinhood Chain mainnet");

        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);

        IUnwindReserve reserve = IUnwindReserve(RESERVE);
        IPositionManagerV4 posm = IPositionManagerV4(POSM);
        address usdg = reserve.asset();

        // ─── Pre-flight (read-only, before any broadcast) ─────────────────────
        console.log("=== Unwind gen-4 liquidity ===");
        console.log("signer / recipient:", me);
        console.log("reserve:", RESERVE);
        console.log("reserve asset (USDG):", usdg);

        uint256 supplyBefore = reserve.totalPooledSupply();
        uint256 usdgBefore = IUnwindToken(usdg).balanceOf(me);
        console.log("totalPooledSupply before:", supplyBefore);
        console.log("deployer USDG before (1e6):", usdgBefore / 1e6);

        // Assert ownership + live liquidity, and collect the distinct pooled brands.
        address[] memory brands = new address[](3);
        uint256 brandCount;
        for (uint256 i; i < TOKEN_IDS.length; i++) {
            uint256 id = TOKEN_IDS[i];
            require(posm.ownerOf(id) == me, "position not owned by signer");
            uint128 liq = posm.getPositionLiquidity(id);
            require(liq > 0, "position already empty");

            (PoolKey memory poolKey,) = posm.getPoolAndPositionInfo(id);
            console.log("token", id, "liquidity", uint256(liq));

            // Exactly one of the two currencies is a registered brand; the other is the asset.
            address brand = _brandOf(
                reserve, Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1)
            );
            if (!_contains(brands, brandCount, brand)) {
                require(brandCount < 3, "more than 3 brands");
                brands[brandCount++] = brand;
            }
        }
        console.log("distinct pooled brands:", brandCount);

        // ─── Broadcast ────────────────────────────────────────────────────────
        vm.startBroadcast(key);

        // 1. Burn every position; both sides land in the deployer's wallet.
        for (uint256 i; i < TOKEN_IDS.length; i++) {
            _burnAndTake(posm, TOKEN_IDS[i], me);
        }

        // 2. Redeem the deployer's whole balance of each brand back to USDG. Read AFTER the
        //    burns: forge applies each broadcast call to the local fork as the script runs, so
        //    these balances already include what the positions returned.
        for (uint256 i; i < brandCount; i++) {
            address brand = brands[i];
            uint256 bal = IUnwindToken(brand).balanceOf(me);
            if (bal == 0) continue;
            reserve.redeem(brand, bal, me);
        }

        vm.stopBroadcast();

        // ─── Post-state ───────────────────────────────────────────────────────
        uint256 usdgAfter = IUnwindToken(usdg).balanceOf(me);
        uint256 supplyAfter = reserve.totalPooledSupply();
        console.log("--- after ---");
        console.log("totalPooledSupply after:", supplyAfter);
        console.log("deployer USDG after (1e6):", usdgAfter / 1e6);
        console.log("USDG gained (1e6):", (usdgAfter - usdgBefore) / 1e6);
        console.log("pooled supply burned:", supplyBefore - supplyAfter);
        for (uint256 i; i < brandCount; i++) {
            console.log(
                "brand", brands[i], "left in wallet:", IUnwindToken(brands[i]).balanceOf(me)
            );
        }
    }

    /// @dev `BURN_POSITION` (decreases liquidity to zero, then burns the NFT) + `TAKE_PAIR`
    ///      (sends both currencies to `recipient`). Minimums are zero — see the contract note.
    function _burnAndTake(IPositionManagerV4 posm, uint256 tokenId, address recipient) private {
        (PoolKey memory poolKey,) = posm.getPoolAndPositionInfo(tokenId);

        bytes memory actions = abi.encodePacked(BURN_POSITION, TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(
            Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1), recipient
        );

        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    /// @dev Whichever of the two pool currencies is a registered pooled brand. Exactly one is.
    function _brandOf(IUnwindReserve reserve, address c0, address c1)
        private
        view
        returns (address brand)
    {
        bool r0 = reserve.isRegistered(c0);
        bool r1 = reserve.isRegistered(c1);
        require(r0 != r1, "expected exactly one registered currency");
        brand = r0 ? c0 : c1;
    }

    function _contains(address[] memory arr, uint256 n, address a) private pure returns (bool) {
        for (uint256 i; i < n; i++) {
            if (arr[i] == a) return true;
        }
        return false;
    }
}
