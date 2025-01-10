// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";

import {ITWAMM} from "@src/ITWAMM.sol";

import {PoolGetters} from "@lib/PoolGetters.sol";
import {OrderPool} from "@lib/OrderPool.sol";
import {TransferHelper} from "@lib/TransferHelper.sol";

contract TWAMM is BaseHook, ITWAMM {
    using TransferHelper for IERC20Minimal;
    using CurrencySettler for Currency;
    using OrderPool for OrderPool.State;
    using PoolIdLibrary for PoolKey;
    using TickMath for int24;
    using TickMath for uint160;
    using SafeCast for uint256;
    using PoolGetters for IPoolManager;
    using TickBitmap for mapping(int16 => uint256);
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    bytes internal constant ZERO_BYTES = bytes("");

    /// @notice Time interval on which orders are allowed to expire. Conserves processing needed on execute.
    uint256 public immutable expirationInterval;

    // twammStates[poolId] => TWAMMState
    mapping(PoolId => TWAMMState) internal twammStates;
    // tokensOwed[token][owner] => amountOwed
    mapping(Currency => mapping(address => uint256)) public tokensOwed;

    constructor(IPoolManager _manager, uint256 _expirationInterval) BaseHook(_manager) {
        expirationInterval = _expirationInterval;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (key.currency0.isAddressZero()) {
            revert PoolWithNativeNotSupported();
        }

        // one-time initialization enforced in PoolManager
        initialize(_getTWAMM(key));

        return BaseHook.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        executeTWAMMOrders(key);

        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        executeTWAMMOrders(key);

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        executeTWAMMOrders(key);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function lastVirtualOrderTimestamp(PoolId key) external view returns (uint256) {
        return twammStates[key].lastVirtualOrderTimestamp;
    }

    function getOrder(PoolKey calldata poolKey, OrderKey calldata orderKey) external view returns (Order memory) {
        return _getOrder(twammStates[poolKey.toId()], _orderId(orderKey));
    }

    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent)
    {
        TWAMMState storage twamm = _getTWAMM(key);

        return zeroForOne
            ? (twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.earningsFactorCurrent)
            : (twamm.orderPool1For0.sellRateCurrent, twamm.orderPool1For0.earningsFactorCurrent);
    }

    /// @notice Initialize TWAMM state
    function initialize(TWAMMState storage self) internal {
        self.lastVirtualOrderTimestamp = _getIntervalTime(block.timestamp);
    }

    function executeTWAMMOrders(PoolKey memory key, uint256 targetTimestamp) public {
        PoolId poolId = key.toId();
        TWAMMState storage twamm = twammStates[poolId];

        if (twamm.lastVirtualOrderTimestamp == 0) {
            revert NotInitialized();
        }

        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        (bool zeroForOne, uint160 sqrtPriceLimitX96, int256 maxSwapAmount) = _executeTWAMMOrders(
            twamm,
            key,
            PoolParamsOnExecute(
                sqrtPriceX96,
                protocolFee + lpFee, // Always under MAX_FEE by design
                poolManager.getLiquidity(poolId),
                0
            ),
            targetTimestamp
        );

        if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96 && maxSwapAmount != 0) {
            uint256 maxToSwap = maxSwapAmount > 0 ? uint256(maxSwapAmount) : uint256(-maxSwapAmount);

            IPoolManager.SwapParams memory swapParams =
                IPoolManager.SwapParams(zeroForOne, -maxToSwap.toInt256(), sqrtPriceLimitX96);

            if (poolManager.isUnlocked()) {
                _processSwap(key, swapParams); // @audit Is this fully safe?
            } else {
                poolManager.unlock(abi.encode(key, swapParams));
            }

            emit Fulfillment(poolId, twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.sellRateCurrent);
        }
    }

    /// @inheritdoc ITWAMM
    function executeTWAMMOrders(PoolKey memory key) public override {
        executeTWAMMOrders(key, block.timestamp);
    }

    /// @inheritdoc ITWAMM
    function submitOrder(PoolKey calldata key, bool zeroForOne, uint256 duration, uint256 amountIn)
        external
        returns (bytes32 orderId, OrderKey memory orderKey)
    {
        executeTWAMMOrders(key);

        PoolId poolId = key.toId();
        uint256 currentTimestampAtInterval = _getIntervalTime(block.timestamp);
        orderKey = OrderKey(msg.sender, (currentTimestampAtInterval + duration).toUint160(), zeroForOne);
        TWAMMState storage twamm = twammStates[poolId];

        if (orderKey.expiration <= block.timestamp) {
            revert ExpirationLessThanBlocktime(orderKey.expiration);
        }

        uint256 sellRate;
        unchecked {
            // checks done in TWAMM library
            sellRate = amountIn / duration;
            orderId = _submitOrder(twamm, orderKey, sellRate);

            IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                .safeTransferFrom(msg.sender, address(this), sellRate * duration);
        }

        emit SubmitOrder(
            poolId,
            orderId,
            orderKey.owner,
            amountIn,
            orderKey.expiration,
            orderKey.zeroForOne,
            sellRate,
            _getOrder(twamm, orderId).earningsFactorLast
        );
    }

    /// @notice Submits a new long term order into the TWAMM
    /// @dev executeTWAMMOrders must be executed up to current timestamp before calling submitOrder
    /// @param orderKey The OrderKey for the new order
    function _submitOrder(TWAMMState storage self, OrderKey memory orderKey, uint256 sellRate)
        internal
        returns (bytes32 orderId)
    {
        if (orderKey.owner != msg.sender) {
            revert MustBeOwner(orderKey.owner, msg.sender);
        }
        if (sellRate == 0) {
            revert SellRateCannotBeZero();
        }
        if (orderKey.expiration % expirationInterval != 0) {
            revert ExpirationNotOnInterval(orderKey.expiration);
        }

        orderId = _orderId(orderKey);
        if (self.orders[orderId].sellRate != 0) {
            revert OrderAlreadyExists(orderKey);
        }

        OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        orderPool.sellRateCurrent += sellRate;
        orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRate;

        self.orders[orderId] = Order({sellRate: sellRate, earningsFactorLast: orderPool.earningsFactorCurrent});
    }

    function syncAndClaimTokens(PoolKey memory key, OrderKey memory orderKey, bool removeRemaining)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed)
    {
        // Calls executeTWAMMOrders
        sync(key, orderKey, removeRemaining);

        tokens0Claimed = _claimTokens(key.currency0);
        tokens1Claimed = _claimTokens(key.currency1);
    }

    /// @inheritdoc ITWAMM
    function sync(PoolKey memory key, OrderKey memory orderKey, bool removeRemaining)
        public
        returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta)
    {
        executeTWAMMOrders(key);

        (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newEarningsFactorLast, bytes32 orderId) =
            _sync(key, orderKey, removeRemaining);

        if (orderKey.zeroForOne) {
            tokens0OwedDelta += sellTokensOwed;
            tokens1OwedDelta += buyTokensOwed;
        } else {
            tokens0OwedDelta += buyTokensOwed;
            tokens1OwedDelta += sellTokensOwed;
        }

        tokensOwed[key.currency0][orderKey.owner] += tokens0OwedDelta;
        tokensOwed[key.currency1][orderKey.owner] += tokens1OwedDelta;

        emit SyncOrder(key.toId(), orderId, removeRemaining, tokens0OwedDelta, tokens1OwedDelta, newEarningsFactorLast);
    }

    function _sync(PoolKey memory key, OrderKey memory orderKey, bool removeRemaining)
        internal
        returns (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 earningsFactorLast, bytes32 orderId)
    {
        PoolId poolId = key.toId();
        TWAMMState storage twamm = twammStates[poolId];
        orderId = _orderId(orderKey);
        Order storage order = _getOrder(twamm, orderId);

        OrderPool.State storage orderPool = orderKey.zeroForOne ? twamm.orderPool0For1 : twamm.orderPool1For0;
        bool isOrderExpired = orderKey.expiration <= block.timestamp;

        if (orderKey.owner != msg.sender) {
            revert MustBeOwner(orderKey.owner, msg.sender);
        }
        if (order.sellRate == 0) {
            revert OrderDoesNotExist(orderKey);
        }

        earningsFactorLast =
            isOrderExpired ? orderPool.earningsFactorAtInterval[orderKey.expiration] : orderPool.earningsFactorCurrent;
        buyTokensOwed = ((earningsFactorLast - order.earningsFactorLast) * order.sellRate) >> FixedPoint96.RESOLUTION;

        if (isOrderExpired) {
            delete twamm.orders[orderId];
        } else {
            order.earningsFactorLast = earningsFactorLast;
        }

        if (removeRemaining && !isOrderExpired) {
            uint256 durationDelta = orderKey.expiration - _getIntervalTime(block.timestamp);
            sellTokensOwed = order.sellRate * durationDelta;

            delete twamm.orders[orderId];
        }
    }

    function _claimTokens(Currency token) internal returns (uint256 amountTransferred) {
        uint256 currentBalance = token.balanceOfSelf();
        amountTransferred = tokensOwed[token][msg.sender];

        if (currentBalance < amountTransferred) {
            amountTransferred = currentBalance; // to catch precision errors
        }

        tokensOwed[token][msg.sender] -= amountTransferred; // @audit Should set this to 0 maybe?

        IERC20Minimal(Currency.unwrap(token)).safeTransfer(msg.sender, amountTransferred);

        emit ClaimTokens(token, msg.sender, amountTransferred);
    }

    /// @inheritdoc ITWAMM
    function claimTokens(PoolKey calldata key) external returns (uint256 tokens0Claimed, uint256 tokens1Claimed) {
        tokens0Claimed = _claimTokens(key.currency0);
        tokens1Claimed = _claimTokens(key.currency1);
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        (PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
            abi.decode(rawData, (PoolKey, IPoolManager.SwapParams));

        _processSwap(key, swapParams);

        return ZERO_BYTES;
    }

    function _processSwap(PoolKey memory key, IPoolManager.SwapParams memory swapParams) internal {
        // @audit This delta is important here since poolManager can be unlocked outside of the hook.
        BalanceDelta delta = poolManager.swap(key, swapParams, ZERO_BYTES);

        if (swapParams.zeroForOne) {
            if (delta.amount0() < 0) {
                key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
            }
            if (delta.amount1() > 0) {
                key.currency1.take(poolManager, address(this), uint256(uint128(delta.amount1())), false);
            }
        } else {
            if (delta.amount1() < 0) {
                key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
            }
            if (delta.amount0() > 0) {
                key.currency0.take(poolManager, address(this), uint256(uint128(delta.amount0())), false);
            }
        }

        emit SwapExecuted(key.toId(), delta);
    }

    function _getTWAMM(PoolKey memory key) internal view returns (TWAMMState storage) {
        return twammStates[key.toId()];
    }

    struct PoolParamsOnExecute {
        uint160 sqrtPriceX96;
        uint24 totalFee;
        uint128 liquidity;
        int256 maxSwapAmount;
    }

    /// @notice Executes all existing long term orders in the TWAMM
    /// @param pool The relevant state of the pool
    function _executeTWAMMOrders(
        TWAMMState storage self,
        PoolKey memory key,
        PoolParamsOnExecute memory pool,
        uint256 targetTimestamp
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96, int256 maxSwapAmount) {
        uint256 currentTimestampAtInterval = _getIntervalTime(targetTimestamp);

        if (currentTimestampAtInterval > block.timestamp || currentTimestampAtInterval < self.lastVirtualOrderTimestamp)
        {
            revert InvalidTargetTimestamp();
        }

        if (!_hasOutstandingOrders(self)) {
            self.lastVirtualOrderTimestamp = currentTimestampAtInterval;

            return (false, 0, 0);
        }

        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderTimestamp;
        uint256 nextExpirationTimestamp = prevTimestamp + expirationInterval;

        unchecked {
            while (nextExpirationTimestamp <= currentTimestampAtInterval) {
                if (_hasOutstandingOrdersAtInterval(self, nextExpirationTimestamp)) {
                    pool = _advanceTimestampForSinglePoolSell(
                        self,
                        key,
                        AdvanceSingleParams(
                            expirationInterval,
                            nextExpirationTimestamp,
                            nextExpirationTimestamp - prevTimestamp,
                            pool,
                            false
                        )
                    );

                    prevTimestamp = nextExpirationTimestamp;
                }

                nextExpirationTimestamp += expirationInterval;

                if (!_hasOutstandingOrders(self)) {
                    break;
                }
            }

            if (prevTimestamp < currentTimestampAtInterval && _hasOutstandingOrders(self)) {
                pool = _advanceTimestampForSinglePoolSell(
                    self,
                    key,
                    AdvanceSingleParams(
                        expirationInterval,
                        currentTimestampAtInterval,
                        currentTimestampAtInterval - prevTimestamp,
                        pool,
                        false
                    )
                );
            }
        }

        self.lastVirtualOrderTimestamp = currentTimestampAtInterval;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;
        maxSwapAmount = pool.maxSwapAmount;
    }

    struct AdvanceParams {
        uint256 expirationInterval;
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        PoolParamsOnExecute pool;
    }

    function _exhaustMatchedOrders(TWAMMState storage self, AdvanceParams memory params)
        private
        returns (bool remainingZeroForOne)
    {
        uint256 priceSq = uint256(params.pool.sqrtPriceX96) ** 2 >> FixedPoint96.RESOLUTION;

        uint256 sellRate0To1 = self.orderPool0For1.sellRateCurrent;
        uint256 sellRate1To0 = self.orderPool1For0.sellRateCurrent;
        uint256 sellRate0To1As1 = (sellRate0To1 * priceSq) >> FixedPoint96.RESOLUTION;
        uint256 sellRate1To0As0 = (sellRate1To0 << FixedPoint96.RESOLUTION) / priceSq;

        // Need to figure out how much sell rate we can adjust between the two of them.
        uint256 maxAdjustable0To1 = sellRate0To1 > sellRate1To0As0 ? sellRate1To0As0 : sellRate0To1;
        uint256 maxAdjustable1To0 = sellRate1To0 > sellRate0To1As1 ? sellRate0To1As1 : sellRate1To0;

        // If one is zero, the other must be zero too.
        if (maxAdjustable0To1 != 0) {
            sellRate0To1As1 = (maxAdjustable0To1 * priceSq) >> FixedPoint96.RESOLUTION;
            sellRate1To0As0 = (maxAdjustable1To0 << FixedPoint96.RESOLUTION) / priceSq;

            self.orderPool0For1.advanceWithoutCommit(
                params.nextTimestamp,
                (sellRate0To1As1 * params.secondsElapsed * FixedPoint96.Q96 / sellRate0To1),
                maxAdjustable0To1
            );
            self.orderPool1For0.advanceWithoutCommit(
                params.nextTimestamp,
                (sellRate1To0As0 * params.secondsElapsed * FixedPoint96.Q96 / sellRate1To0),
                maxAdjustable1To0
            );
        }

        return sellRate0To1 - maxAdjustable0To1 != 0;
    }

    struct AdvanceSingleParams {
        uint256 expirationInterval;
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        PoolParamsOnExecute pool;
        bool zeroForOne;
    }

    function _advanceTimestampForSinglePoolSell(
        TWAMMState storage self,
        PoolKey memory poolKey,
        AdvanceSingleParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        // Including zeroForOne in the params because stack-too-deep
        (params.zeroForOne) = _exhaustMatchedOrders(
            self, AdvanceParams(expirationInterval, params.nextTimestamp, params.secondsElapsed, params.pool)
        );

        OrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        uint256 sellRateCurrent = orderPool.sellRateCurrent - orderPool.sellRateAccounted;
        uint256 amountSelling = sellRateCurrent * params.secondsElapsed * (SwapMath.MAX_SWAP_FEE - params.pool.totalFee)
            / SwapMath.MAX_SWAP_FEE;
        uint256 totalEarnings;

        while (true) {
            uint160 finalSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                params.pool.sqrtPriceX96, params.pool.liquidity, amountSelling, params.zeroForOne
            );

            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolKey, finalSqrtPriceX96);

            if (crossingInitializedTick) {
                (, int128 liquidityNetAtTick) = poolManager.getTickLiquidity(poolKey.toId(), tick);
                uint160 initializedSqrtPrice = TickMath.getSqrtPriceAtTick(tick);

                uint256 swapDelta0 = SqrtPriceMath.getAmount0Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );
                uint256 swapDelta1 = SqrtPriceMath.getAmount1Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );

                params.pool.sqrtPriceX96 = initializedSqrtPrice;
                if (params.zeroForOne) {
                    liquidityNetAtTick = -liquidityNetAtTick;
                }
                params.pool.liquidity = LiquidityMath.addDelta(params.pool.liquidity, liquidityNetAtTick);

                unchecked {
                    totalEarnings += params.zeroForOne ? swapDelta1 : swapDelta0;
                    amountSelling -= params.zeroForOne ? swapDelta0 : swapDelta1;
                }
            } else {
                if (params.zeroForOne) {
                    totalEarnings += SqrtPriceMath.getAmount1Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                    params.pool.maxSwapAmount -= (params.secondsElapsed * sellRateCurrent).toInt256();
                } else {
                    totalEarnings += SqrtPriceMath.getAmount0Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                    params.pool.maxSwapAmount += (params.secondsElapsed * sellRateCurrent).toInt256();
                }

                uint256 accruedEarningsFactor = (totalEarnings * FixedPoint96.Q96) / orderPool.sellRateCurrent;
                if (params.nextTimestamp % params.expirationInterval == 0) {
                    self.orderPool0For1.advanceToInterval(
                        params.nextTimestamp, params.zeroForOne ? accruedEarningsFactor : 0
                    );
                    self.orderPool1For0.advanceToInterval(
                        params.nextTimestamp, params.zeroForOne ? 0 : accruedEarningsFactor
                    );
                } else {
                    // @review This is now useless since timestamps are always on interval.
                    orderPool.advanceToCurrentTime(accruedEarningsFactor);
                }

                params.pool.sqrtPriceX96 = finalSqrtPriceX96;

                break;
            }
        }

        return params.pool;
    }

    function _isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        // use current price as a starting point for nextTickInit
        nextTickInit = pool.sqrtPriceX96.getTickAtSqrtPrice();
        int24 targetTick = nextSqrtPriceX96.getTickAtSqrtPrice();
        bool searchingLeft = nextSqrtPriceX96 < pool.sqrtPriceX96;
        bool nextTickInitFurtherThanTarget; // initialize as false

        // nextTickInit returns the furthest tick within one word if no tick within that word is initialized
        // so we must keep iterating if we haven't reached a tick further than our target tick
        while (!nextTickInitFurtherThanTarget) {
            unchecked {
                if (searchingLeft) {
                    nextTickInit -= 1;
                }
            }
            (nextTickInit, crossingInitializedTick) = poolManager.getNextInitializedTickWithinOneWord(
                poolKey.toId(), nextTickInit, poolKey.tickSpacing, searchingLeft
            );
            nextTickInitFurtherThanTarget = searchingLeft ? nextTickInit <= targetTick : nextTickInit > targetTick;
            if (crossingInitializedTick == true) {
                break;
            }
        }

        if (nextTickInitFurtherThanTarget) {
            crossingInitializedTick = false;
        }
    }

    function _getOrder(TWAMMState storage self, bytes32 orderId) internal view returns (Order storage) {
        return self.orders[orderId];
    }

    function _orderId(OrderKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _hasOutstandingOrders(TWAMMState storage self) internal view returns (bool) {
        return self.orderPool0For1.sellRateCurrent != 0 || self.orderPool1For0.sellRateCurrent != 0;
    }

    function _hasOutstandingOrdersAtInterval(TWAMMState storage self, uint256 timestamp) internal view returns (bool) {
        return self.orderPool0For1.sellRateEndingAtInterval[timestamp] != 0
            || self.orderPool1For0.sellRateEndingAtInterval[timestamp] != 0;
    }

    function _getIntervalTime(uint256 timestamp) internal view returns (uint256) {
        return timestamp - (timestamp % expirationInterval);
    }
}
