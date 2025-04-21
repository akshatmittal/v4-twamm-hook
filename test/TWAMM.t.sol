// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {TWAMMExtended} from "./TWAMMExtended.sol";

import {TWAMM, ITWAMM, RATE_SCALER} from "@src/TWAMM.sol";

contract TWAMMTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TWAMMExtended twammHook;
    PoolId poolId;

    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        vm.warp(10_000);

        // `TWAMMExtended` is the same as `TWAMM` with extra helper functions
        bytes memory constructorArgs = abi.encode(manager, uint256(10_000), address(123));
        deployCodeTo("TWAMMExtended.sol:TWAMMExtended", constructorArgs, flags);
        twammHook = TWAMMExtended(flags);

        key = PoolKey(currency0, currency1, 3000, 60, twammHook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        posm.mint(
            key,
            key.tickSpacing * -1,
            key.tickSpacing * 1,
            10 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        posm.mint(
            key,
            key.tickSpacing * -2,
            key.tickSpacing * 2,
            10 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        posm.mint(
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            10 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function testTWAMM_beforeInitialize_SetsLastVirtualOrderTimestamp() public {
        (Currency _token0, Currency _token1) = deployMintAndApprove2Currencies();
        PoolKey memory initKey = PoolKey(_token0, _token1, 0, 60, twammHook);
        PoolId initId = initKey.toId();

        assertEq(twammHook.lastVirtualOrderTimestamp(initId), 0);
        vm.warp(10000);

        manager.initialize(initKey, SQRT_PRICE_1_1);
        assertEq(twammHook.lastVirtualOrderTimestamp(initId), 10000);
    }

    function testTWAMM_submitOrder_StoresOrderWithCorrectPoolAndOrderPoolInfo() public {
        uint160 expiration = 30000;
        uint160 submitTimestamp = 10000;
        uint160 duration = expiration - submitTimestamp;

        ITWAMM.OrderKey memory orderKey = ITWAMM.OrderKey(address(this), expiration, true);

        ITWAMM.Order memory nullOrder = twammHook.getOrder(key, orderKey);
        assertEq(nullOrder.sellRate, 0);
        assertEq(nullOrder.earningsFactorLast, 0);

        vm.warp(10000);

        token0.approve(address(twammHook), 100 ether);
        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 20000, amountIn: 1 ether})
        );

        ITWAMM.Order memory submittedOrder = twammHook.getOrder(key, orderKey);
        (uint256 sellRateCurrent0For1, uint256 earningsFactorCurrent0For1) = twammHook.getOrderPool(key, true);
        (uint256 sellRateCurrent1For0, uint256 earningsFactorCurrent1For0) = twammHook.getOrderPool(key, false);

        assertEq(submittedOrder.sellRate, 1 ether * RATE_SCALER / duration);
        assertEq(submittedOrder.earningsFactorLast, 0);
        assertEq(sellRateCurrent0For1, 1 ether * RATE_SCALER / duration);
        assertEq(sellRateCurrent1For0, 0);
        assertEq(earningsFactorCurrent0For1, 0);
        assertEq(earningsFactorCurrent1For0, 0);
    }

    function testTWAMMEndToEndSimSymmetricalOrderPools() public {
        uint256 orderAmount = 1e18;
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 30000, false);

        token0.approve(address(twammHook), 100e18);
        token1.approve(address(twammHook), 100e18);
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-2400, 2400, 10 ether, 0), ZERO_BYTES
        );

        vm.warp(10000);

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 20000, amountIn: orderAmount})
        );

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: false, duration: 20000, amountIn: orderAmount})
        );

        vm.warp(20000);
        twammHook.executeTWAMMOrders(key);

        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey1}));
        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey2}));

        uint256 earningsToken0 = twammHook.tokensOwed(key.currency0, address(this));
        uint256 earningsToken1 = twammHook.tokensOwed(key.currency1, address(this));

        assertEq(earningsToken0, orderAmount / 2);
        assertEq(earningsToken1, orderAmount / 2);

        uint256 balance0BeforeTWAMM = MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(twammHook));
        uint256 balance1BeforeTWAMM = MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(twammHook));
        uint256 balance0BeforeThis = key.currency0.balanceOfSelf();
        uint256 balance1BeforeThis = key.currency1.balanceOfSelf();

        vm.warp(30000);
        twammHook.executeTWAMMOrders(key);

        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey1}));
        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey2}));

        twammHook.claimTokensByPoolKey(key);

        assertEq(twammHook.tokensOwed(key.currency0, address(this)), 0);
        assertEq(twammHook.tokensOwed(key.currency1, address(this)), 0);

        uint256 balance0AfterTWAMM = MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(twammHook));
        uint256 balance1AfterTWAMM = MockERC20(Currency.unwrap(key.currency1)).balanceOf(address(twammHook));
        uint256 balance0AfterThis = key.currency0.balanceOfSelf();
        uint256 balance1AfterThis = key.currency1.balanceOfSelf();

        assertEq(balance1AfterTWAMM, 0);
        assertEq(balance0AfterTWAMM, 0);
        assertEq(balance0BeforeTWAMM - balance0AfterTWAMM, orderAmount);
        assertEq(balance0AfterThis - balance0BeforeThis, orderAmount);
        assertEq(balance1BeforeTWAMM - balance1AfterTWAMM, orderAmount);
        assertEq(balance1AfterThis - balance1BeforeThis, orderAmount);
    }

    function testTWAMM_submitOrder_singleSell_zeroForOne_sellRateAndEarningsFactorGetsUpdatedProperly() public {
        /* ITWAMM.OrderKey memory orderKey1 = */
        ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, true);

        token0.approve(address(twammHook), 100e18);
        vm.warp(10000);

        twammHook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 20000, amountIn: 1e18}));

        vm.warp(30000);

        twammHook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 10000, amountIn: 1e18}));

        vm.warp(40000);

        ITWAMM.Order memory submittedOrder = twammHook.getOrder(key, orderKey2);
        (, uint256 earningsFactorCurrent) = twammHook.getOrderPool(key, true);
        assertEq(submittedOrder.sellRate, 1 ether * RATE_SCALER / 10000);
        assertEq(submittedOrder.earningsFactorLast, earningsFactorCurrent);
    }

    function testTWAMM_submitOrder_singleSell_OneForZero_sellRateAndEarningsFactorGetsUpdatedProperly() public {
        /* ITWAMM.OrderKey memory orderKey1 = */
        ITWAMM.OrderKey(address(this), 30000, false);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, false);

        token1.approve(address(twammHook), 100e18);
        vm.warp(10000);

        twammHook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: false, duration: 20000, amountIn: 1e18}));

        vm.warp(30000);

        twammHook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: false, duration: 10000, amountIn: 1e18}));

        vm.warp(40000);

        ITWAMM.Order memory submittedOrder = twammHook.getOrder(key, orderKey2);
        (, uint256 earningsFactorCurrent) = twammHook.getOrderPool(key, false);
        assertEq(submittedOrder.sellRate, 1 ether * RATE_SCALER / 10000);
        assertEq(submittedOrder.earningsFactorLast, earningsFactorCurrent);
    }

    function testTWAMM_submitOrder_revertsIfPoolNotInitialized() public {
        /* ITWAMM.OrderKey memory orderKey1 = */
        ITWAMM.OrderKey(address(this), 30000, true);
        PoolKey memory invalidPoolKey = key;
        invalidPoolKey.fee = 1000;

        token0.approve(address(twammHook), 100e18);
        vm.warp(10000);

        vm.expectRevert(ITWAMM.NotInitialized.selector);

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: invalidPoolKey, zeroForOne: true, duration: 30000, amountIn: 1e18})
        );
    }

    function testTWAMM_submitOrder_revertsIfExpiryInThePast() public {
        /* uint160 prevTimestamp = 10000; */
        token0.approve(address(twammHook), 100e18);
        vm.warp(20000);

        vm.expectRevert(abi.encodeWithSelector(ITWAMM.ExpirationLessThanBlockTime.selector, block.timestamp));

        twammHook.submitOrder(ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 0, amountIn: 1e18}));
    }

    function testTWAMM_syncOrder_updatesTokensOwedIfCalledAfterExpirationWithNoDelta() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // set timestamp to halfway through the order
        vm.warp(orderKey2.expiration + 10);

        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey2}));

        (uint256 updatedSellRate,) = twammHook.getOrderPool(key, false);
        ITWAMM.Order memory deletedOrder = twammHook.getOrder(key, orderKey2);

        uint256 token0Owed = twammHook.tokensOwed(key.currency0, orderKey2.owner);
        uint256 token1Owed = twammHook.tokensOwed(key.currency1, orderKey2.owner);

        // sellRate is 0, tokens owed equal all of order
        assertEq(updatedSellRate, 0);
        assertEq(token0Owed, orderAmount);
        assertEq(token1Owed, 0);
        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.earningsFactorLast, 0);
    }

    function testTWAMM_executeTWAMMOrders_OneIntervalGas() public {
        /* ITWAMM.OrderKey memory orderKey1 = */
        ITWAMM.OrderKey(address(this), 30000, true);
        /* ITWAMM.OrderKey memory orderKey2 = */
        ITWAMM.OrderKey(address(this), 30000, false);

        token0.approve(address(twammHook), 100 ether);
        token1.approve(address(twammHook), 100 ether);

        vm.warp(10000);

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 20000, amountIn: 1 ether})
        );
        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: false, duration: 20000, amountIn: 5 ether})
        );

        vm.warp(60000);
        twammHook.executeTWAMMOrders(key);
    }

    function testTWAMM_executeTWAMMOrders_TwoIntervalsGas() public {
        token0.approve(address(twammHook), 100 ether);
        token1.approve(address(twammHook), 100 ether);

        vm.warp(10000);

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 20000, amountIn: 1 ether})
        );
        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: false, duration: 20000, amountIn: 5 ether})
        );
        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 30000, amountIn: 2 ether})
        );
        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: false, duration: 30000, amountIn: 2 ether})
        );

        vm.warp(60000);
        twammHook.executeTWAMMOrders(key);
    }

    function testTWAMM_executeTWAMMOrders_singlePoolSell_OneIntervalGas() public {
        token0.approve(address(twammHook), 100 ether);

        vm.warp(10000);

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 20000, amountIn: 1 ether})
        );

        vm.warp(30000);
        twammHook.executeTWAMMOrders(key);
    }

    function testTWAMM_executeTWAMMOrders_SinglePoolSell_twoIntervalsGas() public {
        /* ITWAMM.OrderKey memory orderKey1 = */
        ITWAMM.OrderKey(address(this), 30000, true);
        /* ITWAMM.OrderKey memory orderKey2 = */
        ITWAMM.OrderKey(address(this), 40000, true);

        token0.approve(address(twammHook), 100 ether);

        vm.warp(10000);

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 20000, amountIn: 1 ether})
        );
        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 30000, amountIn: 5 ether})
        );

        vm.warp(60000);
        twammHook.executeTWAMMOrders(key);
    }

    function submitOrdersBothDirections()
        internal
        returns (ITWAMM.OrderKey memory key1, ITWAMM.OrderKey memory key2, uint256 amount)
    {
        amount = 1 ether;

        token0.approve(address(twammHook), amount);
        token1.approve(address(twammHook), amount);

        vm.warp(10000);

        (, key1) = twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 20000, amountIn: amount})
        );
        (, key2) = twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: false, duration: 20000, amountIn: amount})
        );
    }
}
