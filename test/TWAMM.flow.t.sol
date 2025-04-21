// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

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

import {TWAMM, ITWAMM, RATE_SCALER} from "@src/TWAMM.sol";

contract TWAMMFlowTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TWAMM twammHook;
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

        bytes memory constructorArgs = abi.encode(manager, uint256(10_000), address(123));
        deployCodeTo("TWAMM.sol:TWAMM", constructorArgs, flags);
        twammHook = TWAMM(flags);

        key = PoolKey(currency0, currency1, 0, 60, twammHook);
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // This test assumes effectively unlimited liquidity
        posm.mint(
            key,
            key.tickSpacing * -1,
            key.tickSpacing * 1,
            1000 ether,
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
            1000 ether,
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
            1000 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function test_TWAMM_Flow_SwapTrigger() public {
        uint256 orderDuration = 20_000;

        vm.warp(10_000);
        ITWAMM.OrderKey memory oKey = _submitOrderSingleDirection(true, 1 ether, orderDuration);

        (uint256 sellRateCurrent,) = twammHook.getOrderPool(key, true);

        assertEq(token0.balanceOf(address(twammHook)), 1 ether);
        assertEq(sellRateCurrent, 1 ether * RATE_SCALER / orderDuration);

        // set timestamp to halfway through the order
        vm.warp(20_000);

        swap(key, false, -int256(0.0001 ether), ZERO_BYTES);

        uint256 balance0Before;
        uint256 balance1Before;
        uint256 balance0After;
        uint256 balance1After;

        (balance0Before, balance1Before) = (key.currency0.balanceOfSelf(), key.currency1.balanceOfSelf());
        twammHook.syncAndClaimTokens(ITWAMM.SyncParams({key: key, orderKey: oKey}));

        (balance0After, balance1After) = (key.currency0.balanceOfSelf(), key.currency1.balanceOfSelf());

        assertEq(balance0After - balance0Before, 0); // It's a zeroForOne trade
        assertApproxEqRel(balance1After - balance1Before, 0.5 ether, 0.01e18);
        console2.log(balance1After - balance1Before);

        // Much further in the future
        vm.warp(100_000);

        swap(key, true, -int256(0.0001 ether), ZERO_BYTES);

        (balance0Before, balance1Before) = (key.currency0.balanceOfSelf(), key.currency1.balanceOfSelf());
        twammHook.syncAndClaimTokens(ITWAMM.SyncParams({key: key, orderKey: oKey}));
        (balance0After, balance1After) = (key.currency0.balanceOfSelf(), key.currency1.balanceOfSelf());

        assertEq(balance0After - balance0Before, 0); // It's a zeroForOne trade
        assertApproxEqRel(balance1After - balance1Before, 0.5 ether, 0.01e18);
        console2.log(balance1After - balance1Before);
    }

    function test_TWAMM_Flow_PartialExecution() public {
        uint256 orderDuration = 20_000;

        vm.warp(10_000);
        _submitOrderSingleDirection(true, 1 ether, orderDuration);

        (uint256 sellRateCurrent,) = twammHook.getOrderPool(key, true);

        assertEq(token0.balanceOf(address(twammHook)), 1 ether);
        assertEq(sellRateCurrent, 1 ether * RATE_SCALER / orderDuration);

        console2.log(token0.balanceOf(address(twammHook)));
        console2.log(token1.balanceOf(address(twammHook)));

        vm.warp(20_000);
        swap(key, false, -int256(0.0001 ether), ZERO_BYTES);

        console2.log(token0.balanceOf(address(twammHook)));
        console2.log(token1.balanceOf(address(twammHook)));

        vm.warp(40_000);
        swap(key, false, -int256(0.0001 ether), ZERO_BYTES);

        console2.log(token0.balanceOf(address(twammHook)));
        console2.log(token1.balanceOf(address(twammHook)));
    }

    function test_TWAMM_Flow_PartialCross() public {
        uint256 orderDuration = 20_000;

        vm.warp(10_000);
        ITWAMM.OrderKey memory oKey1 = _submitOrderSingleDirection(true, 1 ether, orderDuration);
        ITWAMM.OrderKey memory oKey2 = _submitOrderSingleDirection(false, 0.5 ether, orderDuration);

        (uint256 sellRateCurrent,) = twammHook.getOrderPool(key, true);

        assertEq(token0.balanceOf(address(twammHook)), 1 ether);
        assertEq(sellRateCurrent, 1 ether * RATE_SCALER / orderDuration);

        console2.log(token0.balanceOf(address(twammHook)));
        console2.log(token1.balanceOf(address(twammHook)));

        vm.warp(20_000);
        swap(key, false, -int256(0.0001 ether), ZERO_BYTES);

        console2.log(token0.balanceOf(address(twammHook)));
        console2.log(token1.balanceOf(address(twammHook)));

        vm.warp(40_000);
        swap(key, false, -int256(0.0001 ether), ZERO_BYTES);

        console2.log(token0.balanceOf(address(twammHook)));
        console2.log(token1.balanceOf(address(twammHook)));

        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: oKey1}));

        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: oKey2}));

        twammHook.claimTokensByPoolKey(key);
    }

    function testTWAMM_updatedOrder_CalculateTokensOwedAfterExpiration() public {
        uint256 orderAmount = 1 ether;

        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 20000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 20000, false);

        token0.approve(address(twammHook), type(uint256).max);
        token1.approve(address(twammHook), type(uint256).max);

        vm.warp(10000);
        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: true, duration: 10000, amountIn: orderAmount})
        );

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: false, duration: 10000, amountIn: orderAmount})
        );

        _submitOrderAs(address(0xA2), true, orderAmount * 2, 50000);
        _submitOrderAs(address(0xA2), false, orderAmount * 2, 50000);

        vm.warp(40000);
        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey1}));

        twammHook.sync(ITWAMM.SyncParams({key: key, orderKey: orderKey2}));

        uint256 token0Owed = twammHook.tokensOwed(key.currency0, orderKey2.owner);
        uint256 token1Owed = twammHook.tokensOwed(key.currency1, orderKey2.owner);

        assertEq(token0Owed, orderAmount);
        assertEq(token1Owed, orderAmount);
    }

    function testTWAMM_flow_executeTWAMMOrders_TwoIntervals() public {
        vm.warp(10000);

        ITWAMM.OrderKey memory oKey1 = _submitOrderAs(address(0xC1), true, 1 ether, 20000);
        ITWAMM.OrderKey memory oKey2 = _submitOrderAs(address(0xC2), false, 5 ether, 20000);
        ITWAMM.OrderKey memory oKey3 = _submitOrderAs(address(0xC3), true, 2 ether, 30000);
        ITWAMM.OrderKey memory oKey4 = _submitOrderAs(address(0xC4), false, 2 ether, 30000);

        vm.warp(60000);
        twammHook.executeTWAMMOrders(key);

        _updateOrderAndClaim(oKey1);
        _updateOrderAndClaim(oKey2);
        _updateOrderAndClaim(oKey3);
        _updateOrderAndClaim(oKey4);

        assertApproxEqRel(key.currency1.balanceOf(address(0xC1)), 1 ether, 0.02e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xC2)), 5 ether, 0.02e18);
        assertApproxEqRel(key.currency1.balanceOf(address(0xC3)), 2 ether, 0.02e18);
        assertApproxEqRel(key.currency0.balanceOf(address(0xC4)), 2 ether, 0.02e18);
    }

    function _updateOrderAndClaim(ITWAMM.OrderKey memory oKey) internal {
        vm.startPrank(oKey.owner);
        twammHook.syncAndClaimTokens(ITWAMM.SyncParams({key: key, orderKey: oKey}));
        vm.stopPrank();
    }

    function _submitOrderAs(address owner, bool zeroForOne, uint256 amount, uint160 duration)
        internal
        returns (ITWAMM.OrderKey memory oKey)
    {
        if (zeroForOne) {
            token0.transfer(address(owner), amount);
        } else {
            token1.transfer(address(owner), amount);
        }

        vm.startPrank(owner);
        token0.approve(address(twammHook), amount);
        token1.approve(address(twammHook), amount);

        (, oKey) = twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amount})
        );
        vm.stopPrank();
    }

    function _submitOrderSingleDirection(bool zeroForOne, uint256 amount, uint256 duration)
        internal
        returns (ITWAMM.OrderKey memory oKey)
    {
        oKey = ITWAMM.OrderKey(address(this), uint160(block.timestamp + duration), zeroForOne);

        token0.approve(address(twammHook), amount);
        token1.approve(address(twammHook), amount);

        twammHook.submitOrder(
            ITWAMM.SubmitOrderParams({key: key, zeroForOne: zeroForOne, duration: duration, amountIn: amount})
        );
    }
}
