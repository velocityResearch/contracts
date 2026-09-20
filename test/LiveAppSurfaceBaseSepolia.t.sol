// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/token/ERC721/IERC721.sol";

/// @notice THROWAWAY. Drives the DEPLOYED Base Sepolia stack through every call the application
///         sends, happy and unhappy, against the market-unit generation deployed 2026-09-15.
///         Addresses come from `deployments/asset-markets-base-sepolia.json`. This suite is pinned
///         to that deployment on purpose and is not part of the permanent suite.
interface ILiveFactory {
    struct AssetListing {
        bool approved;
        uint24 fee;
        uint256 assetPriceE18;
        uint16 observationCardinality;
        string unitName;
        string unitSymbol;
    }

    struct Metadata {
        string description;
        string logo;
        string socials;
    }

    struct Market {
        address asset;
        address brandToken;
        address treasury;
        address feeVault;
        address lpDistributor;
        bytes32 poolId;
        uint24 fee;
        int24 tickSpacing;
        address creator;
        bool verified;
        uint64 createdAt;
        address reservePool;
    }

    function createMarket(address asset, address reservePool)
        external
        returns (uint256, address, address, address, bytes32);
    function approveAsset(address asset, AssetListing calldata listing) external;
    function registerBrand(string calldata name, string calldata symbol, Metadata calldata m)
        external
        returns (address);
    function market(uint256 marketId) external view returns (Market memory);
    function marketCount() external view returns (uint256);
    function marketOfAsset(address reservePool, address asset) external view returns (uint256);
    function assetListing(address asset) external view returns (AssetListing memory);
    function marketOfBrand(address brandToken) external view returns (uint256);
    function approvedReservePool(address pool) external view returns (bool);
    function owner() external view returns (address);
    function setProtocolFeePips(uint24 pips) external;
}

