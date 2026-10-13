// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin-4/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin-4/contracts/token/ERC721/IERC721.sol";
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
import {ICLGauge} from "../../interfaces/velodrome/ICLGauge.sol";
import {IAerodromeRouter} from "../../interfaces/aerodrome/IAerodromeRouter.sol";
import {IValueInterpreter} from "../../interfaces/frosty/IValueInterpreter.sol";

interface ICLGaugeFactory {
    function minStakeTimes(address _pool) external view returns (uint256);
}

/// @title FrostyFi CLM strategy (Aerodrome Slipstream)
/// @author weso and frondoto, Beefy (StrategyPassiveManagerVelodromeV4, MIT; see NOTICE). Forked by FrostyFi 2026-10-11.
/// @notice This is a contract for managing a passive concentrated liquidity position on Velodrome.
contract FrostyClmStrategy is StratFeeManagerInitializable, IStrategyConcLiq, IStrategyVelodrome {
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
    /// @notice The address of the gauge.
    address public gauge;
    /// @notice The address of the output.
    address public output;
    /// @notice The address of the first token in the liquidity pool.
    address public lpToken0;
    /// @notice The address of the second token in the liquidity pool.
    address public lpToken1;

    /// @notice Claimed output, net of the performance fee, waiting to be compounded.
    uint256 public fees;

    /// @notice FrostyFi 2026-10-11: harvested output is sold into this pool token and added back as liquidity
    ///         (Beefy sent it to a reward pool).
    address public compoundToken;

    /// @notice FrostyFi 2026-10-11: the Aerodrome basic-pool factory of the output → compoundToken route.
    address public routeFactory;

    /// @notice FrostyFi 2026-10-11: the most a harvest's sale may come in under the ValueInterpreter's price (hard rule 5).
    uint256 public constant MAX_SALE_SLIPPAGE_BPS = 200;

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

    /// @notice The timestamp of the most recent gauge deposit.
    uint256 public lastGaugeDeposit;

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
    error ActionLocked(uint256 unlockAt);
    error CallStarved();

    // Events
    event TVL(uint256 bal0, uint256 bal1);
    event HarvestRewards(uint256 fees);
    event SetPositionWidth(int24 oldWidth, int24 width);
    event SetDeviation(int56 maxTickDeviation);
    event SetTwapInterval(uint32 oldInterval, uint32 interval);
    event PerformanceFeePaid(address indexed treasury, uint256 amount);
    event Compounded(uint256 outputSold, uint256 received);
    event SetSwapRoute(address routeFactory, address compoundToken);
    event ClaimedRewards(uint256 fees);

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

    /// @notice Returns the time when the next action can be performed.
    /// @return unlockAt The timestamp when the next action can be performed.
    function actionableAt() public view returns (uint256 unlockAt) {
        unlockAt = lastGaugeDeposit + minActionDelay();
    }

    /// @notice Enforces the action delay for the strategy.
    /// @dev Reverts if the action delay has not passed.
    function _enforceActionDelay() private view {
        if (!_isPaused()) {
            uint256 unlockAt = actionableAt();
            if (block.timestamp < unlockAt) revert ActionLocked(unlockAt);
        }
    }

    /// @notice Returns the minimum action delay for the strategy.
    /// @return The minimum action delay in seconds.
    /// @dev FrostyFi 2026-10-13 (plan 1b): Slipstream-1 and -3 gauges are an older CLGauge with no minimum stake time and
    ///      no early-claim penalty; their factories have no `minStakeTimes`, so the delay there is 0. A read that failed
    ///      for want of gas reverts instead: on Slipstream-2 a claim inside the minimum stake time forfeits the reward.
    function minActionDelay() public view returns (uint256) {
        address factory = ICLGauge(gauge).gaugeFactory();
        uint256 gasBefore = gasleft();
        try ICLGaugeFactory(factory).minStakeTimes(pool) returns (uint256 delay) {
            return delay;
        } catch {
            if (gasleft() < gasBefore / 63) revert CallStarved();
            return 0;
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the strategy and the inherited strat fee manager.
     * @dev Make sure cardinality is set appropriately for the twap.
     * @param _pool The underlying Velodrome pool.
     * @param _nftManager The NFT position manager.
     * @param _gauge The pool's gauge.
     * @param _output The output (reward) token for the strategy.
     * @param _positionWidth The multiplier for tick spacing to find our range.
     * @param _routeFactory The Aerodrome basic-pool factory of the output → compoundToken sale.
     * @param _compoundToken The pool token harvested output is sold into.
     * @param _commonAddresses The common addresses needed for the strat fee manager.
     */
    function initialize(
        address _pool,
        address _nftManager,
        address _gauge,
        address _output,
        int24 _positionWidth,
        address _routeFactory,
        address _compoundToken,
        CommonAddresses calldata _commonAddresses
    ) external initializer {
        __StratFeeManager_init(_commonAddresses);

        pool = _pool;
        output = _output;
        nftManager = _nftManager;
        gauge = _gauge;
        lpToken0 = IVeloPool(_pool).token0();
        lpToken1 = IVeloPool(_pool).token1();

        // FrostyFi 2026-10-11: the gauge must be this pool's and pay `_output` (a wrong gauge would take the NFTs;
        // security review 2026-09-27 found that in the LP positions). The reward is sold into a pool token, so it
        // can't be one.
        if (ICLGauge(_gauge).pool() != _pool || ICLGauge(_gauge).rewardToken() != _output) revert InvalidInput();
        if (_output == lpToken0 || _output == lpToken1) revert InvalidInput();
        _setSwapRoute(_routeFactory, _compoundToken);

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
        _enforceActionDelay();
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

        if (positionMain.nftId != 0) ICLGauge(gauge).deposit(positionMain.nftId);
        if (positionAlt.nftId != 0) ICLGauge(gauge).deposit(positionAlt.nftId);
        if (positionMain.nftId != 0 || positionAlt.nftId != 0) lastGaugeDeposit = block.timestamp;
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

        IERC721(nftManager).approve(gauge, nftId);
    }

    /// @notice Removes liquidity from the main and alternative positions, called on deposit, withdraw and harvest.
    function _removeLiquidity() private {
        uint128 liquidity;
        uint128 liquidityAlt;
        if (positionMain.nftId != 0) {
            (,,,,,,,liquidity,,,,) = INftPositionManager(nftManager).positions(positionMain.nftId);
            ICLGauge(gauge).withdraw(positionMain.nftId);
        }

        if (positionAlt.nftId != 0) {
            (,,,,,,,liquidityAlt,,,,) = INftPositionManager(nftManager).positions(positionAlt.nftId);
            ICLGauge(gauge).withdraw(positionAlt.nftId);
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

    /// @notice FrostyFi 2026-10-11: claim the gauge's output, sell it into `compoundToken` and add it back as liquidity.
    ///         Keeper or owner only (final review I2, 2026-10-13): a harvest re-stakes, which restarts every holder's
    ///         exit delay, and a public one let anyone do that for free and time the sale for a sandwich.
    function harvest() external onlyManager {
        _harvest();
    }

    /// @dev Waits out the gauge's minimum stake time like deposits and withdrawals do: a claim inside it forfeits the
    ///      reward (the CLGauge's `penaltyRate` was 100% on Base on 2026-10-11). Refused while paused: `panic` removes
    ///      the router's allowance, so the sale would fail anyway, without a reason.
    function _harvest() private onlyCalmPeriods {
        _whenStrategyNotPaused();
        _enforceActionDelay();
        _claimEarnings();

        uint256 toSell = fees;
        uint256 minOut = _saleMinimum(toSell);
        uint256 received;
        // Too little to sell (the oracle values it at 0 units of compoundToken): it waits for the next harvest.
        if (minOut != 0) {
            fees = 0;
            received = _sellOutput(toSell, minOut);
            emit Compounded(toSell, received);
        }

        // Before the first deposit there are no ticks to add to.
        if (initTicks) {
            _removeLiquidity();
            _addLiquidity();
        }

        // FrostyFi 2026-10-13 (final review I1): the proceeds reach the share price linearly over DURATION, so capital
        // that arrives just before a harvest can't take the yield earned before it arrived (Beefy's compounding CLM,
        // StrategyPassiveManagerUniswap._harvest).
        (uint256 currentLock0, uint256 currentLock1) = lockedProfit();
        totalLocked0 = currentLock0 + (compoundToken == lpToken0 ? received : 0);
        totalLocked1 = currentLock1 + (compoundToken == lpToken1 ? received : 0);

        lastHarvest = block.timestamp;
        emit HarvestRewards(toSell);
    }

    /// @notice Internal function to claim rewards from the gauge and collect them.
    /// @dev FrostyFi 2026-10-11: the performance fee is paid to the treasury at every claim (deposits, withdrawals,
    ///      rebalances and harvests all claim), so `fees` only ever holds output that is already net of it.
    function _claimEarnings() private {
        // Claim rewards
        uint256 feeBefore = _balanceOfOutput();

        if (positionMain.nftId != 0) _getReward(positionMain.nftId);
        if (positionAlt.nftId != 0) _getReward(positionAlt.nftId);

        uint256 claimed = _balanceOfOutput() - feeBefore;

        uint256 perfFee = claimed * perfFeeBps() / BPS;
        if (perfFee > 0) {
            address to = treasury();
            IERC20Metadata(output).safeTransfer(to, perfFee);
            emit PerformanceFeePaid(to, perfFee);
        }
        fees = fees + claimed - perfFee;

        emit ClaimedRewards(claimed);
    }

    /// @dev The least the sale may return: the ValueInterpreter's value of `_amount` output in compoundToken, less
    ///      MAX_SALE_SLIPPAGE_BPS. The VI reverts on a stale or missing price, so a harvest waits for a fresh one.
    function _saleMinimum(uint256 _amount) private view returns (uint256) {
        if (_amount == 0) return 0;
        uint256 fair = IValueInterpreter(factory.valueInterpreter()).calcCanonicalAssetValue(output, _amount, compoundToken);
        return fair * (BPS - MAX_SALE_SLIPPAGE_BPS) / BPS;
    }

    /// @dev Sells `_amount` output into compoundToken on Aerodrome's basic (volatile) pool through `unirouter`, the
    ///      Aerodrome Router, which reverts if less than `_minOut` arrives.
    function _sellOutput(uint256 _amount, uint256 _minOut) private returns (uint256 received) {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({from: output, to: compoundToken, stable: false, factory: routeFactory});
        uint256 before = IERC20Metadata(compoundToken).balanceOf(address(this));
        IAerodromeRouter(unirouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount, _minOut, routes, address(this), block.timestamp
        );
        received = IERC20Metadata(compoundToken).balanceOf(address(this)) - before;
    }

    /**
     * @notice Private function to claim our rewards from the gauge.
     * @param _nftId The nftId of the position to claim rewards from.
     */
    function _getReward(uint256 _nftId) private {
        ICLGauge(gauge).getReward(_nftId);
    }

    /**
     * @notice Returns total token balances in the strategy.
     * @return token0Bal The amount of token0 in the strategy.
     * @return token1Bal The amount of token1 in the strategy.
    */
    function balances() public view returns (uint256 token0Bal, uint256 token1Bal) {
        (uint256 thisBal0, uint256 thisBal1) = balancesOfThis();
        (uint256 poolBal0, uint256 poolBal1,,,,) = balancesOfPool();
        // FrostyFi 2026-10-13 (final review I1): still-locked harvest proceeds aren't in the share price yet.
        (uint256 locked0, uint256 locked1) = lockedProfit();

        uint256 total0 = thisBal0 + poolBal0 - locked0;
        uint256 total1 = thisBal1 + poolBal1 - locked1;

        // For token0 and token1 we return balance of this contract + balance of positions.
        return (total0, total1);
    }

    /**
     * @notice FrostyFi 2026-10-13 (final review I1): the part of past harvests' proceeds not yet released to the share
     *         price. Released linearly over DURATION and capped at what the strategy holds, as in Beefy's compounding CLM
     *         (StrategyPassiveManagerUniswap.lockedProfit).
     * @return locked0 The amount of token0 locked.
     * @return locked1 The amount of token1 locked.
     */
    function lockedProfit() public override view returns (uint256 locked0, uint256 locked1) {
        (uint256 balThis0, uint256 balThis1) = balancesOfThis();
        (uint256 balPool0, uint256 balPool1,,,,) = balancesOfPool();
        uint256 totalBal0 = balThis0 + balPool0;
        uint256 totalBal1 = balThis1 + balPool1;

        uint256 elapsed = block.timestamp - lastHarvest;
        uint256 remaining = elapsed < DURATION ? DURATION - elapsed : 0;

        // Make sure we don't lock more than we have.
        if (totalBal0 > totalLocked0) locked0 = totalLocked0 * remaining / DURATION;
        else locked0 = totalBal0 * remaining / DURATION;

        if (totalBal1 > totalLocked1) locked1 = totalLocked1 * remaining / DURATION;
        else locked1 = totalBal1 * remaining / DURATION;
    }

    /**
     * @notice Returns total tokens sitting in the strategy.
     * @return token0Bal The amount of token0 in the strategy.
     * @return token1Bal The amount of token1 in the strategy.
    */
    function balancesOfThis() public view returns (uint256 token0Bal, uint256 token1Bal) {
        uint256 unharvestedFees = fees;
        if (output == lpToken0) token0Bal = IERC20Metadata(lpToken0).balanceOf(address(this)) - unharvestedFees;
        else token0Bal = IERC20Metadata(lpToken0).balanceOf(address(this));

        if (output == lpToken1) token1Bal = IERC20Metadata(lpToken1).balanceOf(address(this)) - unharvestedFees;
        else token1Bal = IERC20Metadata(lpToken1).balanceOf(address(this));
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

    /// @notice Returns the balance of the output in the strategy.
    function _balanceOfOutput() private view returns (uint256) {
        return IERC20Metadata(output).balanceOf(address(this));
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

        // We set the alternative position based on the token that has the most value available.
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
        } else if (bal1 < amount0) {
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


    /**
     * @notice FrostyFi 2026-10-11: sets the sale route for harvested output.
     * @param _routeFactory The Aerodrome basic-pool factory of the output → compoundToken pool.
     * @param _compoundToken lpToken0 or lpToken1.
     */
    function setSwapRoute(address _routeFactory, address _compoundToken) external onlyOwner {
        _setSwapRoute(_routeFactory, _compoundToken);
    }

    function _setSwapRoute(address _routeFactory, address _compoundToken) private {
        if (_routeFactory == address(0)) revert InvalidInput();
        if (_compoundToken != lpToken0 && _compoundToken != lpToken1) revert InvalidInput();
        routeFactory = _routeFactory;
        compoundToken = _compoundToken;
        emit SetSwapRoute(_routeFactory, _compoundToken);
    }

    /**
     * @notice set the unirouter address
     * @param _unirouter The new unirouter address
     */
    function setUnirouter(address _unirouter) external override onlyOwner {
        _removeAllowances();
        unirouter = _unirouter;
        _giveAllowances();
        emit SetUnirouter(_unirouter);
    }


    /// @notice Retire the strategy and return all the dust to the fee recipient.
    function retireVault() external onlyOwner {
        if (IFrostyClmVault(vault).totalSupply() != 10**3) revert NotAuthorized();
        panic(0,0);
        address feeRecipient = treasury();
        (uint256 bal0, uint256 bal1) = balancesOfThis();
        if (bal0 > 0) IERC20Metadata(lpToken0).safeTransfer(feeRecipient, bal0);
        if (bal1 > 0) IERC20Metadata(lpToken1).safeTransfer(feeRecipient, bal1);

        uint256 outputBal =  _balanceOfOutput();
        if (outputBal > 0) IERC20Metadata(output).safeTransfer(feeRecipient, outputBal);
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

    /// @notice gives swap permisions for the tokens to the unirouter.
    function _giveAllowances() private {
        IERC20Metadata(output).forceApprove(unirouter, type(uint256).max);
        IERC20Metadata(lpToken0).forceApprove(nftManager, type(uint256).max);
        IERC20Metadata(lpToken1).forceApprove(nftManager, type(uint256).max);
    }

    /// @notice removes swap permisions for the tokens from the unirouter.
    function _removeAllowances() private {
        IERC20Metadata(output).forceApprove(unirouter, 0);
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