// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {OrderPool} from "@lib/OrderPool.sol";

interface ITWAMM {
    error InvalidTargetTimestamp();

    /// @notice Thrown when account other than owner attempts to interact with an order
    /// @param owner The owner of the order
    /// @param currentAccount The invalid account attempting to interact with the order
    error MustBeOwner(address owner, address currentAccount);

    /// @notice Thrown when trying to submit an order with an expiration that isn't on the interval.
    /// @param expiration The expiration timestamp of the order
    error ExpirationNotOnInterval(uint256 expiration);

    /// @notice Thrown when trying to submit an order with an expiration time in the past.
    /// @param expiration The expiration timestamp of the order
    error ExpirationLessThanBlocktime(uint256 expiration);

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

    /// @notice Emitted when a new long term order is submitted
    /// @param poolId The id of the corresponding pool
    /// @param orderId The unique identifier of the order, derived as `keccak256` hash of the `OrderKey`
    /// @param owner The owner of the new order
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
    /// @param poolId The id of the corresponding pool
    /// @param owner The owner claiming tokens
    /// @param amount0 The amount of token0 claimed
    /// @param amount1 The amount of token1 claimed
    event ClaimTokens(
        PoolId indexed poolId,
        address indexed owner,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when an order is synced
    /// @param poolId The id of the corresponding pool
    /// @param orderId The unique identifier of the order, derived as `keccak256` hash of the `OrderKey`
    /// @param removeRemaining Indicates whether the remaining order should be canceled at the current interval
    /// @param tokens0OwedDelta Change in owed tokens0
    /// @param tokens1OwedDelta Change in owed tokens1
    /// @param earningsFactorLast The current earningsFactor of the order pool
    event SyncOrder(
        PoolId indexed poolId,
        bytes32 indexed orderId,
        bool removeRemaining,
        uint256 tokens0OwedDelta,
        uint256 tokens1OwedDelta,
        uint256 earningsFactorLast
    );

    /// @notice Submits a new long term order into the TWAMM. Also executes TWAMM orders if not up to date.
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param zeroForOne Trade direction
    /// @param duration Order duration
    /// @param amountIn The amount of sell token to add to the order. Some precision on amountIn may be lost up to the
    /// magnitude of (orderKey.expiration - block.timestamp)
    /// @return orderId The bytes32 ID of the order
    function submitOrder(PoolKey calldata key, bool zeroForOne, uint256 duration, uint256 amountIn)
        external
        returns (bytes32 orderId, OrderKey memory orderKey);

    /// @notice Syncs the current pool and order state
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param orderKey The OrderKey for which to identify the order
    /// @param removeRemaining If true, the order will be removed after syncing
    /// @return tokens0OwedDelta Change to token0 after syncing
    /// @return tokens1OwedDelta Change to token1 after syncing
    function sync(PoolKey calldata key, OrderKey calldata orderKey, bool removeRemaining)
        external
        returns (uint256 tokens0OwedDelta, uint256 tokens1OwedDelta);

    /// @notice Claim tokens owed from TWAMM contract
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @return tokens0Claimed The total token0 amount collected
    /// @return tokens1Claimed The total token1 amount collected
    function claimTokens(PoolKey calldata key) external returns (uint256 tokens0Claimed, uint256 tokens1Claimed);

    /// @notice Executes TWAMM orders on the pool, swapping on the pool itself to make up the difference between the
    /// two TWAMM pools swapping against each other
    /// @param key The pool key associated with the TWAMM
    function executeTWAMMOrders(PoolKey memory key) external;

    function tokensOwed(Currency token, address owner) external returns (uint256);
}
