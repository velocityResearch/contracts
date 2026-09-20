// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {SharedReservePool} from "../../src/pool/SharedReservePool.sol";
import {LaunchCurve} from "../../src/launchpad/LaunchCurve.sol";
import {LaunchFactory} from "../../src/launchpad/LaunchFactory.sol";
import {GraduationPhase, ILaunchFactory} from "../../src/launchpad/interfaces/ILaunchpad.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";
import {LaunchpadFixture} from "./LaunchpadFixture.sol";

/// @title LaunchHandler
/// @notice The only address the invariant run is allowed to drive, so every state change a
///         launch can undergo arrives through the same functions a user's wallet would call:
///         buy, sell, sweep, and the two graduation phases.
///
///         Three properties are checked *inside* the handler rather than as invariants,
///         because they are statements about a transition rather than about a state:
///         - a buy never increases the curve's sellable allocation,
///         - a sell never decreases it (the tokens come back),
///         - a closed curve refuses both, with `CurveGraduated` and not some other revert.
///
///         The handler never reverts. Each entry point inspects the launch first and either
///         performs the real call or takes the "closed"/"not applicable" branch, so the suite
///         can run with `fail-on-revert = true` — which is what makes the call counters
///         reported by `afterInvariant` mean something. A run whose counters are zero is a run
///         that proved nothing, and this is how that would be visible.
contract LaunchHandler is Test {
    MockUSDC internal immutable usdg;
    SharedReservePool internal immutable reserve;
    LaunchFactory internal immutable launchFactory;
    LaunchCurve internal immutable curve;
    address internal immutable quoteBrand;
    address internal immutable token;

    address[3] public actors;

    // Call counters, reported by the test's `afterInvariant`.
    uint256 public buys;
    uint256 public sells;
    uint256 public sweeps;
    uint256 public phaseOnes;
    uint256 public marketGraduations;
    uint256 public refusedTrades;
    uint256 public refusedGraduations;
    uint256 public skipped;

    /// @notice Largest single curve buy the handler will make, and it is deliberately well
    ///         under the shipped 8,090 threshold: a sequence needs a run of buys — interleaved
    ///         with whatever sells and sweeps the fuzzer chooses — before it can graduate, so
    ///         the pre-graduation state space is actually explored rather than skipped over by
    ///         one enormous first buy.
    uint256 internal constant MAX_BUY = 2_500e6;

    constructor(
        MockUSDC usdg_,
        SharedReservePool reserve_,
        LaunchFactory launchFactory_,
        LaunchCurve curve_,
        address quoteBrand_,
        address token_,
        address[3] memory actors_
    ) {
        usdg = usdg_;
        reserve = reserve_;
        launchFactory = launchFactory_;
        curve = curve_;
        quoteBrand = quoteBrand_;
        token = token_;
        actors = actors_;
    }

    // ─── Trading ─────────────────────────────────────────────────────────

    function buy(uint256 actorSeed, uint256 quoteIn) external {
        address actor = _actor(actorSeed);
        if (curve.graduated()) {
            _proveClosed(actor);
            return;
        }
        // The window between "allocation exhausted" and "flag set" only exists if an auto
        // graduation failed. Trading is closed there too, and the curve says so with the same
        // error, but a probe would be bounced by the quote allowance first — so it is skipped
        // rather than mistaken for a passing check.
        if (curve.sellableTokens() == 0) {
            ++skipped;
            return;
        }

        uint256 amount = bound(quoteIn, 1e4, MAX_BUY);
        uint256 sellableBefore = curve.sellableTokens();
        _fundQuote(actor, amount);

        vm.startPrank(actor);
        IERC20(quoteBrand).approve(address(curve), amount);
        curve.buy(amount, 0, actor);
        vm.stopPrank();

        ++buys;
        assertLe(
            curve.sellableTokens(), sellableBefore, "a buy never adds to the sellable allocation"
        );
    }

    function sell(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        if (curve.graduated()) {
            _proveClosed(actor);
            return;
        }
        if (curve.sellableTokens() == 0) {
            ++skipped;
            return;
        }

        uint256 held = IERC20(token).balanceOf(actor);
        if (held == 0) {
            ++skipped;
            return;
        }
        uint256 tokensIn = bound(amountSeed, 1, held);
        // Two sales the curve refuses outright, and refuses correctly: one so small that the
        // constant product rounds its payout to nothing (`InsufficientOutputAmount`), and one
        // so large that paying it would take more quote than the curve physically holds — the
        // phantom reserve is not money. Both belong to the offline suite's assertions; here
        // they are simply not sales, so they are skipped rather than counted.
        uint256 quoteOut;
        try curve.quoteSell(tokensIn) returns (uint256 out, uint256, uint256) {
            quoteOut = out;
        } catch {
            ++skipped;
            return;
        }
        if (quoteOut == 0 || quoteOut > curve.realQuoteReserve()) {
            ++skipped;
            return;
        }

        uint256 sellableBefore = curve.sellableTokens();
        vm.startPrank(actor);
        IERC20(token).approve(address(curve), tokensIn);
        curve.sell(tokensIn, 0, actor);
        vm.stopPrank();

        ++sells;
        assertGe(curve.sellableTokens(), sellableBefore, "a sell returns supply to the allocation");
    }

    function sweepFees() external {
        if (curve.graduated()) {
            ++skipped;
            return;
        }
        curve.sweepFees();
        ++sweeps;
    }

    // ─── Graduation ──────────────────────────────────────────────────────

    /// @notice Phase one, which the crossing buy normally performs for itself. Whenever it has
    ///         already run — or the curve is not ready — this proves the factory refuses a
    ///         second sweep instead of paying one out.
    function graduate() external {
        ILaunchFactory.LaunchedToken memory launch = launchFactory.getLaunchedToken(token);
        if (launch.phase == GraduationPhase.NotGraduated && curve.readyToGraduate()) {
            launchFactory.graduate(token);
            ++phaseOnes;
            return;
        }
        try launchFactory.graduate(token) {
            revert("phase one ran on a launch that had already swept");
        } catch {
            ++refusedGraduations;
        }
    }

    function graduateToMarket() external {
        if (launchFactory.getLaunchedToken(token).phase != GraduationPhase.Swept) {
            try launchFactory.graduateToMarket(token) {
                revert("phase two ran outside the swept phase");
            } catch {
                ++refusedGraduations;
            }
            return;
        }
        launchFactory.graduateToMarket(token);
        ++marketGraduations;
    }

    // ─── Internals ───────────────────────────────────────────────────────

    /// @dev A graduated curve must refuse both sides, and refuse them with its own error: a
    ///      revert for any other reason would let a closed curve pass this check while still
    ///      being reachable under some other argument.
    function _proveClosed(address actor) private {
        try curve.buy(1e6, 0, actor) {
            revert("a graduated curve filled a buy");
        } catch (bytes memory err) {
            assertEq(bytes4(err), LaunchCurve.CurveGraduated.selector, "buy after graduation");
        }
        try curve.sell(1e18, 0, actor) {
            revert("a graduated curve filled a sell");
        } catch (bytes memory err) {
            assertEq(bytes4(err), LaunchCurve.CurveGraduated.selector, "sell after graduation");
        }
        ++refusedTrades;
    }

    /// @dev Quote brand for `who`, minted 1:1 from fresh USDG at the reserve the way a person
    ///      would. Every base unit of brand in the system enters through here.
    function _fundQuote(address who, uint256 amount) private {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(reserve), amount);
        reserve.mint(quoteBrand, amount, who);
        vm.stopPrank();
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }
}

