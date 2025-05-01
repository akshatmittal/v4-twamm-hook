// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IHooks, Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {ITWAMM} from "@src/ITWAMM.sol";

import {PoolGetters} from "@lib/PoolGetters.sol";
import {OrderPool} from "@lib/OrderPool.sol";
import {TransferHelper} from "@lib/TransferHelper.sol";

uint256 constant RATE_SCALER = 1e18;

/**
 * @title TWAMM Hook
 * @notice This Uniswap V4 hook implements the Time-Weighted Average Market Maker (TWAMM)
 *         strategy as detailed by Paradigm in their original paper.
 * @dev Since this hook operates entirely onchain, there are several additional considerations.
 *      Please see documentation before deploying.
 * @author Uniswap Labs
 * @author Zaha Studio
 */
contract TWAMM is BaseHook, Owned, ITWAMM {
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

    mapping(PoolId poolId => TWAMMState twammState) internal twammStates;
    mapping(Currency token => mapping(address owner => uint256 amountOwed)) public tokensOwed;

    /// @notice If non-zero, the hook has been killed and can no longer be used to create TWAMM orders.
    ///         Swaps & Liquidity Actions will continue to operate normally.
    uint256 public killedAt;

    constructor(IPoolManager _manager, uint256 _expirationInterval, address initialOwner)
        BaseHook(_manager)
        Owned(initialOwner)
    {
        if (_expirationInterval == 0) {
            revert InvalidExpirationInterval();
        }

        expirationInterval = _expirationInterval;
    }

    /// @inheritdoc ITWAMM
    function killHook() external onlyOwner {
        if (killedAt != 0) {
            revert HookKilled();
        }

        killedAt = block.timestamp;
    }

    /// @inheritdoc BaseHook
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

    /// @inheritdoc IHooks
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

    /// @inheritdoc IHooks
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
        // Liquidity removal must always be unblocked.
        try this.executeTWAMMOrders(key) {} catch {}

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

    /// @inheritdoc ITWAMM
    function lastVirtualOrderTimestamp(PoolId key) external view returns (uint256) {
        return twammStates[key].lastVirtualOrderTimestamp;
    }

    /// @inheritdoc ITWAMM
    function getOrder(PoolKey calldata poolKey, OrderKey calldata orderKey) external view returns (Order memory) {
        return _getOrder(twammStates[poolKey.toId()], _orderId(orderKey));
    }

    /// @inheritdoc ITWAMM
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

    /// @inheritdoc ITWAMM
    function executeTWAMMOrders(PoolKey memory key, uint256 targetTimestamp) public {
        if (killedAt != 0) {
            // If the hook has been killed, skip all hook logic.
            return;
        }

        PoolId poolId = key.toId();
        TWAMMState storage twamm = twammStates[poolId];

        if (twamm.lastVirtualOrderTimestamp == 0) {
            revert NotInitialized();
        }

        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);
        (bool zeroForOne, uint160 sqrtPriceLimitX96, uint256 maxSwapAmount) = _executeTWAMMOrders(
            twamm,
            key,
            PoolParamsOnExecute(sqrtPriceX96, protocolFee, lpFee, poolManager.getLiquidity(poolId), 0, 0),
            targetTimestamp
        );

        if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96 && maxSwapAmount != 0) {
            IPoolManager.SwapParams memory swapParams =
                IPoolManager.SwapParams(zeroForOne, -maxSwapAmount.toInt256(), sqrtPriceLimitX96);

            if (poolManager.isUnlocked()) {
                _processSwap(key, swapParams);
            } else {
                poolManager.unlock(abi.encode(key, swapParams));
            }

            emit Fulfillment(poolId, twamm.orderPool0For1.sellRateCurrent, twamm.orderPool1For0.sellRateCurrent);
        }
    }

    /// @inheritdoc ITWAMM
    function executeTWAMMOrders(PoolKey memory key) public override {
        executeTWAMMOrders(key, block.timestamp);
    }

    /// @inheritdoc ITWAMM
    function batchSubmitOrders(SubmitOrderParams[] calldata orders)
        external
        returns (bytes32[] memory orderIds, OrderKey[] memory orderKeys)
    {
        orderIds = new bytes32[](orders.length);
        orderKeys = new OrderKey[](orders.length);

        for (uint256 i = 0; i < orders.length; i++) {
            (orderIds[i], orderKeys[i]) = _submitOrder(orders[i]);
        }
    }

    /// @inheritdoc ITWAMM
    function submitOrder(SubmitOrderParams calldata params)
        external
        returns (bytes32 orderId, OrderKey memory orderKey)
    {
        return _submitOrder(params);
    }

    function _submitOrder(SubmitOrderParams calldata params)
        internal
        returns (bytes32 orderId, OrderKey memory orderKey)
    {
        if (killedAt != 0) {
            // If the hook has been killed, do not allow new orders.
            revert HookKilled();
        }

        executeTWAMMOrders(params.key);

        PoolId poolId = params.key.toId();
        uint256 currentTimestampAtInterval = _getIntervalTime(block.timestamp);
        orderKey = OrderKey({
            owner: msg.sender,
            expiration: (currentTimestampAtInterval + params.duration).toUint160(),
            zeroForOne: params.zeroForOne
        });

        TWAMMState storage twamm = twammStates[poolId];

        if (orderKey.expiration <= block.timestamp) {
            revert ExpirationLessThanBlockTime(orderKey.expiration);
        }
        if (orderKey.expiration % expirationInterval != 0) {
            revert ExpirationNotOnInterval(orderKey.expiration);
        }

        uint256 sellRate = params.amountIn / params.duration;
        // uint256 sellRate = Math.mulDiv(params.amountIn, RATE_SCALER, params.duration);
        if (sellRate == 0) {
            revert SellRateCannotBeZero();
        }

        // Sell rate is scaled after, since we want amounts to stay in the original scale
        uint256 scaledSellRate = sellRate * RATE_SCALER;

        orderId = _orderId(orderKey);

        if (twamm.orders[orderId].sellRate != 0) {
            revert OrderAlreadyExists(orderKey);
        }

        OrderPool.State storage orderPool = params.zeroForOne ? twamm.orderPool0For1 : twamm.orderPool1For0;

        orderPool.sellRateCurrent += scaledSellRate;
        orderPool.sellRateEndingAtInterval[orderKey.expiration] += scaledSellRate;

        uint256 earningsFactorLast = orderPool.earningsFactorCurrent;
        twamm.orders[orderId] = Order({sellRate: scaledSellRate, earningsFactorLast: earningsFactorLast});

        IERC20Minimal(params.zeroForOne ? Currency.unwrap(params.key.currency0) : Currency.unwrap(params.key.currency1))
            .safeTransferFrom(msg.sender, address(this), sellRate * params.duration);

        emit SubmitOrder(
            poolId,
            orderId,
            orderKey.owner,
            params.amountIn,
            orderKey.expiration,
            params.zeroForOne,
            sellRate,
            earningsFactorLast
        );

        return (orderId, orderKey);
    }

    /// @inheritdoc ITWAMM
    function claimTokensByPoolKey(PoolKey calldata key)
        public
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed)
    {
        tokens0Claimed = _claimTokens(key.currency0);
        tokens1Claimed = _claimTokens(key.currency1);
    }

    /// @inheritdoc ITWAMM
    function claimTokensByCurrencies(Currency[] calldata currencies) public returns (uint256[] memory tokensClaimed) {
        tokensClaimed = new uint256[](currencies.length);

        for (uint256 i = 0; i < currencies.length; i++) {
            tokensClaimed[i] = _claimTokens(currencies[i]);
        }
    }

    /// @inheritdoc ITWAMM
    function syncAndClaimTokens(SyncParams calldata params)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed)
    {
        // Calls executeTWAMMOrders
        sync(params);

        (tokens0Claimed, tokens1Claimed) = claimTokensByPoolKey(params.key);
    }

    /// @inheritdoc ITWAMM
    function batchSyncAndClaimTokens(SyncParams[] calldata params, Currency[] calldata currencies)
        external
        returns (uint256[] memory)
    {
        for (uint256 i = 0; i < params.length; i++) {
            // Calls executeTWAMMOrders
            sync(params[i]);
        }

        return claimTokensByCurrencies(currencies);
    }

    /// @inheritdoc ITWAMM
    function sync(SyncParams calldata params) public returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta) {
        if (params.orderKey.owner != msg.sender) {
            revert Unauthorized();
        }

        executeTWAMMOrders(params.key);

        (
            uint256 buyTokensOwed,
            uint256 sellTokensOwed,
            uint256 newEarningsFactorLast,
            bytes32 orderId,
            bool assetsRemoved
        ) = _sync(params.key, params.orderKey);

        if (params.orderKey.zeroForOne) {
            tokens0OwedDelta += sellTokensOwed;
            tokens1OwedDelta += buyTokensOwed;
        } else {
            tokens0OwedDelta += buyTokensOwed;
            tokens1OwedDelta += sellTokensOwed;
        }

        tokensOwed[params.key.currency0][params.orderKey.owner] += tokens0OwedDelta;
        tokensOwed[params.key.currency1][params.orderKey.owner] += tokens1OwedDelta;

        emit SyncOrder(
            params.key.toId(),
            orderId,
            assetsRemoved, // Only true if the hook has been killed
            tokens0OwedDelta,
            tokens1OwedDelta,
            newEarningsFactorLast
        );
    }

    function _sync(PoolKey memory key, OrderKey memory orderKey)
        internal
        returns (
            uint256 buyTokensOwed,
            uint256 sellTokensOwed,
            uint256 earningsFactorLast,
            bytes32 orderId,
            bool assetsRemoved
        )
    {
        PoolId poolId = key.toId();
        TWAMMState storage twamm = twammStates[poolId];
        orderId = _orderId(orderKey);
        Order storage order = _getOrder(twamm, orderId);

        OrderPool.State storage orderPool = orderKey.zeroForOne ? twamm.orderPool0For1 : twamm.orderPool1For0;
        bool isOrderExpired = orderKey.expiration <= twamm.lastVirtualOrderTimestamp;

        if (order.sellRate == 0) {
            revert OrderDoesNotExist(orderKey);
        }

        earningsFactorLast =
            isOrderExpired ? orderPool.earningsFactorAtInterval[orderKey.expiration] : orderPool.earningsFactorCurrent;

        buyTokensOwed = (Math.mulDiv(earningsFactorLast - order.earningsFactorLast, order.sellRate, RATE_SCALER))
            >> FixedPoint96.RESOLUTION;

        if (isOrderExpired) {
            delete twamm.orders[orderId];
        } else {
            order.earningsFactorLast = earningsFactorLast;
        }

        if (killedAt != 0 && !isOrderExpired) {
            uint256 durationDelta = orderKey.expiration - twamm.lastVirtualOrderTimestamp;
            sellTokensOwed = Math.mulDiv(order.sellRate, durationDelta, RATE_SCALER);

            delete twamm.orders[orderId];

            assetsRemoved = true;
        }
    }

    function _claimTokens(Currency token) internal returns (uint256 amountTransferred) {
        amountTransferred = tokensOwed[token][msg.sender];

        if (amountTransferred != 0) {
            uint256 currentBalance = token.balanceOfSelf();

            if (currentBalance < amountTransferred) {
                amountTransferred = currentBalance; // offByOne
            }

            tokensOwed[token][msg.sender] -= amountTransferred;

            token.transfer(msg.sender, amountTransferred);

            emit ClaimTokens(token, msg.sender, amountTransferred);
        }
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        (PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
            abi.decode(rawData, (PoolKey, IPoolManager.SwapParams));

        _processSwap(key, swapParams);

        return ZERO_BYTES;
    }

    function _processSwap(PoolKey memory key, IPoolManager.SwapParams memory swapParams) internal {
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
        uint24 protocolFee;
        uint24 lpFee;
        uint128 liquidity;
        uint256 maxSwap0For1;
        uint256 maxSwap1For0;
    }

    /// @notice Executes all existing long term orders in the TWAMM
    /// @param pool The relevant state of the pool
    function _executeTWAMMOrders(
        TWAMMState storage self,
        PoolKey memory key,
        PoolParamsOnExecute memory pool,
        uint256 targetTimestamp
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96, uint256 maxSwapAmount) {
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
                        false,
                        0
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
                    false,
                    0
                )
            );
        }

        self.lastVirtualOrderTimestamp = currentTimestampAtInterval;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;

        // Only one of them would be active at a time
        maxSwapAmount = zeroForOne ? pool.maxSwap0For1 : pool.maxSwap1For0;
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
        uint256 priceX96 = Math.mulDiv(params.pool.sqrtPriceX96, params.pool.sqrtPriceX96, FixedPoint96.Q96);

        uint256 sellRate0To1 = self.orderPool0For1.sellRateCurrent;
        uint256 sellRate1To0 = self.orderPool1For0.sellRateCurrent;

        uint256 sellRate0To1As1 = Math.mulDiv(sellRate0To1, priceX96, FixedPoint96.Q96);
        uint256 sellRate1To0As0 = Math.mulDiv(sellRate1To0, FixedPoint96.Q96, priceX96);

        // Need to figure out how much sell rate we can adjust between the two of them.
        uint256 maxAdjustable0To1 = Math.min(sellRate0To1, sellRate1To0As0);
        uint256 maxAdjustable1To0 = Math.min(sellRate1To0, sellRate0To1As1);

        if (maxAdjustable0To1 != 0 && maxAdjustable1To0 != 0) {
            sellRate0To1As1 = Math.mulDiv(maxAdjustable0To1, priceX96, FixedPoint96.Q96);
            sellRate1To0As0 = Math.mulDiv(maxAdjustable1To0, FixedPoint96.Q96, priceX96);

            self.orderPool0For1.advanceWithoutCommit(
                Math.mulDiv(sellRate0To1As1 * params.secondsElapsed, FixedPoint96.Q96, sellRate0To1), // Earnings
                maxAdjustable0To1
            );
            self.orderPool1For0.advanceWithoutCommit(
                Math.mulDiv(sellRate1To0As0 * params.secondsElapsed, FixedPoint96.Q96, sellRate1To0), // Earnings
                maxAdjustable1To0
            );

            return sellRate0To1 - maxAdjustable0To1 != 0;
        }

        return sellRate0To1 > sellRate1To0As0;
    }

    struct AdvanceSingleParams {
        uint256 expirationInterval;
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        PoolParamsOnExecute pool;
        bool zeroForOne;
        uint256 activeFee;
    }

    function _advanceTimestampForSinglePoolSell(
        TWAMMState storage self,
        PoolKey memory poolKey,
        AdvanceSingleParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        // Including zeroForOne & activeFee in the params because stack-too-deep
        params.zeroForOne = _exhaustMatchedOrders(
            self, AdvanceParams(expirationInterval, params.nextTimestamp, params.secondsElapsed, params.pool)
        );
        params.activeFee = params.pool.protocolFee == 0
            ? params.pool.lpFee
            : ProtocolFeeLibrary.calculateSwapFee(
                params.zeroForOne
                    ? ProtocolFeeLibrary.getZeroForOneFee(params.pool.protocolFee)
                    : ProtocolFeeLibrary.getOneForZeroFee(params.pool.protocolFee),
                params.pool.lpFee
            );

        OrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        uint256 sellRateCurrent = orderPool.sellRateCurrent - orderPool.sellRateAccounted;

        uint256 amountSelling = Math.mulDiv(
            Math.mulDiv(sellRateCurrent, params.secondsElapsed, RATE_SCALER),
            SwapMath.MAX_SWAP_FEE - params.activeFee,
            SwapMath.MAX_SWAP_FEE
        );
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
                    params.pool.maxSwap0For1 += Math.mulDiv(params.secondsElapsed, sellRateCurrent, RATE_SCALER);
                } else {
                    totalEarnings += SqrtPriceMath.getAmount0Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                    params.pool.maxSwap1For0 += Math.mulDiv(params.secondsElapsed, sellRateCurrent, RATE_SCALER);
                }

                // Simplified for: (totalEarnings * FixedPoint96.Q96) / (orderPool.sellRateCurrent / RATE_SCALER);
                uint256 accruedEarningsFactor =
                    Math.mulDiv(totalEarnings * FixedPoint96.Q96, RATE_SCALER, orderPool.sellRateCurrent);

                self.orderPool0For1.advanceToInterval(
                    params.nextTimestamp, params.zeroForOne ? accruedEarningsFactor : 0
                );
                self.orderPool1For0.advanceToInterval(
                    params.nextTimestamp, params.zeroForOne ? 0 : accruedEarningsFactor
                );

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
