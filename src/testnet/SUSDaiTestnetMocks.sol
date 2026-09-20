// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";

import {IAcrossSpokePool} from "../interfaces/IAcrossSpokePool.sol";
import {ICurveStableSwapNG} from "../interfaces/ICurveStableSwapNG.sol";

abstract contract TestnetOnly {
    constructor() {
        require(
            block.chainid == 46630 || block.chainid == 421614 || block.chainid == 31337,
            "public testnet/local only"
        );
    }
}

/// @notice Permissionless faucet asset. It has no value and cannot be deployed on production chains.
contract SUSDaiTestnetToken is ERC20, TestnetOnly {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

/// @notice Deterministic sUSDai read model for public testnet integration exercises.
///
///         The `mint` faucet is open on purpose — handing anyone test shares is the whole point
///         of the fixture. The PRICES are not a faucet: `SUSDaiHub` derives its swap floors and
///         the value it reports home from them, so an unauthenticated `setSharePrices` let any
///         address mark the hub's collateral at dust and have the honest keeper sell all of it
///         for nothing (RSV-001). They are owner-only now.
///
///         Instances already deployed carry the old, open setter and cannot be fixed in place;
///         what protects the live deployment is `SUSDaiHub`'s own share-price band, which
///         refuses a price outside it no matter who wrote it.
contract SUSDaiTestnetShares is ERC20, Ownable, TestnetOnly {
    address public immutable asset;
    uint256 public depositSharePrice = 1.1e18;
    uint256 public redemptionSharePrice = 1.095e18;

    constructor(address asset_) ERC20("Test Staked USDai", "tsUSDai") Ownable(msg.sender) {
        require(asset_ != address(0), "asset is zero");
        asset = asset_;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function setSharePrices(uint256 depositPrice, uint256 redemptionPrice) external onlyOwner {
        require(depositPrice > 0 && redemptionPrice > 0, "price is zero");
        depositSharePrice = depositPrice;
        redemptionSharePrice = redemptionPrice;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * depositSharePrice / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets * 1e18 / depositSharePrice;
    }

    function totalShares() external view returns (uint256) {
        return totalSupply();
    }
}

/// @notice Two-coin fixed-rate Curve substitute. Coin 0 is 18-decimal shares; coin 1 is USDC.
///         `setRate` is owner-only for the same reason `setSharePrices` is: the hub executes
///         against this venue, so a world-writable rate is a world-writable execution price.
contract SUSDaiTestnetCurve is ICurveStableSwapNG, Ownable, TestnetOnly {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;
    uint256 private constant SCALE = 1e12;

    address public immutable shares;
    address public immutable usdc;
    uint256 public rate;
    uint256 public feeBps;

    constructor(address shares_, address usdc_, uint256 rate_, uint256 feeBps_)
        Ownable(msg.sender)
    {
        require(shares_ != address(0) && usdc_ != address(0), "token is zero");
        require(rate_ > 0 && feeBps_ <= 100, "invalid curve parameters");
        shares = shares_;
        usdc = usdc_;
        rate = rate_;
        feeBps = feeBps_;
    }

    function setRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "rate is zero");
        rate = newRate;
    }

    function coins(uint256 index) external view returns (address) {
        require(index < 2, "index");
        return index == 0 ? shares : usdc;
    }

    function N_COINS() external pure returns (uint256) {
        return 2;
    }

    function get_dy(int128 from, int128 to, uint256 amountIn) public view returns (uint256) {
        require((from == 0 && to == 1) || (from == 1 && to == 0), "pair");
        uint256 gross = from == 0 ? amountIn * rate / WAD / SCALE : amountIn * SCALE * WAD / rate;
        return gross - gross * feeBps / 10_000;
    }

    function exchange(int128 from, int128 to, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut)
    {
        amountOut = get_dy(from, to, amountIn);
        require(amountOut >= minOut, "slippage");
        (address tokenIn, address tokenOut) = from == 0 ? (shares, usdc) : (usdc, shares);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    function stored_rates() external view returns (uint256[] memory result) {
        result = new uint256[](2);
        result[0] = rate;
        result[1] = 1e30;
    }

    function balances(uint256 index) external view returns (uint256) {
        require(index < 2, "index");
        return IERC20(index == 0 ? shares : usdc).balanceOf(address(this));
    }

    function fee() external view returns (uint256) {
        return feeBps * 1e6;
    }
}

/// @notice Across-compatible escrow and event surface for the unsupported testnet route.
///         A configured relayer mints the destination faucet asset and emits the same fill event
///         the production keeper scans. Expired origin deposits can be refunded exactly once.
contract SUSDaiTestnetSpokePool is IAcrossSpokePool, Ownable2Step, TestnetOnly {
    using SafeERC20 for IERC20;

    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        uint32 fillDeadline;
    }

    struct RelayExecutionInfo {
        address updatedRecipient;
        bytes updatedMessage;
        uint256 updatedOutputAmount;
        uint8 fillType;
    }

    struct RelayData {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 originChainId;
        uint32 depositId;
        uint32 fillDeadline;
        address depositor;
        address recipient;
    }

    uint32 public numberOfDeposits;
    uint32 public constant depositQuoteTimeBuffer = 3600;
    uint32 public constant fillDeadlineBuffer = 21600;
    address public relayer;

    mapping(uint32 depositId => Deposit) public deposits;
    mapping(uint256 originChainId => mapping(uint32 depositId => bool)) public filled;

    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);
    event FilledV3Relay(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 repaymentChainId,
        uint256 indexed originChainId,
        uint32 indexed depositId,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        address exclusiveRelayer,
        address indexed relayer,
        address depositor,
        address recipient,
        bytes message,
        RelayExecutionInfo relayExecutionInfo
    );
    event ExecutedRelayerRefundRoot(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint256[] refundAmounts,
        uint32 indexed rootBundleId,
        uint32 indexed leafId,
        address l2TokenAddress,
        address[] refundAddresses,
        bool deferredRefunds,
        address caller
    );

    error NotRelayer();
    error InvalidQuoteTimestamp();
    error InvalidFillDeadline();
    error AlreadyFilled();
    error UnknownDeposit();
    error DepositNotExpired();

    constructor(address owner_, address relayer_) Ownable(owner_) {
        require(owner_ != address(0) && relayer_ != address(0), "authority is zero");
        relayer = relayer_;
    }

    function setRelayer(address newRelayer) external onlyOwner {
        require(newRelayer != address(0), "relayer is zero");
        emit RelayerUpdated(relayer, newRelayer);
        relayer = newRelayer;
    }

    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32,
        bytes calldata
    ) external payable {
        uint256 currentTime = getCurrentTime();
        if (currentTime < quoteTimestamp || currentTime - quoteTimestamp > depositQuoteTimeBuffer) {
            revert InvalidQuoteTimestamp();
        }
        if (fillDeadline < currentTime || fillDeadline > currentTime + fillDeadlineBuffer) {
            revert InvalidFillDeadline();
        }
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        deposits[numberOfDeposits] = Deposit({
            depositor: depositor,
            recipient: recipient,
            inputToken: inputToken,
            outputToken: outputToken,
            inputAmount: inputAmount,
            outputAmount: outputAmount,
            destinationChainId: destinationChainId,
            fillDeadline: fillDeadline
        });
        numberOfDeposits += 1;
    }

    function fill(RelayData calldata relay) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (filled[relay.originChainId][relay.depositId]) revert AlreadyFilled();
        if (block.timestamp > relay.fillDeadline) revert InvalidFillDeadline();
        filled[relay.originChainId][relay.depositId] = true;
        SUSDaiTestnetToken(relay.outputToken).mint(relay.recipient, relay.outputAmount);
        emit FilledV3Relay(
            relay.inputToken,
            relay.outputToken,
            relay.inputAmount,
            relay.outputAmount,
            0,
            relay.originChainId,
            relay.depositId,
            relay.fillDeadline,
            0,
            address(0),
            msg.sender,
            relay.depositor,
            relay.recipient,
            "",
            RelayExecutionInfo({
                updatedRecipient: relay.recipient,
                updatedMessage: "",
                updatedOutputAmount: relay.outputAmount,
                fillType: 0
            })
        );
    }

    function refund(uint32 depositId) external {
        if (msg.sender != relayer && msg.sender != owner()) revert NotRelayer();
        Deposit memory deposit = deposits[depositId];
        if (deposit.depositor == address(0)) revert UnknownDeposit();
        if (block.timestamp <= deposit.fillDeadline) revert DepositNotExpired();
        delete deposits[depositId];
        IERC20(deposit.inputToken).safeTransfer(deposit.depositor, deposit.inputAmount);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = deposit.inputAmount;
        address[] memory recipients = new address[](1);
        recipients[0] = deposit.depositor;
        emit ExecutedRelayerRefundRoot(
            0,
            block.chainid,
            amounts,
            0,
            depositId,
            deposit.inputToken,
            recipients,
            false,
            msg.sender
        );
    }

    function getCurrentTime() public view returns (uint256) {
        return block.timestamp;
    }
}
