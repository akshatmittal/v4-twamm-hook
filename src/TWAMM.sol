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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {ITWAMM} from "@src/ITWAMM.sol";

import {PoolGetters} from "@lib/PoolGetters.sol";
import {TwammMath} from "@lib/TwammMath.sol";
import {OrderPool} from "@lib/OrderPool.sol";
import {TransferHelper} from "@lib/TransferHelper.sol";

import "forge-std/console2.sol";

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

    int256 internal constant MIN_DELTA = -1;
    bool internal constant ZERO_FOR_ONE = true;
    bool internal constant ONE_FOR_ZERO = false;

    /// @notice Contains full state related to the TWAMM
    /// @member lastVirtualOrderTimestamp Last timestamp in which virtual orders were executed
    /// @member orderPool0For1 Order pool trading token0 for token1 of pool
    /// @member orderPool1For0 Order pool trading token1 for token0 of pool
    /// @member orders Mapping of orderId to individual orders on pool
    struct State {
        uint256 lastVirtualOrderTimestamp;
        OrderPool.State orderPool0For1;
        OrderPool.State orderPool1For0;
        mapping(bytes32 => Order) orders;
    }

    /// @inheritdoc ITWAMM
    uint256 public immutable expirationInterval;
    // twammStates[poolId] => Twamm.State
    mapping(PoolId => State) internal twammStates;
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
            beforeRemoveLiquidity: false,
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

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
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
        return _getOrder(twammStates[poolKey.toId()], orderKey);
    }

    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent)
    {
        State storage twamm = _getTWAMM(key);
        return zeroForOne
            ? (twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.earningsFactorCurrent)
            : (twamm.orderPool1For0.sellRateCurrent, twamm.orderPool1For0.earningsFactorCurrent);
    }

    /// @notice Initialize TWAMM state
    function initialize(State storage self) internal {
        self.lastVirtualOrderTimestamp = _getIntervalTime(block.timestamp);
    }

    /// @inheritdoc ITWAMM
    function executeTWAMMOrders(PoolKey memory key) public {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        State storage twamm = twammStates[poolId];

        if (twamm.lastVirtualOrderTimestamp == 0) {
            revert NotInitialized();
        }

        (bool zeroForOne, uint160 sqrtPriceLimitX96, int256 maxSwapAmount) =
            _executeTWAMMOrders(twamm, key, PoolParamsOnExecute(sqrtPriceX96, poolManager.getLiquidity(poolId), 0));

        if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
            /**
             * @dev V3 Math library has precision issues, these two limits are placed to prevent orders going over the
             *      specified limits.
             */
            uint256 maxAvailable = zeroForOne ? key.currency0.balanceOfSelf() : key.currency1.balanceOfSelf();
            uint256 maxToSwap = maxSwapAmount > 0 ? uint256(maxSwapAmount) : uint256(-maxSwapAmount);

            console2.log("maxAvailable", maxAvailable);
            console2.log("maxSwapAmount", maxSwapAmount);
            console2.log("maxToSwap", maxToSwap);
            console2.log("zeroForOne", zeroForOne);

            if (maxToSwap != 0) {
                if (poolManager.isUnlocked()) {
                    _processSwap(key, IPoolManager.SwapParams(zeroForOne, -maxToSwap.toInt256(), sqrtPriceLimitX96)); // @audit Is this fully safe?
                } else {
                    poolManager.unlock(
                        abi.encode(key, IPoolManager.SwapParams(zeroForOne, -maxToSwap.toInt256(), sqrtPriceLimitX96))
                    );
                }
            }
        }
    }

    /// @inheritdoc ITWAMM
    function submitOrder(PoolKey calldata key, bool zeroForOne, uint256 duration, uint256 amountIn)
        external
        returns (bytes32 orderId, OrderKey memory orderKey)
    {
        executeTWAMMOrders(key);

        PoolId poolId = key.toId();
        uint256 intervalTime = _getIntervalTime(block.timestamp);
        orderKey = OrderKey(msg.sender, (intervalTime + duration).toUint160(), zeroForOne);
        State storage twamm = twammStates[poolId];

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
            orderKey.owner,
            orderKey.expiration,
            orderKey.zeroForOne,
            sellRate,
            _getOrder(twamm, orderKey).earningsFactorLast
        );
    }

    /// @notice Submits a new long term order into the TWAMM
    /// @dev executeTWAMMOrders must be executed up to current timestamp before calling submitOrder
    /// @param orderKey The OrderKey for the new order
    function _submitOrder(State storage self, OrderKey memory orderKey, uint256 sellRate)
        internal
        returns (bytes32 orderId)
    {
        if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
        if (sellRate == 0) revert SellRateCannotBeZero();
        if (orderKey.expiration % expirationInterval != 0) revert ExpirationNotOnInterval(orderKey.expiration);

        orderId = _orderId(orderKey);
        if (self.orders[orderId].sellRate != 0) revert OrderAlreadyExists(orderKey);

        OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        unchecked {
            orderPool.sellRateCurrent += sellRate;
            orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRate;
        }

        self.orders[orderId] = Order({sellRate: sellRate, earningsFactorLast: orderPool.earningsFactorCurrent});
    }

    /// @inheritdoc ITWAMM
    function updateOrder(PoolKey memory key, OrderKey memory orderKey, int256 amountDelta)
        external
        returns (uint256 tokens0Owed, uint256 tokens1Owed)
    {
        PoolId poolId = key.toId();
        State storage twamm = twammStates[poolId];

        executeTWAMMOrders(key);

        // This call reverts if the caller is not the owner of the order
        (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellrate, uint256 newEarningsFactorLast) =
            _updateOrder(twamm, orderKey, amountDelta);

        if (orderKey.zeroForOne) {
            tokens0Owed += sellTokensOwed;
            tokens1Owed += buyTokensOwed;
        } else {
            tokens0Owed += buyTokensOwed;
            tokens1Owed += sellTokensOwed;
        }

        tokensOwed[key.currency0][orderKey.owner] += tokens0Owed;
        tokensOwed[key.currency1][orderKey.owner] += tokens1Owed;

        if (amountDelta > 0) {
            IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                .safeTransferFrom(msg.sender, address(this), uint256(amountDelta));
        }

        emit UpdateOrder(
            poolId, orderKey.owner, orderKey.expiration, orderKey.zeroForOne, newSellrate, newEarningsFactorLast
        );
    }

    function _updateOrder(State storage self, OrderKey memory orderKey, int256 amountDelta)
        internal
        returns (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellRate, uint256 earningsFactorLast)
    {
        Order storage order = _getOrder(self, orderKey);
        OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        bool isOrderExpired = orderKey.expiration <= block.timestamp;

        if (orderKey.owner != msg.sender) {
            revert MustBeOwner(orderKey.owner, msg.sender);
        }
        if (order.sellRate == 0) {
            revert OrderDoesNotExist(orderKey);
        }
        if (amountDelta != 0 && isOrderExpired) {
            revert CannotModifyCompletedOrder(orderKey);
        }

        unchecked {
            earningsFactorLast = isOrderExpired
                ? orderPool.earningsFactorAtInterval[orderKey.expiration]
                : orderPool.earningsFactorCurrent;
            buyTokensOwed =
                ((earningsFactorLast - order.earningsFactorLast) * order.sellRate) >> FixedPoint96.RESOLUTION;

            if (isOrderExpired) {
                delete self.orders[_orderId(orderKey)];
            } else {
                order.earningsFactorLast = earningsFactorLast;
            }

            // TODO: Remove this pls
            if (amountDelta != 0) {
                uint256 duration = orderKey.expiration - block.timestamp;
                uint256 unsoldAmount = order.sellRate * duration;
                if (amountDelta == MIN_DELTA) amountDelta = -(unsoldAmount.toInt256());
                int256 newSellAmount = unsoldAmount.toInt256() + amountDelta;
                if (newSellAmount < 0) revert InvalidAmountDelta(orderKey, unsoldAmount, amountDelta);

                newSellRate = uint256(newSellAmount) / duration;

                if (amountDelta < 0) {
                    uint256 sellRateDelta = order.sellRate - newSellRate;
                    orderPool.sellRateCurrent -= sellRateDelta;
                    orderPool.sellRateEndingAtInterval[orderKey.expiration] -= sellRateDelta;
                    sellTokensOwed = uint256(-amountDelta);
                } else {
                    uint256 sellRateDelta = newSellRate - order.sellRate;
                    orderPool.sellRateCurrent += sellRateDelta;
                    orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRateDelta;
                }
                if (newSellRate == 0) {
                    delete self.orders[_orderId(orderKey)];
                } else {
                    order.sellRate = newSellRate;
                }
            }
        }
    }

    /// @inheritdoc ITWAMM
    function claimTokens(Currency token, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred)
    {
        uint256 currentBalance = token.balanceOfSelf();
        amountTransferred = tokensOwed[token][msg.sender];
        if (amountRequested != 0 && amountRequested < amountTransferred) {
            amountTransferred = amountRequested;
        }
        if (currentBalance < amountTransferred) {
            amountTransferred = currentBalance; // to catch precision errors
        }

        tokensOwed[token][msg.sender] -= amountTransferred;
        IERC20Minimal(Currency.unwrap(token)).safeTransfer(to, amountTransferred);
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        (PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
            abi.decode(rawData, (PoolKey, IPoolManager.SwapParams));

        _processSwap(key, swapParams);

        return bytes("");
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
    }

    function _getTWAMM(PoolKey memory key) internal view returns (State storage) {
        return twammStates[key.toId()];
    }

    struct PoolParamsOnExecute {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int256 maxSwapAmount;
    }

    /// @notice Executes all existing long term orders in the TWAMM
    /// @param pool The relevant state of the pool
    function _executeTWAMMOrders(State storage self, PoolKey memory key, PoolParamsOnExecute memory pool)
        internal
        returns (bool zeroForOne, uint160 newSqrtPriceX96, int256 maxSwapAmount)
    {
        uint256 currentTimestampAtInterval = _getIntervalTime(block.timestamp);

        if (!_hasOutstandingOrders(self)) {
            self.lastVirtualOrderTimestamp = currentTimestampAtInterval;

            return (false, 0, 0);
        }

        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderTimestamp;
        uint256 nextExpirationTimestamp = prevTimestamp + expirationInterval;

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

        unchecked {
            while (nextExpirationTimestamp <= currentTimestampAtInterval) {
                if (
                    orderPool0For1.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                        || orderPool1For0.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                ) {
                    if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                        pool = _advanceToNewTimestamp(
                            self,
                            key,
                            AdvanceParams(
                                expirationInterval,
                                nextExpirationTimestamp,
                                nextExpirationTimestamp - prevTimestamp,
                                pool
                            )
                        );
                    } else {
                        pool = _advanceTimestampForSinglePoolSell(
                            self,
                            key,
                            AdvanceSingleParams(
                                expirationInterval,
                                nextExpirationTimestamp,
                                nextExpirationTimestamp - prevTimestamp,
                                pool,
                                orderPool0For1.sellRateCurrent != 0
                            )
                        );
                    }

                    prevTimestamp = nextExpirationTimestamp;
                }

                nextExpirationTimestamp += expirationInterval;

                // console2.log("hasOutstandingOrders", _hasOutstandingOrders(self));

                if (!_hasOutstandingOrders(self)) {
                    break;
                }
            }

            if (prevTimestamp < currentTimestampAtInterval && _hasOutstandingOrders(self)) {
                if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                    pool = _advanceToNewTimestamp(
                        self,
                        key,
                        AdvanceParams(
                            expirationInterval,
                            currentTimestampAtInterval,
                            currentTimestampAtInterval - prevTimestamp,
                            pool
                        )
                    );
                } else {
                    pool = _advanceTimestampForSinglePoolSell(
                        self,
                        key,
                        AdvanceSingleParams(
                            expirationInterval,
                            currentTimestampAtInterval,
                            currentTimestampAtInterval - prevTimestamp,
                            pool,
                            orderPool0For1.sellRateCurrent != 0
                        )
                    );
                }
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

    function _advanceToNewTimestamp(State storage self, PoolKey memory poolKey, AdvanceParams memory params)
        private
        returns (PoolParamsOnExecute memory)
    {
        uint256 secondsElapsedX96 = params.secondsElapsed * FixedPoint96.Q96;
        uint160 finalSqrtPriceX96;

        while (true) {
            TwammMath.ExecutionUpdateParams memory executionParams = TwammMath.ExecutionUpdateParams(
                secondsElapsedX96,
                params.pool.sqrtPriceX96,
                params.pool.liquidity,
                self.orderPool0For1.sellRateCurrent,
                self.orderPool1For0.sellRateCurrent
            );

            finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(executionParams);

            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolKey, finalSqrtPriceX96);

            unchecked {
                if (crossingInitializedTick) {
                    uint256 secondsUntilCrossingX96;
                    (params.pool, secondsUntilCrossingX96) = _advanceTimeThroughTickCrossing(
                        self, poolKey, TickCrossingParams(tick, params.nextTimestamp, secondsElapsedX96, params.pool)
                    );
                    secondsElapsedX96 = secondsElapsedX96 - secondsUntilCrossingX96;
                } else {
                    (uint256 earningsFactorPool0, uint256 earningsFactorPool1) =
                        TwammMath.calculateEarningsUpdates(executionParams, finalSqrtPriceX96);

                    int256 sellRateDelta =
                        -self.orderPool0For1.sellRateCurrent.toInt256() + self.orderPool1For0.sellRateCurrent.toInt256();

                    params.pool.maxSwapAmount += params.secondsElapsed.toInt256() * sellRateDelta;

                    if (params.nextTimestamp % params.expirationInterval == 0) {
                        self.orderPool0For1.advanceToInterval(params.nextTimestamp, earningsFactorPool0);
                        self.orderPool1For0.advanceToInterval(params.nextTimestamp, earningsFactorPool1);
                    } else {
                        self.orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
                        self.orderPool1For0.advanceToCurrentTime(earningsFactorPool1);
                    }

                    params.pool.sqrtPriceX96 = finalSqrtPriceX96;

                    break;
                }
            }
        }

        return params.pool;
    }

    struct AdvanceSingleParams {
        uint256 expirationInterval;
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        PoolParamsOnExecute pool;
        bool zeroForOne;
    }

    function _advanceTimestampForSinglePoolSell(
        State storage self,
        PoolKey memory poolKey,
        AdvanceSingleParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        OrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        uint256 sellRateCurrent = orderPool.sellRateCurrent;
        uint256 amountSelling = sellRateCurrent * params.secondsElapsed;
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
                params.pool.liquidity = params.zeroForOne
                    ? params.pool.liquidity - uint128(liquidityNetAtTick)
                    : params.pool.liquidity + uint128(-liquidityNetAtTick);

                unchecked {
                    totalEarnings += params.zeroForOne ? swapDelta1 : swapDelta0;
                    amountSelling -= params.zeroForOne ? swapDelta0 : swapDelta1;
                }
            } else {
                if (params.zeroForOne) {
                    totalEarnings += SqrtPriceMath.getAmount1Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                    params.pool.maxSwapAmount -= (params.secondsElapsed * orderPool.sellRateCurrent).toInt256();
                } else {
                    totalEarnings += SqrtPriceMath.getAmount0Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                    params.pool.maxSwapAmount += (params.secondsElapsed * orderPool.sellRateCurrent).toInt256();
                }

                uint256 accruedEarningsFactor = (totalEarnings * FixedPoint96.Q96) / sellRateCurrent;
                if (params.nextTimestamp % params.expirationInterval == 0) {
                    orderPool.advanceToInterval(params.nextTimestamp, accruedEarningsFactor);
                } else {
                    orderPool.advanceToCurrentTime(accruedEarningsFactor);
                }

                params.pool.sqrtPriceX96 = finalSqrtPriceX96;

                break;
            }
        }

        return params.pool;
    }

    struct TickCrossingParams {
        int24 initializedTick;
        uint256 nextTimestamp;
        uint256 secondsElapsedX96;
        PoolParamsOnExecute pool;
    }

    function _advanceTimeThroughTickCrossing(
        State storage self,
        PoolKey memory poolKey,
        TickCrossingParams memory params
    ) private returns (PoolParamsOnExecute memory, uint256) {
        uint160 initializedSqrtPrice = params.initializedTick.getSqrtPriceAtTick();

        uint256 secondsUntilCrossingX96 = TwammMath.calculateTimeBetweenTicks(
            params.pool.liquidity,
            params.pool.sqrtPriceX96,
            initializedSqrtPrice,
            self.orderPool0For1.sellRateCurrent,
            self.orderPool1For0.sellRateCurrent
        );

        (uint256 earningsFactorPool0, uint256 earningsFactorPool1) = TwammMath.calculateEarningsUpdates(
            TwammMath.ExecutionUpdateParams(
                secondsUntilCrossingX96,
                params.pool.sqrtPriceX96,
                params.pool.liquidity,
                self.orderPool0For1.sellRateCurrent,
                self.orderPool1For0.sellRateCurrent
            ),
            initializedSqrtPrice
        );

        self.orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
        self.orderPool1For0.advanceToCurrentTime(earningsFactorPool1);

        unchecked {
            // update pool
            (, int128 liquidityNet) = poolManager.getTickLiquidity(poolKey.toId(), params.initializedTick);
            if (initializedSqrtPrice < params.pool.sqrtPriceX96) {
                liquidityNet = -liquidityNet;
            }
            params.pool.liquidity = liquidityNet < 0
                ? params.pool.liquidity - uint128(-liquidityNet)
                : params.pool.liquidity + uint128(liquidityNet);

            params.pool.sqrtPriceX96 = initializedSqrtPrice;
        }
        return (params.pool, secondsUntilCrossingX96);
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

    function _getOrder(State storage self, OrderKey memory key) internal view returns (Order storage) {
        return self.orders[_orderId(key)];
    }

    function _orderId(OrderKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _hasOutstandingOrders(State storage self) internal view returns (bool) {
        return self.orderPool0For1.sellRateCurrent != 0 || self.orderPool1For0.sellRateCurrent != 0;
    }

    function _getIntervalTime(uint256 timestamp) internal view returns (uint256) {
        return timestamp - (timestamp % expirationInterval);
    }
}
