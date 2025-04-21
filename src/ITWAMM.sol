    // SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {OrderPool} from "@lib/OrderPool.sol";

interface ITWAMM {
    /// @notice Thrown when a pool with native currency is not supported
    error PoolWithNativeNotSupported();

    /// @notice Thrown when the provided targetTimestamp is invalid
    /// @dev This can occur if targetTimestamp is in the future relative to the current block
    ///      or is older than the last virtual order timestamp in the TWAMM logic.
    error InvalidTargetTimestamp();

    /// @notice Thrown when the provided expirationInterval equals 0
    error InvalidExpirationInterval();

    /// @notice Thrown when trying to submit an order with an expiration that isn't on the interval.
    /// @param expiration The expiration timestamp of the order
    error ExpirationNotOnInterval(uint256 expiration);

    /// @notice Thrown when trying to submit an order with an expiration time in the past.
    /// @param expiration The expiration timestamp of the order
    error ExpirationLessThanBlockTime(uint256 expiration);

    /// @notice Thrown when trying to submit an order without initializing TWAMM state first
    error NotInitialized();

    /// @notice Thrown when trying to submit an order that's already ongoing.
    /// @param orderKey The already existing orderKey
    error OrderAlreadyExists(OrderKey orderKey);

    /// @notice Thrown when trying to interact with an order that does not exist.
    /// @param orderKey The already existing orderKey
    error OrderDoesNotExist(OrderKey orderKey);

    /// @notice Thrown when submitting an order with a sellRate of 0
    error SellRateCannotBeZero();

    /// @notice Thrown when hook has been killed.
    error HookKilled();

    /// @notice Thrown when an unauthorized action is attempted.
    error Unauthorized();

    /// @notice Information associated with a long term order
    /// @member sellRate Amount of tokens sold per interval
    /// @member earningsFactorLast The accrued earnings factor from which to start claiming owed earnings for this order
    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    /// @notice Contains full state related to the TWAMM
    /// @member lastVirtualOrderTimestamp Last timestamp in which virtual orders were executed
    /// @member orderPool0For1 Order pool trading token0 for token1 of pool
    /// @member orderPool1For0 Order pool trading token1 for token0 of pool
    /// @member orders Mapping of orderId to individual orders on pool
    struct TWAMMState {
        uint256 lastVirtualOrderTimestamp;
        OrderPool.State orderPool0For1;
        OrderPool.State orderPool1For0;
        mapping(bytes32 => Order) orders;
    }

    /// @notice Information that identifies an order
    /// @member owner Owner of the order
    /// @member expiration Timestamp when the order expires
    /// @member zeroForOne Bool whether the order is zeroForOne
    struct OrderKey {
        address owner;
        uint160 expiration;
        bool zeroForOne;
    }

    /// @notice Data required to sync tokens for multiple orders in a single batch call.
    /// @param key The PoolKey for which to identify the pool
    /// @param orderKey The OrderKey for which to identify the order
    struct SyncParams {
        PoolKey key;
        OrderKey orderKey;
    }

    /**
     * @notice Structure to hold parameters for submitting a TWAMM order.
     * @param key The PoolKey identifying which Uniswap V4 pool this order applies to
     * @param zeroForOne The trade direction of the order (true if selling token0 for token1)
     * @param duration How long the order should stay active
     * @param amountIn The amount of tokens being sold over the specified duration
     */
    struct SubmitOrderParams {
        PoolKey key;
        bool zeroForOne;
        uint256 duration;
        uint256 amountIn;
    }

