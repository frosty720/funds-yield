// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin-4/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin-4/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignedMath} from "@openzeppelin-4/contracts/utils/math/SignedMath.sol";
import {StratFeeManagerInitializable} from "../StratFeeManagerInitializable.sol";
import {IVeloPool} from "../../interfaces/velodrome/IVeloPool.sol";
import {LiquidityAmounts} from "../../utils/LiquidityAmounts.sol";
import {TickMath} from "../../utils/TickMath.sol";
import {TickUtils, FullMath} from "../../utils/TickUtils.sol";
import {IFrostyClmVault} from "../../interfaces/clm/IFrostyClmVault.sol";
import {IStrategyConcLiq} from "../../interfaces/clm/IStrategyConcLiq.sol";
import {IStrategyVelodrome} from "../../interfaces/clm/IStrategyVelodrome.sol";
import {IStrategyFactory} from "../../interfaces/clm/IStrategyFactory.sol";
import {INftPositionManager} from "../../interfaces/velodrome/INftPositionManager.sol";

interface INftPositionManagerFactory {
    function factory() external view returns (address);
}

/// @title FrostyFi CLM strategy v2 (Aero Slipstream, fee-earning)
/// @author weso and frondoto, Beefy (StrategyPassiveManagerVelodromeV4, MIT; see NOTICE). Forked by FrostyFi 2026-10-11.
/// @notice FrostyFi 2026-10-25: FrostyClmStrategy without the gauge, for Aero's Slipstream pools. Aerodrome's gauges
///         were killed in the Aero upgrade (2026-10-22), and on Aero a position earns either AERO (staked) or the pool's
///         trading fees (unstaked, less the pool's 5% unstaked fee), never both. Most liquidity stakes, so unstaked
///         positions split the fees (founder 2026-10-25: fee-earning vaults). The positions are never staked. Every
///         vault action and harvest collects their fees in both tokens and pays the performance fee in kind; the rest is in
///         the share price at once, and a deposit is priced after that collect, so it pays for the fees already earned
///         and they stay with whoever held while they were earned. Parked and released over a day after each harvest
///         (Beefy's lock), they went to whoever held during that day instead (red-team YIELD-02, 2026-10-27).
contract FrostyClmStrategyV2 is StratFeeManagerInitializable, IStrategyConcLiq, IStrategyVelodrome {
    using SafeERC20 for IERC20Metadata;
    using TickMath for int24;

    /// @notice The precision for pricing.
    uint256 private constant PRECISION = 1e36;
    uint256 private constant SQRT_PRECISION = 1e18;

    /// @notice The max and min ticks univ3 allows.
    int56 private constant MIN_TICK = -887272;
    int56 private constant MAX_TICK = 887272;

    /// @notice The address of the Velodrome pool.
    address public pool;
    /// @notice The address of the NFT position manager.
    address public nftManager;
    /// @notice The address of the first token in the liquidity pool.
    address public lpToken0;
    /// @notice The address of the second token in the liquidity pool.
    address public lpToken1;

    /// @notice Unused since fees join the share price when collected (red-team YIELD-02, 2026-11-01). Kept: these
    ///         strategies upgrade in place behind a beacon, so the storage layout stays.
    uint256 public fees0;
    uint256 public fees1;

    /// @notice The pool token a harvest's fees are valued in for its events (the subgraph's and the terminal's yield:
    ///         fees ÷ value, as v1's sale proceeds were). Accounting never uses it.
    address public compoundToken;

    uint256 private constant BPS = 10_000;

    /// @notice The struct to store our tick positioning.
    struct Position {
        uint256 nftId;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice The main position of the strategy.
    /// @dev this will always be a 50/50 position that will be equal to position width * tickSpacing on each side.
    Position public positionMain;

    /// @notice The alternative position of the strategy.
    /// @dev this will always be a single sided (limit order) position that will start closest to current tick and continue to width * tickSpacing.
    /// This will always be in the token that has the most value after we fill our main position.
    Position public positionAlt;

    /// @notice The width of the position, thats a multiplier for tick spacing to find our range.
    int24 public positionWidth;

    /// @notice the max tick deviations we will allow for deposits/setTick.
    int56 public maxTickDeviation;

    /// @notice The twap interval seconds we use for the twap check.
    uint32 public twapInterval;

    /// @notice Initializes the ticks on first deposit.
    bool private initTicks;

    /// @notice The timestamp of the last deposit
    uint256 private lastDeposit;

    // Errors
    error NotAuthorized();
    error NotPool();
    error InvalidEntry();
    error NotVault();
    error InvalidInput();
    error InvalidOutput();
    error NotCalm();
    error TooMuchSlippage();
    error InvalidTicks();

    // Events
    event TVL(uint256 bal0, uint256 bal1);
    event HarvestRewards(uint256 fees);
    event SetPositionWidth(int24 oldWidth, int24 width);
    event SetDeviation(int56 maxTickDeviation);
    event SetTwapInterval(uint32 oldInterval, uint32 interval);
    /// @dev v2: `amount` is the fee's value in compoundToken (it is paid in both pool tokens; FeesCollected has them).
    event PerformanceFeePaid(address indexed treasury, uint256 amount);
    /// @dev v2: `received` is the harvested fees' value in compoundToken; nothing is sold (`outputSold` is 0).
    event Compounded(uint256 outputSold, uint256 received);
    /// @dev v2: the collected fees' value in compoundToken.
    event ClaimedRewards(uint256 fees);
    event FeesCollected(uint256 fee0, uint256 fee1, uint256 perfFee0, uint256 perfFee1);

     /// @notice Modifier to only allow deposit/setTick actions when current price is within a certain deviation of twap.
    modifier onlyCalmPeriods() {
        _onlyCalmPeriods();
        _;
    }

    /// @notice function to only allow deposit/setTick actions when current price is within a certain deviation of twap.
    function _onlyCalmPeriods() private view {
        if (!isCalm()) revert NotCalm();
    }

    modifier onlyRebalancers() {
        if (!IStrategyFactory(factory).rebalancers(msg.sender)) revert NotAuthorized();
        _;
    }

    /// @notice function to only allow deposit/harvest actions when current price is within a certain deviation of twap.
    function isCalm() public view returns (bool) {
        int24 tick = currentTick();
        int56 twapTick = twap();
        int56 shortTwapTick = shortTwap();

        int56 minCalmTick = int56(SignedMath.max(twapTick - maxTickDeviation, MIN_TICK));
        int56 maxCalmTick = int56(SignedMath.min(twapTick + maxTickDeviation, MAX_TICK));

        // Calculate if greater than deviation % from twap and revert if it is.
        if (minCalmTick > tick  || maxCalmTick < tick) return false;
        else if (minCalmTick > shortTwapTick || maxCalmTick < shortTwapTick) return false;
        else return true;
    }

    /// @notice When the next action can be performed: always now. v1 waited out the gauge's minimum stake time; v2
    ///         never stakes. Kept for the keeper's and the terminal's reads of every strategy.
    function actionableAt() public pure returns (uint256) {
        return 0;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the strategy and the inherited strat fee manager.
     * @dev Make sure cardinality is set appropriately for the twap.
     * @param _pool The underlying Slipstream pool.
     * @param _nftManager The NFT position manager of the pool's factory.
     * @param _positionWidth The multiplier for tick spacing to find our range.
     * @param _compoundToken The pool token harvests are valued in.
     * @param _commonAddresses The common addresses needed for the strat fee manager.
     */
    function initialize(
        address _pool,
        address _nftManager,
        int24 _positionWidth,
        address _compoundToken,
        CommonAddresses calldata _commonAddresses
    ) external initializer {
        __StratFeeManager_init(_commonAddresses);

        pool = _pool;
        nftManager = _nftManager;
        lpToken0 = IVeloPool(_pool).token0();
        lpToken1 = IVeloPool(_pool).token1();

        // FrostyFi 2026-10-25: the NFT manager must be the pool's factory's: another would hold the vault's positions
        // (v1 checked the gauge, which took the NFTs, for the same reason; security review 2026-09-27).
        if (INftPositionManagerFactory(_nftManager).factory() != IVeloPool(_pool).factory()) revert InvalidInput();
        if (_compoundToken != lpToken0 && _compoundToken != lpToken1) revert InvalidInput();
        compoundToken = _compoundToken;

        // Our width multiplier. The tick distance of each side will be width * tickSpacing.
        positionWidth = _positionWidth;

        // Set the twap interval to 120 seconds.
        twapInterval = 120;

        _giveAllowances();
    }

    /// @notice Only allows the vault to call a function.
    function _onlyVault() private view {
        if (msg.sender != vault) revert NotVault();
    }

    /// @notice Called during deposit and withdraw to remove liquidity and harvest fees for accounting purposes.
    function beforeAction() external {
        _onlyVault();
        _claimEarnings();
        _removeLiquidity();
    }

    /// @notice Called during deposit to add all liquidity back to their positions.
    function deposit() external onlyCalmPeriods {
        _onlyVault();

        if (!initTicks) {
            _setTicks();
            initTicks = true;
        }

        // Add all liquidity
        _addLiquidity();

        (uint256 bal0, uint256 bal1) = balances();

        lastDeposit = block.timestamp;

        // TVL Balances after deposit
        emit TVL(bal0, bal1);
    }

    /**
     * @notice Withdraws the specified amount of tokens from the strategy as calculated by the vault.
     * @param _amount0 The amount of token0 to withdraw.
     * @param _amount1 The amount of token1 to withdraw.
     */
    function withdraw(uint256 _amount0, uint256 _amount1) external {
        _onlyVault();

        if (block.timestamp == lastDeposit) _onlyCalmPeriods();

        // Liquidity has already been removed in beforeAction() so this is just a simple withdraw.
        if (_amount0 > 0) IERC20Metadata(lpToken0).safeTransfer(vault, _amount0);
        if (_amount1 > 0) IERC20Metadata(lpToken1).safeTransfer(vault, _amount1);

        // After we take what is needed we add it all back to our positions.
        if (!_isPaused()) _addLiquidity();

        (uint256 bal0, uint256 bal1) = balances();

        // TVL Balances after withdraw
        emit TVL(bal0, bal1);
    }

    /// @notice Adds liquidity to the main and alternative positions called on deposit, harvest and withdraw.
    function _addLiquidity() private onlyCalmPeriods {
        _whenStrategyNotPaused();

        (uint256 bal0, uint256 bal1) = balancesOfThis();

        int24 mainLower = positionMain.tickLower;
        int24 mainUpper = positionMain.tickUpper;
        int24 altLower = positionAlt.tickLower;
        int24 altUpper = positionAlt.tickUpper;
        uint160 sqrtprice = sqrtPrice();

        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        // Then we fetch how much liquidity we get for adding at the main position ticks with our token balances.
        {
            uint160 mainLowerSqrt = TickMath.getSqrtRatioAtTick(mainLower);
            uint160 mainUpperSqrt = TickMath.getSqrtRatioAtTick(mainUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtprice,
                mainLowerSqrt,
                mainUpperSqrt,
                bal0,
                bal1
            );

            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtprice,
                mainLowerSqrt,
                mainUpperSqrt,
                liquidity
            );
        }

        // Mint or add liquidity to the position.
        if (liquidity > 0 && !(amount0 == 0 || amount1 == 0)) {
            _mintPosition(mainLower, mainUpper, amount0, amount1, true);
            (bal0, bal1) = balancesOfThis();
        } else _onlyCalmPeriods();

        // Fetch how much liquidity we get for adding at the alternative position ticks with our token balances.
        {
            uint160 altLowerSqrt = TickMath.getSqrtRatioAtTick(altLower);
            uint160 altUpperSqrt = TickMath.getSqrtRatioAtTick(altUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtprice,
                altLowerSqrt,
                altUpperSqrt,
                bal0,
                bal1
            );

            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtprice,
                altLowerSqrt,
                altUpperSqrt,
                liquidity
            );

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtprice,
                altLowerSqrt,
                altUpperSqrt,
                amount0,
                amount1
            );
        }

        // Mint or add liquidity to the position.
        if (liquidity > 0 && (amount0 > 0 || amount1 > 0)) {
            _mintPosition(altLower, altUpper, amount0, amount1, false);
        }
    }

    /// @notice Mints a new position for the main or alternative position.
    function _mintPosition(int24 _tickLower, int24 _tickUpper, uint256 _amount0, uint256 _amount1, bool _mainPosition) private {
        INftPositionManager.MintParams memory mintParams = INftPositionManager.MintParams({
            token0: lpToken0,
            token1: lpToken1,
            tickSpacing: _tickDistance(),
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            amount0Desired: _amount0,
            amount1Desired: _amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });

        (uint256 nftId,,,) = INftPositionManager(nftManager).mint(mintParams);

        if (_mainPosition) positionMain.nftId = nftId;
        else positionAlt.nftId = nftId;
    }

    /// @notice Removes liquidity from the main and alternative positions, called on deposit, withdraw and harvest.
    function _removeLiquidity() private {
        uint128 liquidity;
        uint128 liquidityAlt;
        if (positionMain.nftId != 0) {
            (,,,,,,,liquidity,,,,) = INftPositionManager(nftManager).positions(positionMain.nftId);
        }

        if (positionAlt.nftId != 0) {
            (,,,,,,,liquidityAlt,,,,) = INftPositionManager(nftManager).positions(positionAlt.nftId);
        }

        // init our params
        INftPositionManager.DecreaseLiquidityParams memory decreaseLiquidityParams;
        INftPositionManager.CollectParams memory collectParams;

        // If we have liquidity in the positions we remove it and collect our tokens.
        if (liquidity > 0) {
            decreaseLiquidityParams = INftPositionManager.DecreaseLiquidityParams({
                tokenId: positionMain.nftId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

            collectParams = INftPositionManager.CollectParams({
                tokenId: positionMain.nftId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

            INftPositionManager(nftManager).decreaseLiquidity(decreaseLiquidityParams);
            INftPositionManager(nftManager).collect(collectParams);
            INftPositionManager(nftManager).burn(positionMain.nftId);
            positionMain.nftId = 0;

        }

        if (liquidityAlt > 0) {
            decreaseLiquidityParams = INftPositionManager.DecreaseLiquidityParams({
                tokenId: positionAlt.nftId,
                liquidity: liquidityAlt,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

            collectParams = INftPositionManager.CollectParams({
                tokenId: positionAlt.nftId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

            INftPositionManager(nftManager).decreaseLiquidity(decreaseLiquidityParams);
            INftPositionManager(nftManager).collect(collectParams);
            INftPositionManager(nftManager).burn(positionAlt.nftId);
            positionAlt.nftId = 0;

        }
    }

    /// @notice Function called to rebalance the position
    function moveTicks() external onlyCalmPeriods onlyRebalancers {
        _claimEarnings();
        _removeLiquidity();
        _setTicks();
        _addLiquidity();

        (uint256 bal0, uint256 bal1) = balances();
        emit TVL(bal0, bal1);
    }

    /// @notice FrostyFi 2026-10-25: collect the positions' trading fees, pay the performance fee and compound the rest.
    ///         Keeper or owner only (final review I2, 2026-10-13): a public harvest could be timed for a sandwich.
    function harvest() external onlyManager {
        _harvest();
    }

    /// @dev Refused while paused, as in v1. Capital that arrives just before a harvest can't take the yield earned before
    ///      it arrived (final review I1, 2026-10-13): its deposit collected those fees first and paid for them.
    function _harvest() private onlyCalmPeriods {
        _whenStrategyNotPaused();
        (uint256 received0, uint256 received1) = _claimEarnings();

        // Before the first deposit there are no ticks to add to (and no fees).
        if (initTicks) {
            _removeLiquidity();
            _addLiquidity();
        }

        lastHarvest = block.timestamp;
        emit HarvestRewards(_valueInCompoundToken(received0, received1));
    }

    /// @notice Collects the positions' trading fees and pays the performance fee in both pool tokens.
    /// @dev FrostyFi 2026-10-25: deposits, withdrawals, rebalances and harvests all collect (as v1 claimed at each). An
    ///      unstaked position's collect takes its fees to date: the NFT manager pokes the pool first (Aero
    ///      NonfungiblePositionManager.collect).
    /// @return net0 The token0 fees left for the depositors, after the performance fee.
    /// @return net1 The token1 fees left for the depositors.
    function _claimEarnings() private returns (uint256 net0, uint256 net1) {
        uint256 got0;
        uint256 got1;
        if (positionMain.nftId != 0) (got0, got1) = _collect(positionMain.nftId);
        if (positionAlt.nftId != 0) {
            (uint256 alt0, uint256 alt1) = _collect(positionAlt.nftId);
            got0 += alt0;
            got1 += alt1;
        }

        uint256 perf0 = got0 * perfFeeBps() / BPS;
        uint256 perf1 = got1 * perfFeeBps() / BPS;
        address to = treasury();
        if (perf0 > 0) IERC20Metadata(lpToken0).safeTransfer(to, perf0);
        if (perf1 > 0) IERC20Metadata(lpToken1).safeTransfer(to, perf1);
        net0 = got0 - perf0;
        net1 = got1 - perf1;

        emit FeesCollected(got0, got1, perf0, perf1);
        if (perf0 > 0 || perf1 > 0) emit PerformanceFeePaid(to, _valueInCompoundToken(perf0, perf1));
        emit ClaimedRewards(_valueInCompoundToken(got0, got1));
        // at every collect, since each one reaches the share price: the subgraph's yield sums these
        if (net0 > 0 || net1 > 0) emit Compounded(0, _valueInCompoundToken(net0, net1));
    }

    /// @dev One position's fees. It holds no principal owed: _removeLiquidity collects and burns in one go.
    function _collect(uint256 _nftId) private returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = INftPositionManager(nftManager).collect(INftPositionManager.CollectParams({
            tokenId: _nftId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        }));
    }

    /// @dev `_amount0` and `_amount1` in compoundToken at the pool price: only for events (the calm check bounds the
    ///      price at a harvest).
    function _valueInCompoundToken(uint256 _amount0, uint256 _amount1) private view returns (uint256) {
        uint256 _price = price();
        if (compoundToken == lpToken1) return _amount1 + FullMath.mulDiv(_amount0, _price, PRECISION);
        return _amount0 + (_price == 0 ? 0 : FullMath.mulDiv(_amount1, PRECISION, _price));
    }

    /**
     * @notice Returns total token balances in the strategy.
     * @return token0Bal The amount of token0 in the strategy.
     * @return token1Bal The amount of token1 in the strategy.
    */
    function balances() public view returns (uint256 token0Bal, uint256 token1Bal) {
        (uint256 thisBal0, uint256 thisBal1) = balancesOfThis();
        (uint256 poolBal0, uint256 poolBal1,,,,) = balancesOfPool();

        // For token0 and token1 we return balance of this contract + balance of positions.
        return (thisBal0 + poolBal0, thisBal1 + poolBal1);
    }

    /**
     * @notice Nothing is locked: fees join the share price when collected (red-team YIELD-02, 2026-11-01). Kept for
     *         the interface and for ClmVaultPriceFeed, which reads totalLocked0/1 for v1's vaults.
     * @return locked0 Always 0.
     * @return locked1 Always 0.
     */
    function lockedProfit() public override pure returns (uint256 locked0, uint256 locked1) {
        return (0, 0);
    }

    /**
     * @notice Returns total tokens sitting in the strategy.
     * @return token0Bal The amount of token0 in the strategy.
     * @return token1Bal The amount of token1 in the strategy.
    */
    function balancesOfThis() public view returns (uint256 token0Bal, uint256 token1Bal) {
        token0Bal = IERC20Metadata(lpToken0).balanceOf(address(this));
        token1Bal = IERC20Metadata(lpToken1).balanceOf(address(this));
    }

    /**
     * @notice Returns total tokens in pool positions (is a calculation which means it could be a little off by a few wei).
     * @return token0Bal The amount of token0 in the pool.
     * @return token1Bal The amount of token1 in the pool.
     * @return mainAmount0 The amount of token0 in the main position.
     * @return mainAmount1 The amount of token1 in the main position.
     * @return altAmount0 The amount of token0 in the alt position.
     * @return altAmount1 The amount of token1 in the alt position.
    */
    function balancesOfPool() public view returns (uint256 token0Bal, uint256 token1Bal, uint256 mainAmount0, uint256 mainAmount1, uint256 altAmount0, uint256 altAmount1) {
        uint160 sqrtPriceX96 = sqrtPrice();

        uint128 liquidity;
        uint128 altLiquidity;
        uint256 owed0;
        uint256 owed1;
        uint256 altOwed0;
        uint256 altOwed1;
        if (positionMain.nftId != 0) (liquidity, owed0, owed1) = _positions(positionMain.nftId);
        if (positionAlt.nftId != 0) (altLiquidity, altOwed0, altOwed1) = _positions(positionAlt.nftId);

        (mainAmount0, mainAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(positionMain.tickLower),
            TickMath.getSqrtRatioAtTick(positionMain.tickUpper),
            liquidity
        );

        (altAmount0, altAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(positionAlt.tickLower),
            TickMath.getSqrtRatioAtTick(positionAlt.tickUpper),
            altLiquidity
        );

        mainAmount0 += owed0;
        mainAmount1 += owed1;

        altAmount0 += altOwed0;
        altAmount1 += altOwed1;

        token0Bal = mainAmount0 + altAmount0;
        token1Bal = mainAmount1 + altAmount1;
    }

    /// @notice Returns the position of the nft.
    function _positions(uint _nftId) private view returns (uint128 liquidity, uint256 owed0, uint256 owed1) {
        (,,,,,,,liquidity,,,owed0, owed1) = INftPositionManager(nftManager).positions(_nftId);
    }

    /**
     * @notice Returns the range of the pool, will always be the main position.
     * @return lowerPrice The lower price of the position.
     * @return upperPrice The upper price of the position.
    */
    function range() external view returns (uint256 lowerPrice, uint256 upperPrice) {
        // the main position is always covering the alt range
        lowerPrice = _fetchPrice(positionMain.tickLower);
        upperPrice = _fetchPrice(positionMain.tickUpper);
    }

    /// @notice Fetch price for range
    function _fetchPrice(int24 _tick) private pure returns (uint256) {
        return FullMath.mulDiv(uint256(TickMath.getSqrtRatioAtTick(_tick)), SQRT_PRECISION, (2 ** 96)) ** 2;
    }

    /**
     * @notice The current tick of the pool.
     * @return tick The current tick of the pool.
    */
    function currentTick() public view returns (int24 tick) {
        (,tick,,,,) = IVeloPool(pool).slot0();
    }

    /**
     * @notice The current price of the pool.
     * @return _price The current price of the pool.
    */
    function price() public view returns (uint256 _price) {
        uint160 sqrtPriceX96 = sqrtPrice();
        _price = FullMath.mulDiv(uint256(sqrtPriceX96), SQRT_PRECISION, (2 ** 96)) ** 2;
    }

    /**
     * @notice The sqrt price of the pool.
     * @return sqrtPriceX96 The sqrt price of the pool.
    */
    function sqrtPrice() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,) = IVeloPool(pool).slot0();
    }

    /**
     * @notice The swap fee variable is the fee charged for swaps in the underlying pool in 18 decimals
     * @return fee The swap fee of the underlying pool
    */
    function swapFee() external override view returns (uint256 fee) {
        fee = uint256(IVeloPool(pool).fee()) * SQRT_PRECISION / 1e6;
    }

    /**
     * @notice The tick distance of the pool.
     * @return int24 The tick distance/spacing of the pool.
    */
    function _tickDistance() private view returns (int24) {
        return IVeloPool(pool).tickSpacing();
    }

    /// @notice Sets the tick positions for the main and alternative positions.
    function _setTicks() private onlyCalmPeriods {
        int24 tick = currentTick();
        int24 distance = _tickDistance();
        int24 width = positionWidth * distance;

        _setMainTick(tick, distance, width);
        _setAltTick(tick, distance, width);

        lastPositionAdjustment = block.timestamp;
    }

    /// @notice Sets the main tick position.
    function _setMainTick(int24 tick, int24 distance, int24 width) private {
        (positionMain.tickLower, positionMain.tickUpper) = TickUtils.baseTicks(
            tick,
            width,
            distance
        );
    }

    /// @notice Sets the alternative tick position.
    function _setAltTick(int24 tick, int24 distance, int24 width) private {
        (uint256 bal0, uint256 bal1) = balancesOfThis();

        // We calculate how much token0 we have in the price of token1.
        uint256 amount0;

        if (bal0 > 0) {
            amount0 = bal0 * price() / PRECISION;
        }

        // We set the alternative position based on the token that has the most value available. FrostyFi 2026-10-18:
        // an exact tie (or nothing at all, an empty vault's unpause) takes the token0 side: Beefy's `else if` left the
        // alt ticks at (0,0), and _addLiquidity's math then divided by zero (the first deposit of an exactly
        // equal-value pair reverted on Base).
        if (amount0 < bal1) {
            (positionAlt.tickLower, ) = TickUtils.baseTicks(
                tick,
                width,
                distance
            );

            (positionAlt.tickUpper, ) = TickUtils.baseTicks(
                tick,
                distance,
                distance
            );
        } else {
            (, positionAlt.tickLower) = TickUtils.baseTicks(
                tick,
                distance,
                distance
            );

            (, positionAlt.tickUpper) = TickUtils.baseTicks(
                tick,
                width,
                distance
            );
        }

        if (positionMain.tickLower == positionAlt.tickLower && positionMain.tickUpper == positionAlt.tickUpper) revert InvalidTicks();
    }

    /**
     * @notice Sets the deviation from the twap we will allow on adding liquidity.
     * @param _maxDeviation The max deviation from twap we will allow.
    */
    function setDeviation(int56 _maxDeviation) external onlyOwner {
        emit SetDeviation(_maxDeviation);

        // Require the deviation to be less than 40 times the tick spacing.
        if (_maxDeviation >= _tickDistance() * 40) revert InvalidInput();

        maxTickDeviation = _maxDeviation;
    }

    /**
     * @notice The twap of the last minute from the pool.
     * @return twapTick The twap of the last minute from the pool.
    */
    function twap() public view returns (int56 twapTick) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = uint32(twapInterval);
        secondsAgo[1] = 0;

        (int56[] memory tickCuml,) = IVeloPool(pool).observe(secondsAgo);
        twapTick = (tickCuml[1] - tickCuml[0]) / int32(twapInterval);
    }

    /**
     * @notice The twap of the last 3 seconds from the pool.
     * @return twapTick The twap of the last 3 seconds from the pool.
    */
    function shortTwap() public view returns (int56 twapTick) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = uint32(3);
        secondsAgo[1] = 0;

        (int56[] memory tickCuml,) = IVeloPool(pool).observe(secondsAgo);
        twapTick = (tickCuml[1] - tickCuml[0]) / int32(3);
    }

    /**
     * @notice Sets the twap interval for the strategy.
     * @param _interval The new twap interval.
    */
    function setTwapInterval(uint32 _interval) external onlyOwner {
        emit SetTwapInterval(twapInterval, _interval);

        // Require the interval to be greater than 60 seconds.
        if (_interval < 60) revert InvalidInput();

        twapInterval = _interval;
    }

    /**
     * @notice Sets our position width and readjusts our positions.
     * @param _width The new width multiplier of the position.
    */
    function setPositionWidth(int24 _width) external onlyOwner {
        emit SetPositionWidth(positionWidth, _width);
        _claimEarnings();
        _removeLiquidity();
        positionWidth = _width;
        _setTicks();
        _addLiquidity();
    }



    /// @notice Retire the strategy and return all the dust to the fee recipient.
    function retireVault() external onlyOwner {
        if (IFrostyClmVault(vault).totalSupply() != 10**3) revert NotAuthorized();
        panic(0,0);
        address feeRecipient = treasury();
        uint256 bal0 = IERC20Metadata(lpToken0).balanceOf(address(this));
        uint256 bal1 = IERC20Metadata(lpToken1).balanceOf(address(this));
        if (bal0 > 0) IERC20Metadata(lpToken0).safeTransfer(feeRecipient, bal0);
        if (bal1 > 0) IERC20Metadata(lpToken1).safeTransfer(feeRecipient, bal1);
        _transferOwnership(address(0));
    }


    /**
     * @notice Remove Liquidity and Allowances, then pause deposits.
     * @param _minAmount0 The minimum amount of token0 in the strategy after panic.
     * @param _minAmount1 The minimum amount of token1 in the strategy after panic.
     */
    function panic(uint256 _minAmount0, uint256 _minAmount1) public onlyManager {
        _claimEarnings();
        _removeLiquidity();
        _removeAllowances();
        _pause();

        (uint256 bal0, uint256 bal1) = balances();
        if (bal0 < _minAmount0 || bal1 < _minAmount1) revert TooMuchSlippage();
    }

    /// @notice Unpause deposits, give allowances and add liquidity.
    function unpause() external onlyManager {
        if (owner() == address(0)) revert NotAuthorized();
        _giveAllowances();
        _unpause();
        _setTicks();
        _addLiquidity();
    }

    /// @notice gives the NFT manager the pool tokens for minting.
    function _giveAllowances() private {
        IERC20Metadata(lpToken0).forceApprove(nftManager, type(uint256).max);
        IERC20Metadata(lpToken1).forceApprove(nftManager, type(uint256).max);
    }

    /// @notice removes the NFT manager's allowances.
    function _removeAllowances() private {
        IERC20Metadata(lpToken0).forceApprove(nftManager, 0);
        IERC20Metadata(lpToken1).forceApprove(nftManager, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (msg.sender != nftManager) revert NotAuthorized();
    }
}