/// @title LaunchpadInvariantTest
/// @notice What must hold about a launch no matter what order anyone trades, sweeps or
///         graduates it in.
///
///         The unit suites each drive one scripted sequence. These are the statements that have
///         to survive *every* sequence: the curve's own accounting, the conservation of the
///         launch's supply and of its quote brand across a set of addresses that is fixed and
///         enumerable, and the escrow never owing more of an asset than it holds. Each of them
///         is a property a real bug would break — a fee credited without the balance behind it,
///         a sell that pays out more quote than the curve holds, supply that vanishes into the
///         graduation module — and none of them is checked by any single scripted test, because
///         each depends on the whole history rather than on one call.
///
///         `forge test --match-path 'test/launchpad/LaunchpadInvariant.t.sol'`
contract LaunchpadInvariantTest is LaunchpadFixture {
    LaunchHandler internal handler;

    address internal launchToken;
    LaunchCurve internal curve;
    uint256 internal initialSellable;

    /// @dev Everywhere the launch token can legitimately be, and everywhere the quote brand
    ///      can. Both lists are closed: if a base unit of either ever reaches an address that
    ///      is not here, the conservation invariants fail, which is the point of enumerating
    ///      rather than summing what is convenient. The graduated market's unit address is not
    ///      known until a run graduates, so it is read live from the locker.
    address[] internal tokenHolders;
    address[] internal quoteHolders;

    address internal actorA = address(0xA11CE);
    address internal actorB = address(0xB0B);
    address internal actorC = address(0xCA401);

    function setUp() public {
        _deployLaunchpadStack();

        address curveAddr;
        (launchToken, curveAddr) = _launch("Cashcat", "CAT");
        curve = LaunchCurve(curveAddr);
        initialSellable = curve.sellableTokens();

        handler = new LaunchHandler(
            usdg, reserve, launchFactory, curve, quoteBrand, launchToken, [actorA, actorB, actorC]
        );

        // Anywhere either asset can legitimately sit. `posm` is here because the offline
        // periphery mints through the singleton and should never hold an ERC-20 itself —
        // including it means a leak into it would be counted rather than hidden.
        address[7] memory contracts = [
            curveAddr,
            address(launchFactory),
            address(graduation),
            address(locker),
            address(feeEscrow),
            address(manager),
            address(posm)
        ];
        address[7] memory wallets = [
            address(handler),
            actorA,
            actorB,
            actorC,
            creator,
            creatorFeeRecipient,
            protocolFeeRecipient
        ];
        for (uint256 i = 0; i < contracts.length; ++i) {
            tokenHolders.push(contracts[i]);
            quoteHolders.push(contracts[i]);
        }
        for (uint256 i = 0; i < wallets.length; ++i) {
            tokenHolders.push(wallets[i]);
            quoteHolders.push(wallets[i]);
        }

        targetContract(address(handler));
    }

    // ─── The curve's own books ───────────────────────────────────────────

    /// @notice The curve's tracked quote covers everything it has promised out of it, and its
    ///         real balance covers the tracked figure.
    ///
    ///         `trackedQuote` is the curve's claim about what it holds; the fee and tax
    ///         balances are claims against it, and the tradeable real reserve is what is left.
    ///         The first assertion is the accounting identity — a fee accrued without the quote
    ///         behind it breaks it — and the second is the one that matters to a holder: the
    ///         claim is backed by tokens that are actually there. Both are checked against a
    ///         live ERC-20 balance, which is deliberately *not* what the curve prices against.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theCurvesQuoteBooksAreBacked() public view {
        uint256 tracked = curve.trackedQuote();
        uint256 fees = curve.quoteFeeBalance();
        uint256 tax = curve.creatorTaxBalance();

        assertGe(tracked, fees + tax, "fees can never exceed the quote behind them");
        assertEq(tracked, curve.realQuoteReserve() + fees + tax, "the quote books add up exactly");
        assertGe(
            IERC20(quoteBrand).balanceOf(address(curve)), tracked, "and the balance backs the books"
        );
    }

    /// @notice The sellable allocation is bounded by what the launch minted for it, and a
    ///         graduated curve has none left.
    ///
    ///         The per-call direction — buys shrink it, sells return to it — is asserted inside
    ///         the handler, where the transition is visible. What is left for the invariant is
    ///         the bound: no sequence of buys and sells can conjure sellable supply that the
    ///         launch never allocated, which is what a sell that credited more tokens than it
    ///         received would do.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theSellableAllocationIsNeverInvented() public view {
        assertLe(curve.sellableTokens(), initialSellable, "never more than was allocated");
        assertTrue(
            curve.trackedTokens() == 0 || curve.trackedTokens() >= curve.reservedTokens(),
            "the reserved balance is never sold through"
        );
        if (curve.graduated()) {
            assertEq(curve.sellableTokens(), 0, "a graduated curve has nothing left to sell");
        }
    }

    /// @notice A graduated curve is empty and stays empty.
    ///
    ///         Graduation hands every tracked reserve to the factory and closes trading, so a
    ///         graduated curve holding tracked quote, tracked tokens or unswept fees would mean
    ///         either that something re-entered it afterwards or that the handover left money
    ///         behind with no way to ever move it. The refusal of the trades themselves is
    ///         proved in the handler, against the curve's own error.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_aGraduatedCurveIsEmptyForever() public view {
        if (!curve.graduated()) return;
        assertEq(curve.trackedQuote(), 0, "no tracked quote survives graduation");
        assertEq(curve.trackedTokens(), 0, "no tracked supply survives graduation");
        assertEq(curve.quoteFeeBalance(), 0, "fees were swept before the handover");
        assertEq(curve.creatorTaxBalance(), 0, "and so was the creator tax");
    }

    // ─── Conservation ────────────────────────────────────────────────────

    /// @notice The escrow never owes more of an asset than it holds.
    ///
    ///         Every recipient claims from one pooled balance per asset, so a credit recorded
    ///         without the transfer behind it does not starve the recipient who was
    ///         over-credited — it starves whoever claims last. That is why this is a solvency
    ///         invariant and not a pair of matching numbers.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_escrowCreditsAreCoveredByItsBalance() public view {
        _assertEscrowSolvent(quoteBrand);
        _assertEscrowSolvent(launchToken);
        address unit = locker.lockedPosition(launchToken).unit;
        if (unit != address(0)) _assertEscrowSolvent(unit);
    }

    /// @notice The launch's supply is fixed and always fully located.
    ///
    ///         Nothing in the protocol burns a launch token and nothing mints one after the
    ///         constructor, so the total is a constant. The second half is the stronger claim:
    ///         every base unit of it sits at one of a fixed, enumerated set of addresses — the
    ///         curve, the factory mid-graduation, the pool, the permanent lock, the escrow, or
    ///         a wallet that bought some. Supply reaching anywhere else is supply that leaked.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theLaunchSupplyIsConstantAndFullyLocated() public view {
        assertEq(IERC20(launchToken).totalSupply(), LAUNCH_SUPPLY, "supply is fixed");
        assertEq(
            _sum(launchToken, tokenHolders),
            LAUNCH_SUPPLY,
            "every token is on the curve, in the pool, in the lock or in a wallet"
        );
        assertGe(
            IERC20(launchToken).balanceOf(address(locker)),
            locker.lockedSupply(launchToken),
            "the locker's ledger is backed by its balance"
        );
    }

    /// @notice The quote brand never leaves the system unaccounted.
    ///
    ///         Brand enters only by a 1:1 mint at the reserve and leaves only by the reserve
    ///         burning it — which is what graduation does when it converts the curve's float
    ///         into the market's unit. Between those two, every base unit is on the curve, in
    ///         the escrow, with the factory mid-graduation, or in a wallet: the creator's, the
    ///         protocol's, or a trader's. Summing an enumerated set against `totalSupply` is
    ///         what makes "unaccounted" checkable at all.
    /// forge-config: default.invariant.runs = 16
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theQuoteBrandIsFullyAccountedFor() public view {
        assertEq(
            _sum(quoteBrand, quoteHolders),
            IERC20(quoteBrand).totalSupply(),
            "every base unit of the quote brand is somewhere known"
        );
    }

    // ─── Non-vacuity ─────────────────────────────────────────────────────

    /// @notice What the run actually did. An invariant suite whose handler never got past its
    ///         guards is a suite that asserts nothing, and these counters are the only way to
    ///         see the difference from the outside.
    function afterInvariant() public view {
        console.log("curve buys:", handler.buys());
        console.log("curve sells:", handler.sells());
        console.log("fee sweeps:", handler.sweeps());
        console.log("phase-one graduations (crossing buy aside):", handler.phaseOnes());
        console.log("market graduations:", handler.marketGraduations());
        console.log("trades refused by a graduated curve:", handler.refusedTrades());
        console.log("graduations refused out of phase:", handler.refusedGraduations());
        console.log("calls skipped as not applicable:", handler.skipped());

        assertGt(handler.buys(), 0, "the run never traded the curve");
        assertGt(
            handler.refusedGraduations() + handler.marketGraduations(),
            0,
            "the run never touched graduation"
        );
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _assertEscrowSolvent(address asset) private view {
        uint256 owed = feeEscrow.balanceOfToken(protocolFeeRecipient, asset)
            + feeEscrow.balanceOfToken(creatorFeeRecipient, asset)
            + feeEscrow.balanceOfToken(creator, asset);
        assertLe(owed, IERC20(asset).balanceOf(address(feeEscrow)), "escrow credits are covered");
    }

    function _sum(address asset, address[] storage holders) private view returns (uint256 total) {
        for (uint256 i = 0; i < holders.length; ++i) {
            total += IERC20(asset).balanceOf(holders[i]);
        }
    }
}