    /// @notice Emitted when a new long term order is submitted
    /// @param poolId The id of the corresponding pool
    /// @param orderId The unique identifier of the order, derived as `keccak256` hash of the `OrderKey`
    /// @param owner The owner of the new order
    /// @param amountIn The amount for the order
    /// @param expiration The expiration timestamp of the order
    /// @param zeroForOne Whether the order is selling token 0 for token 1
    /// @param sellRate The sell rate of tokens per second being sold in the order
    /// @param earningsFactorLast The current earningsFactor of the order pool
    event SubmitOrder(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        address indexed owner,
        uint256 amountIn,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    /// @notice Emitted when tokens are claimed from the TWAMM
    /// @param token The claimed token
    /// @param owner The owner claiming tokens
    /// @param amount The amount of token claimed
    event ClaimTokens(Currency indexed token, address indexed owner, uint256 amount);

    /// @notice Emitted when an order is synced
    /// @param poolId The id of the corresponding pool
    /// @param orderId The unique identifier of the order, derived as keccak256 hash of the OrderKey
    /// @param assetsRemoved Indicates whether the remaining order has been removed; only if hook has been killed
    /// @param tokens0OwedDelta Change in owed tokens0
    /// @param tokens1OwedDelta Change in owed tokens1
    /// @param earningsFactorLast The current earningsFactor of the order pool
    event SyncOrder(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        bool assetsRemoved,
        uint256 tokens0OwedDelta,
        uint256 tokens1OwedDelta,
        uint256 earningsFactorLast
    );

    /// @notice Emitted when an order is fulfilled within a specific pool.
    /// @dev This event provides detailed information about the state of the pool and the rates before
    //       and after the swap is completed.
    /// @param poolId The id of the corresponding pool where the order was fulfilled.
    /// @param sellRate0for1 The final rate for token0 to token1 at the end of the execute.
    /// @param sellRate1for0 The final rate for token1 to token0 at the end of the execute.
    event Fulfillment(PoolId indexed poolId, uint256 sellRate0for1, uint256 sellRate1for0);

    /// @notice Emitted when a swap is successfully processed.
    /// @dev Contains details about the resulting balance changes.
    /// @param poolId The id of the corresponding pool where the swap occurred.
    /// @param delta The balance changes resulting from the swap
    event SwapExecuted(PoolId indexed poolId, BalanceDelta delta);

    /// @notice Returns the last virtual order execution timestamp for a given pool
    /// @dev This returns the timestamp representing the last time the TWAMM executed orders for the specified pool.
    /// @param key The PoolId that identifies the pool
    /// @return timestamp The timestamp of the last TWAMM order execution for the given pool
    function lastVirtualOrderTimestamp(PoolId key) external view returns (uint256 timestamp);

    /// @notice Kills the hook
    /// @dev Normal pool operations can continue after hook is killed, TWAMM functions are disabled.
    function killHook() external;

    /// @notice Retrieves a specific order from the TWAMM for the given pool.
    /// @dev Provides the entire Order struct associated with the given orderKey in the pool identified by poolKey.
    /// @param poolKey The PoolKey that identifies the relevant pool
    /// @param orderKey The OrderKey for which to identify the order
    /// @return order Information associated with a long term order
    function getOrder(PoolKey calldata poolKey, OrderKey calldata orderKey)
        external
        view
        returns (Order memory order);

    /// @notice Returns the current sell rate and earnings factor for the chosen order pool.
    /// @dev Depending on zeroForOne, returns the state for the pool that sells token0 for token1 or vice versa.
    /// @param key The PoolKey that identifies the relevant pool
    /// @param zeroForOne True for the token0->token1 order pool; False for the token1->token0 order pool
    /// @return sellRateCurrent The current cumulative sell rate (amount of tokens sold per interval)
    /// @return earningsFactorCurrent The current factor used to calculate how many tokens each order is owed
    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent);

    /// @notice Allowing sync multiple orders and then claims the owed tokens.
    /// @dev For each set of parameters, this function calls sync and then claims the owed tokens.
    /// @param params SyncParams for pools to sync
    /// @param currencies Currencies to claim
    /// @return tokensClaimed An array with the amount of tokens claimed
    function batchSyncAndClaimTokens(SyncParams[] calldata params, Currency[] calldata currencies)
        external
        returns (uint256[] memory tokensClaimed);

    /// @notice Allowing sync order and then claims the owed tokens.
    /// @dev For each set of parameters, this function calls sync and then claims the owed tokens.
    /// @param params An array of SyncParams
    /// @return tokens0Claimed An array with the amount of token0 claimed for each order
    /// @return tokens1Claimed An array with the amount of token1 claimed for each order
    function syncAndClaimTokens(SyncParams calldata params)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed);

    /// @notice Submits a new long term order into the TWAMM. Also executes TWAMM orders if not up to date.
    /// @param params An SubmitOrderParams
    /// @return orderId The bytes32 ID of the order
    /// @return orderKey The corresponding order key
    function submitOrder(SubmitOrderParams calldata params)
        external
        returns (bytes32 orderId, OrderKey memory orderKey);

    /// @notice Submits multiple new long term orders into the TWAMM. Also executes TWAMM orders if not up to date.
    /// @param orders An array of SubmitOrderParams
    /// @return orderIds The bytes32 IDs of the newly created orders
    /// @return orderKeys The corresponding order keys for each order
    function batchSubmitOrders(SubmitOrderParams[] calldata orders)
        external
        returns (bytes32[] memory orderIds, OrderKey[] memory orderKeys);

    /// @notice Syncs the current pool and order state
    /// @param params An SyncParams
    /// @return tokens0OwedDelta Change to token0 after syncing
    /// @return tokens1OwedDelta Change to token1 after syncing
    function sync(SyncParams calldata params) external returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta);

    /// @notice Claim tokens owed from TWAMM contract
    /// @param key The PoolKey for which to identify the AMM pool of the order
    /// @return tokens0Claimed The total token0 amount collected
    /// @return tokens1Claimed The total token1 amount collected
    function claimTokensByPoolKey(PoolKey calldata key)
        external
        returns (uint256 tokens0Claimed, uint256 tokens1Claimed);

    /// @notice Claims tokens owed from the TWAMM contract in a batch for multiple currencies.
    /// @param currencies An array of currency addresses for which the caller wants to claim tokens.
    /// @return tokensClaimed An array containing the total amount of tokens claimed for each corresponding currency.
    function claimTokensByCurrencies(Currency[] calldata currencies)
        external
        returns (uint256[] memory tokensClaimed);

    /// @notice Executes TWAMM orders on the pool, swapping on the pool itself to make up the difference between the
    /// two TWAMM pools swapping against each other
    /// @param key The pool key associated with the TWAMM
    function executeTWAMMOrders(PoolKey memory key) external;

    /// @notice Executes all outstanding TWAMM orders on the specified pool, up to the target timestamp.
    /// @param key The pool key associated with the TWAMM.
    /// @param targetTimestamp The timestamp until which to process outstanding TWAMM orders (must be >= lastVirtualOrderTimestamp and <= block.timestamp).
    function executeTWAMMOrders(PoolKey memory key, uint256 targetTimestamp) external;
}