interface ILiveRouter {
    function buyWithUsdg(uint256 id, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        returns (uint256);
    function buyWithBrand(
        uint256 id,
        address brandIn,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline
    ) external returns (uint256);
    function sellForBrand(
        uint256 id,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 deadline
    ) external returns (uint256);
    function seedLiquidity(
        uint256 id,
        uint256 brandIn,
        uint256 assetIn,
        uint256 minBrand,
        uint256 minAsset,
        uint256 deadline
    ) external returns (uint256, uint128, uint256, uint256);
}

interface ILiveReserve {
    function mint(address brand, uint256 assets, address to) external returns (uint256);
    function redeem(address brand, uint256 shares, address to) external returns (uint256);
    function swap(address from, address to, uint256 amount, address recipient)
        external
        returns (uint256);
    function registerBrand(string calldata name, string calldata symbol, address operator)
        external
        returns (address);
    function liabilityCap() external view returns (uint256);
    function setLiabilityCap(uint256 cap) external;
    function owner() external view returns (address);
    function upgradeToAndCall(address impl, bytes calldata data) external;
}

interface ILiveDistributor {
    function stake(uint256 tokenId, address beneficiary) external;
    function unstake(uint256 tokenId) external;
    function claim(address brandOut) external returns (uint256);
    function collectFees(uint256 tokenId) external;
    function earned(address account) external view returns (uint256);
    function positionsOf(address account) external view returns (uint256[] memory);
    function stakedLiquidityOf(address account) external view returns (uint256);
    function stakerOf(uint256 tokenId) external view returns (address);
    function totalStaked() external view returns (uint256);
    function rewardToken() external view returns (address);
    function rewardsDuration() external view returns (uint32);
    function fullRange() external view returns (int24, int24);
}

interface ILiveVault {
    function harvest() external returns (uint256);
    function sweep() external returns (uint256, uint256);
    function pendingYield() external view returns (uint256);
    function minSweep() external view returns (uint256);
    function lpBps() external view returns (uint16);
    function distributor() external view returns (address);
}

interface IFaucetAsset {
    function mint(address to, uint256 amount) external;
}

contract LiveAppSurfaceBaseSepoliaForkTest is Test {
    // deployments/asset-markets-base-sepolia.json, 2026-09-15 market-unit generation.
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant ASSET = 0x0ef8e07b6cd00Df5FDEAac4414293c904a97459d;
    address constant RESERVE = 0x8176AA7C41E5AF467Bb71b67dDDc5dC06b50D704;
    address constant SUSDAI_RESERVE = 0x2219DC1c5Ef859A004B66AB55769F945ceF1ff44;
    address constant FACTORY = 0x512B12bbd112a31314B0567Bd70C6f38a62AD509;
    address constant ROUTER = 0xCA09922d92bF652466723FD227F3517a1F182864;
    address constant UNIT = 0x0025bA36f8D4e40F13F520CDEDC3Ec93a80328E3;
    address constant FEE_VAULT = 0x782b69247b2a8A4197A50f6a40B410EF7e02348e;
    address constant DISTRIBUTOR = 0x822E207CA74e851595dCA32c9EE7E4dCd0c017bf;
    address constant POSITION_MANAGER = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80;
    address constant DEPLOYER = 0xeA6Af6c49cdf4654bCC72007d2095121BB2812A9;
    uint256 constant MARKET1 = 1;
    uint256 constant SEEDED_POSITION = 28076;

    ILiveFactory factory = ILiveFactory(FACTORY);
    ILiveRouter router = ILiveRouter(ROUTER);
    ILiveReserve reserve = ILiveReserve(RESERVE);
    ILiveDistributor distributor = ILiveDistributor(DISTRIBUTOR);
    ILiveVault vault = ILiveVault(FEE_VAULT);

    address user = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://base-sepolia-rpc.publicnode.com"))
        );
        deal(USDC, user, 5_000e6);
        vm.deal(user, 10 ether);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 600;
    }

    function _mintUnit(address to, uint256 amount) internal {
        vm.startPrank(to);
        IERC20(USDC).approve(RESERVE, amount);
        reserve.mint(UNIT, amount, to);
        vm.stopPrank();
    }

    // ─── Wiring: the deployment is what the manifest says ────────────────

    function test_wiring_marketOneIsTheUnitMarketOnTheApprovedAsset() public view {
        ILiveFactory.Market memory m = factory.market(MARKET1);
        assertEq(m.asset, ASSET, "asset");
        assertEq(m.brandToken, UNIT, "unit");
        assertEq(m.lpDistributor, DISTRIBUTOR, "distributor");
        assertEq(m.reservePool, RESERVE, "reserve");
        assertEq(m.creator, DEPLOYER, "creator");
        assertEq(factory.marketOfAsset(RESERVE, ASSET), MARKET1, "pair index");
        assertEq(vault.distributor(), DISTRIBUTOR, "vault pays this market's distributor");
        assertEq(distributor.rewardToken(), UNIT, "rewards are paid in the unit");
        assertEq(distributor.rewardsDuration(), 7 days, "reward period");
        assertEq(vault.lpBps(), 10_000, "the whole float goes to LPs while protocolBps is zero");
    }

    // ─── Happy paths ────────────────────────────────────────────────────

    function test_happy_faucetMintsTheAsset() public {
        vm.prank(user);
        IFaucetAsset(ASSET).mint(user, 10e18);
        assertEq(IERC20(ASSET).balanceOf(user), 10e18, "faucet did not mint");
    }

    function test_happy_mintTheUnitOneForOne() public {
        _mintUnit(user, 1_000e6);
        assertEq(IERC20(UNIT).balanceOf(user), 1_000e6, "unit not credited 1:1");
    }

    function test_happy_buyWithUsdg() public {
        vm.startPrank(user);
        IERC20(USDC).approve(ROUTER, 100e6);
        uint256 out = router.buyWithUsdg(MARKET1, 100e6, 1, user, _deadline());
        vm.stopPrank();
        assertGt(out, 0, "no asset received");
    }

    /// @notice The path the new pay-token menu opens: pay in a representation brand and let the
    ///         router cross it into the unit inside the same call.
    function test_happy_buyWithARepresentationBrand() public {
        vm.prank(user);
        address representation = factory.registerBrand(
            "Scenario Wallet Dollar",
            "scnW",
            ILiveFactory.Metadata({description: "scenario", logo: "", socials: ""})
        );
        vm.startPrank(user);
        IERC20(USDC).approve(RESERVE, 100e6);
        reserve.mint(representation, 100e6, user);
        IERC20(representation).approve(ROUTER, 100e6);
        uint256 out = router.buyWithBrand(MARKET1, representation, 100e6, 1, user, _deadline());
        vm.stopPrank();
        assertGt(out, 0, "cross-and-buy produced nothing");
        assertEq(factory.marketOfBrand(representation), 0, "a representation has no market");
    }

    function test_happy_sellForTheUnit() public {
        vm.startPrank(user);
        IFaucetAsset(ASSET).mint(user, 1e18);
        IERC20(ASSET).approve(ROUTER, 1e18);
        uint256 out = router.sellForBrand(MARKET1, 1e18, 1, user, _deadline());
        vm.stopPrank();
        assertGt(out, 0, "no unit received");
    }

    function test_happy_redeemTheUnitForUsdc() public {
        _mintUnit(user, 500e6);
        vm.startPrank(user);
        uint256 before = IERC20(USDC).balanceOf(user);
        uint256 paid = reserve.redeem(UNIT, 500e6, user);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(user) - before, paid, "USDC not delivered");
    }

    function test_happy_seedLiquidityMintsAFullRangePosition() public {
        _mintUnit(user, 100e6);
        vm.startPrank(user);
        IFaucetAsset(ASSET).mint(user, 100e18);
        IERC20(UNIT).approve(ROUTER, 100e6);
        IERC20(ASSET).approve(ROUTER, 100e18);
        (uint256 tokenId, uint128 liquidity,,) =
            router.seedLiquidity(MARKET1, 100e6, 100e18, 0, 0, _deadline());
        vm.stopPrank();
        assertGt(tokenId, 0, "no position minted");
        assertGt(liquidity, 0, "no liquidity added");
    }

    /// @notice The headline new flow: approve-then-stake, exactly as the rewards panel sends it.
    function test_happy_stakeAndUnstakeALiquidityPosition() public {
        _mintUnit(user, 100e6);
        vm.startPrank(user);
        IFaucetAsset(ASSET).mint(user, 100e18);
        IERC20(UNIT).approve(ROUTER, 100e6);
        IERC20(ASSET).approve(ROUTER, 100e18);
        (uint256 tokenId,,,) = router.seedLiquidity(MARKET1, 100e6, 100e18, 0, 0, _deadline());

        IERC721(POSITION_MANAGER).approve(DISTRIBUTOR, tokenId);
        distributor.stake(tokenId, user);
        assertEq(distributor.stakerOf(tokenId), user, "not recorded as staker");
        assertGt(distributor.stakedLiquidityOf(user), 0, "no staked liquidity");
        assertEq(distributor.positionsOf(user).length, 1, "position not listed");

        distributor.unstake(tokenId);
        vm.stopPrank();
        assertEq(distributor.stakerOf(tokenId), address(0), "still staked");
        assertEq(IERC721(POSITION_MANAGER).ownerOf(tokenId), user, "position not returned");
    }

    /// @notice Yield reaches a staked LP: harvest, sweep, then the stake earns and can claim.
    function test_happy_sweptFloatReachesAStakedProvider() public {
        _mintUnit(user, 1_000e6);
        vm.startPrank(user);
        IFaucetAsset(ASSET).mint(user, 100e18);
        IERC20(UNIT).approve(ROUTER, 100e6);
        IERC20(ASSET).approve(ROUTER, 100e18);
        (uint256 tokenId,,,) = router.seedLiquidity(MARKET1, 100e6, 100e18, 0, 0, _deadline());
        IERC721(POSITION_MANAGER).approve(DISTRIBUTOR, tokenId);
        distributor.stake(tokenId, user);
        vm.stopPrank();

        // The testnet yield source accrues on its own schedule; give it time, then run the
        // permissionless path the rewards panel exposes.
        vm.warp(block.timestamp + 7 days);
        vault.harvest();
        if (
            IERC20(USDC).balanceOf(FEE_VAULT) + IERC20(UNIT).balanceOf(FEE_VAULT) < vault.minSweep()
        ) {
            // Nothing accrued on this fork; the streaming path is covered by the offline suite.
            return;
        }
        (uint256 toProtocol, uint256 toLps) = vault.sweep();
        assertEq(toProtocol, 0, "protocolBps is zero on this deployment");
        assertGt(toLps, 0, "sweep paid the distributor nothing");

        vm.warp(block.timestamp + 1 days);
        assertGt(distributor.earned(user), 0, "a staked provider earned nothing");
        vm.prank(user);
        uint256 claimed = distributor.claim(UNIT);
        assertGt(claimed, 0, "claim paid nothing");
    }

    function test_happy_createAMarketOnTheSusdaiReserve() public {
        assertTrue(factory.approvedReservePool(SUSDAI_RESERVE), "sUSDai reserve not approved");
        assertEq(factory.marketOfAsset(SUSDAI_RESERVE, ASSET), 0, "pair already taken");
        vm.prank(user);
        (uint256 id, address unit,,,) = factory.createMarket(ASSET, SUSDAI_RESERVE);
        assertEq(factory.market(id).reservePool, SUSDAI_RESERVE, "market not on the sUSDai reserve");
        assertEq(factory.market(id).creator, user, "creator not recorded");
        assertEq(factory.market(id).brandToken, unit, "unit not indexed");
    }

    function test_happy_registerARepresentationBrand() public {
        vm.prank(user);
        address brand = factory.registerBrand(
            "Scenario Dollar",
            "scnUSD",
            ILiveFactory.Metadata({description: "scenario", logo: "", socials: ""})
        );
        assertGt(uint160(brand), 0, "no brand deployed");
        vm.startPrank(user);
        IERC20(USDC).approve(RESERVE, 10e6);
        assertEq(reserve.mint(brand, 10e6, user), 10e6, "representation does not mint 1:1");
        vm.stopPrank();
    }

    // ─── Unhappy paths ──────────────────────────────────────────────────

    function test_unhappy_anUnapprovedAssetCannotGetAMarket() public {
        vm.prank(user);
        vm.expectRevert();
        factory.createMarket(USDC, RESERVE);
    }

    function test_unhappy_aPairCannotGetASecondMarket() public {
        vm.prank(user);
        vm.expectRevert();
        factory.createMarket(ASSET, RESERVE);
    }

    function test_unhappy_anUnapprovedReserveIsRefused() public {
        vm.prank(user);
        vm.expectRevert();
        factory.createMarket(ASSET, address(0xBEEF));
    }

    function test_unhappy_buyRefusedWhenSlippageCannotBeMet() public {
        vm.startPrank(user);
        IERC20(USDC).approve(ROUTER, 100e6);
        vm.expectRevert();
        router.buyWithUsdg(MARKET1, 100e6, type(uint128).max, user, _deadline());
        vm.stopPrank();
    }

    function test_unhappy_expiredDeadlineIsRefused() public {
        vm.startPrank(user);
        IERC20(USDC).approve(ROUTER, 100e6);
        vm.expectRevert();
        router.buyWithUsdg(MARKET1, 100e6, 1, user, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_unhappy_zeroAmountIsRefused() public {
        vm.prank(user);
        vm.expectRevert();
        router.buyWithUsdg(MARKET1, 0, 0, user, _deadline());
    }

    function test_unhappy_mintWithoutApprovalIsRefused() public {
        vm.prank(user);
        vm.expectRevert();
        reserve.mint(UNIT, 100e6, user);
    }

    function test_unhappy_redeemBeyondBalanceIsRefused() public {
        vm.prank(user);
        vm.expectRevert();
        reserve.redeem(UNIT, 1_000_000e6, user);
    }

    function test_unhappy_mintBeyondTheLiabilityCapIsRefused() public {
        deal(USDC, user, 200_000_000e6);
        vm.startPrank(user);
        IERC20(USDC).approve(RESERVE, 200_000_000e6);
        vm.expectRevert();
        reserve.mint(UNIT, 200_000_000e6, user);
        vm.stopPrank();
    }

    /// @notice The refusal the rewards panel pre-checks rather than letting a wallet hit it.
    function test_unhappy_aPositionFromAnotherPoolCannotBeStaked() public {
        vm.prank(user);
        vm.expectRevert();
        distributor.stake(SEEDED_POSITION, user);
    }

    function test_unhappy_onlyTheStakerCanUnstake() public {
        vm.prank(user);
        vm.expectRevert();
        distributor.unstake(SEEDED_POSITION);
    }

    function test_unhappy_claimingInAForeignBrandIsRefused() public {
        vm.prank(user);
        vm.expectRevert();
        distributor.claim(USDC);
    }

    function test_unhappy_strangerCannotApproveAnAsset() public {
        vm.prank(user);
        vm.expectRevert();
        factory.approveAsset(
            USDC,
            ILiveFactory.AssetListing({
                approved: true,
                fee: 3000,
                assetPriceE18: 1e18,
                observationCardinality: 62,
                unitName: "Rogue",
                unitSymbol: "rogue"
            })
        );
    }

    function test_unhappy_strangerCannotRetuneTheFactory() public {
        vm.prank(user);
        vm.expectRevert();
        factory.setProtocolFeePips(10_000);
    }

    function test_unhappy_strangerCannotUpgradeTheReserve() public {
        vm.prank(user);
        vm.expectRevert();
        reserve.upgradeToAndCall(address(0xBEEF), "");
    }

    function test_unhappy_strangerCannotMoveTheLiabilityCap() public {
        vm.prank(user);
        vm.expectRevert();
        reserve.setLiabilityCap(type(uint256).max);
    }
}
