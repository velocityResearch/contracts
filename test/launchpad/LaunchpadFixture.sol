// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {IPermit2, IPositionManagerV4} from "../../src/interfaces/IPositionManagerV4.sol";
import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {AssetMarketFactory} from "../../src/markets/AssetMarketFactory.sol";
import {MarketRouter} from "../../src/markets/MarketRouter.sol";
import {ProtocolFeeHook} from "../../src/markets/ProtocolFeeHook.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchDeployer} from "../../src/launchpad/LaunchDeployer.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {LaunchFeeEscrow} from "../../src/launchpad/LaunchFeeEscrow.sol";
import {LaunchGraduation} from "../../src/launchpad/LaunchGraduation.sol";
import {LaunchLocker} from "../../src/launchpad/LaunchLocker.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {
    ILaunchFeeEscrow,
    ILaunchGraduation,
    ILaunchLocker
} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockYieldSource} from "../mocks/MockYieldSource.sol";
import {StandInPermit2, StandInPositionManager} from "../markets/MarketRouter.t.sol";
import {StackFixture} from "../helpers/StackFixture.sol";

/// @title LaunchpadFixture
/// @notice The whole launchpad on top of the market stack, wired the way
///         `ProtocolStack.deployLaunchpad` wires it on chain: a real `PoolManager` behind the
///         real `ProtocolFeeHook`, a real `AssetMarketFactory` and reserve, and the launch
///         factory as a UUPS proxy with the locker, the graduation module and the deployer
///         wired one-shot around it.
///
///         The periphery pair is the offline suite's stand-in `PositionManager` and Permit2,
///         for the reason `MarketRouter.t.sol` gives: the real ones cannot be compiled into
///         this repo. What that leaves unproved — that Uniswap's own contracts accept the
///         calldata the graduation module builds — is `LaunchJourneyV4Fork`'s job.
///
///         The economics are the product's shipped defaults (plan §10): a 1e27 supply, a 1%
///         curve fee, the 0.50% LP tier, and a brand quoted with a 3,236 phantom reserve and
///         an 8,090 threshold, so a launch graduates once its curve holds 8,090 of the brand.
abstract contract LaunchpadFixture is StackFixture {
    // ─── Venue ───────────────────────────────────────────────────────────

    /// @dev Non-zero on purpose: every swap through a graduated market pays the hook's skim
    ///      off its input, exactly as a live market would.
    uint24 internal constant PROTOCOL_FEE_PIPS = 1_000; // 0.10%

    PoolManager internal manager;
    ProtocolFeeHook internal hook;
    PoolSwapTest internal poolSwap;
    StandInPermit2 internal permit2;
    StandInPositionManager internal posm;

    MockUSDC internal usdg;
    MockYieldSource internal yieldSource;
    SharedReservePool internal reserve;
    AssetMarketFactory internal marketFactory;
    MarketRouter internal router;

    // ─── Launchpad ───────────────────────────────────────────────────────

    LaunchFeeEscrow internal feeEscrow;
    LaunchLocker internal locker;
    LaunchGraduation internal graduation;
    LaunchDeployer internal launchDeployer;
    LaunchFactory internal launchFactory;

    /// @notice The brand every launch here is quoted in, registered on `reserve`.
    address internal quoteBrand;
    uint256 internal launchConfigId;

    uint256 internal constant LAUNCH_SUPPLY = 1e27;
    uint256 internal constant CURVE_FEE_BPS = 100;
    uint24 internal constant POOL_FEE = 5_000;
    uint256 internal constant PHANTOM_QUOTE = 3_236e6;
    uint256 internal constant GRADUATION_THRESHOLD = 8_090e6;
    uint256 internal constant LAUNCH_FEE = 1e6;
    uint8 internal constant QUOTE_DECIMALS = 6;

    address internal owner = address(0x0AD01);
    address internal protocolTreasury = address(0xF33);
    address internal protocolFeeRecipient = address(0xFEE);
    address internal creator = address(0x0FE);
    address internal creatorFeeRecipient = address(0xC0FE);
    address internal trader = address(0x7AAD);
    address internal stranger = address(0x57A);

    // ─── Deployment ──────────────────────────────────────────────────────

    /// @notice Everything, in the order the addresses require: the market stack first, then
    ///         the launch factory proxy (its helpers' constructors need its address), then
    ///         the helpers, then the one-shot wiring in both directions.
    function _deployLaunchpadStack() internal {
        _deployUpgradeBase();
        manager = new PoolManager(address(this));
        poolSwap = new PoolSwapTest(IPoolManager(address(manager)));
        hook = _deployHook();

        usdg = new MockUSDC();
        yieldSource = new MockYieldSource();
        reserve = _deployReservePool(address(usdg), address(yieldSource), owner);

        permit2 = new StandInPermit2();
        posm = new StandInPositionManager(IPoolManager(address(manager)), permit2);

        marketFactory = _deployFactory(
            reserve,
            IPoolManager(address(manager)),
            hook,
            IPositionManagerV4(address(posm)),
            protocolTreasury,
            address(0), // verification disabled; a launched token is never canonical anyway
            0, // the whole protocol cut of float yield stays with the market
            owner
        );

        vm.startPrank(owner);
        hook.setRegistrar(address(marketFactory));
        marketFactory.setProtocolFeePips(PROTOCOL_FEE_PIPS);
        vm.stopPrank();

        router = _deployRouter(
            reserve,
            marketFactory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            owner
        );

        feeEscrow = new LaunchFeeEscrow();
        launchFactory = LaunchFactory(
            address(
                new ERC1967Proxy(
                    address(new LaunchFactory()),
                    abi.encodeCall(
                        LaunchFactory.initialize,
                        (
                            owner,
                            address(protocolGuard),
                            marketFactory,
                            IPositionManagerV4(address(posm)),
                            ILaunchFeeEscrow(address(feeEscrow))
                        )
                    )
                )
            )
        );

        locker = new LaunchLocker(owner, address(launchFactory));
        graduation = new LaunchGraduation(
            address(launchFactory),
            marketFactory,
            IPositionManagerV4(address(posm)),
            IPermit2(address(permit2)),
            ILaunchLocker(address(locker)),
            ILaunchFeeEscrow(address(feeEscrow))
        );
        launchDeployer = new LaunchDeployer(address(launchFactory));

        vm.startPrank(owner);
        locker.setGraduation(address(graduation));
        launchFactory.setLaunchDeployer(launchDeployer);
        launchFactory.setGraduation(ILaunchGraduation(address(graduation)));
        launchFactory.setProtocolFeeRecipient(protocolFeeRecipient);
        launchFactory.setLaunchEnabled(true);
        launchConfigId = launchFactory.addLaunchConfig(
            LaunchFactory.LaunchConfig({
                supply: LAUNCH_SUPPLY, curveFeeBps: CURVE_FEE_BPS, poolFee: POOL_FEE, enabled: true
            })
        );
        vm.stopPrank();

        _setLaunchpad(marketFactory, address(graduation));

        // The quote brand: a plain representation brand on the default reserve, registered
        // the way any community would register theirs.
        (quoteBrand,) = marketFactory.registerBrand("Launch Dollar", "launchUSD");
        vm.prank(owner);
        launchFactory.setPairTokenEconomics(
            quoteBrand,
            LaunchFactory.PairTokenEconomics({
                reserve: address(reserve),
                phantomQuote: PHANTOM_QUOTE,
                graduationThreshold: GRADUATION_THRESHOLD,
                launchFee: LAUNCH_FEE,
                decimals: QUOTE_DECIMALS,
                approved: true
            })
        );
    }

    /// @dev A v4 hook's permission bits live in the low 14 bits of its own address, so the
    ///      address is not a free choice. `deployCodeTo` writes the contract where we want it
    ///      and still runs the constructor, so `Hooks.validateHookPermissions` still executes.
    function _deployHook() internal returns (ProtocolFeeHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x7777 << 144)
        );
        return _deployHookAt(flags, IPoolManager(address(manager)), owner);
    }

    // ─── Money ───────────────────────────────────────────────────────────

    /// @notice Put `amount` of the quote brand in `who`'s wallet, minted 1:1 from fresh USDG
    ///         at the reserve the way a person would.
    function _fundQuote(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(reserve), amount);
        reserve.mint(quoteBrand, amount, who);
        vm.stopPrank();
    }

    // ─── Launching and trading ───────────────────────────────────────────

    function _tokenParams(string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (LaunchFactory.TokenParams memory)
    {
        return LaunchFactory.TokenParams({
            name: name,
            symbol: symbol,
            logo: "",
            description: "",
            socials: LaunchToken.Socials({
                twitter: "", telegram: "", discord: "", website: "", farcaster: ""
            }),
            creatorFeeRecipient: creatorFeeRecipient,
            creatorTaxBps: 0,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    /// @notice Launch a token as `creator`, paying the launch fee in the quote brand, and
    ///         step past the snipe-tax window so the buys that follow trade at the untaxed
    ///         price.
    function _launch(string memory name, string memory symbol)
        internal
        returns (address token, address curve)
    {
        _fundQuote(creator, LAUNCH_FEE);
        vm.startPrank(creator);
        IERC20(quoteBrand).approve(address(launchFactory), LAUNCH_FEE);
        (token, curve) = launchFactory.launchToken(
            _tokenParams(name, symbol, keccak256(bytes(symbol))),
            launchConfigId,
            quoteBrand,
            new address[](0)
        );
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + launchFactory.snipeTaxSeconds() + 1);
    }

    /// @notice Buy on the curve as `who` with freshly minted quote. What the curve does not
    ///         spend — the excess of a threshold-crossing buy — comes back to `who`.
    function _buy(address curve, address who, uint256 quoteIn) internal returns (uint256) {
        _fundQuote(who, quoteIn);
        vm.startPrank(who);
        IERC20(quoteBrand).approve(curve, quoteIn);
        uint256 out = LaunchCurve(curve).buy(quoteIn, 0, who);
        vm.stopPrank();
        return out;
    }

    /// @notice One buy large enough to cross the threshold, which also runs phase one of
    ///         graduation from inside the curve. The curve refunds what it did not need.
    function _buyToThreshold(address curve, address who) internal {
        // Threshold plus the fee on it, with room: the crossing buy is partially filled and
        // the remainder refunded, so over-sending costs nothing.
        _buy(curve, who, GRADUATION_THRESHOLD * 2);
    }

    /// @notice Exact-input swap in a graduated market's pool through v4's own test router,
    ///         so the fees the locked position earns are Uniswap's arithmetic.
    function _swapInMarket(uint256 marketId, address who, address tokenIn, uint256 amountIn)
        internal
    {
        PoolKey memory key = marketFactory.poolKeyOf(marketId);
        bool zeroForOne = tokenIn == Currency.unwrap(key.currency0);

        vm.startPrank(who);
        IERC20(tokenIn).approve(address(poolSwap), amountIn);
        poolSwap.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }
}
